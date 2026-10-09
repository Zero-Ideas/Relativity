--!native
--!strict
--!optimize 2
--[[
	Projectile/Raycast.luau
	Physical ray/capsule movement casts, world/entity hit resolution, and wall
	penetration. The resolvers decide what a contact does and apply its
	immediate effects (OnHit, pierce bookkeeping, reflection, nudging past the
	surface), then return a Types.Verdict; lifecycle -- Destroy(), time
	accounting -- stays with the caller in init.luau.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Entity = require(Shared:WaitForChild("Entity"))
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local SafeMath = require(Shared:WaitForChild("SafeMath"))

local Replication = require(script.Parent.Replication)
local Occupancy = require(script.Parent.Occupancy)
local Types = require(script.Parent.Types)
local Store = require(script.Parent.Store)
local CollisionLOD = require(script.Parent.CollisionLOD)
local Profile = require(script.Parent.Profile)

type State = Types.State
type Verdict = Types.Verdict

local Raycast = {}

-- Clearance when stepping just past a surface after a pass-through contact.
local PASS_CLEARANCE = 0.1
-- Clearance off a surface after a bounce.
local BOUNCE_CLEARANCE = 0.05

-- Built once per projectile and cached on it (Source never changes after
-- construction), reused for every raycast that projectile makes -- Roblox
-- re-evaluates FilterDescendantsInstances against the live scene at cast time, so
-- one instance is safe to reuse across many casts/frames; this only removes the
-- allocation churn of rebuilding it every substep, not a correctness change.
-- NOTE: if a future feature needs to grow the exclude list dynamically (e.g.
-- adding pierced entities instead of the current position-nudge approach),
-- mutating `ignore` in place won't take effect -- FilterDescendantsInstances
-- would need reassigning.
-- Shared params by content: nothing writes to a projectile's _rayParams, so
-- every projectile ignoring the same instances (a burst, a stress test, one
-- player's shots) uses one RaycastParams instead of building its own. Keyed
-- by a trie of the ignored instances; reset when it grows past
-- MAX_SHARED_PARAMS (dead characters), which only costs a rebuild.
local MAX_SHARED_PARAMS = 1024
local sharedParams: { [any]: any } = {}
local sharedCount = 0
local LEAF = newproxy() -- (trie key for a node's params; can't collide with an Instance)

-- OnHit, if anyone connected (an efficient projectile only has the signal
-- once someone has).
local function fireHit(projectile: any, info: any)
	local signal = Store.Peek(projectile, "OnHit")
	if signal then
		signal:Fire(info)
	end
end

function Raycast.buildRayParams(source: Types.EntityLike?, ignoreInstances: { Instance }?): RaycastParams
	local ignore: { Instance } = {}
	local sourceInstance = source and source.Instance
	if sourceInstance then
		table.insert(ignore, sourceInstance)
	end
	-- Excluded independently of Source: Source only exists once the firing
	-- entity is registered with the Entity system (see PlayerManager.server.luau),
	-- so a shot fired in the window before that registration lands would
	-- otherwise have nothing excluding the shooter's own character from this
	-- raycast -- IgnoreInstances closes that gap without depending on timing.
	if ignoreInstances then
		table.move(ignoreInstances, 1, #ignoreInstances, #ignore + 1, ignore)
	end
	local node = sharedParams
	for _, instance in ignore do
		local nextNode = node[instance]
		if not nextNode then
			nextNode = {}
			node[instance] = nextNode
		end
		node = nextNode
	end
	local shared = node[LEAF]
	if shared then
		return shared
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	sharedCount += 1
	if sharedCount > MAX_SHARED_PARAMS then
		table.clear(sharedParams)
		sharedCount = 0
		return params
	end
	node[LEAF] = params
	return params
end

-- Sweeps the projectile's body along `displacement`. Entity-free chunks use
-- a centerline ray; occupied/boundary chunks retain the full swept radius.
-- The already-computed adaptive-step flag avoids another lookup near entities.
-- Returns the contact as a
-- plain table (see Types.Contact) or nil. Distance is how far the ray -- or
-- the sphere's center -- travelled, which is what the time accounting in
-- init.luau needs; for a Spherecast, Position is the surface point instead.
-- The instances a movement RaycastParams excludes, as a set, for Occupancy:
-- moving parts that belong to them (the shooter's own character...) don't
-- stop a cast from being skipped. Cached per params (they're shared, see
-- buildRayParams), so FilterDescendantsInstances is read once.
local ignoreSets: { [RaycastParams]: { [Instance]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

local function ignoreSetFor(params: RaycastParams): { [Instance]: boolean }
	local set = ignoreSets[params]
	if not set then
		set = {}
		for _, instance in params.FilterDescendantsInstances do
			set[instance] = true
		end
		ignoreSets[params] = set
	end
	return set
end

-- (BeamChain: the set a sleeping beam sample's box test ignores)
Raycast.ignoreSetFor = ignoreSetFor

function Raycast.castMovement(projectile: State, origin: Vector3, displacement: Vector3, overrideParams: RaycastParams?, nearEntities: boolean?): Types.Contact?
	-- Provably empty space: the cast would find nothing, so don't make it
	-- (see Occupancy -- it only says yes when nothing could be in the way).
	-- The projectile's own filter is passed so its shooter doesn't block the
	-- skip; an override (a beam body's params) only ever excludes more.
	local baseParams: RaycastParams = projectile._rayParams
	if Occupancy.SegmentClear(origin, displacement, projectile.Radius, ignoreSetFor(baseParams)) then
		return nil
	end
	local params = overrideParams or baseParams
	local radius = projectile.Radius
	if radius > 0 and not nearEntities then
		radius = CollisionLOD.Radius(ChunkManager.GetEntityChunkMask(), ChunkManager.ChunkSize,
			ChunkManager.UseY, origin, displacement, radius)
	end
	local result
	if radius > 0 then
		-- Sweeping a sphere along a line is exactly a capsule: a cylindrical
		-- body of Radius around this segment plus spherical caps at both ends.
		-- Adjacent adaptive substeps share the cap at their common joint, so
		-- curved paths have no wedge-shaped collision gaps.
		Profile.Count("CastSphere", 1)
		result = workspace:Spherecast(origin, radius, displacement, params)
	else
		Profile.Count("CastRay", 1)
		result = workspace:Raycast(origin, displacement, params)
	end
	if not result then
		return nil
	end
	return {
		Position = result.Position,
		Normal = result.Normal,
		Instance = result.Instance,
		Distance = result.Distance,
	}
end

-- Does the chunk containing `position` currently hold any entities? Drives the
-- high/low resolution decision each substep.
function Raycast.chunkHasEntities(position: Vector3): boolean
	local chunk = ChunkManager.GetChunk(position)
	return chunk ~= nil and chunk.EntityCount > 0
end

-- Builds the table passed to every projectile.OnHit listener -- see the
-- "Events" section in init.luau. `entity` is nil for a pure world/wall contact.
function Raycast.buildHitInfo(contact: Types.Contact, entity: Types.EntityLike?, hurtbox: Types.Hurtbox?): Types.HitInfo
	local normal = SafeMath.direction(contact.Normal, Vector3.zAxis)
	return {
		CFrame = CFrame.lookAt(contact.Position, contact.Position + normal),
		Part = contact.Instance,
		Entity = entity,
		Hurtbox = hurtbox,
	}
end

-- Steps the projectile just past `surface` along its direction of travel.
function Raycast.nudgePast(projectile: State, surface: Vector3)
	projectile.Position = surface
		+ SafeMath.direction(projectile.Velocity, Vector3.zAxis) * (projectile.Radius + PASS_CLEARANCE)
end
local nudgePast = Raycast.nudgePast

-- Resolves `entity` being struck at `contact` (by a raycast, or by a
-- lag-compensated rewind check -- see RewindHit). "destroy" means the caller
-- must Destroy(contact, "entity").
function Raycast.resolveEntityHit(
	projectile: State,
	entity: Types.EntityLike,
	contact: Types.Contact,
	hurtbox: Types.Hurtbox?,
	bodyHit: boolean?
): Verdict
	if entity == projectile.Source or projectile._ignore[entity] then
		-- can't collide with ourselves or an already-pierced target
		if not bodyHit then nudgePast(projectile, contact.Position) end
		return "pass"
	end
	local filter = projectile.Filter
	if filter and not filter(entity) then
		return "fallthrough"
	end

	fireHit(projectile, Raycast.buildHitInfo(contact, entity, hurtbox))
	if projectile.PiercesLeft > 0 then
		projectile.PiercesLeft -= 1
		projectile.DamageMultiplier *= (1 - projectile.PierceFalloff)
		projectile._ignore[entity] = true
		projectile._spanParams = nil -- the pierced set changed; invalidate lazily
		if not bodyHit then nudgePast(projectile, contact.Position) end
		return "pass"
	end
	return "destroy"
end

-- Attempts to punch this projectile through the wall it just hit. Probes a
-- point Penetration studs further along the ray past the entry point, then
-- raycasts BACKWARD from that probe to the entry point, whitelisted to ONLY
-- the part that was just hit:
--  - Hit: the wall's far/exit surface lies between the probe and the entry
--    point, i.e. the wall is thinner than the remaining budget. The wall's
--    actual thickness (not the probe distance) is subtracted, so a thin wall
--    barely dents the budget and a thick one nearly exhausts it.
--  - Nil: the probe point is still INSIDE the wall (Roblox raycasts never hit
--    a part they start inside), so the wall is thicker than the budget.
-- Returns the position just past the exit surface, or nil if blocked.
local function attemptPenetration(projectile: State, contact: Types.Contact): Vector3?
	local instance = contact.Instance
	if not instance then
		return nil
	end

	local direction = SafeMath.direction(projectile.Velocity, Vector3.zAxis)
	local probeOrigin = contact.Position + direction * projectile.Penetration

	local probeParams = RaycastParams.new()
	probeParams.FilterType = Enum.RaycastFilterType.Include
	probeParams.FilterDescendantsInstances = { instance }

	local probeResult = workspace:Raycast(probeOrigin, contact.Position - probeOrigin, probeParams)
	if not probeResult then
		return nil
	end

	local thickness = (probeResult.Position - contact.Position).Magnitude
	projectile.Penetration = math.max(projectile.Penetration - thickness, 0)
	return probeResult.Position + direction * (projectile.Radius + PASS_CLEARANCE)
end

-- Resolves a physical cast contact. Returns the verdict and, for "destroy",
-- the kind to Destroy() with. A bounce queues a one-shot ProjMove correction
-- (Bounced = true) -- the ONLY streaming a non-homing bouncing projectile
-- ever gets; it tells rendering clients to snap instead of tween and to
-- re-baseline their local physics (see ProjectileClient).
function Raycast.resolveHit(projectile: State, contact: Types.Contact): (Verdict, string?)
	local instance = contact.Instance
	local entity: Types.EntityLike? = if instance then Entity.Get(instance) else nil

	if entity then
		-- Head/Body classification is purely analytic: the raycast hits
		-- whatever real rig geometry is physically in the way; we just check
		-- whether that hit POINT falls within HeadRadius of the Head center
		-- (see Entity.luau's "Head + Body hurtboxes" section).
		local hurtbox: Types.Hurtbox = "Body"
		local headPosition = entity:GetHeadPosition()
		if headPosition and (contact.Position - headPosition).Magnitude <= entity.HeadRadius then
			hurtbox = "Head"
		end

		local verdict = Raycast.resolveEntityHit(projectile, entity, contact, hurtbox)
		if verdict == "destroy" then
			return "destroy", "entity"
		elseif verdict ~= "fallthrough" then
			-- (cast: Luau widens the refined literal union back to string)
			return verdict :: Verdict, nil
		end
		-- filtered out: treat like world geometry below
	end

	-- Penetration is tried before bouncing; a wall thicker than the remaining
	-- budget falls through to bounce/destroy as if Penetration were 0.
	if projectile.Penetration > 0 then
		local exitPosition = attemptPenetration(projectile, contact)
		if exitPosition then
			fireHit(projectile, Raycast.buildHitInfo(contact, entity, nil))
			projectile.Position = exitPosition
			return "pass", nil
		end
	end

	if projectile.BouncesLeft > 0 then
		projectile.BouncesLeft -= 1
		local normal = SafeMath.direction(contact.Normal, Vector3.yAxis)
		local velocity = projectile.Velocity
		projectile.Velocity = (velocity - 2 * velocity:Dot(normal) * normal) * projectile.Restitution
		projectile.Position = contact.Position + normal * (projectile.Radius + BOUNCE_CLEARANCE)
		if projectile.Beam and not projectile._spawnStreamed then projectile._beamOrigin = projectile.Position end
		-- Connect the cleared sphere center, not the surface inside its radius.
		if projectile._beamTurns then table.insert(projectile._beamTurns, projectile.Position) end
		-- The client must SNAP on a bounce instead of tweening a straight line
		-- from its pre-bounce position, which would visibly cut through the
		-- surface it bounced off. The snap goes out with this frame's ProjMove
		-- batch (see Replication.queueBounce for why it carries the end-of-frame
		-- pose), even if a later substep this same tick destroys the
		-- projectile; ProjHit is only flushed on a later frame, so the snap
		-- always reaches the client first.
		Replication.queueBounce(projectile, contact.Position, normal)
		local onBounce = projectile.OnBounce
		if onBounce then
			task.spawn(onBounce, projectile, contact)
		end
		fireHit(projectile, Raycast.buildHitInfo(contact, entity, nil))
		return "bounce", nil
	end

	fireHit(projectile, Raycast.buildHitInfo(contact, entity, nil))
	return "destroy", "world"
end

return Raycast
