--!strict
--!native
--!optimize 2
--[[
	Projectile/ApplyPass.luau
	Pass 1 of Parallel.Apply, on its own: every worker result that is a plain
	"moved, hit nothing" for a projectile nothing touched is written straight
	into Store's columns and its slot's packed record; the rest are listed
	for the serial pass. Kept in a small module of its own so it gets native
	code generation regardless of the rest of Parallel.
]]

local SafeMath = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SafeMath"))
local Sweep = require(script.Parent.Sweep)
local Store = require(script.Parent.Store)

local IN, OUT = Sweep.InputStride, Sweep.OutputStride
local IN_MOTION, IN_AGE, IN_REMAINING = Sweep.InputMotion, Sweep.InputAge, Sweep.InputRemaining
local OUT_STATUS, OUT_POSITION, OUT_AGE, OUT_REMAINING = Sweep.OutStatus, Sweep.OutPosition, Sweep.OutAge, Sweep.OutRemaining
local S_MOTION, S_TIME, S_MARK, S_SCALE = Store.MotionStride, Store.TimeStride, Store.MarkStride, Store.ScaleStride
local S_HOMING, HOMING_OUT = Store.HomingStride, Sweep.HomingOutStride
local DEAD_OR_DIRTY = bit32.bor(Store.Dead, Store.Dirty)
local SWEEP_DONE = Sweep.Done
local LIMIT = SafeMath.Limit

-- Returns dropped, deferred, kept counts; fills `released` (items whose slot
-- to release) and `deferred` (items for the serial pass).
return function(motion: buffer, times: buffer, marks: buffer, flagsColumn: buffer, scalesColumn: buffer,
	data: buffer, input: buffer, count: number, slots: { number }, generations: { number }, scales: { number },
	deadlines: { number }, generationOf: { number }, sources: { any }, now: number, mark: number,
	released: { number }, deferred: { number }, homing: { boolean }?, homingOut: buffer?,
	homingTimers: buffer): (number, number, number)
	local dropped, slow, kept = 0, 0, 0
	for item = 1, count do
		local slot = slots[item]
		if generationOf[slot] ~= generations[item] then
			-- released since (the step loop dropped it): nothing to apply
			dropped += 1
			released[dropped] = item
			continue
		end
		local out = (item - 1) * OUT
		local plain = buffer.readu8(data, out + OUT_STATUS) == SWEEP_DONE
			and bit32.band(buffer.readu8(flagsColumn, slot), DEAD_OR_DIRTY) == 0 and now < deadlines[item]
		if plain then
			-- its scale is still the one it was sent with (own * source's; anything
			-- unusual goes to the serial code, which uses combinedTimeScale)
			local s = slot * S_SCALE
			local own = buffer.readf64(scalesColumn, s)
			local index = buffer.readu32(scalesColumn, s + 8)
			local sourceScale: any = if index ~= 0 then sources[index].TimeScale else 1
			plain = type(sourceScale) == "number" and sourceScale >= 0 and own >= 0 and sourceScale < LIMIT
				and own < LIMIT and sourceScale * own == scales[item]
		end
		if not plain then
			slow += 1
			deferred[slow] = item
			continue
		end
		-- position/velocity are float32 in the output, the column and the slot
		buffer.copy(motion, slot * S_MOTION, data, out + OUT_POSITION, 24)
		local age = buffer.readf64(data, out + OUT_AGE)
		local debt = buffer.readf64(data, out + OUT_REMAINING)
		local t = slot * S_TIME
		buffer.writef64(times, t, age)
		buffer.writef64(times, t + 8, debt)
		if homing and homing[item] and homingOut then
			-- (a homing item's timers, as the worker left them)
			buffer.copy(homingTimers, slot * S_HOMING, homingOut, (item - 1) * HOMING_OUT, 24)
		end
		local i = (item - 1) * IN
		buffer.copy(input, i + IN_MOTION, data, out + OUT_POSITION, 24)
		buffer.writef64(input, i + IN_AGE, age)
		buffer.writef64(input, i + IN_REMAINING, debt) -- (dispatch adds next frame's budget)
		local px = buffer.readf32(data, out + OUT_POSITION)
		local py = buffer.readf32(data, out + OUT_POSITION + 4)
		local pz = buffer.readf32(data, out + OUT_POSITION + 8)
		if math.abs(px) <= LIMIT and math.abs(py) <= LIMIT and math.abs(pz) <= LIMIT then
			buffer.writei32(marks, slot * S_MARK, mark)
			kept += 1
		else
			-- flew past SafeMath.Limit: dies in the step loop
			buffer.writei32(marks, slot * S_MARK, -mark)
			dropped += 1
			released[dropped] = item
		end
	end
	return dropped, slow, kept
end
