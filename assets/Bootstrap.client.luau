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

-- An NPC that respects local time. Inside the slow zone its dt shrinks,
-- so it thinks, moves, and attacks in slow motion — for free.
local rig = workspace:FindFirstChild("Dummy")
if rig then
	local npc = Entity.new(rig, { ScaleHumanoid = true, AttackCooldown = 2 })
	Gravity.Apply(npc) -- falls softer inside the slow zone (g scales with time²)

	local cooldown = 0
	npc:OnUpdate(function(dt, self)
		cooldown -= dt -- dilated: cooldowns tick slower in slow chunks
		if cooldown <= 0 then
			cooldown = self.AttackCooldown
			-- swing...
		end
	end)

	npc.ChunkChanged:Connect(function(newChunk)
		print(`Dummy entered chunk {newChunk.Key}, local time x{newChunk.TimeScale}`)
	end)
end

-- Query helpers.
Heartbeat.ConnectInterval(2, function()
	local nearby = ChunkManager.GetEntitiesInRadius(zoneCenter, 96)
	print(`{#nearby} entities inside the slow zone`)
	local stats = ChunkManager.GetStats()
	print(`{stats.LoadedChunkCount}/{stats.ChunkCount} chunks loaded`)
end, { Name = "Example.ZoneReport" })
