--!optimize 2
--[[ MapGen/Furniture/Table.luau -- built facing +Z, floor at local Y=0. ]]

local FurnitureBase = require(script.Parent.FurnitureBase)
local part = FurnitureBase.part

local Table = {}

export type TableConfig = {
	topColor: Color3?,
	legColor: Color3?,
	width: number?, -- studs, along local X
	depth: number?, -- studs, along local Z
}

function Table.generate(cframe: CFrame, config: TableConfig?): Model
	config = config or {}
	local topColor = config.topColor or Color3.fromRGB(150, 110, 70)
	local legColor = config.legColor or Color3.fromRGB(70, 50, 30)
	local w = config.width or 4
	local d = config.depth or 3
	local legInsetX, legInsetZ = w / 2 - 0.3, d / 2 - 0.3

	local top = part("Top", Vector3.new(w, 0.3, d), CFrame.new(0, 2.5, 0), topColor, Enum.Material.Wood)

	local parts = {
		part("LegFL", Vector3.new(0.3, 2.35, 0.3), CFrame.new(legInsetX, 1.175, legInsetZ), legColor, Enum.Material.Wood),
		part("LegFR", Vector3.new(0.3, 2.35, 0.3), CFrame.new(-legInsetX, 1.175, legInsetZ), legColor, Enum.Material.Wood),
		part("LegBL", Vector3.new(0.3, 2.35, 0.3), CFrame.new(legInsetX, 1.175, -legInsetZ), legColor, Enum.Material.Wood),
		part("LegBR", Vector3.new(0.3, 2.35, 0.3), CFrame.new(-legInsetX, 1.175, -legInsetZ), legColor, Enum.Material.Wood),
	}

	return FurnitureBase.assemble("Table", top, parts, cframe)
end

return Table
