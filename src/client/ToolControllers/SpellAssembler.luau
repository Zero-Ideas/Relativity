-- Thin Tool launcher; SpellAssemblerGui can later be opened by any menu.

local controller = require(script.Parent.Parent.SpellAssemblerGui)
local activation: RBXScriptConnection? = nil
local deactivation: RBXScriptConnection? = nil

return {
	Equip = function(tool: Tool, _character: Model)
		if activation then activation:Disconnect() end
		if deactivation then deactivation:Disconnect() end
		activation = tool.Activated:Connect(controller.Cast)
		deactivation = tool.Deactivated:Connect(controller.StopCast)
		controller.Equip(tool)
	end,
	Unequip = function(tool: Tool, _character: Model)
		if activation then activation:Disconnect(); activation = nil end
		if deactivation then deactivation:Disconnect(); deactivation = nil end
		controller.Unequip(tool)
	end,
}
