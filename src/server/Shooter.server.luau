--[[
	Shooter (server authority)
	Receives fire requests from clients (VisualOffload "FireBullet") and spawns a
	bullet through the Projectile system. The server owns the projectile — clients
	only send where they clicked and non-authoritative tuning (speed, damage,
	etc.); the bullet's Model/Visual is decided server-side (see
	PROJECTILE_MODELS below), rendered client-side by
	Projectile.EnableClientRendering().

	Because Projectile steps on the dilated Heartbeat, these bullets slow down with
	the global time ratio and inside slow chunks for free -- and, per-shooter, live
	with that player's own personal time ratio (Projectile.luau reads Source.
	TimeScale every tick, so a shooter dragging their ratio mid-flight speeds up
	or slows down bullets already in the air).

	Anti-exploit, defense in depth (VisualOffload's remote is reachable directly by
	any client, bypassing ShooterController's own throttling entirely):
	 - FIRE_COOLDOWN is a hard per-player rate limit enforced here regardless of
	   how fast (or how directly) the remote is fired.
	 - MAX_ACTIVE_PROJECTILES_PER_PLAYER caps how many of a player's bullets can be
	   alive at once, so even max-rate firing with a huge Lifetime can't build an
	   unbounded swarm.
	 - A shot is only accepted while the firing player's character has the
	   TimeBlaster tool (see ShooterTool.luau) equipped.
	 - The bullet's Model is looked up server-side from the equipped tool's
	   name (PROJECTILE_MODELS below), never taken from client config -- a
	   client-supplied Instance reference could point at anything replicated
	   to them and get cloned onto every observer via ProjSpawn.

	Lag compensation: each shot carries RewindSeconds, half the firing player's
	current network ping, clamped to MAX_REWIND. Projectile.luau uses this to check
	nearby entities against their position as of (now - RewindSeconds) instead of
	their live position while the bullet is near entities -- see Projectile.luau's
	top-of-file doc comment for the full behavior.

	Also handles "StressTestFire": a dev/benchmarking request that spawns many
	projectiles in one go, bypassing FIRE_COOLDOWN (which throttles per-click
	requests, not a single "spawn N" request) -- see the client's N keybind in
	ShooterController.luau. Restricted to Studio (see the RunService:IsStudio()
	guard below) since spawning thousands of projectiles per request is itself an
	exploit vector if left reachable in a live game. Use
	Heartbeat.GetStats().AvgFrameTime to read the actual per-frame cost while a
	batch is in flight.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Heartbeat = require(Shared.Heartbeat)
local Entity = require(Shared.Entity)
local Projectile = require(Shared.Projectile)
local VisualOffload = require(Shared.VisualOffload)
local ShooterToolInfo = require(Shared.ShooterTool)

-- Server-owned mapping of equipped-tool name -> the Model clients render for
-- that tool's bullets. NEVER trust a client-sent Model reference (a remote
-- can carry an Instance argument, and a client could point it at literally
-- anything replicated to them -- another player's rig, a chunk of terrain, a
-- LocalScript buried somewhere else in the game -- which the server would
-- then clone and broadcast onto every observer via ProjSpawn). The tool a
-- shot came from is already validated below (character:FindFirstChild(
-- ShooterToolInfo.Name)), so keying off tool.Name here is safe. A tool with
-- no entry (or a missing asset) just falls back to the default Visual ball.
local Effects = ReplicatedStorage:FindFirstChild("Effects")
local PROJECTILE_MODELS: { [string]: Instance } = {
	[ShooterToolInfo.Name] = Effects and Effects:FindFirstChild("Model"),
}

local MAX_ORIGIN_DISTANCE = 24 -- reject/clamp origins claimed too far from the shooter
local FIRE_COOLDOWN = 0.1 -- server-side rate limit (seconds, real time) -- 10/sec hard cap, independent of client input
local MAX_ACTIVE_PROJECTILES_PER_PLAYER = 150 -- concurrently-alive cap per player
local MAX_REWIND = 0.4 -- seconds; stays safely under Entity.HistoryWindow (0.5s)

