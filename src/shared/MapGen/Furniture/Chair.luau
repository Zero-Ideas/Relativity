--!optimize 2
--[[ MapGen/Furniture/Chair.luau -- built facing +Z, floor at local Y=0. ]]

local FurnitureBase = require(script.Parent.FurnitureBase)
local part = FurnitureBase.part

local Chair = {}

export type ChairConfig = {
	seatColor: Color3?,
	legColor: Color3?,
}

function Chair.generate(cframe: CFrame, config: ChairConfig?): Model
	config = config or {}
	local seatColor = config.seatColor or Color3.fromRGB(120, 80, 50)
	local legColor = config.legColor or Color3.fromRGB(60, 45, 30)

	local seat = part("Seat", Vector3.new(2, 0.3, 2), CFrame.new(0, 1.5, 0), seatColor, Enum.Material.Wood)

	local parts = {
		part("Back", Vector3.new(2, 1.8, 0.3), CFrame.new(0, 2.55, -0.85), seatColor, Enum.Material.Wood),
		part("LegFL", Vector3.new(0.2, 1.5, 0.2), CFrame.new(0.8, 0.75, 0.8), legColor, Enum.Material.Wood),
		part("LegFR", Vector3.new(0.2, 1.5, 0.2), CFrame.new(-0.8, 0.75, 0.8), legColor, Enum.Material.Wood),
		part("LegBL", Vector3.new(0.2, 1.5, 0.2), CFrame.new(0.8, 0.75, -0.8), legColor, Enum.Material.Wood),
		part("LegBR", Vector3.new(0.2, 1.5, 0.2), CFrame.new(-0.8, 0.75, -0.8), legColor, Enum.Material.Wood),
	}

	return FurnitureBase.assemble("Chair", seat, parts, cframe)
end

return Chair
