--!optimize 2
--[[
	Weapons/Shared.luau
	Small helpers shared by the weapon dispatcher (Shooter.server.luau) and
	individual weapon modules. Kept separate from init.luau (the registry)
	so a weapon module's own OnHitFunction can require this directly without
	pulling in (or risk circularly requiring) the registry itself.
]]

local WeaponsShared = {}

export type FireContext = {
	Player: Player,
	Shooter: any?, -- Entity? -- may be nil if the character wasn't registered yet
	Tool: Tool,
	Projectile: any, -- the live Projectile instance this hit/destroy came from
}

export type Hit = {
	CFrame: CFrame,
	Part: BasePart,
	Entity: any?,
	Hurtbox: ("Head" | "Body")?,
}

-- The default damage-dealing behavior every weapon gets unless it defines
-- its own OnHitFunction (see the WeaponDef schema in Weapons/init.luau).
-- Also callable from a custom OnHitFunction that wants standard damage PLUS
-- extra effects, so weapon authors never have to reimplement this by hand.
-- Reads proj.Damage * proj.DamageMultiplier -- DamageMultiplier already
-- reflects PierceFalloff from any earlier pierce on THIS projectile by the
-- time OnHit fires for a given hit. hit.Hurtbox applies the target's own
-- HeadshotMultiplier on top.
function WeaponsShared.DealDefaultDamage(ctx: FireContext, hit: Hit)
	if not hit.Entity then
		return
	end
	local proj = ctx.Projectile
	local damage = proj.Damage * proj.DamageMultiplier
	if hit.Hurtbox == "Head" then
		damage *= hit.Entity.HeadshotMultiplier
	end
	if damage <= 0 then
		return
	end
	local info = { Type = "Projectile", Source = ctx.Shooter, Position = hit.CFrame.Position, Hurtbox = hit.Hurtbox }
	if ctx.Shooter and ctx.Shooter.DealDamage then
		ctx.Shooter:DealDamage(hit.Entity, damage, info)
	else
		hit.Entity:TakeDamage(damage, info)
	end
end

return WeaponsShared
