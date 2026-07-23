--!optimize 2
--[[
	MapGen/CellSpace.luau
	Pure helpers mapping grid cell coordinates to world-space positions, shared by
	Visualizer and Builder so both always agree on where a cell actually sits.
]]

local CellSpace = {}

-- World position of a cell's center on the XZ plane (Y taken from origin).
function CellSpace.worldXZ(origin: Vector3, cellSize: number, x: number, y: number): Vector3
	return origin + Vector3.new((x - 0.5) * cellSize, 0, (y - 0.5) * cellSize)
end

-- World position of a cell's min corner (its -X,-Z edge). Passing x = width+1
-- (one past the last column) gives the grid's far X boundary, and likewise y.
function CellSpace.cellMin(origin: Vector3, cellSize: number, x: number, y: number): Vector3
	return origin + Vector3.new((x - 1) * cellSize, 0, (y - 1) * cellSize)
end

return CellSpace
