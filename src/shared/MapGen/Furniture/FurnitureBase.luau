--!optimize 2
--[[
	MapGen/Furniture/FurnitureBase.luau
	Shared assembly helper for furniture generators. Each generator (Chair,
	Table, Sofa, ...) builds its parts in LOCAL space -- as if placed at the
	origin, facing +Z -- and calls FurnitureBase.assemble to weld them into one
	rigid Model and move the whole thing to the requested world CFrame in one
	step via Model:PivotTo.

	Rigid, not static: the root part is Anchored so the assembly holds still on
	its own, but every other part is unanchored and WeldConstraint'd to the
	root, so the whole piece is a single physical rigid body -- unanchor the
	root later (e.g. to hand it to a player as a prop-hunt disguise) and the
	whole assembly falls/moves together correctly, instead of each part being
	independently anchored and immovable forever.
]]

local FurnitureBase = {}

-- Builds a Model named `name` from `root` (becomes PrimaryPart, Anchored) and
-- `parts` (welded to root, unanchored), then pivots the whole assembly to
-- `cframe`. Parts should already be positioned in local/origin space.
function FurnitureBase.assemble(name: string, root: BasePart, parts: { BasePart }, cframe: CFrame): Model
	local model = Instance.new("Model")
	model.Name = name

	root.Anchored = true
	root.Parent = model

	for _, part in parts do
		part.Anchored = false
		part.Parent = model
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = part
		weld.Parent = part
	end

	model.PrimaryPart = root
	model:PivotTo(cframe)
	return model
end

-- Small helper for generators: a Part with the common non-collidable-for-decor
-- defaults filled in (still CanCollide=true by default, since furniture should
-- physically block movement like real level geometry).
function FurnitureBase.part(name: string, size: Vector3, localCFrame: CFrame, color: Color3, material: Enum.Material?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = localCFrame
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	return part
end

return FurnitureBase
