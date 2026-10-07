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
	  input  (48 bytes): motion spec id u32, filter id u32, position 3 x f32,
	         velocity 3 x f32 (Vector3s are float32: exact), age f64,
	         remaining f64. The per-shot constants (acceleration and its
	         direction, gravity, min/max speed, radius, lifetime) are a
	         MotionSpec the workers are sent once and keep, like filters.
	  output (OUTPUT_BYTES): status u8, guard u8, position 3 x f32, velocity
	         3 x f32 (both are Vector3s, float32 already: exact), age f64,
	         remaining f64
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ProjectileMotion = require(Shared:WaitForChild("ProjectileMotion"))
local Math = require(script.Parent.Math)
local Planner = require(Shared:WaitForChild("ProjectileStepPlanner"))

local Sweep = {}

Sweep.MaxSubsteps = 16
Sweep.Done = 0 -- loop finished; `remaining` is the carried simulation debt
Sweep.Contact = 1 -- the next substep hits something: resume serially from here
Sweep.Expired = 2 -- lifetime ran out (Step returns false)

local MIN_STEP_DT = ProjectileMotion.MinStepDt
local MAX_SUBSTEPS = Sweep.MaxSubsteps
local DONE, CONTACT, EXPIRED = Sweep.Done, Sweep.Contact, Sweep.Expired

local IN, OUT = 48, 44

-- Byte strides and offsets Parallel's persistent slots update in place.
Sweep.InputStride, Sweep.OutputStride = IN, OUT
Sweep.InputMotion = 8 -- position then velocity, 6 x f32 (same layout as the output's)
Sweep.InputAge = 32
Sweep.InputRemaining = 40
-- output offsets
Sweep.OutStatus, Sweep.OutGuard, Sweep.OutPosition, Sweep.OutVelocity, Sweep.OutAge, Sweep.OutRemaining =
	0, 1, 4, 16, 28, 36

-- A projectile's per-shot motion constants, as the workers keep them (plus
-- its homing constants, when it homes).
export type MotionSpec = {
	Acceleration: number | Vector3,
	Direction: Vector3?,
	Gravity: number | Vector3,
	MinSpeed: number,
	MaxSpeed: number,
	Radius: number,
	Lifetime: number,
	TurnRate: number?, -- rad/s; nil: no homing
	AutoAcquire: boolean?, -- searches for targets itself (AcquireRadius / TargetTag(s))
	Retarget: boolean?, -- re-checks for the nearest target (Retarget and not Permalock)
	-- target searches on the worker (WorkerSearch: no custom Filter): the
	-- frame's target list is matched by TagMask (0: any entity) within
	-- AcquireRadius (nil: unbounded); timers reset like Homing.update's
	WorkerSearch: boolean?,
	TagMask: number?,
	AcquireRadius: number?,
	AcquireInterval: number?,
	ReacquireRate: number?,
}

-- This frame's homing targets for the workers (Parallel.Dispatch): every
-- eligible entity's position and tag bits.
export type HomingFrame = { Positions: { Vector3 }, Bits: { number } }

-- Homing steers at most this many radians per substep (Projectile.Step uses
-- the same cap, so worker and serial substeps match).
Sweep.MaxHomingTurnStep = math.rad(5)

-- Per-frame homing state, in a separate buffer per batch (only homing items
-- use it): flags u8 (HOMING, TARGET_POSITION: the target exists and has a
-- position, HAS_TARGET: HomingTarget is set, EXPLICIT: it's the config's own
-- Target), the index of its own Source in the frame's target list u32 at 4
-- (0: none; never picked), target position 3 x f32 at 8, HomingDelay f64 at
-- 24, _acquireTimer f64 at 32, ReacquireTimer f64 at 40. The worker hands back
-- the three timers and a target change f64 (0: unchanged, -1: none found, >0:
-- the frame target list index it picked) -- 32 bytes per item.
Sweep.HomingInStride, Sweep.HomingOutStride = 48, 32
Sweep.HomingFlag, Sweep.HomingTargetPosition, Sweep.HomingHasTarget, Sweep.HomingExplicit = 1, 2, 4, 8
local HOMING_IN, HOMING_OUT = 48, 32

-- The nearest of the frame's targets matching `mask` within `radius` of
-- `position`, skipping `exclude` (Homing.acquireTarget's rule, distance <=
-- best). 0 if none.
local function searchTarget(frame: HomingFrame, position: Vector3, radius: number?, mask: number, exclude: number): number
	local best, bestDistance = 0, radius or math.huge
	local positions, bits = frame.Positions, frame.Bits
	for index = 1, #positions do
		if index ~= exclude and (mask == 0 or bit32.band(bits[index], mask) ~= 0) then
			local distance = (positions[index] - position).Magnitude
			if distance <= bestDistance then
				best, bestDistance = index, distance
			end
		end
	end
	return best
end

