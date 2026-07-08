--[[
	Example 4 — Projectiles (bouncing, homing, client-offloaded) and explosions
	Requires a part/model template for visuals, e.g. ReplicatedStorage.Effects.Bullet.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Entity = require(Shared.Entity)
local Projectile = require(Shared.Projectile)
local Hitbox = require(Shared.Hitbox)

local bulletTemplate = ReplicatedStorage:FindFirstChild("Effects")
	and ReplicatedStorage.Effects:FindFirstChild("Bullet")

local explode -- forward-declared, defined below

-- ── Straight bullet, rendering offloaded to clients ─────────────────────────
local function fireBullet(shooterEntity, origin: Vector3, direction: Vector3)
	Projectile.new({
		Origin = origin,
		Direction = direction,
		Speed = 250,
		Lifetime = 4,
		Damage = 18,
		Source = shooterEntity, -- ignored by the ray, deals the damage
		Model = bulletTemplate,
		Visualize = true, -- server = logic only; clients render
		VisualRange = 512,
		OnHit = function(projectile, result, hitEntity)
			if hitEntity then
				print("bullet hit entity", hitEntity.Id)
			end
		end,
	})
end

-- ── Bouncing grenade with an explosion on timeout ───────────────────────────
local function throwGrenade(thrower, origin: Vector3, direction: Vector3)
	Projectile.new({
		Origin = origin,
		Direction = direction,
		Speed = 60,
		Gravity = 60, -- integrated with dilated dt: floats in slow chunks
		Radius = 0.5, -- spherecast
		Bounces = 5,
		Restitution = 0.45,
		Lifetime = 3, -- dilated fuse: burns slower in slow zones
		Source = thrower,
		Model = bulletTemplate,
		Visualize = true,
		OnBounce = function(projectile, result)
			-- play bounce sound at result.Position
		end,
		OnHit = function(projectile, result)
			explode(thrower, result.Position)
		end,
	})
end

explode = function(source, position: Vector3)
	Hitbox.Explode(position, {
		Radius = 14,
		Damage = 60,
		MinDamage = 10, -- linear falloff toward the edge
		Knockback = 45,
		Source = source, -- runs through source's outgoing modifiers
		Visual = true, -- cosmetic Roblox Explosion (pressure 0)
		Filter = function(entity)
			return entity.Team ~= (source and source.Team)
		end,
	})
end

-- ── Homing missile (explicit target) ────────────────────────────────────────
local function fireMissile(shooter, origin: Vector3, target)
	Projectile.new({
		Origin = origin,
		Direction = Vector3.yAxis, -- launches up, then curves in
		Speed = 90,
		Lifetime = 8,
		Homing = {
			Target = target, -- Entity, BasePart, or Vector3
			TurnRate = math.rad(140), -- max degrees/sec of steering (dilated)
			Delay = 0.25, -- fly straight briefly before homing
		},
		Source = shooter,
		Model = bulletTemplate,
		Visualize = true,
		OnHit = function(projectile, result)
			explode(shooter, result.Position)
		end,
	})
end

-- ── Seeker: auto-locks the nearest "Enemy"-tagged entity via the chunk grid ──
local function fireSeeker(shooter, origin: Vector3, aimDir: Vector3)
	Projectile.new({
		Origin = origin,
		Direction = aimDir,
		Speed = 110,
		Lifetime = 6,
		Homing = {
			AcquireRadius = 80, -- no explicit target: lock nearest in range
			TargetTag = "Enemy",
			Retarget = true, -- re-acquire if the target dies/leaves
			ReacquireRate = 0.3,
			TurnRate = math.rad(160),
			Delay = 0.1,
		},
		Source = shooter,
		Model = bulletTemplate,
		Visualize = true,
	})
end

-- ── Piercing railshot: passes through up to 3 enemies, 20% damage falloff each ─
local function fireRail(shooter, origin: Vector3, direction: Vector3)
	Projectile.new({
		Origin = origin,
		Direction = direction,
		Speed = 600,
		Lifetime = 1,
		Damage = 80,
		MaxPierces = 3,
		PierceFalloff = 0.2,
		Source = shooter,
		Visual = { Shape = "Cylinder", Color = Color3.fromRGB(120, 200, 255), Size = Vector3.new(4, 0.2, 0.2) },
		Visualize = true,
	})
end

-- ── Shotgun: 8 pellets in a cone, aimed at a point instead of a direction ────
local function fireShotgun(shooter, origin: Vector3, aimPoint: Vector3)
	Projectile.Burst({
		Origin = origin,
		TargetPosition = aimPoint, -- aim at a world point
		Speed = 300,
		Spread = 6, -- 6° cone half-angle, rolled per pellet
		Lifetime = 0.6,
		Damage = 9,
		DestroyDelay = 0.4, -- tracers linger briefly after impact
		Source = shooter,
		Visual = { Shape = "Ball", Size = Vector3.one * 0.3 },
		Visualize = true,
	}, 8)
end

-- ── Continuous melee hitbox (sword swing window) ────────────────────────────
local function swordSwing(attacker)
	local hitbox = Hitbox.new({
		Shape = "Box",
		Size = Vector3.new(5, 6, 7),
		Follow = attacker, -- tracks the entity's root
		Offset = CFrame.new(0, 0, -4), -- box floats in front of them
		Damage = 35,
		Source = attacker,
		HitOnce = true, -- each target hit once per swing
		Lifetime = 0.3, -- auto-stops (dilated seconds)
	})
	hitbox.OnHit:Connect(function(entity)
		print("slashed", entity.Id)
	end)
	hitbox:Start()
end

-- Demo: nearest zombie gets a missile every 6 seconds.
task.spawn(function()
	while task.wait(6) do
		local zombies = Entity.GetTagged("Zombie")
		if #zombies > 0 then
			fireMissile(nil, Vector3.new(0, 30, 0), zombies[1])
		end
	end
end)
