--!strict
--!optimize 2
--[[
	ProjectileStepPlanner.luau
	Chooses the next integration substep for a projectile. The authoritative
	server Step and the client's dead-reckoning both call this, so they
	partition time identically: same chunk sampling, same boundary stops,
	same curvature limit, same carry rule for time too small to integrate.
	Keeping one copy is what keeps the two sides from drifting apart as
	either one is tuned.

	Per substep:
	 local sample, chunkScale = Planner.Sample(position, velocity, accel, uniformTime)
	 -- chunkScale == 0: frozen chunk; consume the frame's remaining time.
	 local stepDt = Planner.StepDt(position, velocity, accel, chunkScale,
	     remaining, lifeRemaining, nearEntities, uniformTime, maxDt)
	 -- stepDt == 0: not enough time for a meaningful step; carry `remaining`.

	Remaining time is in personal/global seconds (before chunk dilation); a
	step of stepDt dilated seconds consumes stepDt / chunkScale of it.
]]

local ChunkManager = require(script.Parent.ChunkManager)
local ProjectileMotion = require(script.Parent.ProjectileMotion)
local SafeMath = require(script.Parent.SafeMath)

local Planner = {}

-- Chunk/zone scale as projectile motion sees it -- see
-- ProjectileMotion.SnapTimeScale.
function Planner.ChunkTimeScaleAt(position: Vector3): number
	return ProjectileMotion.SnapTimeScale(ChunkManager.GetTimeScaleAt(position))
end

-- Returns a point just ahead of `position` along the direction of travel,
-- and the chunk time scale there (the chunk being entered wins when
-- sitting exactly on a boundary).
function Planner.Sample(
	position: Vector3,
	velocity: Vector3,
	accelerationVector: Vector3,
	uniformTime: boolean
): (Vector3, number)
	local direction = SafeMath.direction(velocity, SafeMath.direction(accelerationVector, Vector3.zAxis))
	local sample = position + direction * ProjectileMotion.GetNudge(position)
	return sample, if uniformTime then 1 else Planner.ChunkTimeScaleAt(sample)
end

function Planner.StepDt(
	position: Vector3,
	velocity: Vector3,
	accelerationVector: Vector3,
	chunkScale: number,
	remaining: number,
	lifeRemaining: number,
	nearEntities: boolean,
	uniformTime: boolean,
	maxDt: number
): number
	local minStepDt = ProjectileMotion.MinStepDt
	local availableDt = remaining * chunkScale
	if availableDt <= minStepDt then
		return 0
	end

	local predictedVelocity = velocity + accelerationVector * availableDt
	local movementVelocity = (velocity + predictedVelocity) * 0.5
	local speed = movementVelocity.Magnitude
	local stepDt = math.min(availableDt, lifeRemaining, maxDt)
	if speed > 1e-5 then
		stepDt = math.min(stepDt, ProjectileMotion.GetAdaptiveMaxDistance(speed, nearEntities) / speed)
		if not uniformTime then
			stepDt = math.min(
				stepDt,
				ProjectileMotion.GetTimeScaleBoundaryDt(
					position,
					movementVelocity,
					ChunkManager.ChunkSize,
					ChunkManager.UseY,
					chunkScale,
					stepDt,
					Planner.ChunkTimeScaleAt
				),
				ChunkManager.GetRadialTimeScaleBoundaryDt(position, movementVelocity, stepDt)
			)
		end
	end
	stepDt = math.min(
		stepDt,
		ProjectileMotion.GetCurvatureStepDt(velocity, accelerationVector, ProjectileMotion.CurveError)
	)

	-- Boundary and curvature limits can shrink a step toward zero -- e.g. a
	-- projectile resting a hair before a chunk plane. Floor it so they can
	-- never stall progress; overshooting a boundary by minStepDt of travel
	-- is far below anything visible.
	return math.max(stepDt, math.min(minStepDt, availableDt, lifeRemaining))
end

return Planner
