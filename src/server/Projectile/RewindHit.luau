--!optimize 2
--[[
	Projectile/RewindHit.luau
	Lag-compensated ("rewound") entity hit detection -- the authoritative hit
	check for any shot fired with RewindSeconds > 0 (see Shooter.server.luau),
	which in practice is almost every real networked shot. RewindHit.Methods
	gets mixed onto the Projectile class by init.luau (so
	self:_checkRewoundHit(from, to) keeps working unchanged).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Entity = require(Shared.Entity)
local ChunkManager = require(Shared.ChunkManager)

local Math = require(script.Parent.Math)

local RewindHit = {}
RewindHit.Methods = {}

-- Lag-compensated entity check for one movement substep. Only meaningful while
-- passing through a chunk that contains entities (see `highRes` in init.luau's
-- Step) and only for shots that carry a positive RewindSeconds. Builds its
-- hurtbox whitelist directly from the (loaded) chunk(s) the segment touches --
-- not a radius sweep -- so a projectile only ever considers entities actually
-- in a loaded chunk it's in, per-shooter-desync.
--
-- Two memoization/deferral choices preserve the exact "nearest in-range entity
-- with a clear LOS to `from`" semantics while cutting redundant work:
--  - The rewind instant (os.clock() - RewindSeconds) is pinned for the whole
--    Step (see Step's useRewind setup), and each entity's rewound position is
--    memoized in self._rewindCache. Within a frame RewindSeconds is constant
--    and os.clock() is stable, so an entity rewinds to the same place on every
--    substep -- previously this recomputed GetPositionAt per entity per
--    substep.
--  - LOS verification is deferred: in-range candidates are collected into a
--    reusable buffer, sorted ascending by distance-along-segment, then
--    LOS-checked nearest-first, returning the first whose LOS to `from` is
--    unobstructed. The survivor is exactly the nearest clear entity the old
--    hash-order loop would also have produced, but the raycast count is now the
--    rank of the nearest clear candidate (or N if all blocked) rather than up
--    to N regardless of order -- deterministically O(rank), not O(N) worst-case.
function RewindHit.Methods:_checkRewoundHit(from: Vector3, to: Vector3)
	local whitelist = {}
	for _, position in { from, to } do
		local chunk = ChunkManager.GetChunk(position)
		if chunk and ChunkManager.IsChunkActive(chunk) then
			for entity in chunk.Entities do
				whitelist[entity] = true
			end
		end
	end

	-- Collect in-range candidates (no raycasts yet) into the reusable buffer.
	-- Each entity is tested against BOTH its rewound Head and Body spheres
	-- (see the module doc comment's "Head + Body hurtboxes" section) --
	-- Head is checked first and wins outright if in range (the two spheres
	-- are independent, not required to nest -- see Entity.luau).
	local candidates = self._candidateBuf
	for entity in whitelist do
		if entity ~= self.Source and not self._ignore[entity] and (not self.Filter or self.Filter(entity)) then
			local cache = self._rewindCache[entity]
			if not cache then
				cache = {
					Body = entity:GetBodyPositionAt(self._rewindTime),
					Head = entity:GetHeadPositionAt(self._rewindTime),
				}
				self._rewindCache[entity] = cache
			end

			local matchedHead = false
			if cache.Head then
				local closest, distance = Math.closestPointOnSegment(cache.Head, from, to)
				if distance <= entity.HeadRadius + self.Radius then
					table.insert(candidates, {
						entity = entity,
						point = closest,
						distAlong = (closest - from).Magnitude,
						hurtbox = "Head",
					})
					matchedHead = true
				end
			end
			if not matchedHead then
				local closest, distance = Math.closestPointOnSegment(cache.Body, from, to)
				if distance <= entity.HitboxRadius + self.Radius then
					table.insert(candidates, {
						entity = entity,
						point = closest,
						distAlong = (closest - from).Magnitude,
						hurtbox = "Body",
					})
				end
			end
		end
	end

	-- Nearest-first: sort ascending by distance along the segment, then
	-- LOS-check in order, returning the first unobstructed one. This matches
	-- the old "bestDistAlong, clear only" survivor exactly.
	table.sort(candidates, function(a, b)
		return a.distAlong < b.distAlong
	end)

	for _, c in candidates do
		-- line-of-sight: real geometry must not block the shot before it would
		-- reach this point, so stale rewound data can never be used to hit
		-- someone through a wall. The hit instance must not belong to the
		-- candidate itself, so a target's own body can't block hitting it.
		local los = workspace:Raycast(from, c.point - from, self._rayParams)
		local blocked = los ~= nil
			and (los.Position - from).Magnitude < c.distAlong - 0.5
			and Entity.Get(los.Instance) ~= c.entity
		if not blocked then
			-- drain the buffer for this frame so the next substep starts clean
			-- (Step already clears it, but this keeps the function honest if
			-- ever called from elsewhere).
			table.clear(candidates)
			return c.entity, c.point, Math.safeUnit(from - c.point, Vector3.yAxis), c.hurtbox
		end
	end

	table.clear(candidates)
	return nil
end

return RewindHit
