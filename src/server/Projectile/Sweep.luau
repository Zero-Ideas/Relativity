--!strict
--!native
--!optimize 2
--[[
	Projectile/Sweep.luau
	The parallel half of projectile movement: the substep loop of
	Projectile.Step for a projectile with no homing and no lag compensation,
	run inside an Actor worker (ProjectileWorkerBootstrap) on a packed copy of
	its state. It plans, casts and integrates exactly as Step does -- same
	ProjectileMotion / ProjectileStepPlanner calls, same constants -- and stops
	at the first contact, handing that substep (and everything after it) back
	to the serial Step code, which owns hits, damage and signals. So a frame
	with no contact is computed entirely here; one with a contact ends in the
	same state it would have without the split.

	Also defines the packed layouts both sides use:
	  input  (INPUT_SLOTS f64): index, filter, position, velocity,
	         acceleration (kind + value), acceleration direction (flag +
	         vector), gravity (kind + value), min/max speed, radius, age,
	         lifetime, remaining
	  output (OUTPUT_BYTES): status u8, guard u8, position 3 x f32, velocity
	         3 x f32 (both are Vector3s, float32 already: exact), age f64,
	         remaining f64
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ProjectileMotion = require(Shared:WaitForChild("ProjectileMotion"))
local Planner = require(Shared:WaitForChild("ProjectileStepPlanner"))

local Sweep = {}

Sweep.MaxSubsteps = 16
Sweep.Done = 0 -- loop finished; `remaining` is the carried simulation debt
Sweep.Contact = 1 -- the next substep hits something: resume serially from here
Sweep.Expired = 2 -- lifetime ran out (Step returns false)

local MIN_STEP_DT = ProjectileMotion.MinStepDt
local MAX_SUBSTEPS = Sweep.MaxSubsteps
local DONE, CONTACT, EXPIRED = Sweep.Done, Sweep.Contact, Sweep.Expired

Sweep.InputSlots = 26
local IN, OUT = Sweep.InputSlots * 8, 44

-- Byte strides and offsets Parallel's persistent slots update in place.
Sweep.InputStride, Sweep.OutputStride = IN, OUT
Sweep.InputMotion = 16 -- position then velocity, 6 x f64
-- output offsets
Sweep.OutStatus, Sweep.OutGuard, Sweep.OutPosition, Sweep.OutVelocity, Sweep.OutAge, Sweep.OutRemaining =
	0, 1, 4, 16, 28, 36
Sweep.InputAge = 184
Sweep.InputRemaining = 200

local writef64, readf64 = buffer.writef64, buffer.readf64
local writef32, readf32, writeu8, readu8 = buffer.writef32, buffer.readf32, buffer.writeu8, buffer.readu8

--------------------------------------------------------------------------------
-- Packing
--------------------------------------------------------------------------------

local function writeVector(b: buffer, offset: number, v: Vector3)
	writef64(b, offset, v.X)
	writef64(b, offset + 8, v.Y)
	writef64(b, offset + 16, v.Z)
end

local function readVector(b: buffer, offset: number): Vector3
	return Vector3.new(readf64(b, offset), readf64(b, offset + 8), readf64(b, offset + 16))
end

-- number-or-Vector3 (Acceleration / Gravity): kind slot then 3 value slots
local function writeScalarOrVector(b: buffer, offset: number, value: any)
	if typeof(value) == "Vector3" then
		writef64(b, offset, 1)
		writeVector(b, offset + 8, value)
	else
		writef64(b, offset, 0)
		writef64(b, offset + 8, value or 0)
	end
end

local function readScalarOrVector(b: buffer, offset: number): any
	if readf64(b, offset) == 1 then
		return readVector(b, offset + 8)
	end
	return readf64(b, offset + 8)
end

function Sweep.InputSize(count: number): number
	return count * IN
end

function Sweep.OutputSize(count: number): number
	return count * OUT
end

function Sweep.WriteInput(b: buffer, item: number, index: number, filter: number, p: any, remaining: number)
	local o = (item - 1) * IN
	writef64(b, o, index)
	writef64(b, o + 8, filter)
	writeVector(b, o + 16, p.Position)
	writeVector(b, o + 40, p.Velocity)
	writeScalarOrVector(b, o + 64, p.Acceleration)
	local direction = p.AccelerationDirection
	writef64(b, o + 96, if direction then 1 else 0)
	if direction then
		writeVector(b, o + 104, direction)
	end
	writeScalarOrVector(b, o + 128, p.Gravity)
	writef64(b, o + 160, p.MinSpeed)
	writef64(b, o + 168, p.MaxSpeed)
	writef64(b, o + 176, p.Radius)
	writef64(b, o + 184, p.Age)
	writef64(b, o + 192, p.Lifetime)
	writef64(b, o + 200, remaining)
end

local function writeVector32(b: buffer, offset: number, v: Vector3)
	writef32(b, offset, v.X)
	writef32(b, offset + 4, v.Y)
	writef32(b, offset + 8, v.Z)
end

local function readVector32(b: buffer, offset: number): Vector3
	return Vector3.new(readf32(b, offset), readf32(b, offset + 4), readf32(b, offset + 8))
end

function Sweep.WriteOutput(b: buffer, item: number, status: number, position: Vector3, velocity: Vector3, age: number, remaining: number, guard: number)
	local o = (item - 1) * OUT
	writeu8(b, o, status)
	writeu8(b, o + 1, guard)
	writeVector32(b, o + 4, position)
	writeVector32(b, o + 16, velocity)
	writef64(b, o + 28, age)
	writef64(b, o + 36, remaining)
end

-- One result as plain values (no table): status, position, velocity, age,
-- remaining, guard.
function Sweep.ReadOutputValues(b: buffer, item: number): (number, Vector3, Vector3, number, number, number)
	local o = (item - 1) * OUT
	return readu8(b, o), readVector32(b, o + 4), readVector32(b, o + 16), readf64(b, o + 28),
		readf64(b, o + 36), readu8(b, o + 1)
end

--------------------------------------------------------------------------------
-- The loop
--------------------------------------------------------------------------------

-- Runs one packed projectile and writes its result. `castHits(from,
-- displacement, radius, filter)` is the worker's movement cast (occupancy skip
-- + Raycast/Spherecast); `hasEntities(position)` its mirror of
-- Raycast.chunkHasEntities.
function Sweep.Run(
	input: buffer,
	item: number,
	output: buffer,
	uniformTime: boolean,
	castHits: (Vector3, Vector3, number, number) -> boolean,
	hasEntities: (Vector3) -> boolean
)
	local o = (item - 1) * IN
	local index = readf64(input, o)
	local filter = readf64(input, o + 8)
	local position = readVector(input, o + 16)
	local velocity = readVector(input, o + 40)
	local acceleration = readScalarOrVector(input, o + 64)
	local direction: Vector3? = if readf64(input, o + 96) == 1 then readVector(input, o + 104) else nil
	local gravity = readScalarOrVector(input, o + 128)
	local minSpeed = readf64(input, o + 160)
	local maxSpeed = readf64(input, o + 168)
	local radius = readf64(input, o + 176)
	local age = readf64(input, o + 184)
	local lifetime = readf64(input, o + 192)
	local remaining = readf64(input, o + 200)

	-- Mirrors Projectile.Step's loop (no homing: maxDt is unbounded; no
	-- rewind: no lag-compensated entity check).
	local guard = 0
	while remaining > MIN_STEP_DT and guard < MAX_SUBSTEPS do
		guard += 1
		local lifeRemaining = lifetime - age
		if lifeRemaining <= MIN_STEP_DT then
			Sweep.WriteOutput(output, item, EXPIRED, position, velocity, age, remaining, guard)
			return
		end

		local accelerationVector = ProjectileMotion.GetAcceleration(velocity, acceleration, direction, gravity)
		local sample, chunkScale = Planner.Sample(position, velocity, accelerationVector, uniformTime)
		if chunkScale <= 0 then
			remaining = 0
			break
		end
		local highRes = hasEntities(sample)
		local stepDt = Planner.StepDt(position, velocity, accelerationVector, chunkScale, remaining, lifeRemaining,
			highRes, uniformTime, math.huge)
		if stepDt <= 0 then
			break
		end

		local endVelocity, movementVelocity = ProjectileMotion.Integrate(velocity, acceleration, direction, gravity,
			minSpeed, maxSpeed, stepDt)
		local displacement = movementVelocity * stepDt
		if castHits(position, displacement, radius, filter) then
			-- hand this substep back untouched; Step redoes it serially
			Sweep.WriteOutput(output, item, CONTACT, position, velocity, age, remaining, guard - 1)
			return
		end
		velocity = endVelocity
		position += displacement
		age += stepDt
		remaining -= stepDt / chunkScale
		if age >= lifetime - MIN_STEP_DT then
			Sweep.WriteOutput(output, item, EXPIRED, position, velocity, age, remaining, guard)
			return
		end
	end
	Sweep.WriteOutput(output, item, DONE, position, velocity, age, remaining, guard)
end

return Sweep
