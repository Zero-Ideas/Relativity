--!optimize 2
--[[
	MapGen (init.luau)
	Procedural map generator for a prop-hunt house/hotel theme.

	Phase 1 (this module): hallway network + empty-space detection so we know
	where rooms can be placed. Rooms are currently only *detected & visualized*
	(as candidate rectangles); actually building furnished rooms comes later.

	Pipeline:
	  1. HallwayGenerator carves a connected corridor network on a coarse lattice.
	  2. RoomFinder flood-fills the leftover space into regions and greedily packs
	     room-sized rectangles into them, tagging each with adjacent hallway cells
	     (future doors).

	Two entry points:
	  MapGen.generate(config)          -> headless: returns { grid, regions, rooms }
	  MapGen.visualizeAnimated(config) -> builds it live under a workspace folder,
	                                      animating each stage. Call from task.spawn
	                                      (it yields). Returns the same result table.

	See MapGen.DefaultConfig for tunables.
]]

local Grid = require(script.Grid)
local HallwayGenerator = require(script.HallwayGenerator)
local RoomFinder = require(script.RoomFinder)
local Visualizer = require(script.Visualizer)
local Builder = require(script.Builder)
local CellSpace = require(script.CellSpace)

local MapGen = {}
MapGen.Grid = Grid
MapGen.HallwayGenerator = HallwayGenerator
MapGen.RoomFinder = RoomFinder
MapGen.Visualizer = Visualizer
MapGen.Builder = Builder
MapGen.CellSpace = CellSpace

export type Config = {
	width: number?, -- grid size in cells
	height: number?,
	cellSize: number?, -- studs per cell
	origin: Vector3?, -- world position of the grid's (0,0) corner
	seed: number?, -- deterministic when set

	-- hallway lattice
	spacing: number?, -- cells between parallel corridors
	hallWidth: number?, -- corridor width in cells (clamped to < spacing)
	spacingJitter: number?, -- randomizes each lattice interval by +/- this many cells
	loopChance: number?, -- chance to carve each non-tree (loop) edge
	margin: number?, -- empty border cells around the lattice

	-- rooms. Note: an un-merged lattice block is exactly (spacing - hallWidth)
	-- cells square, so most rooms will have one edge pinned to that value unless
	-- these bounds sit well clear of it -- see the hallWidth comment above.
	minWidth: number?, -- min room edge along X, in cells
	maxWidth: number?, -- max room edge along X, in cells
	minLength: number?, -- min room edge along Y (Z in world), in cells
	maxLength: number?, -- max room edge along Y (Z in world), in cells

	-- leftover pockets findRooms couldn't claim (too small for min bounds):
	-- touching exactly one room merges into it; touching none is culled into
	-- the hallway; touching 2+ rooms rolls this chance to become a connecting
	-- hallway segment between them instead of extending one at random.
	pocketHallwayChance: number?,
	-- a room stops accepting further pocket merges once its irregularity rating
	-- (merged area / original area) reaches this; rejected merges become
	-- hallway instead. See RoomFinder.resolvePockets.
	irregularityThreshold: number?,
	-- cells wide per door opened between a forced/connecting hallway pocket and
	-- each room it touches (NOT the whole shared boundary).
	pocketDoorWidth: number?,

	-- rooms findRooms packed directly edge-to-edge (no hallway between them)
	-- normally get a plain wall; this is the chance each such pair instead gets
	-- its own connecting door, widened up to roomLinkDoorWidth cells.
	roomLinkChance: number?,
	roomLinkDoorWidth: number?,

	-- animation pacing (visualizeAnimated only)
	edgesPerFrame: number?, -- corridors carved between waits
	stepWait: number?, -- seconds waited between animation frames
}

MapGen.DefaultConfig = {
	width = 50,
	height = 50,
	cellSize = 8,
	origin = Vector3.new(250, 0, 250),
	seed = nil,

	spacing = 6,
	hallWidth = 2, -- corridor width in cells
	spacingJitter = 2, -- +/- cells per lattice interval; breaks the "every room has a (spacing-hallWidth) edge" pattern
	-- High loop density: a spanning tree alone leaves corridors too sparse to
	-- enclose rooms (all pockets merge into one blob). Carving most lattice edges
	-- gives a double-loaded-corridor "hotel grid" where each block is a room off a
	-- hallway; leaving some edges out merges neighbours into larger rooms for variety.
	loopChance = 0.7,
	margin = 1,

	minWidth = 3,
	maxWidth = 7,
	minLength = 3,
	maxLength = 7,
	pocketHallwayChance = 0.4,
	irregularityThreshold = 0.5,
	pocketDoorWidth = 2,
	roomLinkChance = 0.15,
	roomLinkDoorWidth = 2,

	edgesPerFrame = 10,
	stepWait = 0.01,
}

