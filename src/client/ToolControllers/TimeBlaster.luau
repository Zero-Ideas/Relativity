--!optimize 2
--[[
	TimeBlaster tool controller.
	Loaded and driven entirely by ToolManager.luau, which calls Equip(tool,
	character) when this tool (matched by Tool.Name == this module's Name,
	i.e. "TimeBlaster") becomes equipped, and Unequip(tool, character) when it
	stops being equipped. This is the only place that knows the shooter menu
	and firing are tied to a specific tool -- ShooterConfigGui and
	ShooterController themselves know nothing about equip state; they're just
	started/stopped here.
]]

local ShooterConfigGui = require(script.Parent.Parent.ShooterConfigGui)
local ShooterController = require(script.Parent.Parent.ShooterController)

ShooterConfigGui.start() -- idempotent; just builds the (hidden) panel once

local TimeBlasterController = {}

function TimeBlasterController.Equip(_tool: Tool, _character: Model)
	ShooterConfigGui.setVisible(true)
	ShooterController.start()
end

function TimeBlasterController.Unequip(_tool: Tool, _character: Model)
	ShooterConfigGui.setVisible(false)
	ShooterController.stop()
end

return TimeBlasterController
