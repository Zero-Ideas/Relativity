--!strict
--[[
	ProjectileBench (server, Studio only)
	A steady-state projectile load for the local analytics server
	(tools/stats_server.py): keeps about Target projectiles alive for Seconds,
	firing from the first player's character, then stops. Start / end
	markers go to the stream as "bench" messages so tools/bench_report.py can
	summarise exactly that window.

	    python tools/send_command.py bench Mode=basic Target=60000 Seconds=20 Label=b0
	    python tools/send_command.py bench Mode=full Target=60000 Seconds=20 Label=f0
	    python tools/send_command.py benchstop

	Modes:
	  basic  straight shots, nothing else, server-only (no replication)
	  full   every movement feature at once: gravity, acceleration toward a
	         speed cap, a sphere radius, bounces, piercing, homing
	  (every mode is server-only: no replication, so it measures the server
	  heartbeat alone)
	  nohoming  full without homing
	  rewind basic + RewindSeconds (lag compensation: always the serial path)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

if not RunService:IsStudio() then
	return
end

local Server = ServerScriptService:WaitForChild("Server")
local Projectile = require(Server:WaitForChild("Projectile"))
local DebugStream = require(Server:WaitForChild("DebugStream"))
local Entity = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Entity"))
local Heartbeat = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Heartbeat"))

local SPEED = 220
local LIFETIME = 4
local MAX_PER_FRAME = 4000 -- ramp: at most this many new shots a frame

local running: { label: string, stop: boolean }? = nil

local function configFor(mode: string, character: Model): any
	local shooter = Entity.Get(character)
	local config: any = {
		Speed = SPEED,
		Lifetime = LIFETIME,
		Damage = 0,
		Source = shooter,
		IgnoreInstances = { character },
		Visualize = false,
	}
	if mode == "full" or mode == "nohoming" then
		config.Gravity = Vector3.new(0, -40, 0)
		config.Acceleration = 30
		config.MaxSpeed = 320
		config.Radius = 0.4
		config.Bounces = 2
		config.Restitution = 0.6
		config.Penetration = 2
		config.MaxPierces = 1
		config.Homing = if mode == "nohoming" then nil else {
			AcquireRadius = 150,
			TargetTags = { "Enemy" },
			Retarget = true,
			ReacquireRate = 0.3,
			TurnRate = math.rad(140),
			Delay = 0.05,
		}
	elseif mode == "rewind" then
		config.RewindSeconds = 0.1
	end
	return config
end

local random = Random.new(1)

-- Where every run fires from: fixed for the session (the first SpawnLocation,
-- else the character's spot at the first run), so runs see the same geometry.
local benchOrigin: Vector3? = nil
local function originFor(root: BasePart): Vector3
	if not benchOrigin then
		local spawn = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
		benchOrigin = if spawn then spawn.Position + Vector3.new(0, 5, 0) else root.Position + Vector3.new(0, 2, 0)
	end
	return benchOrigin :: Vector3
end

-- Aimed-ish shots: any yaw, a little below to well above level, from head
-- height -- so some skim the floor and hit walls, like real fire.
local function direction(): Vector3
	local yaw = random:NextNumber(0, math.pi * 2)
	local pitch = math.rad(random:NextNumber(-6, 25))
	return Vector3.new(math.cos(yaw) * math.cos(pitch), math.sin(pitch), math.sin(yaw) * math.cos(pitch))
end

local function run(message: any)
	if running then
		running.stop = true
	end
	local player = Players:GetPlayers()[1]
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not root then
		DebugStream.Send("bench", { phase = "error", text = "no character to fire from" })
		return
	end
	local mode = if message.Mode == "full" or message.Mode == "rewind" or message.Mode == "nohoming" then message.Mode else "basic"
	local target = math.clamp(tonumber(message.Target) or 20000, 1, 300000)
	local seconds = math.clamp(tonumber(message.Seconds) or 20, 1, 300)
	local label = tostring(message.Label or mode)
	local state = { label = label, stop = false }
	running = state
	local compiled = Projectile.Compile(configFor(mode, character))
	random = Random.new(tonumber(message.Seed) or 1) -- (the same shot pattern every run)
	local origin = originFor(root)
	DebugStream.Send("bench", { phase = "start", label = label, mode = mode, target = target, seconds = seconds,
		origin = { origin.X, origin.Y, origin.Z } })
	print(`[Bench] {label}: {mode}, {target} projectiles for {seconds} s`)
	-- Profile=1: the workers' detailed phase timing for this run (it costs a little)
	local profile = tonumber(message.Profile) == 1
	ServerScriptService:SetAttribute("ProjectileProfile", if profile then true else nil)
	-- TimeScale=x: the world time scale for the run (restored after)
	local previousScale = Heartbeat.GetGlobalTimeScale()
	local timeScale = tonumber(message.TimeScale)
	if timeScale then
		Heartbeat.SetGlobalTimeScale(timeScale)
	end
	local started = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function()
		if state.stop or os.clock() - started >= seconds or not root.Parent then
			connection:Disconnect()
			if timeScale then
				Heartbeat.SetGlobalTimeScale(previousScale)
			end
			ServerScriptService:SetAttribute("ProjectileProfile", nil)
			if running == state then
				running = nil
			end
			DebugStream.Send("bench", { phase = "end", label = label, mode = mode })
			print(`[Bench] {label}: done`)
			return
		end
		local alive = Projectile.GetStats().Active
		for _ = 1, math.min(target - alive, MAX_PER_FRAME) do
			local d = direction()
			Projectile.Fire(compiled, origin + d * 3, d)
		end
	end)
end

DebugStream.OnCommand("bench", run)
DebugStream.OnCommand("benchstop", function()
	if running then
		running.stop = true
	end
end)
