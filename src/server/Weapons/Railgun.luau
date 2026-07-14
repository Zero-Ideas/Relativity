--!optimize 2
--[[
	Weapons/Railgun.luau
	First "real" weapon on the new per-weapon schema: a real fire rate and a
	tracked magazine (see Shooter.server.luau's ammo bookkeeping). Stats
	below are a starting point -- TUNE ME by feel in Studio, just edit this
	file and Rojo will live-sync it.
]]

-- Muzzle flash: bursts every ParticleEmitter under the Tool's "blast" folder
-- by its own EmitCount attribute (defaulting to 20 if unset). Runs
-- server-side (see OnFire in Weapons/init.luau) -- :Emit() calls replicate
-- to every client automatically, no remote needed.
local function emitMuzzleBlast(tool: Tool)
	print("emitMuzzleBlast",tool)
	local blast = tool:FindFirstChild("Flash")
	if not blast then
		return
	end
	for _, child in blast:GetDescendants() do
		if child:IsA("ParticleEmitter") then
			child:Emit(child:GetAttribute("EmitCount") or 20)
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
		Penetration = 0,
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
}
