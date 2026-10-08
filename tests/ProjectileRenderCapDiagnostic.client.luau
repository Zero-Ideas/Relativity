-- Temporary diagnostic only: no renderer algorithm or persisted settings changes.
-- Run in a quiet Studio session; creates/clears the local user's benchmark batch.
local RS = game:GetService("RunService")
local Players = game:GetService("Players")
local Shared = game.ReplicatedStorage.Shared
local Client = require(Shared.Projectile.Client)
local Prediction = require(Shared.Projectile.Client.Prediction)
local Heartbeat = require(Shared.Heartbeat)
local Offload = require(Shared.VisualOffload)
local Schema = require(Shared.ProjectileBenchmark)
local originalSettings = Client.GetRenderSettings()
local connection
for _, c in Heartbeat.GetConnections() do
	if c.Name == "ProjectileSystem.ClientSimulate" then connection = c end
end
assert(connection, "Live client renderer not found")
local callback, simulate, project = connection.Callback, Prediction.simulate, Prediction.projectDeferred
local frames, seconds, simulations, probes, worst = 0, 0, 0, 0, 0
local sampling = false
local result
local listener = Offload.On("DebugBenchmarkResult", function(data) if data.SpawnMs then result = data end end)
local ok, err = pcall(function()
	local player = Players.LocalPlayer
	local character = player.Character or player.CharacterAdded:Wait()
	local root = character:WaitForChild("HumanoidRootPart")
	local camera = workspace.CurrentCamera
	local position = camera.CFrame.Position + camera.CFrame.LookVector * 50
	local settings = Schema.Defaults()
	settings.Count, settings.Pattern, settings.SpawnRadius = 10000, "Parallel", 0
	settings.SpawnOffset = position - root.Position
	settings.CustomDirection, settings.Direction = true, camera.CFrame.LookVector
	settings.TimeScale, settings.Lifetime, settings.MaxRealLifetime = 0, 20, 60
	settings.VisualSize = "0.03, 0.03, 0.03"
	Client.SetRenderSettings({MaxRendered = 10000, MaxDistance = 100000, MaxSmooth = 0, MaxUpdates = 2500})
	Offload.Fire("DebugBenchmark", {Action = "Run", Settings = settings})
	local deadline = os.clock() + 15
	repeat task.wait(0.05) until result or os.clock() > deadline
	assert(result and not result.Error and result.Spawned == 10000, "Test batch failed")
	repeat task.wait(0.05) until Client.GetStats().Visuals >= 10000 or os.clock() > deadline
	assert(Client.GetStats().Visuals >= 10000, "Visual batch did not arrive")
	Prediction.simulate = function(...)
		if sampling then simulations += 1 end
		return simulate(...)
	end
	Prediction.projectDeferred = function(...)
		if sampling then probes += 1 end
		return project(...)
	end
	connection.Callback = function(...)
		local start = os.clock()
		callback(...)
		if sampling then
			local cost = os.clock() - start
			frames += 1; seconds += cost; worst = math.max(worst, cost)
		end
	end
	for _, cap in {10000, 500, 10000} do
		Client.SetRenderSettings({MaxRendered = cap})
		task.wait(0.4) -- exclude initial parking/re-entry
		frames, seconds, simulations, probes, worst = 0, 0, 0, 0, 0
		sampling = true
		for _ = 1, 60 do RS.RenderStepped:Wait() end
		sampling = false
		print(string.format("[RenderCapDiagnostic] cap=%d frames=%d avg=%.3fms worst=%.3fms simulate/frame=%.0f deferred/frame=%.0f total-visits/frame=%.0f",
			cap, frames, seconds / math.max(frames, 1) * 1000, worst * 1000,
			simulations / math.max(frames, 1), probes / math.max(frames, 1), (simulations + probes) / math.max(frames, 1)))
	end
end)
sampling = false
connection.Callback, Prediction.simulate, Prediction.projectDeferred = callback, simulate, project
Client.SetRenderSettings(originalSettings)
listener:Disconnect()
Offload.Fire("DebugBenchmark", {Action = "Clear"})
assert(ok, err)
print("[RenderCapDiagnostic] Restored callbacks and original render settings")
