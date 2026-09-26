--!optimize 2
--[[
	Shared projectile acceleration integration. Keeping this here ensures the
	server-authoritative trajectory and client dead-reckoning use identical
	math.

	Acceleration accepts either:
	 - a Vector3 in world-space studs/s^2, or
	 - a number applied along AccelerationDirection (or current velocity when
	   no direction is supplied, preserving the original speed-up/slow-down API).

	Gravity is also acceleration: a number means that many studs/s^2 downward,
	while a Vector3 supplies a custom world-space gravity vector.
]]

local ProjectileMotion = {}

local EPSILON = 1e-5

ProjectileMotion.PositionEpsilon = 1e-3

local function safeUnit(value: Vector3, fallback: Vector3): Vector3
	local magnitude = value.Magnitude
	if magnitude < EPSILON then
		return fallback
	end
	return value / magnitude
end

function ProjectileMotion.GetAcceleration(
	velocity: Vector3,
	acceleration: (number | Vector3)?,
	accelerationDirection: Vector3?,
	gravity: (number | Vector3)?
): Vector3
	local result = Vector3.zero

	if typeof(acceleration) == "Vector3" then
		result += acceleration
	elseif typeof(acceleration) == "number" and acceleration ~= 0 then
		local direction = accelerationDirection
		if typeof(direction) ~= "Vector3" then
			direction = velocity
		end
		result += safeUnit(direction, safeUnit(velocity, Vector3.zAxis)) * acceleration
	end

	if typeof(gravity) == "Vector3" then
		result += gravity
	elseif typeof(gravity) == "number" and gravity ~= 0 then
		result += Vector3.new(0, -gravity, 0)
	end

	return result
end

-- Returns the velocity at the end of the step and the average velocity to use
-- for displacement during the step. The average makes constant acceleration
-- (including gravity) integrate as p += v*dt + 0.5*a*dt^2 instead of treating
-- the end velocity as a fixed speed for the entire frame.
function ProjectileMotion.Integrate(
	velocity: Vector3,
	acceleration: (number | Vector3)?,
	accelerationDirection: Vector3?,
	gravity: (number | Vector3)?,
	minSpeed: number,
	maxSpeed: number,
	dt: number
): (Vector3, Vector3)
	local accelerationVector = ProjectileMotion.GetAcceleration(velocity, acceleration, accelerationDirection, gravity)
	if accelerationVector == Vector3.zero or dt <= 0 then
		return velocity, velocity
	end

	local nextVelocity = velocity + accelerationVector * dt
	local unclampedSpeed = nextVelocity.Magnitude
	local speed = math.clamp(unclampedSpeed, minSpeed, maxSpeed)
	if speed ~= unclampedSpeed then
		nextVelocity = safeUnit(nextVelocity, safeUnit(velocity, Vector3.zAxis)) * speed
	end

	return nextVelocity, (velocity + nextVelocity) * 0.5
end

-- Longer casts are safe for fast, mostly-linear projectiles because Roblox
-- ray/sphere casts sweep the full segment. The cap grows with speed to avoid
-- ray-count explosions, while nearby entities retain a tighter ceiling.
function ProjectileMotion.GetAdaptiveMaxDistance(speed: number, nearEntities: boolean): number
	if nearEntities then
		return math.clamp(speed / 120, 4, 64) -- roughly 120 Hz near targets
	end
	return math.clamp(speed / 30, 64, 256) -- roughly 30 Hz in empty space
end

-- Bounds the straight-chord approximation by limiting how far constant
-- acceleration can bend away from that chord during one integration step.
function ProjectileMotion.GetCurvatureStepDt(velocity: Vector3, acceleration: Vector3, allowedError: number): number
	local speed = velocity.Magnitude
	local perpendicular = acceleration
	if speed > EPSILON then
		local direction = velocity / speed
		perpendicular -= direction * acceleration:Dot(direction)
	end
	local magnitude = perpendicular.Magnitude
	if magnitude < EPSILON then
		return math.huge
	end
	return math.sqrt(8 * allowedError / magnitude)
end

-- Time until the current straight trajectory reaches the next chunk plane.
-- Sampling a tiny distance ahead resolves the ambiguous "exactly on a plane"
-- case in favor of the chunk the projectile is entering.
function ProjectileMotion.GetChunkBoundaryDt(
	position: Vector3,
	velocity: Vector3,
	chunkSize: number,
	useY: boolean
): number
	local speed = velocity.Magnitude
	if speed < EPSILON then
		return math.huge
	end

	local direction = velocity / speed
	local sample = position + direction * ProjectileMotion.PositionEpsilon
	local bestDistance = math.huge

	local function consider(sampleCoordinate: number, actualCoordinate: number, component: number)
		if math.abs(component) < EPSILON then
			return
		end
		local cell = math.floor(sampleCoordinate / chunkSize)
		local boundary = if component > 0 then (cell + 1) * chunkSize else cell * chunkSize
		local distance = (boundary - actualCoordinate) / component
		if distance > ProjectileMotion.PositionEpsilon and distance < bestDistance then
			bestDistance = distance
		end
	end

	consider(sample.X, position.X, direction.X)
	consider(sample.Z, position.Z, direction.Z)
	if useY then
		consider(sample.Y, position.Y, direction.Y)
	end

	return bestDistance / speed
end

-- Finds the first crossed chunk plane whose far side actually has a different
-- time scale. Equal-scale chunks are skipped, so very fast projectiles do not
-- pay one substep per 64 studs across ordinary 1x space.
function ProjectileMotion.GetTimeScaleBoundaryDt(
	position: Vector3,
	velocity: Vector3,
	chunkSize: number,
	useY: boolean,
	currentScale: number,
	maxDt: number,
	getScaleAt: (Vector3) -> number
): number
	local speed = velocity.Magnitude
	if speed < EPSILON then
		return math.huge
	end

	local direction = velocity / speed
	local cursorTime = 0
	for _ = 1, 32 do
		local cursorPosition = position + velocity * cursorTime
		local boundaryDt = ProjectileMotion.GetChunkBoundaryDt(cursorPosition, velocity, chunkSize, useY)
		if boundaryDt == math.huge then
			return math.huge
		end
		local boundaryTime = cursorTime + boundaryDt
		if boundaryTime >= maxDt then
			return math.huge
		end
		if getScaleAt(position + velocity * boundaryTime + direction * ProjectileMotion.PositionEpsilon) ~= currentScale then
			return boundaryTime
		end
		cursorTime = boundaryTime + ProjectileMotion.PositionEpsilon / speed
	end

	-- Bound the scan itself in pathological ultra-fast cases; the next
	-- simulation segment resumes the search from here without losing time.
	return cursorTime
end

return ProjectileMotion
