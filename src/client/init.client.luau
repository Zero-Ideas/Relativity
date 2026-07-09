--[[
	Client bootstrap: enables projectile visual rendering, receives chunk/global
	time-scale replication, and starts the client-side dilation systems
	(movement, chunk overlay, and the global time-ratio panel).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local ChunkManager = require(Shared.ChunkManager)
local Projectile = require(Shared.Projectile)
local Entity = require(Shared.Entity)

-- Client-local systems (sibling ModuleScripts of this LocalScript).
local MovementController = require(script.MovementController)
local ChunkVisualizer = require(script.ChunkVisualizer)
local TimeControlGui = require(script.TimeControlGui)
local ShooterConfigGui = require(script.ShooterConfigGui)
local ShooterController = require(script.ShooterController)

ChunkManager.EnableReplication()
Projectile.EnableClientRendering()
Entity.EnableHurtboxRendering() -- draws hurtboxes when Entity.ShowHurtboxes is true
Entity.EnableHurtboxHistoryRendering() -- draws the history trail when Entity.ShowHurtboxHistory is true

MovementController.start()
ChunkVisualizer.start()
TimeControlGui.start()
ShooterConfigGui.start()
ShooterController.start()

-- Optional: custom impact VFX for offloaded projectiles.
-- Projectile.SetImpactHandler(function(position, normal, model)
-- 	local effect = ReplicatedStorage.Effects.Impact:Clone()
-- 	effect.Position = position
-- 	effect.Parent = workspace
-- 	task.delay(1, effect.Destroy, effect)
-- end)

print("[Relativity] client render systems online")