-- A homing item's timers where its frame ended (or was handed back), and
-- its target change.
local function writeTimers(homingOut: buffer?, item: number, d: number, a: number, r: number, change: number)
	if homingOut then
		local h = (item - 1) * HOMING_OUT
		buffer.writef64(homingOut, h, d)
		buffer.writef64(homingOut, h + 8, a)
		buffer.writef64(homingOut, h + 16, r)
		buffer.writef64(homingOut, h + 24, change)
	end
end

local writef64, readf64 = buffer.writef64, buffer.readf64
local writef32, readf32, writeu8, readu8 = buffer.writef32, buffer.readf32, buffer.writeu8, buffer.readu8
local writeu32, readu32 = buffer.writeu32, buffer.readu32

--------------------------------------------------------------------------------
-- Packing
--------------------------------------------------------------------------------

function Sweep.InputSize(count: number): number
	return count * IN
end

function Sweep.OutputSize(count: number): number
	return count * OUT
end

local function writeVector32(b: buffer, offset: number, v: Vector3)
	writef32(b, offset, v.X)
	writef32(b, offset + 4, v.Y)
	writef32(b, offset + 8, v.Z)
end

local function readVector32(b: buffer, offset: number): Vector3
	return Vector3.new(readf32(b, offset), readf32(b, offset + 4), readf32(b, offset + 8))
end

-- The motion spec of `p` (its per-shot constants; see MotionSpec).
function Sweep.SpecOf(p: any): MotionSpec
	local homing = p.Homing
	return {
		Acceleration = p.Acceleration or 0,
		Direction = p.AccelerationDirection,
		Gravity = p.Gravity or 0,
		MinSpeed = p.MinSpeed,
		MaxSpeed = p.MaxSpeed,
		Radius = p.Radius,
		Lifetime = p.Lifetime,
		TurnRate = homing and homing.TurnRate,
		AutoAcquire = homing and (homing.AcquireRadius ~= nil or homing.TargetTag ~= nil or homing.TargetTags ~= nil),
		Retarget = homing and (homing.Retarget and not homing.Permalock),
		WorkerSearch = homing and p.Filter == nil,
		AcquireRadius = homing and homing.AcquireRadius,
		AcquireInterval = homing and homing.AcquireInterval,
		ReacquireRate = homing and homing.ReacquireRate,
		-- (TagMask is filled in by Parallel, which owns the tag bits)
	}
end

-- WriteInput from plain values (a freshly fired projectile; Parallel.PackNew).
function Sweep.WriteInputValues(b: buffer, item: number, spec: number, filter: number, position: Vector3,
	velocity: Vector3, age: number, remaining: number)
	local o = (item - 1) * IN
	writeu32(b, o, spec)
	writeu32(b, o + 4, filter)
	writeVector32(b, o + 8, position)
	writeVector32(b, o + 20, velocity)
	writef64(b, o + 32, age)
	writef64(b, o + 40, remaining)
end

function Sweep.WriteInput(b: buffer, item: number, spec: number, filter: number, p: any, remaining: number)
	local o = (item - 1) * IN
	writeu32(b, o, spec)
	writeu32(b, o + 4, filter)
	writeVector32(b, o + 8, p.Position)
	writeVector32(b, o + 20, p.Velocity)
	writef64(b, o + 32, p.Age)
	writef64(b, o + 40, remaining)
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

