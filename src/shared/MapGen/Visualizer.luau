--!optimize 2
--[[
	MapGen/Visualizer.luau
	Draws the generation state as parts in the workspace so you can watch the
	map build. It renders a flat grid of floor tiles (one per cell), recolors
	tiles as cells change type, tints empty regions during detection, and pops
	translucent boxes + labels over detected room rectangles.

	It holds no generation logic — the orchestrator (init.luau) steps the
	generator and calls into here to reflect each change, pacing the animation
	with waits. Everything lives under a single workspace Folder that :destroy()
	tears down, so re-running is clean.

	Cell -> world mapping:
	  worldXZ(x,y) = origin + ((x-0.5)*cellSize, (y-0.5)*cellSize) on the XZ plane.
]]

local Grid = require(script.Parent.Grid)
local CellSpace = require(script.Parent.CellSpace)

local Visualizer = {}
Visualizer.__index = Visualizer

local TILE_THICKNESS = 0.4

local COLORS = {
	[Grid.EMPTY] = Color3.fromRGB(38, 40, 48),
	[Grid.HALL] = Color3.fromRGB(228, 208, 170),
	[Grid.ROOM] = Color3.fromRGB(90, 130, 200),
	[Grid.DOOR] = Color3.fromRGB(240, 120, 80),
}

-- Distinct, readable palette cycled across regions / rooms.
local PALETTE = {
	Color3.fromRGB(232, 108, 108),
	Color3.fromRGB(232, 168, 92),
	Color3.fromRGB(224, 214, 96),
	Color3.fromRGB(120, 208, 120),
	Color3.fromRGB(96, 200, 208),
	Color3.fromRGB(120, 152, 232),
	Color3.fromRGB(176, 128, 232),
	Color3.fromRGB(232, 128, 192),
}

function Visualizer.new(grid, config)
	local origin = config.origin or Vector3.new(0, 0, 0)
	local self = setmetatable({
		grid = grid,
		cellSize = config.cellSize or 8,
		origin = origin,
		tiles = table.create(grid.width * grid.height), -- flat, parallel to grid.cells
		root = nil,
		tileFolder = nil,
		overlayFolder = nil,
		enabled = true,
	}, Visualizer)

	local root = Instance.new("Folder")
	root.Name = "MapGenVisualizer"
	local tiles = Instance.new("Folder")
	tiles.Name = "Tiles"
	tiles.Parent = root
	local overlays = Instance.new("Folder")
	overlays.Name = "Overlays"
	overlays.Parent = root
	root.Parent = workspace

	self.root = root
	self.tileFolder = tiles
	self.overlayFolder = overlays
	return self
end

function Visualizer.worldXZ(self, x: number, y: number): Vector3
	return CellSpace.worldXZ(self.origin, self.cellSize, x, y)
end

-- Show/hide the whole debug overlay by reparenting its folder (mirrors
-- ChunkVisualizer's convention). Useful once Builder has placed real geometry
-- and you want to compare it against the debug preview without both rendering
-- at once.
function Visualizer.setEnabled(self, value: boolean)
	self.enabled = value
	if self.root then
		self.root.Parent = value and workspace or nil
	end
end

function Visualizer.toggle(self)
	self:setEnabled(not self.enabled)
end

-- Center of the whole map (handy for aiming a camera).
function Visualizer.center(self): Vector3
	return self.origin + Vector3.new(self.grid.width * self.cellSize / 2, 0, self.grid.height * self.cellSize / 2)
end

-- Build every floor tile up front, colored by current cell type.
function Visualizer.drawBase(self)
	local size = self.cellSize
	for y = 1, self.grid.height do
		for x = 1, self.grid.width do
			local idx = self.grid:index(x, y)
			local tile = Instance.new("Part")
			tile.Name = `T_{x}_{y}`
			tile.Anchored = true
			tile.CanCollide = false
			tile.CanQuery = false
			tile.CanTouch = false
			tile.CastShadow = false
			tile.Material = Enum.Material.SmoothPlastic
			tile.Size = Vector3.new(size - 0.15, TILE_THICKNESS, size - 0.15)
			tile.Position = self:worldXZ(x, y) - Vector3.new(0, TILE_THICKNESS / 2, 0)
			tile.Color = COLORS[self.grid.cells[idx]] or COLORS[Grid.EMPTY]
			tile.Parent = self.tileFolder
			self.tiles[idx] = tile
		end
	end
end

-- Recolor one tile to match its current grid cell type.
function Visualizer.paintCell(self, x: number, y: number)
	local idx = self.grid:index(x, y)
	local tile = self.tiles[idx]
	if tile then
		tile.Color = COLORS[self.grid.cells[idx]] or COLORS[Grid.EMPTY]
	end
end

function Visualizer.paintCells(self, cells)
	for _, c in cells do
		self:paintCell(c[1], c[2])
	end
end

function Visualizer.paletteColor(self, index: number): Color3
	return PALETTE[((index - 1) % #PALETTE) + 1]
end

-- Tint an empty region's tiles (empty-space detection visualization).
function Visualizer.highlightRegion(self, region, color: Color3)
	for _, c in region.cells do
		local tile = self.tiles[self.grid:index(c[1], c[2])]
		if tile then
			tile.Color = color
		end
	end
end

-- Pop a translucent box + label over a detected room rectangle.
function Visualizer.addRoom(self, room, color: Color3, label: string?)
	local size = self.cellSize
	local box = Instance.new("Part")
	box.Name = `Room_{room.x}_{room.y}`
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false
	box.CanTouch = false
	box.CastShadow = false
	box.Material = Enum.Material.SmoothPlastic
	box.Transparency = 0.5
	box.Color = color
	box.Size = Vector3.new(room.w * size - 0.4, size * 0.6, room.h * size - 0.4)
	-- center of the rectangle in cell space
	local cx = room.x + (room.w - 1) / 2
	local cy = room.y + (room.h - 1) / 2
	box.Position = self:worldXZ(cx, cy) + Vector3.new(0, box.Size.Y / 2, 0)
	box.Parent = self.overlayFolder

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(44, 16)
	billboard.AlwaysOnTop = true
	billboard.Parent = box
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 1)
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.TextStrokeTransparency = 0.3
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Text = label or `{room.w}x{room.h}`
	text.Parent = billboard

	-- Mark door cells with a distinct color on the base tiles.
	for _, d in room.doorCells do
		local tile = self.tiles[self.grid:index(d[1], d[2])]
		if tile then
			tile.Color = COLORS[Grid.DOOR]
		end
	end

	return box
end

function Visualizer.clearOverlays(self)
	self.overlayFolder:ClearAllChildren()
end

function Visualizer.destroy(self)
	if self.root then
		self.root:Destroy()
		self.root = nil
	end
end

-- Remove any previous visualization folder before making a new one.
function Visualizer.clearWorkspace()
	local existing = workspace:FindFirstChild("MapGenVisualizer")
	if existing then
		existing:Destroy()
	end
end

return Visualizer
