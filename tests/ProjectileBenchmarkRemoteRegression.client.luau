-- Studio client only. Creates harmless benchmark shots and clears ONLY those.
local Shared = game.ReplicatedStorage.Shared
local Schema = require(Shared.ProjectileBenchmark)
local Offload = require(Shared.VisualOffload)
local messages = {}
local stage = "start"
local listener = Offload.On("DebugBenchmarkResult", function(data)
	print("[BenchmarkRemoteReply]", stage, data.Status or data.Error, data.Spawned)
	table.insert(messages, data)
end)
local function receive(predicate)
	local deadline = os.clock() + 20
	repeat
		for index, data in messages do
			if predicate(data) then table.remove(messages, index); return data end
		end
		task.wait(0.05)
	until os.clock() >= deadline
	error("Timed out waiting for benchmark result at " .. stage)
end
local function clear()
	Offload.Fire("DebugBenchmark", {Action = "Clear"})
	receive(function(data) return data.Status == "Cleared your benchmark projectiles" end)
end
local function run(overrides)
	task.wait(0.6)
	local settings = Schema.Defaults()
	settings.TimeScale, settings.MaxRealLifetime = 0, 30
	for key, value in overrides do settings[key] = value end
	Offload.Fire("DebugBenchmark", {Action = "Run", Settings = settings})
	local result = receive(function(data) return data.Error ~= nil or data.SpawnMs ~= nil end)
	assert(not result.Error, result.Error)
	assert(result.Spawned == settings.Count, "Wrong spawn count")
	print(`[ProjectileBenchmarkRemoteRegression] {settings.Count} shots: {result.SpawnMs} ms spawn CPU`)
	clear()
end
local ok, problem = pcall(function()
	clear()
	stage = "10k server-only"
	run({Count = 10000, Visualize = false})
	stage = "replicated"
	run({Count = 1000, Visualize = true, Pattern = "Grid", GridSpacing = 0.25})
	stage = "homing"
	run({Count = 16, HomingEnabled = true, Visualize = false})
	stage = "beams"
	run({Count = 16, BeamEnabled = true, Radius = 0.35, Visualize = true})
	stage = "malformed"
	task.wait(0.6)
	Offload.Fire("DebugBenchmark", {Action = "Run", Settings = {Count = 50001}})
	assert(receive(function(data) return data.Error ~= nil end).Error, "Malformed request accepted")
	stage = "batched cancellation"
	task.wait(0.6)
	local settings = Schema.Defaults()
	settings.Count, settings.BatchSize, settings.Visualize = 2000, 1, false
	settings.TimeScale = 0
	Offload.Fire("DebugBenchmark", {Action = "Run", Settings = settings})
	task.wait(0.1)
	Offload.Fire("DebugBenchmark", {Action = "Cancel"})
	local result = receive(function(data) return data.SpawnMs ~= nil or data.Error ~= nil end)
	assert(not result.Error, result.Error)
	assert(result.Spawned > 0 and result.Spawned < settings.Count, "Batched cancellation did not stop spawning")
	clear()
end)
listener:Disconnect()
assert(ok, problem)
print("[ProjectileBenchmarkRemoteRegression] PASS: 10k server-only, replication, homing, beams, validation, cancel/clear")