-- Runs one packed projectile and writes its result. `specs` are the motion
-- specs this worker has been sent; `castHits(from, displacement, radius,
-- filter)` is the worker's movement cast (occupancy skip +
-- Raycast/Spherecast); `hasEntities(position)` its mirror of
-- Raycast.chunkHasEntities.
function Sweep.Run(
	input: buffer,
	item: number,
	output: buffer,
	uniformTime: boolean,
	specs: { [number]: MotionSpec },
	castHits: (Vector3, Vector3, number, number) -> any,
	hasEntities: (Vector3) -> boolean,
	onContact: ((item: number, from: Vector3, displacement: Vector3, hit: any) -> ())?,
	homingIn: buffer?,
	homingOut: buffer?,
	homingFrame: HomingFrame?
)
	local o = (item - 1) * IN
	local filter = readu32(input, o + 4)
	local position = readVector32(input, o + 8)
	local velocity = readVector32(input, o + 20)
	local age = readf64(input, o + 32)
	local remaining = readf64(input, o + 40)
	local spec = specs[readu32(input, o)]
	if not spec then
		-- unknown spec: hand the whole frame to the serial path
		Sweep.WriteOutput(output, item, CONTACT, position, velocity, age, remaining, 0)
		return
	end
	local acceleration, direction, gravity = spec.Acceleration, spec.Direction, spec.Gravity
	local minSpeed, maxSpeed, radius, lifetime = spec.MinSpeed, spec.MaxSpeed, spec.Radius, spec.Lifetime

	-- Homing (Homing.update, per substep): steering toward the target's
	-- position this frame. A target search due mid-frame is made here, from
	-- the frame's target list (WorkerSearch); a config with a custom Filter
	-- hands the substep back for the main thread to search instead.
	local turnRate = spec.TurnRate
	local homingFlags = 0
	local targetPosition = Vector3.zero
	local delay, acquireTimer, reacquireTimer = 0, 0, 0
	local exclude = 0
	if homingIn and turnRate then
		local h = (item - 1) * HOMING_IN
		homingFlags = readu8(homingIn, h)
		if homingFlags ~= 0 then
			exclude = readu32(homingIn, h + 4)
			targetPosition = readVector32(homingIn, h + 8)
			delay, acquireTimer, reacquireTimer = readf64(homingIn, h + 24), readf64(homingIn, h + 32), readf64(homingIn, h + 40)
		end
	end
	local homing = homingFlags ~= 0
	local hasTargetPosition = bit32.btest(homingFlags, 2)
	local hasTarget = bit32.btest(homingFlags, 4)
	local explicit = bit32.btest(homingFlags, 8)
	local targetChange = 0
	local workerSearch = homing and spec.WorkerSearch == true and homingFrame ~= nil

	-- Mirrors Projectile.Step's loop (no rewind: no lag-compensated entity
	-- check).
	local guard = 0
	while remaining > MIN_STEP_DT and guard < MAX_SUBSTEPS do
		guard += 1
		local lifeRemaining = lifetime - age
		if lifeRemaining <= MIN_STEP_DT then
			if homing then writeTimers(homingOut, item, delay, acquireTimer, reacquireTimer, targetChange) end
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
		local maxDt = if homing and hasTarget and (turnRate :: number) > 0
			then Sweep.MaxHomingTurnStep / (turnRate :: number)
			else math.huge
		local stepDt = Planner.StepDt(position, velocity, accelerationVector, chunkScale, remaining, lifeRemaining,
			highRes, uniformTime, maxDt)
		if stepDt <= 0 then
			break
		end

		-- (what this substep starts from, for handing it back untouched)
		local startVelocity, startDelay, startAcquire, startReacquire = velocity, delay, acquireTimer, reacquireTimer
		if homing then
			if delay > 0 then
				delay -= stepDt
			else
				local searchDue = false
				if not hasTargetPosition then
					if spec.AutoAcquire then
						if acquireTimer - stepDt <= 0 then
							searchDue = true
						else
							acquireTimer -= stepDt
						end
					end
				elseif spec.Retarget and not explicit then
					if reacquireTimer - stepDt <= 0 then
						searchDue = true
					else
						reacquireTimer -= stepDt
					end
				end
				if searchDue then
					if not workerSearch then
						-- the main thread searches (a custom Filter): hand this substep back
						writeTimers(homingOut, item, startDelay, startAcquire, startReacquire, targetChange)
						Sweep.WriteOutput(output, item, CONTACT, position, startVelocity, age, remaining, guard - 1)
						return
					end
					-- (as Homing.update: reset the timer, then search from here)
					if hasTargetPosition then
						reacquireTimer = spec.ReacquireRate :: number
					else
						acquireTimer = (spec.AcquireInterval :: number) * (0.5 + math.random())
					end
					local found = searchTarget(homingFrame :: HomingFrame, position, spec.AcquireRadius, spec.TagMask or 0, exclude)
					if found > 0 then
						targetChange = found
						targetPosition = (homingFrame :: HomingFrame).Positions[found]
						hasTargetPosition, hasTarget, explicit = true, true, false
					else
						targetChange = -1
						hasTargetPosition, hasTarget, explicit = false, false, false
					end
				end
				if hasTargetPosition then
					local speed = velocity.Magnitude
					velocity = Math.rotateTowards(velocity, targetPosition - position, (turnRate :: number) * stepDt) * speed
				end
			end
		end

		local endVelocity, movementVelocity = ProjectileMotion.Integrate(velocity, acceleration, direction, gravity,
			minSpeed, maxSpeed, stepDt)
		local displacement = movementVelocity * stepDt
		local hit = castHits(position, displacement, radius, filter)
		if hit then
			-- hand this substep back untouched; Step redoes it serially (with
			-- this cast's result, so it needn't cast it again -- see onContact)
			if onContact and hit ~= true then
				onContact(item, position, displacement, hit)
			end
			writeTimers(homingOut, item, startDelay, startAcquire, startReacquire, targetChange)
			Sweep.WriteOutput(output, item, CONTACT, position, startVelocity, age, remaining, guard - 1)
			return
		end
		velocity = endVelocity
		position += displacement
		age += stepDt
		remaining -= stepDt / chunkScale
		if age >= lifetime - MIN_STEP_DT then
			if homing then writeTimers(homingOut, item, delay, acquireTimer, reacquireTimer, targetChange) end
			Sweep.WriteOutput(output, item, EXPIRED, position, velocity, age, remaining, guard)
			return
		end
	end
	if homing then writeTimers(homingOut, item, delay, acquireTimer, reacquireTimer, targetChange) end
	Sweep.WriteOutput(output, item, DONE, position, velocity, age, remaining, guard)
end

return Sweep
