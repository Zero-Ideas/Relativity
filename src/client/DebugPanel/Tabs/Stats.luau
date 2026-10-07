--!optimize 2
--[[
	Stats tab: client and server stats. Client frame sampling and the
	server's stats stream only run while this tab is showing.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)
local Util = require(script.Parent.Parent.Util)
local ProjectileClient = require(Shared.ProjectileClient)
local statLine = Util.statLine
local fmt, readStat = Util.fmt, Util.readStat

-- In a Studio playtest DataReceiveKbps reads 0 on both sides while
-- DataSendKbps works (the Stats.Network items that do report it are not
-- readable from game scripts). One side's inbound is the other's outbound, so
-- a 0 inbound is filled from the server's per-player outbound and shown as ~.
local function rate(value: number?, approx: boolean?): string
	return (if approx then "~" else "") .. fmt("%.1f", value)
end

local localPlayer = Players.LocalPlayer

return function(window)
	local tab = window:CreateTab({ Name = "Stats" })

	tab:Separator({ Text = "Client" })
	local cFps = statLine(tab, "FPS")
	local cFrame = statLine(tab, "Frame ms (avg / worst)")
	local cPing = statLine(tab, "Ping")
	local cNet = statLine(tab, "Data in / out")
	local cMemory = statLine(tab, "Memory")
	local cInstances = statLine(tab, "Instances")
	local cVisuals = statLine(tab, "Projectile visuals")

	tab:Separator({ Text = "Server" })
	local sFps = statLine(tab, "Heartbeat FPS")
	local sFrame = statLine(tab, "Frame ms (avg / worst)")
	local sStep = statLine(tab, "Heartbeat / physics ms")
	local sPing = statLine(tab, "Ping (server-side)")
	local sNet = statLine(tab, "Data out / in")
	local sMemory = statLine(tab, "Memory")
	local sInstances = statLine(tab, "Instances")
	local sProjectiles = statLine(tab, "Projectiles")
	local sProjectileStep = statLine(tab, "Projectile movement ms (avg / worst)")
	local sBeamStep = statLine(tab, "Beam bodies ms (avg / worst)")
	local sReplication = statLine(tab, "Projectile replication ms (avg / worst)")
	local sProjectileTotal = statLine(tab, "Projectile total ms")
	local sSkipped = statLine(tab, "Raycasts skipped (empty space)")
	local sParallel = statLine(tab, "Parallel movement")
	local sWorkers = statLine(tab, "Worker ms per frame (slowest / all)")
	local sSlots = statLine(tab, "  Slots (held / packed / released per frame)")
	local sDispatch = statLine(tab, "  Main: dispatch ms (setup / pack / budget / send)")
	local sApply = statLine(tab, "  Main: apply ms (decode / buffer path / serial finish / release)")
	local sDecode = statLine(tab, "    results KB per frame")
	local sHeap = statLine(tab, "  Lua heap MB / GC freed MB per frame")
	local sLoop = statLine(tab, "  Main: step loop ms (loop / destroys)")
	local sQueues = statLine(tab, "Visual queue (spawn / hit)")
	local sBeams = statLine(tab, "Beam pose updates (total)")
	local sEntities = statLine(tab, "Entities")
	local sChunks = statLine(tab, "Chunks (loaded / total)")
	local sPlayers = statLine(tab, "Players / world time")

	local serverOutPerPlayer: number? = nil
	VisualOffload.On("DebugServerStats", function(s)
		if typeof(s) ~= "table" then
			return
		end
		sFps(fmt("%.0f", s.Fps))
		sFrame(`{fmt("%.2f", s.FrameMs)} / {fmt("%.2f", s.WorstFrameMs)}`)
		sStep(`{fmt("%.2f", s.HeartbeatMs)} / {fmt("%.2f", s.PhysicsMs)}`)
		sPing(fmt("%.0f ms", s.PingMs))
		serverOutPerPlayer = if s.SendKbps then s.SendKbps / math.max(s.Players or 1, 1) else nil
		sNet(`{rate(s.SendKbps)} / {rate(s.ReceiveKbps, s.ReceiveApprox)} KB/s`)
		sMemory(fmt("%.0f MB", s.MemoryMb))
		sInstances(fmt("%d", s.Instances))
		sProjectiles(fmt("%d", s.Projectiles))
		-- each phase, and how much of the whole server frame they add up to
		local function share(ms: any): string
			return if typeof(s.FrameMs) == "number" and s.FrameMs > 0 and typeof(ms) == "number"
				then string.format("  (%d%%)", math.floor(ms / s.FrameMs * 100 + 0.5))
				else ""
		end
		sProjectileStep(`{fmt("%.2f", s.StepMs)} / {fmt("%.2f", s.StepWorstMs)}{share(s.StepMs)}`)
		sBeamStep(`{fmt("%.2f", s.BeamMs)} / {fmt("%.2f", s.BeamWorstMs)}{share(s.BeamMs)}`)
		sReplication(`{fmt("%.2f", s.ReplicationMs)} / {fmt("%.2f", s.ReplicationWorstMs)}{share(s.ReplicationMs)}`)
		local total = (tonumber(s.StepMs) or 0) + (tonumber(s.BeamMs) or 0) + (tonumber(s.ReplicationMs) or 0)
		sProjectileTotal(`{fmt("%.2f", total)}{share(total)} of a {fmt("%.1f", s.FrameMs)} ms frame`)
		local parallelSteps = tonumber(s.ParallelSteps) or 0
		local resumed = tonumber(s.ResumedSteps) or 0
		local allSteps = parallelSteps + resumed + (tonumber(s.SerialSteps) or 0) + (tonumber(s.FallbackSteps) or 0)
		if allSteps > 0 then
			sParallel(string.format("%d%% fully on %d workers, %d%% finished serially at a contact  (fallback %d, late %d)",
				math.floor(parallelSteps / allSteps * 100 + 0.5), tonumber(s.ParallelWorkers) or 0,
				math.floor(resumed / allSteps * 100 + 0.5), tonumber(s.FallbackSteps) or 0, tonumber(s.LateSteps) or 0))
		else
			sParallel("-")
		end
		sWorkers(`{fmt("%.2f", s.SlowestWorkerMs)} / {fmt("%.2f", s.WorkerMs)}`)
		-- main-thread breakdown (~ rows are sampled estimates of the loop above them)
		local p = if typeof(s.MainProfile) == "table" then s.MainProfile else {}
		local function ms(...: string): string
			local parts = {}
			for _, key in { ... } do
				table.insert(parts, string.format("%.2f", tonumber(p[key]) or 0))
			end
			return table.concat(parts, " / ")
		end
		sSlots(string.format("%d / %d / %d", tonumber(p.Slots) or 0, tonumber(p.Acquired) or 0, tonumber(p.Released) or 0))
		sDispatch(ms("DispatchSetup", "DispatchAcquire", "DispatchLoop", "DispatchSend"))
		sApply(ms("ApplyDecode", "ApplyLoop", "ApplySlow", "ApplyRelease"))
		sDecode(string.format("%.0f KB", tonumber(p.TransferKB) or 0))
		sHeap(string.format("%.0f / %.1f", tonumber(p.HeapMB) or 0, tonumber(p.GcFreedMB) or 0))
		sLoop(ms("StepLoop", "StepDestroy"))
		if s.OccupancyReady == false then
			sSkipped("baking map...")
		elseif typeof(s.RaycastChecks) == "number" and s.RaycastChecks > 0 then
			sSkipped(string.format("%d%% of %d  (%s cells, %s moving parts)", math.floor(s.RaycastsSkipped / s.RaycastChecks * 100 + 0.5),
				s.RaycastChecks, tostring(s.OccupancyCells), tostring(s.OccupancyDynamic)))
		else
			sSkipped("-")
		end
		sQueues(`{fmt("%d", s.PendingSpawns)} / {fmt("%d", s.PendingHits)}`)
		sBeams(fmt("%d", s.BeamPoseUpdates))
		sEntities(fmt("%d", s.Entities))
		sChunks(`{fmt("%d", s.LoadedChunks)} / {fmt("%d", s.Chunks)}`)
		sPlayers(`{fmt("%d", s.Players)} / {fmt("x%.2f", s.GlobalTimeScale)}`)
	end)

	-- Client frame sampling; only connected while the tab is showing.
	local frames, frameTime, worstFrame = 0, 0, 0
	local connection: RBXScriptConnection? = nil

	local function setActive(active: boolean)
		if active and not connection then
			frames, frameTime, worstFrame = 0, 0, 0
			connection = RunService.RenderStepped:Connect(function(dt)
				frames += 1
				frameTime += dt
				if dt > worstFrame then
					worstFrame = dt
				end
			end)
		elseif not active and connection then
			connection:Disconnect()
			connection = nil
		end
		VisualOffload.Fire("DebugStats", active)
	end

	local function sample()
		local averageMs = if frames > 0 then frameTime / frames * 1000 else nil
		cFps(fmt("%.0f", if frameTime > 0 then frames / frameTime else nil))
		cFrame(`{fmt("%.2f", averageMs)} / {fmt("%.2f", worstFrame * 1000)}`)
		frames, frameTime, worstFrame = 0, 0, 0
		cPing(fmt("%.0f ms", localPlayer:GetNetworkPing() * 1000))
		local received, sent = readStat("DataReceiveKbps"), readStat("DataSendKbps")
		local approx = (received or 0) <= 0 and serverOutPerPlayer ~= nil
		cNet(`{rate(if approx then serverOutPerPlayer else received, approx)} / {rate(sent)} KB/s`)
		-- lets the server fill its own 0 inbound (see DebugService)
		VisualOffload.Fire("DebugClientNet", sent)
		cMemory(fmt("%.0f MB", Stats:GetTotalMemoryUsageMb()))
		cInstances(fmt("%d", readStat("InstanceCount")))
		cVisuals(fmt("%d", ProjectileClient.GetStats().Visuals))
	end

	return { Active = setActive, Tick = sample }
end
