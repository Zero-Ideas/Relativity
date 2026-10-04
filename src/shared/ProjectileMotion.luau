--!strict
--!optimize 2
--[[
	Shared projectile acceleration integration. Keeping this here ensures the
	server-authoritative trajectory and client dead-reckoning use identical
	math. Pure functions only -- chunk/time-zone lookups are passed in (see
	ProjectileStepPlanner, which wires these to ChunkManager for both sides).

	Acceleration accepts either:
	 - a Vector3 in world-space studs/s^2, or
	 - a number applied along AccelerationDirection (or current velocity when
	   no direction is supplied, preserving the original speed-up/slow-down API).

	Gravity is also acceleration: a number means that many studs/s^2 downward,
	while a Vector3 supplies a custom world-space gravity vector.

	Precision: Vector3 is float32, so a fixed nudge like 1e-3 studs vanishes
	entirely once a coordinate passes ~8k studs (the float32 spacing there is
	~1e-3). Boundary math below therefore runs on plain Luau numbers (doubles),
	and every positional nudge scales with distance from the origin via
	GetNudge.
]]

local SafeMath = require(script.Parent.SafeMath)

export type Acceleration = number | Vector3

local ProjectileMotion = {}

local EPSILON = 1e-5

-- Minimum positional nudge near the origin; see GetNudge.
ProjectileMotion.PositionEpsilon = 1e-3
-- Dilated seconds below which a substep is not worth integrating; smaller
-- slices of time are carried to the next frame, never discarded.
ProjectileMotion.MinStepDt = 1e-5
-- Maximum studs between a curved path and the straight chord cast for it.
ProjectileMotion.CurveError = 0.35
-- Chunk/zone time scales below this count as frozen. A scale of 1e-9 would
-- otherwise accumulate carried time for minutes and then spend all of it in
-- one burst the moment the projectile reaches ordinary time.
ProjectileMotion.MinTimeScale = 1e-4

-- 2^-18: 32 float32 ulps, so a nudged Vector3 always lands strictly past
-- the point it was nudged from, however far that is from the origin.
local RELATIVE_NUDGE = 2 ^ -18

-- Smallest offset guaranteed to move a Vector3 at `position`.
function ProjectileMotion.GetNudge(position: Vector3): number
	local largest = math.max(math.abs(position.X), math.abs(position.Y), math.abs(position.Z))
	return math.max(ProjectileMotion.PositionEpsilon, largest * RELATIVE_NUDGE)
end

-- Collapses negligible (or NaN) scales to a clean 0 and caps absurd ones.
function ProjectileMotion.SnapTimeScale(scale: number): number
	if not (scale >= ProjectileMotion.MinTimeScale) then
		return 0
	end
	return math.min(scale, SafeMath.Limit)
end

function ProjectileMotion.GetAcceleration(
	velocity: Vector3,
	acceleration: Acceleration?,
	accelerationDirection: Vector3?,
	gravity: Acceleration?
): Vector3
	local result = Vector3.zero

	if typeof(acceleration) == "Vector3" then
		result += acceleration
	elseif typeof(acceleration) == "number" and acceleration ~= 0 then
		local heading = SafeMath.direction(velocity, Vector3.zAxis)
		local direction = if accelerationDirection then SafeMath.direction(accelerationDirection, heading) else heading
		result += direction * acceleration
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
-- the end velocity as a fixed speed for the entire frame. Speed is always
-- held within SafeMath.Limit, even with MaxSpeed = math.huge, so unbounded
-- acceleration can never overflow float32.
function ProjectileMotion.Integrate(
	velocity: Vector3,
	acceleration: Acceleration?,
	accelerationDirection: Vector3?,
	gravity: Acceleration?,
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
	local ceiling = math.min(maxSpeed, SafeMath.Limit)
	local speed = math.clamp(unclampedSpeed, math.min(minSpeed, ceiling), ceiling)
	if speed ~= unclampedSpeed then
		nextVelocity = SafeMath.direction(nextVelocity, SafeMath.direction(velocity, Vector3.zAxis)) * speed
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
	if not (magnitude >= EPSILON) then
		return math.huge
	end
	return math.sqrt(8 * allowedError / magnitude)
end

-- Time until the current straight trajectory reaches the next chunk plane.
-- Sampling a nudge ahead resolves the ambiguous "exactly on a plane" case in
-- favor of the chunk the projectile is entering; the sample is a double, not
-- a Vector3, so the nudge survives at any distance from the origin.
function ProjectileMotion.GetChunkBoundaryDt(
	position: Vector3,
	velocity: Vector3,
	chunkSize: number,
	useY: boolean
): number
	local speed = velocity.Magnitude
	if not (speed >= EPSILON) then
		return math.huge
	end

	local nudge = ProjectileMotion.GetNudge(position)
	local best = math.huge

	local function consider(coordinate: number, velocityComponent: number)
		local directionComponent = velocityComponent / speed
		if math.abs(directionComponent) < EPSILON then
			return
		end
		local cell = math.floor((coordinate + directionComponent * nudge) / chunkSize)
		local boundary = if directionComponent > 0 then (cell + 1) * chunkSize else cell * chunkSize
		local dt = (boundary - coordinate) / velocityComponent
		if dt > 0 and dt < best then
			best = dt
		end
	end

	consider(position.X, velocity.X)
	consider(position.Z, velocity.Z)
	if useY then
		consider(position.Y, velocity.Y)
	end

	return best
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
	if not (speed >= EPSILON) then
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
		local boundaryPosition = position + velocity * boundaryTime
		local nudge = ProjectileMotion.GetNudge(boundaryPosition)
		if getScaleAt(boundaryPosition + direction * nudge) ~= currentScale then
			return boundaryTime
		end
		cursorTime = boundaryTime + nudge / speed
	end

	-- Bound the scan itself in pathological ultra-fast cases; the next
	-- simulation segment resumes the search from here without losing time.
	return cursorTime
end

return ProjectileMotion
