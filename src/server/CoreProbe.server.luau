--!strict
--[[
	CoreProbe (server)
	How many CPU cores the server actually gives parallel Luau (there's no
	API for it). Run normally, this script makes PROBE_ACTORS Actors, each
	holding a clone of itself. A probe has one of them do a fixed amount of
	work alone (how long one core takes), then all of them at once: N x the
	single time / the wall time for all N is how many ran side by side.

	Runs once PROBE_DELAY seconds after the server starts, and again on
	request (DebugStream command "coreprobe"). The result (median of
	ROUNDS) goes in ServerScriptService's "CoreProbeCores" attribute, which
	DebugService streams with its stats (Stats tab: Server cores). A probe
	keeps every core busy for a few frames: a short hitch, so it isn't
	repeated on its own.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PROBE_ACTORS = 16 -- the most cores it can report
local TARGET_SECONDS = 0.004 -- each actor's share of work, calibrated to about this
local ROUNDS = 3
local PROBE_DELAY = 15

local actor = script:GetActor()

if actor then
	-- inside an Actor: do `iterations` of busy work in parallel, report when it ran
	local done = (actor.Parent :: Instance):WaitForChild("Done") :: BindableEvent
	actor:BindToMessageParallel("Run", function(round: number, iterations: number)
		local started = os.clock()
		local x = 0
		for i = 1, iterations do
			x += math.sqrt(i)
		end
		local finished = os.clock()
		task.synchronize()
		done:Fire(round, started, finished, x)
	end)
	return
end

local folder = Instance.new("Folder")
folder.Name = "CoreProbeActors"
folder.Parent = script.Parent
local doneEvent = Instance.new("BindableEvent")
doneEvent.Name = "Done"
doneEvent.Parent = folder
local actors: { Actor } = {}
for index = 1, PROBE_ACTORS do
	local probeActor = Instance.new("Actor")
	probeActor.Name = `CoreProbe{index}`
	local clone = script:Clone()
	clone.Parent = probeActor
	probeActor.Parent = folder
	table.insert(actors, probeActor)
end

local nextRound = 0

-- Sends `iterations` to `count` actors and waits for them: (sum of each
-- one's run time, wall time from the first start to the last finish).
local function run(count: number, iterations: number): (number, number)
	nextRound += 1
	local round = nextRound
	local starts, finishes, busy, received = math.huge, -math.huge, 0, 0
	local connection = doneEvent.Event:Connect(function(id: number, started: number, finished: number)
		if id == round then
			received += 1
			busy += finished - started
			starts, finishes = math.min(starts, started), math.max(finishes, finished)
		end
	end)
	for index = 1, count do
		actors[index]:SendMessage("Run", round, iterations)
	end
	local deadline = os.clock() + 5
	while received < count and os.clock() < deadline do
		task.wait()
	end
	connection:Disconnect()
	return busy, if received == count then finishes - starts else 0
end

local function probe(): number?
	-- calibrate the work so one actor's share takes about TARGET_SECONDS
	local iterations = 20000
	for _ = 1, 6 do
		local single = run(1, iterations)
		if single >= TARGET_SECONDS * 0.5 then
			iterations = math.floor(iterations * TARGET_SECONDS / single)
			break
		end
		iterations *= 4
	end
	local results = {}
	for _ = 1, ROUNDS do
		local single = run(1, iterations)
		local _, wall = run(PROBE_ACTORS, iterations)
		if single > 0 and wall > 0 then
			table.insert(results, math.clamp(PROBE_ACTORS * single / wall, 1, PROBE_ACTORS))
		end
	end
	if #results == 0 then
		return nil
	end
	table.sort(results)
	local cores = results[(#results + 1) // 2]
	ServerScriptService:SetAttribute("CoreProbeCores", math.floor(cores * 10 + 0.5) / 10)
	print(string.format("[CoreProbe] about %.1f cores for parallel Luau (%d actors, rounds: %s)", cores, PROBE_ACTORS,
		table.concat((function()
			local parts = {}
			for _, value in results do
				table.insert(parts, string.format("%.1f", value))
			end
			return parts
		end)(), ", ")))
	return cores
end

task.delay(PROBE_DELAY, probe)

local Server = script.Parent
local DebugStream = require(Server:WaitForChild("DebugStream"))
DebugStream.OnCommand("coreprobe", function()
	probe()
end)
