--[[
	Client bootstrap: enables projectile visual rendering, receives chunk/global
	time-scale replication, and starts the client-side dilation systems
	(movement, chunk overlay, and the personal time-ratio panel). Also starts
	ToolManager, which swaps in each equipped tool's controller module (see
	ToolManager.luau and ToolControllers/) -- e.g. the shooter menu only shows
	up while the TimeBlaster tool is equipped, driven entirely by
	ToolControllers/TimeBlaster.luau.
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
local ToolManager = require(script.ToolManager)

ChunkManager.EnableReplication()
Projectile.EnableClientRendering()
Entity.EnableHurtboxRendering() -- draws hurtboxes when Entity.ShowHurtboxes is true
Entity.EnableHurtboxHistoryRendering() -- draws the history trail when Entity.ShowHurtboxHistory is true

MovementController.start()
ChunkVisualizer.start()
TimeControlGui.start()
ToolManager.start()

-- Optional: custom impact VFX for offloaded projectiles.
-- Projectile.SetImpactHandler(function(position, normal, model)
-- 	local effect = ReplicatedStorage.Effects.Impact:Clone()
-- 	effect.Position = position
-- 	effect.Parent = workspace
-- 	task.delay(1, effect.Destroy, effect)
-- end)

print("[Relativity] client render systems online")
