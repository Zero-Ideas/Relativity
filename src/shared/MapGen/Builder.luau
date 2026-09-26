--!optimize 2
--[[
	MapGen/Builder.luau
	Turns generated grid + room data into real, physical geometry -- floors,
	walls with door openings, and hallway carpet styling. Everything before this
	(Grid / HallwayGenerator / RoomFinder) only decides WHERE things go; this
	module places the actual parts, and they collide like normal level geometry
	(unlike Visualizer's non-solid debug preview tiles).

	Compartments
	------------
	Every floor cell (hallway or room interior) belongs to exactly one
	"compartment": a specific room, or the shared hallway network. A wall goes up
	on every edge between cells in different compartments (including the map
	boundary), except at each room's door opening(s), which cut a gap in the wall
	between that room and its chosen adjacent hallway cell. Two rooms that happen
	to sit directly next to each other (RoomFinder can pack rooms edge-to-edge
	within the same empty pocket) get a plain solid wall between them by default --
	unless RoomFinder.connectAdjacentRooms rolled a connecting door for that pair
	(see `openEdges` below), since only hallway-adjacency and that roll generate
	doors on their own.

	Each room gets exactly one door position (optionally widened to `doorWidth`
	cells), picked from the doorCells RoomFinder already tagged as bordering it.
	RoomFinder.resolvePockets may also merge irregular leftover pockets into a
	room's `cells` (beyond its original rectangle) or fuse two rooms together via
	an always-open connecting pocket, and RoomFinder.connectAdjacentRooms can add
	direct room-to-room doors -- pass the combined edge list in as `openEdges` so
	those specific edges skip the wall/door logic entirely.

	Walls are merged into straight runs along each lattice line (they're only
	ever 1 cell thick, so a run is the natural unit). Floors instead use a greedy
	largest-rectangle-first cover (the same anchored-maximal-rectangle scan
	RoomFinder.findRooms uses for packing, just uncapped) so a big open room or
	hallway stretch becomes a handful of large slabs instead of one thin part per
	row -- both to keep part counts sane and because it looks like an actual
	floor instead of floorboards.
]]

local Grid = require(script.Parent.Grid)
local CellSpace = require(script.Parent.CellSpace)

local Builder = {}

export type BuildConfig = {
	cellSize: number?,
	origin: Vector3?,
	wallThickness: number?, -- studs
	wallHeight: number?, -- studs
	floorThickness: number?, -- studs
	doorWidth: number?, -- cells wide per door opening
	hallCarpetColor: Color3?,
	roomFloorColor: Color3?,
	wallColor: Color3?,
	seed: number?, -- only used to pick which doorCell each room opens at
	openEdges: { { number } }?, -- {ax,ay,bx,by} cell-pair edges to always leave open (see RoomFinder.resolvePockets)

	-- roof: a single ceiling slab cover sitting on top of the walls
	ceilingThickness: number?, -- studs
	ceilingColor: Color3?,

	-- ceiling lights: placed on a uniform cell grid wherever there's floor below.
	-- Keep lightRange comfortably above (lightSpacing * cellSize) / 2 -- that's
	-- the point exactly between two adjacent lights, and a Range that only just
	-- reaches it will be dim there even without a literal dark gap.
	lightSpacing: number?, -- cells between lights, both axes
	lightRange: number?, -- studs
	lightBrightness: number?,
	lightColor: Color3?,
	lightFixtureSize: number?, -- studs, the visible fixture housing
	lightShadows: boolean?, -- shadow-casting lights are far more expensive; off by default
}

local DEFAULTS = {
	cellSize = 8,
	origin = Vector3.new(0, 0, 0),
	wallThickness = 1,
	wallHeight = 10,
	floorThickness = 1,
	doorWidth = 2,
	hallCarpetColor = Color3.fromRGB(120, 30, 35),
	roomFloorColor = Color3.fromRGB(195, 178, 150),
	wallColor = Color3.fromRGB(230, 225, 215),

	ceilingThickness = 1,
	ceilingColor = Color3.fromRGB(235, 232, 224),

	lightSpacing = 5,
	lightRange = 32,
	lightBrightness = 2.5,
	lightColor = Color3.fromRGB(255, 244, 214),
	lightFixtureSize = 2,
	lightShadows = false,
}

local function withDefaults(config: BuildConfig?)
	local merged = {}
	for k, v in DEFAULTS do
		merged[k] = v
	end
	if config then
		for k, v in config do
			merged[k] = v
		end
	end
	return merged
end

local function makePart(size: Vector3, position: Vector3, color: Color3, material: Enum.Material, name: string, parent: Instance)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Material = material
	part.Color = color
	part.Size = size
	part.Position = position
	part.Parent = parent
	return part
end

--------------------------------------------------------------------------------
-- Door selection
--------------------------------------------------------------------------------

-- Given a room and one of its doorCells (a HALL cell coordinate), work out
-- which side of the room it borders and its coordinate along that wall run.
local function resolveDoor(room, hx: number, hy: number): (string?, number?)
	if hy == room.y - 1 and hx >= room.x and hx < room.x + room.w then
		return "N", hx
	elseif hy == room.y + room.h and hx >= room.x and hx < room.x + room.w then
		return "S", hx
	elseif hx == room.x - 1 and hy >= room.y and hy < room.y + room.h then
		return "W", hy
	elseif hx == room.x + room.w and hy >= room.y and hy < room.y + room.h then
		return "E", hy
	end
	return nil, nil
end

-- Returns a list of {hx, hy, side} door-edge descriptors for one room: a
-- primary doorCell chosen at random, widened up to doorWidth cells along the
-- same wall run (only where a hall-adjacent cell actually exists there).
local function pickDoors(room, doorWidth: number, rng: Random)
	if #room.doorCells == 0 then
		return {}
	end
	local primary = room.doorCells[rng:NextInteger(1, #room.doorCells)]
	local side, primaryCoord = resolveDoor(room, primary[1], primary[2])
	if not side then
		return {}
	end

	local sameSide = {}
	for _, d in room.doorCells do
		local s, coord = resolveDoor(room, d[1], d[2])
		if s == side then
			sameSide[coord] = d
		end
	end

	local half = math.floor((doorWidth - 1) / 2)
	local doors = {}
	for coord = primaryCoord - half, primaryCoord - half + doorWidth - 1 do
		local d = sameSide[coord]
		if d then
			table.insert(doors, { hx = d[1], hy = d[2], side = side })
		end
	end
	return doors
end

-- doorH[y][x] = true  -> horizontal edge between row y and row y+1, column x
-- doorV[x][y] = true  -> vertical edge between column x and x+1, row y
local function buildDoorEdges(rooms, doorWidth: number, rng: Random)
	local doorH, doorV = {}, {}
	for _, room in rooms do
		for _, d in pickDoors(room, doorWidth, rng) do
			if d.side == "N" then
				local y = room.y - 1
				doorH[y] = doorH[y] or {}
				doorH[y][d.hx] = true
			elseif d.side == "S" then
				local y = room.y + room.h - 1
				doorH[y] = doorH[y] or {}
				doorH[y][d.hx] = true
			elseif d.side == "W" then
				local x = room.x - 1
				doorV[x] = doorV[x] or {}
				doorV[x][d.hy] = true
			else -- "E"
				local x = room.x + room.w - 1
				doorV[x] = doorV[x] or {}
				doorV[x][d.hy] = true
			end
		end
	end
	return doorH, doorV
end

-- Marks an arbitrary cell-pair edge as open, independent of room rectangle
-- geometry -- used for RoomFinder.resolvePockets's connecting-hallway edges,
-- which can border a merged (non-rectangular) part of a room.
local function markOpenEdge(doorH, doorV, ax: number, ay: number, bx: number, by: number)
	if ax == bx then
		local y = math.min(ay, by)
		doorH[y] = doorH[y] or {}
		doorH[y][ax] = true
	else
		local x = math.min(ax, bx)
		doorV[x] = doorV[x] or {}
		doorV[x][ay] = true
	end
end

--------------------------------------------------------------------------------
-- Compartments: which room (if any) owns each cell, for wall-edge decisions.
--------------------------------------------------------------------------------

local function buildCellRoom(grid, rooms)
	local cellRoom = table.create(grid.width * grid.height, 0)
	for roomIndex, room in rooms do
		for _, c in room.cells do
			cellRoom[grid:index(c[1], c[2])] = roomIndex
		end
	end
	return cellRoom
end

-- room index (a distinct compartment id) for a room cell, -1 for hallway,
-- nil for void/out of bounds.
local function compartment(grid, cellRoom, x: number, y: number): number?
	if x < 1 or x > grid.width or y < 1 or y > grid.height then
		return nil
	end
	local idx = grid:index(x, y)
	local r = cellRoom[idx]
	if r ~= 0 then
		return r
	end
	if grid.cells[idx] == Grid.HALL then
		return -1
	end
	return nil
end

--------------------------------------------------------------------------------
-- Walls: merge contiguous "wall needed" cells along each lattice line into
-- single parts instead of one per cell-edge.
--------------------------------------------------------------------------------

local function buildHorizontalWalls(grid, cellRoom, doorH, cfg, folder)
	local W, H = grid.width, grid.height
	local cellSize, thickness, height = cfg.cellSize, cfg.wallThickness, cfg.wallHeight
	for y = 0, H do
		local doorRow = doorH[y]
		local runStart = nil
		local function flush(xEnd: number)
			if runStart == nil then
				return
			end
			local minCorner = CellSpace.cellMin(cfg.origin, cellSize, runStart, y + 1)
			local maxCorner = CellSpace.cellMin(cfg.origin, cellSize, xEnd + 1, y + 1)
			local size = Vector3.new(maxCorner.X - minCorner.X + thickness, height, thickness)
			local pos = Vector3.new((minCorner.X + maxCorner.X) / 2, cfg.origin.Y + height / 2, minCorner.Z)
			makePart(size, pos, cfg.wallColor, Enum.Material.SmoothPlastic, `Wall_H_{runStart}_{y}`, folder)
			runStart = nil
		end
		for x = 1, W do
			local a = compartment(grid, cellRoom, x, y)
			local b = compartment(grid, cellRoom, x, y + 1)
			local needsWall = a ~= b and not (doorRow and doorRow[x])
			if needsWall then
				runStart = runStart or x
			else
				flush(x - 1)
			end
		end
		flush(W)
	end
end

local function buildVerticalWalls(grid, cellRoom, doorV, cfg, folder)
	local W, H = grid.width, grid.height
	local cellSize, thickness, height = cfg.cellSize, cfg.wallThickness, cfg.wallHeight
	for x = 0, W do
		local doorCol = doorV[x]
		local runStart = nil
		local function flush(yEnd: number)
			if runStart == nil then
				return
			end
			local minCorner = CellSpace.cellMin(cfg.origin, cellSize, x + 1, runStart)
			local maxCorner = CellSpace.cellMin(cfg.origin, cellSize, x + 1, yEnd + 1)
			local size = Vector3.new(thickness, height, maxCorner.Z - minCorner.Z + thickness)
			local pos = Vector3.new(minCorner.X, cfg.origin.Y + height / 2, (minCorner.Z + maxCorner.Z) / 2)
			makePart(size, pos, cfg.wallColor, Enum.Material.SmoothPlastic, `Wall_V_{x}_{runStart}`, folder)
			runStart = nil
		end
		for y = 1, H do
			local a = compartment(grid, cellRoom, x, y)
			local b = compartment(grid, cellRoom, x + 1, y)
			local needsWall = a ~= b and not (doorCol and doorCol[y])
			if needsWall then
				runStart = runStart or y
			else
				flush(y - 1)
			end
		end
		flush(H)
	end
end

--------------------------------------------------------------------------------
-- Floors: greedy largest-rectangle-first cover over a predicate, instead of
-- one thin part per row. Rooms can be irregular once RoomFinder.resolvePockets
-- has merged leftover pockets into them, so this works from the same
-- predicate-over-the-grid approach for both rooms (cellRoom ~= 0) and hallway
-- (grid.cells == HALL) rather than assuming a room is still one rectangle.
--------------------------------------------------------------------------------

-- Greedily covers every cell where predicate(x,y) is true with the largest
-- axis-aligned rectangles available, repeatedly, until none remain. Same
-- anchored-maximal-rectangle scan as RoomFinder.findRooms's packing loop, just
-- uncapped (no min/max) since the goal here is covering everything, not
-- filtering to room-sized pieces.
local function greedyRectangleCover(W: number, H: number, predicate: (number, number) -> boolean): { { number } }
	local free = table.create(W * H, false)
	for y = 1, H do
		for x = 1, W do
			if predicate(x, y) then
				free[(y - 1) * W + x] = true
			end
		end
	end
	local function isFree(x, y)
		return x >= 1 and x <= W and y >= 1 and y <= H and free[(y - 1) * W + x]
	end

	local rects = {}
	while true do
		local best = { area = 0, x = 0, y = 0, w = 0, h = 0 }
		for y = 1, H do
			for x = 1, W do
				if isFree(x, y) then
					local minW = W
					for h = 1, H - y + 1 do
						local ry = y + h - 1
						local w = 0
						while w < minW and isFree(x + w, ry) do
							w += 1
						end
						if w == 0 then
							break
						end
						minW = math.min(minW, w)
						local area = minW * h
						if area > best.area then
							best.area = area
							best.x, best.y, best.w, best.h = x, y, minW, h
						end
					end
				end
			end
		end
		if best.area == 0 then
			break
		end
		for cy = best.y, best.y + best.h - 1 do
			for cx = best.x, best.x + best.w - 1 do
				free[(cy - 1) * W + cx] = false
			end
		end
		table.insert(rects, { best.x, best.y, best.w, best.h })
	end
	return rects
end

local function buildFloorRects(cfg, rects, color: Color3, material: Enum.Material, namePrefix: string, folder)
	for _, r in rects do
		local x, y, w, h = r[1], r[2], r[3], r[4]
		local minCorner = CellSpace.cellMin(cfg.origin, cfg.cellSize, x, y)
		local maxCorner = CellSpace.cellMin(cfg.origin, cfg.cellSize, x + w, y + h)
		local size = Vector3.new(maxCorner.X - minCorner.X, cfg.floorThickness, maxCorner.Z - minCorner.Z)
		local pos = Vector3.new(
			(minCorner.X + maxCorner.X) / 2,
			cfg.origin.Y - cfg.floorThickness / 2,
			(minCorner.Z + maxCorner.Z) / 2
		)
		makePart(size, pos, color, material, `{namePrefix}_{x}_{y}`, folder)
	end
end

--------------------------------------------------------------------------------
-- Roof: one ceiling slab cover over every floor cell (room or hallway alike --
-- unlike floors, the roof doesn't need a per-compartment material split), sat
-- on top of the walls. Same greedy rectangle cover as the floors.
--------------------------------------------------------------------------------

local function buildCeiling(grid, cellRoom, cfg, folder)
	local rects = greedyRectangleCover(grid.width, grid.height, function(x, y)
		return cellRoom[grid:index(x, y)] ~= 0 or grid:get(x, y) == Grid.HALL
	end)
	local ceilingY = cfg.origin.Y + cfg.wallHeight
	for _, r in rects do
		local x, y, w, h = r[1], r[2], r[3], r[4]
		local minCorner = CellSpace.cellMin(cfg.origin, cfg.cellSize, x, y)
		local maxCorner = CellSpace.cellMin(cfg.origin, cfg.cellSize, x + w, y + h)
		local size = Vector3.new(maxCorner.X - minCorner.X, cfg.ceilingThickness, maxCorner.Z - minCorner.Z)
		local pos = Vector3.new(
			(minCorner.X + maxCorner.X) / 2,
			ceilingY + cfg.ceilingThickness / 2,
			(minCorner.Z + maxCorner.Z) / 2
		)
		makePart(size, pos, cfg.ceilingColor, Enum.Material.SmoothPlastic, `Ceiling_{x}_{y}`, folder)
	end
end

--------------------------------------------------------------------------------
-- Ceiling lights: placed per-room and per hallway-rect (the same greedy-cover
-- pieces the hallway floor already uses) instead of a uniform grid over the
-- whole map. A uniform grid doesn't know where room/hallway boundaries are, so
-- it can land a light right against a wall or miss a small room's center
-- entirely. Per-piece placement guarantees a light is centered in anything too
-- small to need more than one, and evenly spread (still centered within its
-- own even share of the space) once a piece is big enough for several.
--
-- Roofing the map blocks the outdoor sun from reaching indoor space, so these
-- need real range/brightness to actually light rooms -- not just decorative
-- fixtures.
--
-- Room lights are placed against each room's ORIGINAL packed rectangle
-- (room.w/room.h), not any pocket RoomFinder.resolvePockets merged into it --
-- a merged extension relies on spillover from the main room's lights (or a
-- hallway light nearby) rather than getting a dedicated fixture of its own.
--------------------------------------------------------------------------------

-- Evenly spaced, centered offsets along one axis of length `size` (in cells):
-- 1 offset dead-center if `size` doesn't clear `spacing`, otherwise as many as
-- fit at roughly `spacing` apart, each centered within its own even share.
local function axisLightOffsets(size: number, spacing: number): { number }
	local n = math.max(1, math.floor(size / spacing + 0.5))
	local offsets = table.create(n)
	for i = 1, n do
		offsets[i] = (i - 0.5) * size / n
	end
	return offsets
end

local function placeLight(cfg, worldX: number, worldZ: number, ceilingY: number, name: string, folder)
	local fixture = Instance.new("Part")
	fixture.Name = name
	fixture.Anchored = true
	fixture.CanCollide = false
	fixture.CanQuery = false
	fixture.CastShadow = false
	fixture.Material = Enum.Material.Neon
	fixture.Color = cfg.lightColor
	fixture.Size = Vector3.new(cfg.lightFixtureSize, 0.4, cfg.lightFixtureSize)
	fixture.Position = Vector3.new(worldX, ceilingY - 0.2, worldZ)
	fixture.Parent = folder

	local light = Instance.new("PointLight")
	light.Color = cfg.lightColor
	light.Range = cfg.lightRange
	light.Brightness = cfg.lightBrightness
	light.Shadows = cfg.lightShadows
	light.Parent = fixture
end

-- Places a centered/evenly-spread light grid over one axis-aligned cell
-- rectangle (a room's original packed rectangle, or a hallway floor piece).
local function lightRect(cfg, x: number, y: number, w: number, h: number, ceilingY: number, namePrefix: string, folder)
	for _, ox in axisLightOffsets(w, cfg.lightSpacing) do
		for _, oy in axisLightOffsets(h, cfg.lightSpacing) do
			local worldX = cfg.origin.X + (x - 1 + ox) * cfg.cellSize
			local worldZ = cfg.origin.Z + (y - 1 + oy) * cfg.cellSize
			placeLight(cfg, worldX, worldZ, ceilingY, `{namePrefix}_{x}_{y}_{ox}_{oy}`, folder)
		end
	end
end

local function buildCeilingLights(rooms, hallRects, cfg, folder)
	local ceilingY = cfg.origin.Y + cfg.wallHeight
	for _, room in rooms do
		lightRect(cfg, room.x, room.y, room.w, room.h, ceilingY, "Light_Room", folder)
	end
	for _, r in hallRects do
		lightRect(cfg, r[1], r[2], r[3], r[4], ceilingY, "Light_Hall", folder)
	end
end

--------------------------------------------------------------------------------

-- Builds real, collidable geometry from generated grid + room data under a
-- fresh workspace.MapGenBuild folder (any previous one is replaced).
function Builder.build(grid, rooms, config: BuildConfig?): Folder
	local cfg = withDefaults(config)
	local rng = Random.new(cfg.seed or os.clock() * 1e6)

	local existing = workspace:FindFirstChild("MapGenBuild")
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "MapGenBuild"

	local floors = Instance.new("Folder")
	floors.Name = "Floors"
	floors.Parent = folder
	local walls = Instance.new("Folder")
	walls.Name = "Walls"
	walls.Parent = folder
	local ceiling = Instance.new("Folder")
	ceiling.Name = "Ceiling"
	ceiling.Parent = folder
	local lights = Instance.new("Folder")
	lights.Name = "Lights"
	lights.Parent = folder

	local cellRoom = buildCellRoom(grid, rooms)
	local roomRects = greedyRectangleCover(grid.width, grid.height, function(x, y)
		return cellRoom[grid:index(x, y)] ~= 0
	end)
	buildFloorRects(cfg, roomRects, cfg.roomFloorColor, Enum.Material.WoodPlanks, "Floor_Room", floors)

	local hallRects = greedyRectangleCover(grid.width, grid.height, function(x, y)
		return grid:get(x, y) == Grid.HALL
	end)
	buildFloorRects(cfg, hallRects, cfg.hallCarpetColor, Enum.Material.Fabric, "Floor_Hall", floors)

	local doorH, doorV = buildDoorEdges(rooms, cfg.doorWidth, rng)
	for _, e in cfg.openEdges or {} do
		markOpenEdge(doorH, doorV, e[1], e[2], e[3], e[4])
	end
	buildHorizontalWalls(grid, cellRoom, doorH, cfg, walls)
	buildVerticalWalls(grid, cellRoom, doorV, cfg, walls)

	buildCeiling(grid, cellRoom, cfg, ceiling)
	buildCeilingLights(rooms, hallRects, cfg, lights)

	folder.Parent = workspace
	return folder
end

return Builder
