--!native
--!strict
--!optimize 2
--[[
	Projectile/RewindHit.luau
	Lag-compensated ("rewound") entity hit detection -- the authoritative hit
	check for any shot fired with RewindSeconds > 0 (see Shooter.server.luau),
	which in practice is almost every real networked shot.

	RewindHit.check only answers "which entity, if any, does this segment hit
	from the shooter's point of view"; resolving what the hit does (pierce,
	destroy, events) is Raycast.resolveEntityHit's job.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Entity = require(Shared:WaitForChild("Entity"))
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local SafeMath = require(Shared:WaitForChild("SafeMath"))

local Math = require(script.Parent.Math)
local Types = require(script.Parent.Types)

type State = Types.State

type Candidate = {
	entity: Types.EntityLike,
	point: Vector3,
	distAlong: number,
	hurtbox: Types.Hurtbox,
}

local RewindHit = {}

-- Reused by every check (the server step is single-threaded, and each check
-- drains it before returning) to avoid per-substep allocation churn.
local candidates: { Candidate } = {}

local function byDistance(a: Candidate, b: Candidate): boolean
	return a.distAlong < b.distAlong
end

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
--    Step (see init.luau), and each entity's rewound position is memoized in
--    projectile._rewindCache, so an entity rewinds once per frame rather than
--    once per substep.
--  - LOS verification is deferred: in-range candidates are sorted nearest
--    first and LOS-checked in that order, so the raycast count is the rank of
--    the nearest clear candidate rather than every candidate.
-- Returns entity, contact point, surface normal, hurtbox -- or nil.
function RewindHit.check(
	projectile: State,
	from: Vector3,
	to: Vector3
): (Types.EntityLike?, Vector3?, Vector3?, Types.Hurtbox?)
	local whitelist: { [Types.EntityLike]: boolean } = {}
	for _, position in { from, to } do
		local chunk = ChunkManager.GetChunk(position)
		if chunk and ChunkManager.IsChunkActive(chunk) then
			for entity in chunk.Entities do
				whitelist[entity] = true
			end
		end
	end

	-- Each entity is tested against BOTH its rewound Head and Body spheres --
	-- Head is checked first and wins outright if in range (the two spheres
	-- are independent, not required to nest -- see Entity.luau).
	local filter = projectile.Filter
	local cache = projectile._rewindCache
	for entity in whitelist do
		if entity ~= projectile.Source and not projectile._ignore[entity] and (not filter or filter(entity)) then
			local rewound = cache[entity]
			if not rewound then
				rewound = {
					Body = entity:GetBodyPositionAt(projectile._rewindTime),
					Head = entity:GetHeadPositionAt(projectile._rewindTime),
				}
				cache[entity] = rewound
			end

			local head = rewound.Head
			local matchedHead = false
			if head then
				local closest, distance = Math.closestPointOnSegment(head, from, to)
				if distance <= entity.HeadRadius + projectile.Radius then
					local candidate: Candidate = {
						entity = entity,
						point = closest,
						distAlong = (closest - from).Magnitude,
						hurtbox = "Head",
					}
					table.insert(candidates, candidate)
					matchedHead = true
				end
			end
			if not matchedHead then
				local closest, distance = Math.closestPointOnSegment(rewound.Body, from, to)
				if distance <= entity.HitboxRadius + projectile.Radius then
					local candidate: Candidate = {
						entity = entity,
						point = closest,
						distAlong = (closest - from).Magnitude,
						hurtbox = "Body",
					}
					table.insert(candidates, candidate)
				end
			end
		end
	end

	table.sort(candidates, byDistance)

	for _, candidate in candidates do
		-- line-of-sight: real geometry must not block the shot before it would
		-- reach this point, so stale rewound data can never be used to hit
		-- someone through a wall. The hit instance must not belong to the
		-- candidate itself, so a target's own body can't block hitting it.
		local los = workspace:Raycast(from, candidate.point - from, projectile._rayParams)
		local blocked = los ~= nil
			and (los.Position - from).Magnitude < candidate.distAlong - 0.5
			and Entity.Get(los.Instance) ~= candidate.entity
		if not blocked then
			table.clear(candidates)
			return candidate.entity,
				candidate.point,
				SafeMath.direction(from - candidate.point, Vector3.yAxis),
				candidate.hurtbox
		end
	end

	table.clear(candidates)
	return nil, nil, nil, nil
end

return RewindHit