local function withDefaults(config: Config?)
	local merged = {}
	for k, v in MapGen.DefaultConfig do
		merged[k] = v
	end
	if config then
		for k, v in config do
			merged[k] = v
		end
	end
	return merged
end

-- Headless generation: no parts, just data.
function MapGen.generate(config: Config?)
	local cfg = withDefaults(config)
	local rng = Random.new(cfg.seed or os.clock() * 1e6)

	local grid = Grid.new(cfg.width, cfg.height)

	local gen = HallwayGenerator.new(grid, {
		spacing = cfg.spacing,
		hallWidth = cfg.hallWidth,
		spacingJitter = cfg.spacingJitter,
		loopChance = cfg.loopChance,
		margin = cfg.margin,
	}, rng)
	gen:run()

	local regions = RoomFinder.detectRegions(grid)
	local rooms = RoomFinder.findRooms(grid, {
		minWidth = cfg.minWidth,
		maxWidth = cfg.maxWidth,
		minLength = cfg.minLength,
		maxLength = cfg.maxLength,
	})
	local openEdges = RoomFinder.resolvePockets(grid, rooms, rng, {
		hallwayChance = cfg.pocketHallwayChance,
		irregularityThreshold = cfg.irregularityThreshold,
		doorWidth = cfg.pocketDoorWidth,
	})
	for _, e in RoomFinder.connectAdjacentRooms(grid, rooms, rng, {
		chance = cfg.roomLinkChance,
		doorWidth = cfg.roomLinkDoorWidth,
	}) do
		table.insert(openEdges, e)
	end

	return {
		grid = grid,
		regions = regions,
		rooms = rooms,
		openEdges = openEdges,
		config = cfg,
	}
end

-- Animated build under a workspace folder. Yields; run inside task.spawn.
function MapGen.visualizeAnimated(config: Config?)
	local cfg = withDefaults(config)
	local rng = Random.new(cfg.seed or os.clock() * 1e6)

	Visualizer.clearWorkspace()
	local grid = Grid.new(cfg.width, cfg.height)
	local vis = Visualizer.new(grid, { cellSize = cfg.cellSize, origin = cfg.origin })
	vis:drawBase()
	task.wait(0.15)

	-- Stage 1: carve hallways, painting corridors as they grow.
	local gen = HallwayGenerator.new(grid, {
		spacing = cfg.spacing,
		hallWidth = cfg.hallWidth,
		spacingJitter = cfg.spacingJitter,
		loopChance = cfg.loopChance,
		margin = cfg.margin,
	}, rng)

	local sinceWait = 0
	while gen:step() do
		vis:paintCells(gen.lastCarved)
		sinceWait += 1
		if sinceWait >= cfg.edgesPerFrame then
			sinceWait = 0
			task.wait(cfg.stepWait)
		end
	end
	task.wait(0.4)

	-- Stage 2a: detect + tint connected empty regions (only reachable ones).
	local regions = RoomFinder.detectRegions(grid)
	local colorIndex = 0
	for _, region in regions do
		if region.touchesHall then
			colorIndex += 1
			vis:highlightRegion(region, vis:paletteColor(colorIndex))
			task.wait(cfg.stepWait * 2)
		end
	end
	task.wait(0.4)

	-- Stage 2b: pack + pop candidate room rectangles.
	local rooms = RoomFinder.findRooms(grid, {
		minWidth = cfg.minWidth,
		maxWidth = cfg.maxWidth,
		minLength = cfg.minLength,
		maxLength = cfg.maxLength,
	})
	for i, room in rooms do
		vis:addRoom(room, vis:paletteColor(i), `{room.w}x{room.h}`)
		task.wait(cfg.stepWait * 3)
	end

	-- Stage 2c: resolve leftover pockets (merge/cull/connect), then roll doors
	-- between rooms packed directly edge-to-edge -- not animated, happens
	-- instantly like Builder.build does.
	local openEdges = RoomFinder.resolvePockets(grid, rooms, rng, {
		hallwayChance = cfg.pocketHallwayChance,
		irregularityThreshold = cfg.irregularityThreshold,
		doorWidth = cfg.pocketDoorWidth,
	})
	for _, e in RoomFinder.connectAdjacentRooms(grid, rooms, rng, {
		chance = cfg.roomLinkChance,
		doorWidth = cfg.roomLinkDoorWidth,
	}) do
		table.insert(openEdges, e)
	end

	return {
		grid = grid,
		regions = regions,
		rooms = rooms,
		openEdges = openEdges,
		config = cfg,
		visualizer = vis,
	}
end

return MapGen
