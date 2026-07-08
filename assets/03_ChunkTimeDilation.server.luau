--[[
	Example 1 — Heartbeat basics
	Connections, priorities, intervals, per-connection time scale,
	dilated delays/waits, and inspecting the loop.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Heartbeat = require(Shared.Heartbeat)

-- Runs every frame. dt is already scaled by the global time scale.
local frameConnection = Heartbeat.Connect(function(dt, connection)
	-- physics-ish work here
end, { Name = "Example.EveryFrame", Priority = 0 })

-- Runs every 0.5 dilated seconds; dt is the real accumulated local time.
Heartbeat.ConnectInterval(0.5, function(dt)
	print(`half-second tick (elapsed {dt})`)
end, { Name = "Example.Ticker" })

-- A connection living at half speed: its dt and LocalTime run 2x slower.
local slowConnection = Heartbeat.Connect(function(dt, connection)
	-- connection.LocalTime advances at 0.5x
end, { Name = "Example.SlowSystem", TimeScale = 0.5 })

-- One-shot after 3 dilated seconds (stretches if global time slows).
Heartbeat.Delay(3, function(elapsed)
	print(`fired after {elapsed} local seconds`)
end)

-- Slow the whole game to 30% for two real seconds, then restore.
task.spawn(function()
	Heartbeat.SetGlobalTimeScale(0.3)
	task.wait(2)
	Heartbeat.SetGlobalTimeScale(1)
end)

-- Yield in dilated time from any coroutine:
task.spawn(function()
	local elapsed = Heartbeat.Wait(1) -- 1 dilated second
	print(`waited {elapsed}`)
end)

-- Inspect the loop.
task.delay(5, function()
	local stats = Heartbeat.GetStats()
	print(`{stats.ConnectionCount} connections, avg frame cost {stats.AvgFrameTime * 1000} ms`)
	for _, connection in Heartbeat.GetConnections() do
		print(connection.Name, "localTime:", connection.LocalTime, "scale:", connection.TimeScale)
	end
	frameConnection:Disconnect()
	slowConnection:Disconnect()
end)
