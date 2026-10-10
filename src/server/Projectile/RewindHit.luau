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

-- A frame-shared historical broadphase. Index the envelope of every retained
-- root sample plus the live root, inflated by BOTH hurtboxes. Interpolation
-- stays inside that envelope, even after a teleport or a chunk transition.
-- Queries visit nearby 3D cells, independent of delayed current membership.
local CELL = 64
local MAX_CELLS = 256
local buckets: { [Vector3]: { any } } = {}
local overflow: { any } = {}
local indexed: { any } = {}
local whitelist: { [any]: boolean } = {}
local indexReady = false
local indexVersion = -1

function RewindHit.BeginFrame()
	indexReady = false
	-- Drop entity references even in frames with no rewound shots.
	table.clear(buckets)
	table.clear(overflow)
	table.clear(indexed)
end

local function cellRange(lo: Vector3, hi: Vector3): (Vector3, Vector3, number)
	local a = Vector3.new(math.floor(lo.X / CELL), math.floor(lo.Y / CELL), math.floor(lo.Z / CELL))
	local b = Vector3.new(math.floor(hi.X / CELL), math.floor(hi.Y / CELL), math.floor(hi.Z / CELL))
	return a, b, (b.X - a.X + 1) * (b.Y - a.Y + 1) * (b.Z - a.Z + 1)
end

local function buildIndex()
	table.clear(buckets)
	table.clear(overflow)
	indexed = Entity.GetAll()
	for _, entity in indexed do
		if entity.IsDestroyed then continue end
		local position = entity:GetPosition()
		local lo, hi = position, position
		for _, sample in entity._history do
			lo, hi = lo:Min(sample.Position), hi:Max(sample.Position)
		end
		local bodyOffset = entity.BodyOffset
		local bodyRadius = Vector3.one * entity.HitboxRadius
		local lowOffset, highOffset = bodyOffset - bodyRadius, bodyOffset + bodyRadius
		if entity._headOffset then
			local headOffset = entity._headOffset + entity.HeadOffset
			local headRadius = Vector3.one * entity.HeadRadius
			lowOffset = lowOffset:Min(headOffset - headRadius)
			highOffset = highOffset:Max(headOffset + headRadius)
		end
		local a, b, count = cellRange(lo + lowOffset, hi + highOffset)
		if count > MAX_CELLS then
			-- Huge teleports/radii remain correct without allocating a giant grid.
			table.insert(overflow, entity)
			continue
		end
		for x = a.X, b.X do
			for y = a.Y, b.Y do
				for z = a.Z, b.Z do
					local key = Vector3.new(x, y, z)
					local list = buckets[key]
					if not list then list = {}; buckets[key] = list end
					table.insert(list, entity)
				end
			end
		end
	end
	indexReady = true
	indexVersion = Entity.PositionVersion
end

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
	if not indexReady or indexVersion ~= Entity.PositionVersion then buildIndex() end
	table.clear(whitelist)
	local padding = Vector3.one * projectile.Radius
	local a, b, count = cellRange(from:Min(to) - padding, from:Max(to) + padding)
	if count > MAX_CELLS then
		for _, entity in indexed do whitelist[entity] = true end
	else
		for x = a.X, b.X do
			for y = a.Y, b.Y do
				for z = a.Z, b.Z do
					local list = buckets[Vector3.new(x, y, z)]
					if list then for _, entity in list do whitelist[entity] = true end end
				end
			end
		end
		for _, entity in overflow do whitelist[entity] = true end
	end

	-- Each entity is tested against BOTH its rewound Head and Body spheres --
	-- Head is checked first and wins outright if in range (the two spheres
	-- are independent, not required to nest -- see Entity.luau).
	local filter = projectile.Filter
	local cache = projectile._rewindCache
	for entity in whitelist do
		if not entity.IsDestroyed and entity:IsActive() and entity ~= projectile.Source and not projectile._ignore[entity] and (not filter or filter(entity)) then
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
			table.clear(whitelist)
			return candidate.entity,
				candidate.point,
				SafeMath.direction(from - candidate.point, Vector3.yAxis),
				candidate.hurtbox
		end
	end

	table.clear(candidates)
	table.clear(whitelist)
	return nil, nil, nil, nil
end

return RewindHit
