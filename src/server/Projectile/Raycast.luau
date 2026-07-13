--!optimize 2
--[[
	Projectile/Raycast.luau
	Physical raycast/spherecast movement, world/entity hit resolution, and
	wall penetration. Raycast.Methods gets mixed onto the Projectile class by
	init.luau (so self:_resolveHit(result) etc. keep working unchanged).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Entity = require(Shared.Entity)
local ChunkManager = require(Shared.ChunkManager)

local Math = require(script.Parent.Math)
local Replication = require(script.Parent.Replication)

local Raycast = {}
Raycast.Methods = {}

-- Built once per projectile and cached on it (Source never changes after
-- construction), reused for every raycast that projectile makes -- Roblox
-- re-evaluates FilterDescendantsInstances against the live scene at cast time, so
-- one instance is safe to reuse across many casts/frames; this only removes the
-- allocation churn of rebuilding it every substep, not a correctness change.
-- NOTE: if a future feature needs to grow the exclude list dynamically (e.g.
-- adding pierced entities instead of the current position-nudge approach),
-- mutating `ignore` in place won't take effect -- FilterDescendantsInstances
-- would need reassigning.
function Raycast.buildRayParams(projectile)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	local source = projectile.Source
	if source and source.Instance then
		table.insert(ignore, source.Instance)
	end
	-- Excluded independently of Source: Source only exists once the firing
	-- entity is registered with the Entity system (see PlayerManager.server.luau),
	-- so a shot fired in the window before that registration lands would
	-- otherwise have nothing excluding the shooter's own character from this
	-- raycast -- IgnoreInstances closes that gap without depending on timing.
	if projectile.IgnoreInstances then
		for _, instance in projectile.IgnoreInstances do
			table.insert(ignore, instance)
		end
	end
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	return params
end

function Raycast.castMovement(projectile, origin: Vector3, displacement: Vector3)
	local params = projectile._rayParams
	if projectile.Radius > 0 then
		return workspace:Spherecast(origin, projectile.Radius, displacement, params)
	end
	return workspace:Raycast(origin, displacement, params)
end

-- Does the chunk containing `position` currently hold any entities? Drives the
-- high/low resolution decision each frame.
function Raycast.chunkHasEntities(position: Vector3): boolean
	local chunk = ChunkManager.GetChunk(position)
	return chunk ~= nil and chunk.EntityCount > 0
end

-- Builds the { CFrame, Part, Entity?, Hurtbox? } table passed to every
-- projectile.OnHit listener -- see the module doc comment's "Events"
-- section. `result` is a RaycastResult (or an equivalent plain table shape
-- for a bounce/penetration point); entity is nil for a pure world/wall
-- contact. hurtboxName is "Head" | "Body" | nil -- see _resolveHit /
-- RewindHit, which resolve it analytically against
-- entity:GetHeadPosition()/GetBodyPosition() (see Entity.luau's "Head +
-- Body hurtboxes" section).
function Raycast.buildHitInfo(result, entity, hurtboxName: string?)
	local normal = result.Normal and Math.safeUnit(result.Normal, Vector3.zAxis) or Vector3.zAxis
	return {
		CFrame = CFrame.lookAt(result.Position, result.Position + normal),
		Part = result.Instance,
		Entity = entity,
		Hurtbox = hurtboxName,
	}
end

-- Broadcasts a single movement raycast segment for debug visualization.
-- lowRes marks the coarse casts taken through empty (entity-free) chunks.
function Raycast.Methods:_streamRay(from: Vector3, to: Vector3, lowRes: boolean)
	Replication.streamTo(self, "ProjRay", { From = from, To = to, LowRes = lowRes })
end

-- Handles the case where a raycast (or a lag-compensated rewind check, see
-- RewindHit) resolved to hitting `entity` at `result`. Returns "continue" if
-- the projectile keeps flying (pierced, or a self/ignored hit), "destroy" if
-- it called Destroy() itself, or nil if the entity should be treated as a
-- fallthrough (filtered out) -- the caller decides what happens next
-- (bounce/world resolution).
function Raycast.Methods:_resolveEntityHit(entity, result, hurtboxName: string?): string?
	if entity == self.Source or self._ignore[entity] then
		-- can't collide with ourselves or an already-pierced target;
		-- nudge past the surface and keep going
		self.Position = result.Position + Math.safeUnit(self.Velocity, Vector3.zAxis) * (self.Radius + 0.1)
		return "continue"
	end
	if self.Filter and not self.Filter(entity) then
		return nil -- fallthrough: filtered out, treat like world geometry
	end

	self.OnHit:Fire(Raycast.buildHitInfo(result, entity, hurtboxName))
	if self.PiercesLeft > 0 then
		self.PiercesLeft -= 1
		self.DamageMultiplier *= (1 - self.PierceFalloff)
		self._ignore[entity] = true
		self.Position = result.Position + Math.safeUnit(self.Velocity, Vector3.zAxis) * (self.Radius + 0.1)
		return "continue"
	end
	self:Destroy(result, "entity")
	return "destroy"
end

-- Returns "continue" | "destroy" after resolving a physical raycast hit. A
-- bounce marks _bouncedThisTick and immediately flushes a one-shot ProjMove
-- correction (Bounced = true) below -- this is now the ONLY streaming a
-- non-homing bouncing projectile ever gets; it tells rendering clients to
-- snap instead of tween (see ProjectileClient) and re-baseline their local
-- physics from this post-reflection Position/Velocity.
function Raycast.Methods:_resolveHit(result)
	local instance = result.Instance
	local entity = instance and Entity.Get(instance)

	if entity then
		-- Head/Body classification is purely analytic here (no synthetic
		-- hurtbox Parts, no CanQuery/CollisionGroup tricks -- see the module
		-- doc comment's "Head + Body hurtboxes" section): the raycast hits
		-- whatever real rig geometry is physically in the way, exactly as
		-- before this feature existed; we just check whether that hit POINT
		-- happens to fall within HeadRadius of the entity's Head center.
		local hurtboxName = "Body"
		local headPosition = entity:GetHeadPosition()
		if headPosition and (result.Position - headPosition).Magnitude <= entity.HeadRadius then
			hurtboxName = "Head"
		end

		local verdict = self:_resolveEntityHit(entity, result, hurtboxName)
		if verdict then
			return verdict
		end
		-- fallthrough (filtered out): treat like world geometry below
	end

	-- world geometry (or a filtered-out entity): try to punch straight through
	-- before considering a bounce -- see _attemptPenetration / the module doc
	-- comment's config section.
	if self.Penetration > 0 then
		local exitPosition = self:_attemptPenetration(result)
		if exitPosition then
			self.OnHit:Fire(Raycast.buildHitInfo(result, entity))
			self.Position = exitPosition
			return "continue"
		end
		-- Blocked (wall thicker than remaining Penetration): fall through to
		-- the normal bounce/destroy resolution below, same as if Penetration
		-- had been 0 all along.
	end

	-- world geometry (or a filtered-out entity): bounce if we can
	if self.BouncesLeft > 0 then
		self.BouncesLeft -= 1
		local normal = result.Normal
		local reflected = self.Velocity - 2 * self.Velocity:Dot(normal) * normal
		self.Velocity = reflected * self.Restitution
		self.Position = result.Position + normal * (self.Radius + 0.05)
		-- Flags this tick's streamed position as a bounce (see the module doc
		-- comment / _checkSyncTransition's Step-level reset): the client must
		-- SNAP to it instead of tweening a straight line from its pre-bounce
		-- position, which would visibly cut through whatever surface sits
		-- between the two -- exactly where the bounce happened.
		self._bouncedThisTick = true
		self._bouncedNormal = normal
		-- Flush this bounce's snap-to-position immediately instead of waiting
		-- for the end-of-frame batch in the server step loop. If this is the
		-- last bounce (BouncesLeft just hit 0) and the reflected path clips
		-- more geometry later in this SAME tick's substep loop, that next hit
		-- destroys the projectile and fires ProjHit synchronously -- before
		-- Step() even returns -- so the outer loop's batching never gets a
		-- chance to queue this update at all (its "not alive" branch queues
		-- nothing). Without this, the client would never learn a bounce
		-- happened here and would keep coasting its stale pre-bounce
		-- trajectory straight through the surface until ProjHit teleports it
		-- to the real final position. Sending here guarantees the snap
		-- always reaches the client before any same-tick Destroy's ProjHit.
		-- This fires unconditionally on every bounce regardless of homing
		-- state -- it is the sole sync mechanism for a non-homing bouncer
		-- (see Replication.isSynced): the client is otherwise fully unsynced
		-- and coasts on local physics between bounces.
		if self.Visualize then
			Replication.flushMoveBatch({ {
				VisualRange = self.VisualRange,
				Position = self.Position,
				Payload = {
					Id = self.Id,
					Position = self.Position,
					Velocity = self.Velocity,
					Bounced = true,
					Normal = normal,
				},
			} })
		end
		-- Consumed for this tick already -- clear it so the outer loop's
		-- end-of-frame batch (only reachable while actively homing; see
		-- Replication.isSynced) doesn't re-snap/re-flash a second time at
		-- wherever the projectile ends up after further substeps this same
		-- tick.
		self._bouncedThisTick = false
		if self.OnBounce then
			task.spawn(self.OnBounce, self, result)
		end
		self.OnHit:Fire(Raycast.buildHitInfo(result, entity))
		return "continue"
	end

	self.OnHit:Fire(Raycast.buildHitInfo(result, entity))
	self:Destroy(result, "world")
	return "destroy"
end

-- Attempts to punch this projectile through the wall it just hit. Probes a
-- point Penetration studs further along the ray past the entry point, then
-- raycasts BACKWARD from that probe to the entry point, whitelisted to ONLY
-- the part that was just hit:
--  - Hit (not nil): the probe already crossed back into the SAME part from
--    outside it, meaning the wall's far/exit surface is somewhere between the
--    probe and the entry point -- i.e. the wall is thinner than the current
--    Penetration budget. The distance from the entry point to that exit
--    surface is the wall's actual thickness; that amount (not the probe
--    distance) is subtracted from Penetration, since a thin wall should
--    barely dent the budget and a thick one should nearly exhaust it.
--  - Nil: the probe point is still INSIDE the wall's solid (Roblox raycasts
--    never register a hit against a part the ray starts inside of), meaning
--    the wall is thicker than the entire Penetration budget -- can't punch
--    through at all.
-- Returns the position just past the exit surface on success, or nil if
-- blocked (caller falls through to bounce/destroy as normal).
function Raycast.Methods:_attemptPenetration(result): Vector3?
	local instance = result.Instance
	if not instance then
		return nil
	end

	local direction = Math.safeUnit(self.Velocity, Vector3.zAxis)
	local probeOrigin = result.Position + direction * self.Penetration

	local probeParams = RaycastParams.new()
	probeParams.FilterType = Enum.RaycastFilterType.Include
	probeParams.FilterDescendantsInstances = { instance }

	local probeResult = workspace:Raycast(probeOrigin, result.Position - probeOrigin, probeParams)
	if not probeResult then
		return nil
	end

	local thickness = (probeResult.Position - result.Position).Magnitude
	self.Penetration -= thickness
	if self.Penetration < 0 then
		-- Ran out of power exactly on this wall -- treat as blocked, same as
		-- the nil case above.
		return nil
	end

	return probeResult.Position + direction * (self.Radius + 0.1)
end

return Raycast
