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
local Types = require(script.Parent.Types)

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
function Raycast.buildRayParams(source: Types.EntityLike?, ignoreInstances: { Instance }?): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
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
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	return params
end

-- Sweeps the projectile's body along `displacement`. Returns the contact as a
-- plain table (see Types.Contact) or nil. Distance is how far the ray -- or
-- the sphere's center -- travelled, which is what the time accounting in
-- init.luau needs; for a Spherecast, Position is the surface point instead.
function Raycast.castMovement(projectile: State, origin: Vector3, displacement: Vector3, overrideParams: RaycastParams?): Types.Contact?
	local params = overrideParams or projectile._rayParams
	local result
	if projectile.Radius > 0 then
		-- Sweeping a sphere along a line is exactly a capsule: a cylindrical
		-- body of Radius around this segment plus spherical caps at both ends.
		-- Adjacent adaptive substeps share the cap at their common joint, so
		-- curved paths have no wedge-shaped collision gaps.
		result = workspace:Spherecast(origin, projectile.Radius, displacement, params)
	else
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
	hurtbox: Types.Hurtbox?
): Verdict
	if entity == projectile.Source or projectile._ignore[entity] then
		-- can't collide with ourselves or an already-pierced target
		nudgePast(projectile, contact.Position)
		return "pass"
	end
	local filter = projectile.Filter
	if filter and not filter(entity) then
		return "fallthrough"
	end

	projectile.OnHit:Fire(Raycast.buildHitInfo(contact, entity, hurtbox))
	if projectile.PiercesLeft > 0 then
		projectile.PiercesLeft -= 1
		projectile.DamageMultiplier *= (1 - projectile.PierceFalloff)
		projectile._ignore[entity] = true
		nudgePast(projectile, contact.Position)
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
			projectile.OnHit:Fire(Raycast.buildHitInfo(contact, entity, nil))
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
		if projectile._beamTurns then table.insert(projectile._beamTurns, contact.Position) end
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
		projectile.OnHit:Fire(Raycast.buildHitInfo(contact, entity, nil))
		return "bounce", nil
	end

	projectile.OnHit:Fire(Raycast.buildHitInfo(contact, entity, nil))
	return "destroy", "world"
end

return Raycast
