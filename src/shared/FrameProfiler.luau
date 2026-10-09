--!strict
--!optimize 2
--[[
	FrameProfiler (shared): per-system script time for anything hooked to a
	frame signal directly (RunService.Heartbeat / RenderStepped / Stepped /
	PreSimulation, BindToRenderStep), averaged per frame. The shared
	Heartbeat module times its own handlers (Heartbeat.TakeProfile); this
	covers everything else, so the debug panel can show where script time
	goes outside the projectile system.

	  FrameProfiler.Connect(signal, name, fn) -> RBXScriptConnection
	      signal:Connect(fn), timed under `name`
	  FrameProfiler.Wrap(name, fn) -> fn   (e.g. for BindToRenderStep)
	  FrameProfiler.Add(name, seconds)     (a section measured by hand)
	  FrameProfiler.Take() -> { { Name, Ms, Calls } }
	      ms and calls per frame since the last Take, costliest first; resets

	Cost: two os.clock() reads per timed call.
]]

local RunService = game:GetService("RunService")

local FrameProfiler = {}

local totals: { [string]: number } = {}
local calls: { [string]: number } = {}
local frames = 0
local clock = os.clock

RunService.Heartbeat:Connect(function()
	frames += 1
end)

function FrameProfiler.Add(name: string, seconds: number)
	totals[name] = (totals[name] or 0) + seconds
	calls[name] = (calls[name] or 0) + 1
end

function FrameProfiler.Wrap<A...>(name: string, fn: (A...) -> ()): (A...) -> ()
	return function(...: A...)
		local started = clock()
		fn(...)
		totals[name] = (totals[name] or 0) + clock() - started
		calls[name] = (calls[name] or 0) + 1
	end
end

function FrameProfiler.Connect(signal: RBXScriptSignal, name: string, fn: (...any) -> ()): RBXScriptConnection
	return signal:Connect(FrameProfiler.Wrap(name, fn))
end

function FrameProfiler.Take(): { { Name: string, Ms: number, Calls: number } }
	local count = math.max(frames, 1)
	local result = {}
	for name, seconds in totals do
		table.insert(result, { Name = name, Ms = seconds / count * 1000, Calls = (calls[name] or 0) / count })
	end
	table.sort(result, function(a, b)
		return a.Ms > b.Ms
	end)
	table.clear(totals)
	table.clear(calls)
	frames = 0
	return result
end

return FrameProfiler
