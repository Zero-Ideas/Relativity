--!optimize 2
--[[
	Weapons (server)
	Registry of every server-authoritative weapon module, keyed by Tool name.
	Shooter.server.luau is a generic dispatcher driven entirely by this
	table -- it never hardcodes a weapon name. Adding a new shooting weapon:
	hand-place its Tool in StarterPack, add a ToolControllers/<Name>.luau
	client controller (see ToolControllers/_ShootingWeapon.luau -- most
	weapons can just re-export it), and drop a new
	Weapons/<Name>.luau module in this folder returning a WeaponDef (see the
	type below) -- Shooter.server.luau picks it up automatically.

	This replaces the old src/shared/ShooterTool.luau: nothing outside this
	dispatcher ever needs to enumerate weapon names (the client matches tool
	-> controller purely by ModuleScript name via ToolManager.luau), so the
	registry lives server-only now instead of shared.
]]

local WeaponsShared = require(script.Shared)

export type WeaponDef = {
	-- ReplicatedStorage.Effects child name for this weapon's bullet visual.
	Model: string,

	-- Seeds Projectile.new(config) directly -- any field from Projectile's
	-- own config schema is valid here (see src/server/Projectile/init.luau);
	-- omitted fields fall back to Projectile's own defaults.
	Stats: { [string]: any },

	-- Optional -- same shape as Projectile's Homing config sub-table.
	Homing: { [string]: any }?,

	-- Shots/sec. Converted to a per-(Player, Tool) cooldown by the
	-- dispatcher; still floored by MIN_FIRE_INTERVAL regardless of what a
	-- weapon declares (defense in depth -- see Shooter.server.luau).
	FireRate: number,

	-- nil = infinite ammo, no reload ever offered. Present = tracked per
	-- (Player, Tool instance) by the dispatcher.
	Magazine: { Size: number, Reserve: number, ReloadTime: number }?,

	-- Optional. Called once per ACCEPTED shot (fire-rate/ammo checks already
	-- passed), before the projectile spawns -- purely cosmetic (muzzle
	-- flash, fire sound, recoil kick, etc.), never gameplay. Runs
	-- SERVER-SIDE and is passed the equipped Tool instance plus the exact
	-- Origin/Direction the projectile itself is about to spawn with (see
	-- resolveMuzzleOrigin in Shooter.server.luau), so a muzzle effect can
	-- place itself directly on the bullet's actual path instead of relying
	-- on the Tool's own (possibly stale/third-person) transform. CAUTION on
	-- what actually shows from server code: property changes and new
	-- instances replicate (so Sound:Play() works -- Playing is a property),
	-- but METHOD calls like ParticleEmitter:Emit() do NOT -- particle
	-- bursts must be broadcast to clients instead; fire a VisualOffload
	-- channel handled in src/client/WeaponEffects.luau (see Railgun.luau's
	-- "MuzzleBlast" for the pattern).
	OnFire: ((tool: Tool, origin: Vector3, direction: Vector3) -> ())?,

	-- Optional. FULLY REPLACES default damage-dealing for this weapon's
	-- hits when present -- the dispatcher does not auto-apply damage if
	-- this exists. Call WeaponsShared.DealDefaultDamage(ctx, hit) from
	-- inside here to opt back into standard damage before adding custom
	-- effects (chain damage, status effects, VFX, etc.).
	OnHitFunction: ((WeaponsShared.FireContext, WeaponsShared.Hit) -> ())?,

	-- Optional, purely additive -- there's no default destroy-time gameplay
	-- behavior to replace (only internal bookkeeping, which always runs
	-- regardless -- see Shooter.server.luau's OnDestroy handling).
	OnDestroyFunction: ((WeaponsShared.FireContext, { Position: Vector3, Normal: Vector3, Kind: string? }) -> ())?,
}

local Weapons: { [string]: WeaponDef } = {}

for _, child in script:GetChildren() do
	if child:IsA("ModuleScript") and child.Name ~= "Shared" then
		Weapons[child.Name] = require(child) :: WeaponDef
	end
end

return Weapons
