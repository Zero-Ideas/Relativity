--!optimize 2
--[[
	Railgun tool controller.
	Loaded and driven entirely by ToolManager.luau, which calls Equip(tool,
	character) when this tool (matched by Tool.Name == this module's Name,
	i.e. "Railgun") becomes equipped, and Unequip(tool, character) when it
	stops being equipped. Mirrors TimeBlaster.luau: starts the same
	ShooterController input/config pipeline (click to fire), plus the
	viewmodel hold pose. Viewmodel.Equip is a no-op if this Tool has no
	RightGripAttachment yet -- safe to call unconditionally even before the
	weapon's grip attachments are set up in Studio.

	Firing renders the RailgunRod effect specifically because "Railgun" is
	registered in Shared.ShooterTool.Weapons (-> ReplicatedStorage.Effects.
	RailgunRod) -- see that module and Shooter.server.luau's PROJECTILE_MODELS
	for how the server picks the bullet Model from the equipped tool's name.
]]

local ShooterConfigGui = require(script.Parent.Parent.ShooterConfigGui)
local ShooterController = require(script.Parent.Parent.ShooterController)
local Viewmodel = require(script.Parent.Parent.Viewmodel)

local RailgunController = {}

function RailgunController.Equip(tool: Tool, character: Model)
	ShooterConfigGui.setVisible(true)
	ShooterController.start()
	Viewmodel.Equip(tool, character)
end

function RailgunController.Unequip(tool: Tool, character: Model)
	ShooterConfigGui.setVisible(false)
	ShooterController.stop()
	Viewmodel.Unequip(tool, character)
end

return RailgunController
