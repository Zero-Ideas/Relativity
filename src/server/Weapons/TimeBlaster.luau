--!optimize 2
--[[
	Weapons/TimeBlaster.luau
	The dev/debug tuning weapon -- unlimited ammo, fire rate capped only by
	the dispatcher's global MIN_FIRE_INTERVAL floor (see Shooter.server.luau)
	the same as every other weapon. Stats match this weapon's old hardcoded
	defaults from before the per-weapon module split, so behavior is
	unchanged for existing testers. Tune by editing this file directly --
	Rojo live-syncs on save, no in-game panel needed anymore.
]]

return {
	Model = "Model", -- ReplicatedStorage.Effects.Model

	Stats = {
		Speed = 220,
		Acceleration = 0,
		MinSpeed = 0,
		MaxSpeed = 1000,
		Damage = 20,
		Lifetime = 4,
		Gravity = 0,
		Radius = 0,
		Bounces = 0,
		Restitution = 0.5,
		Penetration = 0,
		MaxPierces = 0,
		PierceFalloff = 0.2,
	},

	-- Matches the dispatcher's MIN_FIRE_INTERVAL (0.1s) exactly, so this
	-- weapon's own FireRate never adds any extra restriction beyond the
	-- global anti-spam floor -- unlimited in practice, same as before.
	FireRate = 10,

	Magazine = nil, -- infinite ammo, no reload
}
