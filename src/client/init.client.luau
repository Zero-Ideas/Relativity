--[[
	Client bootstrap: enables projectile visual rendering, receives chunk/global
	time-scale replication, and starts the client-side dilation systems
	(movement, chunk overlay, and the personal time-ratio panel). Also starts
	ToolManager, which swaps in each equipped tool's controller module (see
	ToolManager.luau and ToolControllers/) -- e.g. firing input only listens
	while a registered weapon (TimeBlaster, Railgun, ...) is equipped, driven
	entirely by that tool's ToolControllers/<Name>.luau.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local ChunkManager = require(Shared.ChunkManager)
local ProjectileClient = require(Shared.Projectile.Client)
local Entity = require(Shared.Entity)

-- Client-local systems (sibling ModuleScripts of this LocalScript).
local MovementController = require(script.MovementController)
local ChunkVisualizer = require(script.ChunkVisualizer)
local TimeControlGui = require(script.TimeControlGui)
local ToolManager = require(script.ToolManager)
local DebugPanel = require(script.DebugPanel) -- Studio-only ReGui panel (F2)
-- These two self-register their VisualOffload listeners at require time
-- (no .start()) -- see AmmoState.luau (ammo cache for a future HUD) and
-- WeaponEffects.luau (server-broadcast one-shot weapon VFX like the
-- muzzle blast).
local _AmmoState = require(script.AmmoState)
local _WeaponEffects = require(script.WeaponEffects)
local _SpellEffects = require(script.SpellEffects) -- spell Beam visuals
local _DummyEffects = require(script.DummyEffects) -- test dummy damage flashes

ChunkManager.EnableReplication()
ProjectileClient.EnableClientRendering()
Entity.EnableHurtboxRendering() -- draws hurtboxes when Entity.ShowHurtboxes is true
Entity.EnableHurtboxHistoryRendering() -- draws the history trail when Entity.ShowHurtboxHistory is true

MovementController.start()
ChunkVisualizer.start()
-- the time slider lives in the debug panel's Time tab; the old on-screen
-- panel is gone everywhere
TimeControlGui.start({ Headless = true })
-- builds itself only for players allowed to use it (see DebugPanel)
DebugPanel.start()
ToolManager.start()
-- MainHud (hotbar) or the classic Backpack UI, switched from the topbar
task.spawn(function() require(script.UiMode).start() end)

-- Optional: custom impact VFX for offloaded projectiles.
-- ProjectileClient.SetImpactHandler(function(position, normal, model)
-- 	local effect = ReplicatedStorage.Effects.Impact:Clone()
-- 	effect.Position = position
-- 	effect.Parent = workspace
-- 	task.delay(1, effect.Destroy, effect)
-- end)

print("[Relativity] client render systems online")
