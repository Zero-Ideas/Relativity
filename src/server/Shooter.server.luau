--[[
	Shooter (server authority)
	Receives fire requests from clients (VisualOffload "FireBullet") and spawns a
	bullet through the Projectile system. The server owns the projectile — clients
	only send where they clicked. No model: the bullet is a plain Visual ball spec,
	rendered client-side by Projectile.EnableClientRendering().

	Because Projectile steps on the dilated Heartbeat, these bullets slow down with
	the global time ratio and inside slow chunks for free.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Entity = require(Shared.Entity)
local Projectile = require(Shared.Projectile)
local VisualOffload = require(Shared.VisualOffload)

local MAX_ORIGIN_DISTANCE = 24 -- reject/clamp origins claimed too far from the shooter
local FIRE_COOLDOWN = 0.1 -- server-side rate limit (seconds, real time)

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

	-- read + clamp the client's shooter config (all optional)
	local cfg = typeof(data.Config) == "table" and data.Config or {}
	local speed = num(cfg.Speed, 220, 10, 1000)
	local bounces = math.floor(num(cfg.Bounces, 0, 0, 10))
	local pierces = math.floor(num(cfg.Pierces, 0, 0, 10))

	local projectileConfig = {
		Origin = origin + direction * 3, -- spawn ahead of the muzzle so we never hit ourselves
		Direction = direction,
		Speed = speed,
		Lifetime = num(cfg.Lifetime, 4, 0.1, 10),
		Damage = num(cfg.Damage, 20, 0, 1000),
		Gravity = num(cfg.Gravity, 0, 0, 500),
		Radius = num(cfg.Radius, 0, 0, 5),
		Bounces = bounces,
		Restitution = num(cfg.Restitution, 0.5, 0, 1),
		MaxPierces = pierces,
		PierceFalloff = num(cfg.PierceFalloff, 0.2, 0, 1),
		Source = shooter,
		Visualize = true, -- server = logic only; clients render
		VisualRange = 800,
		Visual = { Shape = "Ball", Size = Vector3.one * 0.4, Color = Color3.fromRGB(120, 220, 255) },
	}

	-- homing: auto-lock the nearest "Enemy"-tagged entity within range
	if cfg.Homing == true then
		projectileConfig.Homing = {
			AcquireRadius = num(cfg.AcquireRadius, 60, 0, 300),
			TargetTag = "Enemy",
			Retarget = true,
			ReacquireRate = 0.3,
			TurnRate = math.rad(num(cfg.TurnRate, 140, 0, 360)),
			Delay = 0.05,
		}
	end

	Projectile.new(projectileConfig)
end)

game:GetService("Players").PlayerRemoving:Connect(function(player)
	lastFire[player] = nil
end)

print("[Relativity] shooter online")
