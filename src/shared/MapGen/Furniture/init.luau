--!optimize 2
--[[
	MapGen/Furniture (init.luau)
	Procedural, part-based furniture generators. Each submodule exposes a single
	`generate(cframe: CFrame, config?) -> Model` function: it builds its parts in
	local space (origin, facing +Z, floor at Y=0), welds them into one rigid
	assembly via FurnitureBase.assemble, and pivots the whole thing to `cframe`.

	Every generated Model has an Anchored PrimaryPart with the rest welded to it
	(WeldConstraint, unanchored) -- a real rigid body, not just a pile of
	individually-anchored parts, so it can later be handed to a player as a
	prop-hunt disguise by unanchoring the root.

	Usage:
		local Furniture = require(...)
		local chair = Furniture.Chair.generate(CFrame.new(10, 0, 20))
		chair.Parent = workspace
]]

local Furniture = {}

Furniture.Base = require(script.FurnitureBase)
Furniture.Chair = require(script.Chair)
Furniture.Table = require(script.Table)
Furniture.Sofa = require(script.Sofa)
Furniture.TV = require(script.TV)
Furniture.Fridge = require(script.Fridge)

return Furniture
