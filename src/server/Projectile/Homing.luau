--!native
--!strict
--!optimize 2
--[[
	Projectile/Homing.luau
	Target acquisition and steering. Homing.update(projectile, dt) runs once
	per substep from init.luau's Step; it only ever changes the projectile's
	HomingTarget, its homing timers, and the direction of its Velocity.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local Entity = require(Shared:WaitForChild("Entity"))

local Math = require(script.Parent.Math)
local Types = require(script.Parent.Types)

type State = Types.State

local Homing = {}

function Homing.targetPosition(target: Types.HomingTarget?): Vector3?
	if target == nil then
		return nil
	end
	if typeof(target) == "Vector3" then
		return target
	end
	if typeof(target) == "Instance" then
		if target:IsA("BasePart") then
			return target.Position
		elseif target:IsA("Model") then
			return target:GetPivot().Position
		end
		return nil
	end
	-- an Entity
	if target.IsDestroyed then
		return nil
	end
	return target:GetPosition()
end

local function isEligible(projectile: State, homing: Types.Homing, entity: Types.EntityLike): boolean
	if entity == projectile.Source or entity.IsDestroyed then
		return false
	end
	local filter = projectile.Filter
	if filter and not filter(entity) then
		return false
	end
	local tags = homing.TargetTags
	if tags then
		for _, tag in tags do
			if entity:HasTag(tag) then
				return true
			end
		end
		return false
	elseif homing.TargetTag then
		return entity:HasTag(homing.TargetTag)
	end
	return true
end

-- Finds the nearest valid homing target: entities matching TargetTag/TargetTags
-- (or ALL entities if neither given), excluding the projectile's own Source and
-- anything its Filter rejects. Uses ChunkManager's spatial index when
-- AcquireRadius is set (the normal case -- every real spawn site sets one), so
-- cost scales with local entity density, not total entity/projectile count; the
-- unbounded case (rare) falls back to a full scan.
function Homing.acquireTarget(projectile: State, homing: Types.Homing, position: Vector3): Types.EntityLike?
	local function eligible(entity: Types.EntityLike): boolean
		return isEligible(projectile, homing, entity)
	end

	local radius = homing.AcquireRadius
	local candidates: { Types.EntityLike }
	local bestDistance = math.huge
	if radius then
		candidates = ChunkManager.GetEntitiesInRadius(position, radius, { Filter = eligible })
		bestDistance = radius
	else
		candidates = {}
		local pool = if homing.TargetTag then Entity.GetTagged(homing.TargetTag) else Entity.GetAll()
		for _, entity in pool do
			if eligible(entity) then
				table.insert(candidates, entity)
			end
		end
	end

	local best: Types.EntityLike? = nil
	for _, entity in candidates do
		local distance = (entity:GetPosition() - position).Magnitude
		if distance <= bestDistance then
			best, bestDistance = entity, distance
		end
	end
	return best
end

function Homing.update(projectile: State, dt: number)
	local homing = projectile.Homing
	if not homing then
		return
	end

	if projectile.HomingDelay > 0 then
		projectile.HomingDelay -= dt
		return
	end

	-- (re)acquire a target when none / auto-targeting
	local target = projectile.HomingTarget
	local targetGone = target == nil or Homing.targetPosition(target) == nil

	if targetGone then
		if homing.AcquireRadius or homing.TargetTag or homing.TargetTags then
			projectile._acquireTimer -= dt
			if projectile._acquireTimer <= 0 then
				-- Jittered so a burst fired on one frame spreads its searches
				-- across frames instead of spiking together forever.
				projectile._acquireTimer = homing.AcquireInterval * (0.5 + math.random())
				target = Homing.acquireTarget(projectile, homing, projectile.Position)
				projectile.HomingTarget = target
			end
		end
	elseif not homing.Permalock and homing.Retarget and target ~= homing.Target then
		-- (a target passed in the config -- homing.Target, e.g. a spell's "Lock
		-- on" -- is a lock: rechecking for the nearest only re-evaluates targets
		-- the projectile picked itself. If the locked one goes away, targetGone
		-- above falls back to normal acquisition.)
		projectile.ReacquireTimer -= dt
		if projectile.ReacquireTimer <= 0 then
			projectile.ReacquireTimer = homing.ReacquireRate
			-- No `or target` fallback: if nothing is in range anymore, the lock
			-- is genuinely dropped. Homing.Permalock (checked above) is the
			-- explicit opt-in for "never drop a lock due to range."
			target = Homing.acquireTarget(projectile, homing, projectile.Position)
			projectile.HomingTarget = target
		end
	end

	local goal = Homing.targetPosition(target)
	if not goal then
		return
	end
	local speed = projectile.Velocity.Magnitude
	local newDirection = Math.rotateTowards(projectile.Velocity, goal - projectile.Position, homing.TurnRate * dt)
	projectile.Velocity = newDirection * speed
end

return Homing
