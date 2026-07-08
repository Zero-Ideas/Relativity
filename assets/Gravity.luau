--[[
	Client bootstrap: enables projectile visual rendering and receives
	chunk/global time-scale replication so client-side visual simulation
	dilates exactly like the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local ChunkManager = require(Shared.ChunkManager)
local Projectile = require(Shared.Projectile)

ChunkManager.EnableReplication()
Projectile.EnableClientRendering()

-- Optional: custom impact VFX for offloaded projectiles.
-- Projectile.SetImpactHandler(function(position, normal, model)
-- 	local effect = ReplicatedStorage.Effects.Impact:Clone()
-- 	effect.Position = position
-- 	effect.Parent = workspace
-- 	task.delay(1, effect.Destroy, effect)
-- end)
