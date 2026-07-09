--[[
	Shooter (server authority)
	Receives fire requests from clients (VisualOffload "FireBullet") and spawns a
	bullet through the Projectile system. The server owns the projectile — clients
	only send where they clicked. No model: the bullet is a plain Visual ball spec,
	rendered client-side by Projectile.EnableClientRendering().

	Because Projectile steps on the dilated Heartbeat, these bullets slow down with
	the global time ratio and inside slow chunks for free.

	Lag compensation: each shot carries RewindSeconds, half the firing player's
	current network ping, clamped to MAX_REWIND. Projectile.luau uses this to check
	nearby entities against their position as of (now - RewindSeconds) instead of
	their live position while the bullet is near entities -- see Projectile.luau's
	top-of-file doc comment for the full behavior.

	Also handles "StressTestFire": a dev/benchmarking request that spawns many
	projectiles in one go, bypassing FIRE_COOLDOWN (which throttles per-click
	requests, not a single "spawn N" request) -- see the client's N keybind in
	ShooterController.luau. Use Heartbeat.GetStats().AvgFrameTime to read the
	actual per-frame cost while a batch is in flight.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Heartbeat = require(Shared.Heartbeat)
local Entity = require(Shared.Entity)
local Projectile = require(Shared.Projectile)
local VisualOffload = require(Shared.VisualOffload)

local MAX_ORIGIN_DISTANCE = 24 -- reject/clamp origins claimed too far from the shooter
local FIRE_COOLDOWN = 0 -- server-side rate limit (seconds, real time)
local MAX_REWIND = 0.4 -- seconds; stays safely under Entity.HistoryWindow (0.5s)

local lastFire: { [Player]: number } = {}

-- Clamp a client-supplied number into a trusted range (anti-cheat + sanity).
local function num(value: any, default: number, min: number, max: number): number
	if typeof(value) ~= "number" or value ~= value then
		return default
	end
	return math.clamp(value, min, max)
end

VisualOffload.On("FireBullet", function(data, player)
	if not player or typeof(data) ~= "table" then
		return
	end

	local origin = data.Origin
	local direction = data.Direction
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or direction.Magnitude < 1e-3 then
		return
	end
	direction = direction.Unit

	-- rate limit
	local now = os.clock()
	if lastFire[player] and now - lastFire[player] < FIRE_COOLDOWN then
		return
	end
	lastFire[player] = now

	local character = player.Character
	local root = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
	if not root then
		return
	end

	-- basic anti-cheat: don't trust a claimed origin far from the character
	if (origin - root.Position).Magnitude > MAX_ORIGIN_DISTANCE then
		origin = root.Position
	end

	local shooter = Entity.Get(character) -- may be nil if the character isn't registered

	-- lag compensation: how far back (real seconds) this shooter's view was
	-- desynced when they fired, half their round-trip ping, clamped.
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	local rewindSeconds = (ok and typeof(ping) == "number" and ping == ping) and math.clamp(ping / 2, 0, MAX_REWIND) or 0

	-- read + clamp the client's shooter config (all optional)
	local cfg = typeof(data.Config) == "table" and data.Config or {}
	local speed = num(cfg.Speed, 220, 10, 1000)
	local bounces = math.floor(num(cfg.Bounces, 0, 0, 10))
	local pierces = math.floor(num(cfg.Pierces, 0, 0, 10))

	local projectileConfig = {
		Origin = origin + direction * 3, -- spawn ahead of the muzzle so we never hit ourselves
		Direction = direction,
		Speed = speed,
		Acceleration = num(cfg.Acceleration, 0, -2000, 2000),
		MinSpeed = num(cfg.MinSpeed, 0, 0, 1000),
		MaxSpeed = num(cfg.MaxSpeed, 1000, 0, 2000),
		Lifetime = num(cfg.Lifetime, 4, 0.1, 10),
		Damage = num(cfg.Damage, 20, 0, 1000),
		Gravity = num(cfg.Gravity, 0, 0, 500),
		Radius = num(cfg.Radius, 0, 0, 5),
		Bounces = bounces,
		Restitution = num(cfg.Restitution, 0.5, 0, 1),
		MaxPierces = pierces,
		PierceFalloff = num(cfg.PierceFalloff, 0.2, 0, 1),
		Source = shooter,
		RewindSeconds = rewindSeconds,
		Visualize = true, -- server = logic only; clients render
		VisualRange = 800,
		Visual = { Shape = "Ball", Size = Vector3.one * 0.4, Color = Color3.fromRGB(120, 220, 255) },
	}

	-- homing: auto-lock the nearest Enemy- or Player-tagged entity within range
	-- (the shooter's own character is always excluded by Projectile's acquireTarget)
	if cfg.Homing == true then
		projectileConfig.Homing = {
			AcquireRadius = num(cfg.AcquireRadius, 60, 0, 300),
			TargetTags = { "Enemy", "Player" },
			Retarget = true,
			ReacquireRate = 0.3,
			Permalock = cfg.Permalock == true,
			TurnRate = math.rad(num(cfg.TurnRate, 140, 0, 360)),
			Delay = 0.05,
		}
	end

	Projectile.new(projectileConfig)
end)

-- Dev/benchmarking only: spawns Count projectiles immediately in one request,
-- bypassing FIRE_COOLDOWN above (that throttles per-click requests; this is a
-- single request asking for N spawns, not N separate clicks). Damage is forced to
-- 0 so a stress test never kills the Dummy or otherwise interferes with real
-- gameplay mid-benchmark. Has its own, longer cooldown so repeated presses don't
-- compound into an ever-growing pile.
local MAX_STRESS_COUNT = 5000
local STRESS_COOLDOWN = 2
local lastStressTest: { [Player]: number } = {}

local function randomDirection(): Vector3
	local theta = math.random() * 2 * math.pi
	local z = math.random() * 2 - 1
	local r = math.sqrt(1 - z * z)
	return Vector3.new(r * math.cos(theta), z, r * math.sin(theta))
end

VisualOffload.On("StressTestFire", function(data, player)
	if not player then
		return
	end

	local now = os.clock()
	if lastStressTest[player] and now - lastStressTest[player] < STRESS_COOLDOWN then
		return
	end
	lastStressTest[player] = now

	local character = player.Character
	local root = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
	if not root then
		return
	end

	local requestedCount = typeof(data) == "table" and data.Count or nil
	local count = math.floor(num(requestedCount, 500, 1, MAX_STRESS_COUNT))
	local shooter = Entity.Get(character)

	for _ = 1, count do
		local direction = randomDirection()
		Projectile.new({
			Origin = root.Position + direction * 3,
			Direction = direction,
			Speed = 220,
			Lifetime = 4,
			Damage = 0, -- pure load test; never affects real gameplay/entities
			Source = shooter,
			Visualize = true,
			Homing = true,
			VisualRange = 8000,
			Visual = { Shape = "Ball", Size = Vector3.one * 0.4, Color = Color3.fromRGB(255, 140, 60) },
			Homing = {
				AcquireRadius = num(60, 60, 0, 300),
				TargetTags = { "Enemy", "Player" },
				Retarget = true,
				ReacquireRate = 0.3,
				Permalock = true,
				TurnRate = math.rad(num(140, 140, 0, 360)),
				Delay = 0.05,
			}
		})
	end

	print(`[Relativity] stress test: spawned {count} projectiles for {player.Name}`)

	-- Real frame-cost data while the batch is in flight (Heartbeat.GetStats() is
	-- shared module state, so this reads the actual live loop -- not a
	-- disconnected/isolated snapshot).
	task.spawn(function()
		for _ = 1, 6 do
			task.wait(0.5)
			local stats = Heartbeat.GetStats()
			print(
				`[Relativity] stress test stats: {stats.ConnectionCount} connections, avg frame cost {string.format("%.3f", stats.AvgFrameTime * 1000)} ms`
			)
		end
	end)
end)

game:GetService("Players").PlayerRemoving:Connect(function(player)
	lastFire[player] = nil
	lastStressTest[player] = nil
end)

print("[Relativity] shooter online")
