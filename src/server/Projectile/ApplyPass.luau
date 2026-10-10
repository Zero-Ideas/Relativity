--!strict
--!native
--!optimize 2
-- Native bookkeeping for the worker's resident records. The main thread
-- still resolves contacts and dirty records; this pass only commits the
-- ordinary movement results the worker previously copied in its script.
local Sweep = require(script.Parent.Sweep)
local SafeMath = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("SafeMath"))

local IN, OUT = Sweep.InputStride, Sweep.OutputStride
local IN_MOTION, IN_AGE, IN_REMAINING = Sweep.InputMotion, Sweep.InputAge, Sweep.InputRemaining
local OUT_POSITION, OUT_AGE, OUT_REMAINING = Sweep.OutPosition, Sweep.OutAge, Sweep.OutRemaining
local HOMING_IN, HOMING_OUT = Sweep.HomingInStride, Sweep.HomingOutStride
local DONE, LIMIT = Sweep.Done, SafeMath.Limit

local ApplyPass = {}

function ApplyPass.Prepare(records: buffer, scales: buffer, timers: buffer, count: number, dt: number,
	 homingIn: buffer?)
	for item = 1, count do
		local i = item - 1
		local o = i * IN + IN_REMAINING
		buffer.writef64(records, o, buffer.readf64(records, o) + dt * buffer.readf64(scales, i * 8))
	end
	if homingIn then
		for item = 1, count do
			local h = (item - 1) * HOMING_IN
			if buffer.readu8(homingIn, h) ~= 0 then
				buffer.copy(homingIn, h + 24, timers, (item - 1) * 24, 24)
			end
		end
	end
end

function ApplyPass.Commit(records: buffer, timers: buffer, result: buffer, count: number,
	homingIn: buffer?, homingOut: buffer?, exceptions: { number }, changes: { number })
	for item = 1, count do
		local i = item - 1
		local o = i * OUT
		local homes = homingOut ~= nil and homingIn ~= nil and buffer.readu8(homingIn :: buffer, i * HOMING_IN) ~= 0
		if homes then
			local change = buffer.readf64(homingOut :: buffer, i * HOMING_OUT + 24)
			if change ~= 0 then
				table.insert(changes, item)
				table.insert(changes, change)
			end
		end
		if buffer.readu8(result, o) == DONE then
			local px = buffer.readf32(result, o + OUT_POSITION)
			local py = buffer.readf32(result, o + OUT_POSITION + 4)
			local pz = buffer.readf32(result, o + OUT_POSITION + 8)
			if math.abs(px) <= LIMIT and math.abs(py) <= LIMIT and math.abs(pz) <= LIMIT then
				local r = i * IN
				buffer.copy(records, r + IN_MOTION, result, o + OUT_POSITION, 24)
				buffer.writef64(records, r + IN_AGE, buffer.readf64(result, o + OUT_AGE))
				buffer.writef64(records, r + IN_REMAINING, buffer.readf64(result, o + OUT_REMAINING))
				if homes then
					buffer.copy(timers, i * 24, homingOut :: buffer, i * HOMING_OUT, 24)
				end
				continue
			end
		end
		table.insert(exceptions, item)
	end
end

return ApplyPass
