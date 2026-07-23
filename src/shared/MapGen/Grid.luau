--!optimize 2
--[[
	MapGen/Grid.luau
	A flat 2D cell grid used by the map generator. Coordinates are 1-based cell
	indices (x = column, y = row). Cells hold a CellType enum value; everything
	starts EMPTY. Storage is a single flat array indexed (y-1)*width + x for cache
	friendliness.

	This module is intentionally dumb data + helpers — the hallway generator and
	room finder read/write cells through it, and the visualizer reads it to draw.
]]

local Grid = {}
Grid.__index = Grid

-- Cell types (kept as plain numbers so the flat array stays a number array).
Grid.EMPTY = 0
Grid.HALL = 1
Grid.ROOM = 2
Grid.DOOR = 3

export type Grid = typeof(setmetatable(
	{} :: {
		width: number,
		height: number,
		cells: { number },
	},
	Grid
))

function Grid.new(width: number, height: number): Grid
	local self = setmetatable({
		width = width,
		height = height,
		cells = table.create(width * height, Grid.EMPTY),
	}, Grid)
	return self
end

function Grid.inBounds(self: Grid, x: number, y: number): boolean
	return x >= 1 and x <= self.width and y >= 1 and y <= self.height
end

function Grid.index(self: Grid, x: number, y: number): number
	return (y - 1) * self.width + x
end

-- Returns the cell type, or nil when out of bounds (so callers can treat the
-- border as "solid wall" without a separate bounds check).
function Grid.get(self: Grid, x: number, y: number): number?
	if x < 1 or x > self.width or y < 1 or y > self.height then
		return nil
	end
	return self.cells[(y - 1) * self.width + x]
end

function Grid.set(self: Grid, x: number, y: number, value: number)
	if x < 1 or x > self.width or y < 1 or y > self.height then
		return
	end
	self.cells[(y - 1) * self.width + x] = value
end

function Grid.is(self: Grid, x: number, y: number, value: number): boolean
	return self:get(x, y) == value
end

-- Count cells of a given type (used for fill targets / stats).
function Grid.count(self: Grid, value: number): number
	local n = 0
	for _, v in self.cells do
		if v == value then
			n += 1
		end
	end
	return n
end

return Grid
