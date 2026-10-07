--!native
--!strict
--!optimize 2
--[[
	ProjectileClient/Prediction.luau
	Client dead-reckoning: the mirror of the server's Projectile Step minus
	hit detection. Substeps are chosen by the same ProjectileStepPlanner the
	server uses, and time that is too small to integrate is carried exactly
	the same way, so both sides consume identical simulated time.

	Prediction.simulate(visual, baseDt) advances one visual by baseDt
	personal/global seconds (already multiplied by visual.timeScale) and
	returns (alive, moved).
]]

local Shared = script.Parent.Parent
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local ProjectileMotion = require(Shared:WaitForChild("ProjectileMotion"))
local Planner = require(Shared:WaitForChild("ProjectileStepPlanner"))
local SafeMath = require(Shared:WaitForChild("SafeMath"))

local Types = require(script.Parent.Types)

type Visual = Types.Visual

local Prediction = {}

local MIN_STEP_DT = ProjectileMotion.MinStepDt
local MAX_SUBSTEPS = 16

local function integrate(visual: Visual, dt: number)
	local movementVelocity
	visual.velocity, movementVelocity = ProjectileMotion.Integrate(
		visual.velocity,
		visual.acceleration,
		visual.accelerationDirection,
		visual.gravity,
		visual.minSpeed,
		visual.maxSpeed,
		dt
	)
	visual.position += movementVelocity * dt
	visual.life -= dt
end

-- Only these trajectories have an exact elapsed-time solution. Everything
-- else keeps the normal planner so skipping frames cannot change its path.
function Prediction.canDefer(visual: Visual): boolean
	return ChunkManager.IsTimeUniform()
		and visual.simulationDebt == 0
		and visual.minSpeed <= 0
		and visual.maxSpeed == math.huge
		and (typeof(visual.acceleration) ~= "number" or visual.acceleration == 0)
end

-- Cheap visibility probe without advancing any simulation state. Using the
-- current projected position (not the frozen exit pose) also detects shots
-- that fly into view while the camera stays still.
function Prediction.projectDeferred(visual: Visual, dt: number): Vector3
	dt = math.min(math.max(dt, 0), math.max(visual.life, 0))
	local acceleration = ProjectileMotion.GetAcceleration(
		visual.velocity, visual.acceleration, visual.accelerationDirection, visual.gravity
	)
	return visual.position + visual.velocity * dt + acceleration * (0.5 * dt * dt)
end

-- Used before a world time-field mutation: settle the old uniform interval
-- before any new zone could be applied retroactively to the deferred time.
function Prediction.settleDeferred(visual: Visual, dt: number)
	if dt > 0 then integrate(visual, math.min(dt, math.max(visual.life, 0))) end
end

function Prediction.simulate(visual: Visual, baseDt: number): (boolean, boolean)
	if not (baseDt > 0) then
		return true, false
	end

	local remaining = baseDt + visual.simulationDebt
	visual.simulationDebt = 0
	local uniformTime = ChunkManager.IsTimeUniform()

	-- Fast path: with no dilation anywhere there are no boundaries to stop at,
	-- and constant (vector/gravity) acceleration without speed clamps is
	-- integrated exactly by one averaged-velocity step. The substep loop below
	-- only exists for boundaries, clamps and velocity-relative acceleration.
	if
		uniformTime
		and visual.minSpeed <= 0
		and visual.maxSpeed == math.huge
		and (typeof(visual.acceleration) ~= "number" or visual.acceleration == 0)
	then
		integrate(visual, math.min(remaining, visual.life))
		return visual.life > MIN_STEP_DT and SafeMath.isFiniteVector(visual.position), true
	end

	local moved = false
	local guard = 0
	while remaining > MIN_STEP_DT and guard < MAX_SUBSTEPS do
		guard += 1
		if visual.life <= MIN_STEP_DT then
			return false, moved
		end

		local accelerationVector = ProjectileMotion.GetAcceleration(
			visual.velocity,
			visual.acceleration,
			visual.accelerationDirection,
			visual.gravity
		)
		local _, chunkScale = Planner.Sample(visual.position, visual.velocity, accelerationVector, uniformTime)
		if chunkScale <= 0 then
			remaining = 0
			break
		end

		-- The client can't see entities, so it always plans at the fine
		-- resolution; that only changes where substeps fall, not the path.
		local stepDt = Planner.StepDt(
			visual.position,
			visual.velocity,
			accelerationVector,
			chunkScale,
			remaining,
			visual.life,
			true,
			uniformTime,
			math.huge
		)
		if stepDt <= 0 then
			break
		end

		integrate(visual, stepDt)
		remaining -= stepDt / chunkScale
		moved = true
		if visual.life <= MIN_STEP_DT then
			return false, moved
		end
	end

	-- Carry whatever wasn't simulated, exactly like the server's Step.
	visual.simulationDebt = remaining
	-- Mirrors the server expiring a projectile past SafeMath.Limit.
	return SafeMath.isFiniteVector(visual.position), moved
end

return Prediction
