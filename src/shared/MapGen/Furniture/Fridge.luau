--!optimize 2
--[[ MapGen/Furniture/Fridge.luau -- built facing +Z, floor at local Y=0. ]]

local FurnitureBase = require(script.Parent.FurnitureBase)
local part = FurnitureBase.part

local Fridge = {}

export type FridgeConfig = {
	bodyColor: Color3?,
}

function Fridge.generate(cframe: CFrame, config: FridgeConfig?): Model
	config = config or {}
	local color = config.bodyColor or Color3.fromRGB(225, 225, 228)

	local body = part("Body", Vector3.new(2.5, 5.5, 2.5), CFrame.new(0, 2.75, 0), color, Enum.Material.Metal)

	local parts = {
		part("HandleTop", Vector3.new(0.15, 1.3, 0.15), CFrame.new(1.15, 3.8, 1.3), Color3.fromRGB(60, 60, 62), Enum.Material.Metal),
		part("HandleBottom", Vector3.new(0.15, 1.3, 0.15), CFrame.new(1.15, 1.6, 1.3), Color3.fromRGB(60, 60, 62), Enum.Material.Metal),
	}

	return FurnitureBase.assemble("Fridge", body, parts, cframe)
end

return Fridge
