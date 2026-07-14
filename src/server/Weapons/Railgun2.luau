--!optimize 2
--[[
	Weapons/Railgun.luau
	First "real" weapon on the new per-weapon schema: a real fire rate and a
	tracked magazine (see Shooter.server.luau's ammo bookkeeping). Stats
	below are a starting point -- TUNE ME by feel in Studio, just edit this
	file and Rojo will live-sync it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VisualOffload = require(ReplicatedStorage:WaitForChild("Shared").VisualOffload)

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
