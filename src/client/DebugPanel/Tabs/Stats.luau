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
local ProjectileClient = require(Shared.Projectile.Client)
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
	local sStep = statLine(tab, "Heartbeat / reported physics ms")
	local sPrimitives = statLine(tab, "Server physics components")
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
	local sCasts = statLine(tab, "  engine casts per frame (sphere: chunk with an entity / ray: elsewhere)")
	local sReasons = statLine(tab, "  not skipped: not baked / too wide / outside terrain / near geometry (of which moving)")
	local sParallel = statLine(tab, "Parallel movement")
	local sWorkers = statLine(tab, "Worker ms per frame (slowest / all)")
	local sSlots = statLine(tab, "  Slots (held / packed / released per frame)")
	local sDispatch = statLine(tab, "  Main: dispatch ms (setup / pack / budget / send)")
	local sApply = statLine(tab, "  Main: apply ms (decode / buffer path / serial finish / release)")
	local sSerial = statLine(tab, "    serial: contacts ms (count) / fallback steps / repack")
	local sDecode = statLine(tab, "    results KB per frame")
	local sHeap = statLine(tab, "  Lua heap MB / GC freed MB per frame")
	local sSplit = statLine(tab, "Frame split ms (ours / sim: workers+physics+others / between frames)")
	local sSim = statLine(tab, "  sim split ms (slowest worker / physics / early handlers / engine+other)")
	local sHandlers = statLine(tab, "Heartbeat handlers ms/frame (costliest)")
	local sNetChannels = statLine(tab, "Network out by channel (msgs/s · KB/s · list items/s)")
	local sSpawn = statLine(tab, "  spawning ms (count per frame)")
	local sBeam = statLine(tab, "  beam ms (heads / links / stream), samples (asleep, coasting), joiners, links kept whole, new joiners per frame")
	local sAwake = statLine(tab, "    awake beam samples by reason (chain can't / clipped / dilated / short window / moving part / geometry / unknown)")
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
		sPrimitives(fmt("%d", s.PhysicsPrimitives))
		sPing(fmt("%.0f ms", s.PingMs))
		serverOutPerPlayer = if s.SendKbps then s.SendKbps / math.max(s.Players or 1, 1) else nil
		sNet(`{rate(s.SendKbps)} / {rate(s.ReceiveKbps, s.ReceiveApprox)} KB/s`)
		sMemory(fmt("%.0f MB", s.MemoryMb))
		sInstances(fmt("%d", s.Instances))
		if typeof(s.BeamSamples) == "number" then
			sProjectiles(string.format("%s  (+ %d beam samples in %d chains)", fmt("%d", s.Projectiles), s.BeamSamples,
				tonumber(s.BeamChains) or 0))
		else
			sProjectiles(fmt("%d", s.Projectiles))
		end
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
		sSerial(string.format("%s (%d) / %s / %s", ms("SerialContact"), tonumber(p.SerialContacts) or 0, ms("SerialFallback"), ms("SerialRepack")))
		sDecode(string.format("%.0f KB", tonumber(p.TransferKB) or 0))
		sHeap(string.format("%.0f / %.1f", tonumber(p.HeapMB) or 0, tonumber(p.GcFreedMB) or 0))
		sSplit(ms("FrameOurs", "FrameSimulation", "FrameBetween"))
		-- what the sim gap holds: the parallel phase's slowest worker, the
		-- engine's physics step, our Heartbeat handlers that run before the
		-- projectile step, and whatever's left (other engine work)
		local simMs = tonumber(p.FrameSimulation) or 0
		local workerMs = tonumber(s.SlowestWorkerMs) or 0
		local physicsMs = tonumber(s.PhysicsMs) or 0
		local earlyMs = tonumber(s.EarlyHandlersMs) or 0
		sSim(string.format("%.2f / %.2f / %.2f / %.2f", workerMs, physicsMs, earlyMs, math.max(simMs - workerMs - physicsMs - earlyMs, 0)))
		local handlerParts = {}
		for _, entry in (if typeof(s.Handlers) == "table" then s.Handlers else {}) do
			table.insert(handlerParts, string.format("%s %.2f", tostring(entry.Name), tonumber(entry.Ms) or 0))
		end
		sHandlers(if #handlerParts > 0 then table.concat(handlerParts, "  ·  ") else "-")
		local netParts = {}
		for _, entry in (if typeof(s.NetChannels) == "table" then s.NetChannels else {}) do
			table.insert(netParts, string.format("%s %.0f · %.1f · %.0f", tostring(entry.Channel), tonumber(entry.PerSecond) or 0,
				tonumber(entry.KBps) or 0, tonumber(entry.ItemsPerSecond) or 0))
		end
		sNetChannels(if #netParts > 0 then table.concat(netParts, "   ") else "-")
		sSpawn(string.format("%s  (%.0f)", ms("Spawn"), tonumber(p.Spawned) or 0))
		if typeof(s.BeamSamples) == "number" then
			-- BeamChain: every head step, every link, the event stream
			sBeam(string.format("%s, %d samples (%d asleep, %d coasting), %d joiners, %d whole, %.1f new",
				ms("BeamHeads", "BeamLinkPass", "BeamReplicate"), s.BeamSamples, tonumber(s.BeamSleeping) or 0,
				tonumber(s.BeamCoasting) or 0, tonumber(s.BeamJoiners) or 0, tonumber(s.BeamLazyLinks) or 0,
				tonumber(p.BeamCreated) or 0))
			local w = if typeof(s.BeamWakeful) == "table" then s.BeamWakeful else {}
			local function n(key: string): number
				return tonumber(w[key]) or 0
			end
			sAwake(string.format("%d / %d / %d / %d / %d / %d / %d", n("Chain"), n("Clipped"), n("Dilated"), n("Window"),
				n("Moving"), n("Static"), n("Unknown")))
		else
			sAwake("-")
			-- legacy handler: span casts / plan+connect / new joiners / rest
			local beamTotal = tonumber(s.BeamMs) or 0
			local beamKnown = (tonumber(p.BeamResolve) or 0) + (tonumber(p.BeamPlan) or 0) + (tonumber(p.BeamCreate) or 0)
			sBeam(string.format("%s / %.2f, %.0f links, %.1f joiners", ms("BeamResolve", "BeamPlan", "BeamCreate"),
				math.max(beamTotal - beamKnown, 0), tonumber(p.BeamLinks) or 0, tonumber(p.BeamCreated) or 0))
		end
		sLoop(ms("StepLoop", "StepDestroy"))
		local reasons = if typeof(s.RaycastReasons) == "table" then s.RaycastReasons else {}
		local checks = math.max(tonumber(s.RaycastChecks) or 0, 1)
		local function pct(index: number): string
			return string.format("%d%%", math.floor((tonumber(reasons[index]) or 0) / checks * 100 + 0.5))
		end
		sReasons(`{pct(1)} / {pct(2)} / {pct(3)} / {pct(4)} ({pct(5)})`)
		if s.OccupancyReady == false then
			sSkipped("baking map...")
		elseif typeof(s.RaycastChecks) == "number" and s.RaycastChecks > 0 then
			sSkipped(string.format("%d%% of %d  (%s cells, %s moving parts)", math.floor(s.RaycastsSkipped / s.RaycastChecks * 100 + 0.5),
				s.RaycastChecks, tostring(s.OccupancyCells), tostring(s.OccupancyDynamic)))
		else
			sSkipped("-")
		end
		sCasts(string.format("%.0f / %.0f", tonumber(s.CastsSphere) or 0, tonumber(s.CastsRay) or 0))
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
		local clientStats = ProjectileClient.GetStats()
		cVisuals(fmt("%d  (+ %d beam chains, %d samples)", clientStats.Visuals, clientStats.BeamChains or 0,
			clientStats.BeamSamples or 0))
	end

	return { Active = setActive, Tick = sample }
end
