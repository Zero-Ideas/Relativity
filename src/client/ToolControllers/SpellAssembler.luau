-- Thin Tool launcher; SpellAssemblerGui can later be opened by any menu.

local controller = require(script.Parent.Parent.SpellAssemblerGui)
local activation: RBXScriptConnection? = nil

return {
	Equip = function(tool: Tool, _character: Model)
		if activation then activation:Disconnect() end
		activation = tool.Activated:Connect(controller.Cast)
		controller.Equip(tool)
	end,
	Unequip = function(tool: Tool, _character: Model)
		if activation then activation:Disconnect(); activation = nil end
		controller.Unequip(tool)
	end,
}
