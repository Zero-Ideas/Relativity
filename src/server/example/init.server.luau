--[[
	Server bootstrap.
	 - Enables chunk / global time-scale replication so clients mirror dilation
	   (the true world-level Heartbeat scale, if anything ever sets one --
	   distinct from the per-player ratio below).
	 - Owns each player's own personal time ratio: a client requests a value
	   through the VisualOffload "RequestPersonalTimeScale" channel, the server
	   clamps it, applies it ONLY to that player's Entity (Entity:SetTimeScale --
	   see Entity.luau), and replies with the clamped value on
	   "PersonalTimeScale" to that player alone (never broadcast -- it's
	   personal, it should never affect or even be visible to anyone else). The
	   ratio is also stashed on a PersonalTimeScale player Attribute so
	   PlayerManager.server.luau can reapply it to each new character on
	   respawn.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local ChunkManager = require(Shared.ChunkManager)
local Entity = require(Shared.Entity)
local VisualOffload = require(Shared.VisualOffload)
local Projectile = require(script.Parent.Projectile)

ChunkManager.EnableReplication()

-- Clients can toggle projectile raycast visualization (B key by default).
VisualOffload.On("SetProjectileDebug", function(enabled)
	Projectile.SetDebugRays(enabled == true)
end)

-- Clients can toggle ProjSpawn/ProjSync/ProjHit + ProjMove-rate server console
-- logging (V key by default) -- see Projectile.SetDebugSync's doc comment.
VisualOffload.On("SetProjectileSyncDebug", function(enabled)
	Projectile.SetDebugSync(enabled == true)
end)

-- Bounds for a player's own controllable personal time ratio.
local MIN_RATIO = 0
local MAX_RATIO = 3

VisualOffload.On("RequestPersonalTimeScale", function(value, player)
	if not player or typeof(value) ~= "number" or value ~= value then -- reject nil / NaN
		return
	end
	local clamped = math.clamp(value, MIN_RATIO, MAX_RATIO)

	-- persisted so PlayerManager.server.luau can reapply it to the next
	-- character this player spawns (a fresh Entity otherwise starts at 1x)
	player:SetAttribute("PersonalTimeScale", clamped)

	local entity = Entity.Get(player.Character)
	if entity then
		entity:SetTimeScale(clamped)
	end

	-- reply only to the requesting player -- this is personal, not global
	VisualOffload.FireClient(player, "PersonalTimeScale", clamped)
	print(`[Relativity] {player.Name} set personal time ratio -> x{clamped}`)
end)

-- Optional: freeze simulation in chunks with no players nearby.
-- ChunkManager.ConfigureAutoLoad({ Enabled = true, Radius = 256, Interval = 0.5 })

print("[Relativity] server systems online")
