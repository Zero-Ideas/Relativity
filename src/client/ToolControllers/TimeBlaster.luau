--!optimize 2
--[[
	TimeBlaster tool controller.
	Loaded and driven entirely by ToolManager.luau, which calls Equip(tool,
	character) when this tool (matched by Tool.Name == this module's Name,
	i.e. "TimeBlaster") becomes equipped, and Unequip(tool, character) when it
	stops being equipped. Controller modules like this are the only place
	that know the shooter menu, firing, and the viewmodel pose are tied to a
	specific tool -- ShooterConfigGui, ShooterController, and Viewmodel
	themselves know nothing about equip state; they're just
	started/stopped/posed here (and mirrored by
	ToolControllers/Railgun.luau, since only one tool controller is ever
	active at a time -- see ToolManager.luau). Which bullet Model actually
	renders is chosen server-side per equipped tool -- see Shared.ShooterTool
	/ Shooter.server.luau's PROJECTILE_MODELS. Viewmodel.Equip is a no-op if
	this Tool has no RightGripAttachment (see Viewmodel/init.luau) -- safe to
	call unconditionally even before a weapon's grip attachments are set up
	in Studio.
]]

local ShooterConfigGui = require(script.Parent.Parent.ShooterConfigGui)
local ShooterController = require(script.Parent.Parent.ShooterController)
local Viewmodel = require(script.Parent.Parent.Viewmodel)

ShooterConfigGui.start() -- idempotent; just builds the (hidden) panel once

local TimeBlasterController = {}

function TimeBlasterController.Equip(tool: Tool, character: Model)
	ShooterConfigGui.setVisible(true)
	ShooterController.start()
	Viewmodel.Equip(tool, character)
end

function TimeBlasterController.Unequip(tool: Tool, character: Model)
	ShooterConfigGui.setVisible(false)
	ShooterController.stop()
	Viewmodel.Unequip(tool, character)
end

return TimeBlasterController
