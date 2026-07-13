--!optimize 2
--[[
	Railgun tool controller.
	Loaded and driven entirely by ToolManager.luau, which calls Equip(tool,
	character) when this tool (matched by Tool.Name == this module's Name,
	i.e. "Railgun") becomes equipped, and Unequip(tool, character) when it
	stops being equipped. Currently only hooks up the viewmodel hold pose --
	see the module doc comment in Viewmodel/init.luau for the full system.
	Viewmodel.Equip is a no-op if this Tool has no RightGripAttachment yet --
	safe to call unconditionally even before the weapon's grip attachments
	are set up in Studio.

	NOTE: this does NOT wire up firing (unlike TimeBlaster.luau, which also
	starts ShooterController/ShooterConfigGui) -- the server-side Shooter
	system currently only recognizes a tool literally named "TimeBlaster"
	(see ShooterTool.luau / Shooter.server.luau), so making Railgun actually
	shoot needs a separate, deliberate change there, not just a client
	controller. Add that once it's confirmed Railgun should fire through the
	same pipeline (or its own).
]]

local Viewmodel = require(script.Parent.Parent.Viewmodel)

local RailgunController = {}

function RailgunController.Equip(tool: Tool, character: Model)
	Viewmodel.Equip(tool, character)
end

function RailgunController.Unequip(tool: Tool, character: Model)
	Viewmodel.Unequip(tool, character)
end

return RailgunController
