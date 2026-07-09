--[[
	Server bootstrap.
	 - Enables chunk / global time-scale replication so clients mirror dilation.
	 - Owns the authoritative global time ratio: clients request a value through
	   the VisualOffload "RequestGlobalScale" channel and the server validates it,
	   applies it via Heartbeat, and the replication loop broadcasts it back out.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Heartbeat = require(Shared.Heartbeat)
local ChunkManager = require(Shared.ChunkManager)
local VisualOffload = require(Shared.VisualOffload)
local Projectile = require(Shared.Projectile)

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

-- Bounds for the player-controllable global time ratio.
local MIN_RATIO = 0
local MAX_RATIO = 3

VisualOffload.On("RequestGlobalScale", function(value, player)
	if typeof(value) ~= "number" or value ~= value then -- reject nil / NaN
		return
	end
	local clamped = math.clamp(value, MIN_RATIO, MAX_RATIO)
	Heartbeat.SetGlobalTimeScale(clamped)
	if player then
		print(`[Relativity] {player.Name} set global time ratio -> x{clamped}`)
	end
end)

-- Optional: freeze simulation in chunks with no players nearby.
-- ChunkManager.ConfigureAutoLoad({ Enabled = true, Radius = 256, Interval = 0.5 })

print("[Relativity] server systems online")