local lastFire: { [Player]: number } = {}
local activeProjectileCount: { [Player]: number } = {}

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

	local character = player.Character
	local root = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
	if not root then
		return
	end

	-- must have the TimeBlaster tool equipped -- closes the gap where an
	-- exploiter fires this remote directly without ever equipping anything
	local tool = character:FindFirstChild(ShooterToolInfo.Name)
	if not tool or not tool:IsA("Tool") then
		return
	end

	-- rate limit: a hard per-player cap independent of client input, since the
	-- remote is reachable directly (see the module doc comment above)
	local now = os.clock()
	if lastFire[player] and now - lastFire[player] < FIRE_COOLDOWN then
		return
	end

	-- concurrent-projectile cap: stops max-rate firing + a huge Lifetime from
	-- building an unbounded swarm
	if (activeProjectileCount[player] or 0) >= MAX_ACTIVE_PROJECTILES_PER_PLAYER then
		return
	end
	lastFire[player] = now

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

	-- read + clamp the client's shooter config (all optional). Only the lower
	-- bounds are real limits (e.g. a projectile needs Speed > 0); the upper
	-- bounds are intentionally uncapped (math.huge) so lifetime/bounces/
	-- pierces/velocity/etc. can be tuned arbitrarily high from the config GUI.
	local cfg = typeof(data.Config) == "table" and data.Config or {}
	local speed = num(cfg.Speed, 220, 10, math.huge)
	local bounces = math.floor(num(cfg.Bounces, 0, 0, math.huge))
	local pierces = math.floor(num(cfg.Pierces, 0, 0, math.huge))

	local projectileConfig = {
		Origin = origin + direction * 3, -- spawn ahead of the muzzle so we never hit ourselves
		Direction = direction,
		Speed = speed,
		Acceleration = num(cfg.Acceleration, 0, -math.huge, math.huge),
		MinSpeed = num(cfg.MinSpeed, 0, 0, math.huge),
		MaxSpeed = num(cfg.MaxSpeed, 1000, 0, math.huge),
		Lifetime = num(cfg.Lifetime, 4, 0.1, math.huge),
		Damage = num(cfg.Damage, 20, 0, math.huge),
		Gravity = num(cfg.Gravity, 0, 0, math.huge),
		Radius = num(cfg.Radius, 0, 0, math.huge),
		Bounces = bounces,
		Restitution = num(cfg.Restitution, 0.5, 0, math.huge),
		Penetration = num(cfg.Penetration, 0, 0, math.huge),
		MaxPierces = pierces,
		PierceFalloff = num(cfg.PierceFalloff, 0.2, 0, math.huge),
		Source = shooter,
		-- Belt-and-suspenders against self-hits: shooter (the Entity) may
		-- still be nil for a shot fired in the brief window before
		-- PlayerManager.server.luau registers this character on CharacterAdded
		-- -- IgnoreInstances excludes the raw character model from the
		-- raycast regardless, so a self-hit can't happen even during that race.
		IgnoreInstances = { character },
		RewindSeconds = rewindSeconds,
		Visualize = true, -- server = logic only; clients render
		VisualRange = 800,
		Visual = { Shape = "Ball", Size = Vector3.one * 0.4, Color = Color3.fromRGB(120, 220, 255) },
		-- Chosen server-side from the validated equipped tool, never from cfg
		-- (see PROJECTILE_MODELS above) -- a client-supplied Model reference
		-- would be an easy exploit vector.
		Model = PROJECTILE_MODELS[tool.Name],
	}

	-- homing: auto-lock the nearest Enemy- or Player-tagged entity within range
	-- (the shooter's own character is always excluded by Projectile's acquireTarget)
	if cfg.Homing == true then
		projectileConfig.Homing = {
			AcquireRadius = num(cfg.AcquireRadius, 60, 0, math.huge),
			TargetTags = { "Enemy", "Player" },
			Retarget = true,
			ReacquireRate = 0.3,
			Permalock = cfg.Permalock == true,
			TurnRate = math.rad(num(cfg.TurnRate, 140, 0, math.huge)),
			Delay = 0.05,
		}
	end

	-- counted against MAX_ACTIVE_PROJECTILES_PER_PLAYER above; OnDestroy fires
	-- exactly once per projectile on every removal path (entity hit, world
	-- hit, dilated lifetime expiry, or the real-time MaxRealLifetime safety
	-- cap -- see Projectile.luau's Step/Destroy), so this always balances the
	-- increment below. OnHit is NOT exactly-once (piercing/bouncing/
	-- penetrating fire it without removing the projectile), which is exactly
	-- why this uses OnDestroy instead. The real-time cap matters here
	-- specifically: a shooter who freezes their own personal time with shots
	-- in flight would otherwise have those shots sit in activeProjectileCount
	-- forever, silently eating into their MAX_ACTIVE_PROJECTILES_PER_PLAYER
	-- budget.
	activeProjectileCount[player] = (activeProjectileCount[player] or 0) + 1
	local proj = Projectile.new(projectileConfig)
	proj.OnDestroy:Connect(function()
		activeProjectileCount[player] = math.max((activeProjectileCount[player] or 1) - 1, 0)
	end)

	-- The module deals no damage itself anymore (see Projectile.luau's
	-- "Events" doc section) -- this replicates the exact damage behavior that
	-- used to live in Projectile:_dealDamage, just from the caller side now.
	-- DamageMultiplier already reflects PierceFalloff, applied live per pierce.
	-- hit.Hurtbox ("Head" | "Body" | nil, see Entity.luau's "Head + Body
	-- hurtboxes" section) applies the target's own HeadshotMultiplier on top.
	proj.OnHit:Connect(function(hit)
		if not hit.Entity then
			return
		end
		local damage = proj.Damage * proj.DamageMultiplier
		if hit.Hurtbox == "Head" then
			damage *= hit.Entity.HeadshotMultiplier
		end
		if damage <= 0 then
			return
		end
		local info = { Type = "Projectile", Source = shooter, Position = hit.CFrame.Position, Hurtbox = hit.Hurtbox }
		if shooter and shooter.DealDamage then
			shooter:DealDamage(hit.Entity, damage, info)
		else
			hit.Entity:TakeDamage(damage, info)
		end
	end)
end)

-- Dev/benchmarking only: spawns Count projectiles immediately in one request,
-- bypassing FIRE_COOLDOWN above (that throttles per-click requests; this is a
-- single request asking for N spawns, not N separate clicks). Damage is forced to
-- 0 so a stress test never kills the Dummy or otherwise interferes with real
-- gameplay mid-benchmark. Has its own, longer cooldown so repeated presses don't
-- compound into an ever-growing pile. Restricted to Studio (see the IsStudio
-- guard below): spawning up to MAX_STRESS_COUNT projectiles per request is
-- itself an "ungodly amounts of projectiles" vector if any client could reach
-- it in a live game, so this never runs outside of testing.
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
	if not player or not RunService:IsStudio() then
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
			IgnoreInstances = { character },
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
	activeProjectileCount[player] = nil
end)

print("[Relativity] shooter online")
