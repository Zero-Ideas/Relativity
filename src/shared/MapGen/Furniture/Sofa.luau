--!optimize 2
--[[ MapGen/Furniture/Sofa.luau -- built facing +Z, floor at local Y=0. ]]

local FurnitureBase = require(script.Parent.FurnitureBase)
local part = FurnitureBase.part

local Sofa = {}

export type SofaConfig = {
	fabricColor: Color3?,
}

function Sofa.generate(cframe: CFrame, config: SofaConfig?): Model
	config = config or {}
	local color = config.fabricColor or Color3.fromRGB(90, 100, 130)

	local seat = part("Seat", Vector3.new(6, 1, 2.2), CFrame.new(0, 1.2, 0), color, Enum.Material.Fabric)

	local parts = {
		part("Back", Vector3.new(6, 1.5, 0.6), CFrame.new(0, 2.45, -0.8), color, Enum.Material.Fabric),
		part("ArmL", Vector3.new(0.6, 1.6, 2.2), CFrame.new(2.7, 1.5, 0), color, Enum.Material.Fabric),
		part("ArmR", Vector3.new(0.6, 1.6, 2.2), CFrame.new(-2.7, 1.5, 0), color, Enum.Material.Fabric),
	}

	return FurnitureBase.assemble("Sofa", seat, parts, cframe)
end

return Sofa
