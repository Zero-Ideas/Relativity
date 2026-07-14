--!optimize 2
--[[
	Weapons/Railgun.luau
	First "real" weapon on the new per-weapon schema: a real fire rate and a
	tracked magazine (see Shooter.server.luau's ammo bookkeeping). Stats
	below are a starting point -- TUNE ME by feel in Studio, just edit this
	file and Rojo will live-sync it. On hit, also applies the shared "Stun"
	status effect (ragdoll -- see StatusEffects.server.luau /
	src/server/Ragdoll/init.luau) plus a hard fling along the bullet's own
	travel direction -- see onRailgunHit below.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)
local StatusEffectSys = require(Shared.StatusEffectSys)
local WeaponsShared = require(script.Parent.Shared)

-- How far along the shot's own path (origin + direction * this) the muzzle
-- blast effect is placed -- NOT relative to the Tool's transform, so the
-- effect always lines up with the actual projectile path even if the Tool's
-- third-person pose doesn't match the shooter's first-person aim.
local BLAST_DISTANCE = 8

-- Muzzle flash. The actual clone/position/emit work happens CLIENT-side
-- (see src/client/WeaponEffects.luau's "MuzzleBlast" handler) -- this just
-- broadcasts the shot. It HAS to be client-side: ParticleEmitter:Emit() is
-- a method call, and method calls never replicate -- an earlier version
-- called Emit() right here on the server and nothing ever showed on any
-- client (only property changes and new instances replicate; a Sound:Play()
-- works from the server because Playing is a property, but Emit does not).
-- The Flash template instance is sent by reference; the Tool lives in the
-- shooter's character, so it's replicated to everyone who could see the
-- shot anyway.
local function emitMuzzleBlast(tool: Tool, origin: Vector3, direction: Vector3)
	local template = tool:FindFirstChild("Flash")
	if not template then
		return
	end
	VisualOffload.Fire("MuzzleBlast", {
		Template = template,
		Origin = origin,
		Direction = direction,
		Distance = BLAST_DISTANCE,
	})
end

local STUN_DURATION = 10 -- seconds a hit entity is ragdolled for (see StatusEffects.server.luau's "Stun")
local FLING_FORCE = 250 -- studs/s of instantaneous velocity kick along the shot's travel direction
local FLING_UP_RATIO = 0.4 -- fraction of FLING_FORCE added straight up, for a launch arc instead of a flat shove
local FLING_SPIN_FORCE = 25 -- rad/s; max per-axis magnitude of the random tumble applied alongside the fling

-- On hit: deals the weapon's own damage (OnHitFunction FULLY REPLACES the
-- dispatcher's default damage-dealing -- see the WeaponDef schema in
-- Weapons/init.luau -- so this calls the shared helper explicitly to opt
-- back into standard damage), then stuns (ragdolls) the target and gives it
-- a hard fling along the bullet's own travel direction. World/wall hits
-- (hit.Entity == nil) only deal damage -- nothing to stun or fling.
local function onRailgunHit(ctx: WeaponsShared.FireContext, hit: WeaponsShared.Hit)
	WeaponsShared.DealDefaultDamage(ctx, hit)

	local entity = hit.Entity
	if not entity then
		return
	end

	StatusEffectSys:ApplyEffect(entity, "Stun", STUN_DURATION)

	-- Fling AFTER the stun above: Stun's OnApply ragdolls synchronously (see
	-- StatusEffects.server.luau), so by this point the target's Motor6Ds are
	-- already disabled and its root part is its own free physics body --
	-- exactly what makes a velocity kick here read as a hard launch instead
	-- of just nudging a rigid, animation-locked rig.
	local humanoid = entity.Humanoid
	local rootPart = humanoid and humanoid.RootPart
	if rootPart then
		local direction = ctx.Projectile.Velocity
		if direction.Magnitude > 1e-3 then
			rootPart.AssemblyLinearVelocity = direction.Unit * FLING_FORCE + Vector3.new(0, FLING_FORCE * FLING_UP_RATIO, 0)
			-- Random tumble so every fling reads as a chaotic ragdoll hit
			-- instead of a perfectly clean launch -- the connected limbs
			-- (via the Stun ragdoll's BallSocketConstraints) get dragged
			-- along with the spinning root part over subsequent physics
			-- steps, same as the linear kick above.
			rootPart.AssemblyAngularVelocity = Vector3.new(
				(math.random() * 2 - 1) * FLING_SPIN_FORCE,
				(math.random() * 2 - 1) * FLING_SPIN_FORCE,
				(math.random() * 2 - 1) * FLING_SPIN_FORCE
			)
		end
	end
end

return {
	Model = "RailgunRod", -- ReplicatedStorage.Effects.RailgunRod

	Stats = {
		Speed = 1250,
		Acceleration = 0,
		MinSpeed = 0,
		MaxSpeed = 10000,
		Damage = 750,
		Lifetime = 3,
		Gravity = 0,
		Radius = 0.2,
		Bounces = 0,
		Restitution = 0,
		Penetration = 1000,
		MaxPierces = 3,
		PierceFalloff = 0.15,
	},

	FireRate = 2, -- shots/sec

	Magazine = {
		Size = 6,
		Reserve = 24,
		ReloadTime = 2.2, -- seconds
	},

	OnFire = emitMuzzleBlast,
	OnHitFunction = onRailgunHit,
}
