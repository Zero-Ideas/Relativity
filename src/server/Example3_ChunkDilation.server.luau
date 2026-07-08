--[[
	Example 3 — Chunk-local time dilation and chunk queries
	A "slow zone": everything inside runs at 20% speed — entity updates,
	projectiles flying through, humanoid movement, gravity, hitbox ticks.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Heartbeat = require(Shared.Heartbeat)
local ChunkManager = require(Shared.ChunkManager)
local Entity = require(Shared.Entity)
local Gravity = require(Shared.Gravity)

-- Slow time to 0.2x in a 96-stud bubble around the map center.
local zoneCenter = Vector3.new(0, 0, 0)
ChunkManager.SetTimeScaleInRadius(zoneCenter, 96, 0.2)

-- ...and restore it after 10 seconds.
task.delay(10, function()
	ChunkManager.SetTimeScaleInRadius(zoneCenter, 96, 1)
end)

-- Freeze chunks nobody is near: entities there stop updating, and hitbox /
-- projectile queries skip them entirely.
ChunkManager.ConfigureAutoLoad({ Enabled = true, Radius = 256, Interval = 0.5 })

-- The Dummy NPC is owned by DummyManager (registers it as an entity, tags it
-- "Enemy", and respawns it on death), so it isn't created here to avoid two
-- systems registering the same rig.

-- Query helpers.
Heartbeat.ConnectInterval(2, function()
	local nearby = ChunkManager.GetEntitiesInRadius(zoneCenter, 96)
	print(`{#nearby} entities inside the slow zone`)
	local stats = ChunkManager.GetStats()
	print(`{stats.LoadedChunkCount}/{stats.ChunkCount} chunks loaded`)
end, { Name = "Example.ZoneReport" })
