--!optimize 2
--[[
	ToolControllers/_ShootingWeapon.luau
	Shared Equip/Unequip body for every plain shooting weapon (see
	Weapons/init.luau on the server for the per-weapon stat sheet/behavior
	side of this). Leading underscore is deliberate: ToolManager.luau
	matches a controller to a Tool purely by exact Tool.Name ==
	ModuleScript.Name, and no Tool is ever named "_ShootingWeapon", so this
	file is inert as a controller on its own -- other controller modules
	require and re-export it instead, e.g.:

		-- ToolControllers/Railgun.luau
		return require(script.Parent._ShootingWeapon)

	A weapon only needs its own dedicated controller file (instead of
	re-exporting this) if it needs behavior beyond "start the generic
	fire/viewmodel pipeline" -- e.g. a melee weapon, or one with a unique
	client-side windup/charge visual.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)

local client = script.Parent.Parent
local ShooterController = require(client.ShooterController)
local Viewmodel = require(client.Viewmodel)
local ShooterConfigGui = require(client.ShooterConfigGui)

local ShootingWeapon = {}

function ShootingWeapon.Equip(tool: Tool, character: Model)
	ShooterConfigGui.start() -- idempotent; no-ops outside Studio -- see ShooterConfigGui.luau
	ShooterConfigGui.setVisible(true)
	ShooterController.start()
	Viewmodel.Equip(tool, character)
	-- Lets the server sync starting ammo immediately (see Shooter.server.
	-- luau's "WeaponEquip" handler) instead of waiting for the first shot --
	-- a no-op server-side for weapons with no Magazine.
	VisualOffload.Fire("WeaponEquip", { ToolName = tool.Name })
end

function ShootingWeapon.Unequip(tool: Tool, character: Model)
	ShooterConfigGui.setVisible(false)
	ShooterController.stop()
	Viewmodel.Unequip(tool, character)
end

return ShootingWeapon
