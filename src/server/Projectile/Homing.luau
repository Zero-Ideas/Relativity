--!optimize 2
--[[
	Projectile/Homing.luau
	Target acquisition/tracking. Homing.Methods gets mixed onto the Projectile
	class by init.luau (so self:_updateHoming(dt) keeps working unchanged).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared.ChunkManager)
local Entity = require(Shared.Entity)

local Math = require(script.Parent.Math)

local Homing = {}
Homing.Methods = {}

function Homing.targetPosition(target): Vector3?
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
	-- assume an Entity
	if target.IsDestroyed then
		return nil
	end
	if target.GetPosition then
		return target:GetPosition()
	end
	return nil
end

-- Finds the nearest valid homing target: entities matching TargetTag/TargetTags
-- (or ALL entities if neither given), excluding the projectile's own Source and
-- anything its Filter rejects. Uses ChunkManager's spatial index when
-- AcquireRadius is set (the normal case -- every real spawn site sets one), so
-- cost scales with local entity density, not total entity/projectile count; the
-- unbounded case (rare) falls back to a full scan.
function Homing.acquireTarget(projectile, homing, position: Vector3)
	local source = projectile.Source
	local filter = projectile.Filter

	local function isEligible(entity): boolean
		if entity == source or entity.IsDestroyed then
			return false
		end
		if filter and not filter(entity) then
			return false
		end
		if homing.TargetTags then
			for _, tag in homing.TargetTags do
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

	if homing.AcquireRadius then
		local best, bestDist = nil, homing.AcquireRadius
		local candidates = ChunkManager.GetEntitiesInRadius(position, homing.AcquireRadius, { Filter = isEligible })
		for _, entity in candidates do
			local distance = (entity:GetPosition() - position).Magnitude
			if distance <= bestDist then
				best, bestDist = entity, distance
			end
		end
		return best
	end

	local best, bestDist = nil, math.huge
	local candidates = homing.TargetTag and Entity.GetTagged(homing.TargetTag) or Entity.GetAll()
	for _, entity in candidates do
		if isEligible(entity) then
			local distance = (entity:GetPosition() - position).Magnitude
			if distance <= bestDist then
				best, bestDist = entity, distance
			end
		end
	end
	return best
end

function Homing.Methods:_updateHoming(dt: number)
	local homing = self.Homing
	if not homing then
		return
	end

	if self.HomingDelay > 0 then
		self.HomingDelay -= dt
		return
	end

	-- (re)acquire a target when none / auto-targeting
	local target = self.HomingTarget
	local targetGone = target == nil or Homing.targetPosition(target) == nil

	if targetGone then
		if homing.AcquireRadius or homing.TargetTag or homing.TargetTags then
			self.HomingTarget = Homing.acquireTarget(self, homing, self.Position)
			target = self.HomingTarget
		end
	elseif not homing.Permalock and homing.Retarget then
		self.ReacquireTimer -= dt
		if self.ReacquireTimer <= 0 then
			self.ReacquireTimer = homing.ReacquireRate or 0.3
			-- No `or target` fallback: if nothing is in range anymore, the lock
			-- is genuinely dropped, matching "re-acquire if the target ...
			-- leaves" above. Homing.Permalock (checked above) is the explicit
			-- opt-in for "never drop a lock due to range."
			self.HomingTarget = Homing.acquireTarget(self, homing, self.Position)
			target = self.HomingTarget
		end
	end

	local goal = target and Homing.targetPosition(target)
	if not goal then
		return
	end
	local desired = goal - self.Position
	local turn = (homing.TurnRate or math.rad(120)) * dt
	local speed = self.Velocity.Magnitude
	local newDir = Math.rotateTowards(self.Velocity, desired, turn)
	self.Velocity = newDir * speed
end

return Homing
