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
