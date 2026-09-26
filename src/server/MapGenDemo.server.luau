--[[
	MapGenDemo.server.luau
	Runs the prop-hunt map generator and animates its build when you press Play.

	Gated behind a Workspace attribute so it doesn't fire during unrelated
	playtests: set Workspace:SetAttribute("RunMapGen", true) (or flip the
	DEFAULT_ON flag below) to enable it.

	Phase 1 shows: hallway network growing, then empty-space detection tinting the
	reachable pockets, then candidate room rectangles popping in. Phase 2 then
	builds real, collidable geometry (walls with door openings, room floors,
	hallway carpet, a roof, and ceiling lights) and hides the debug preview --
	press G client-side to bring the debug preview back and compare it against
	the built map.

	CONFIG below is the single source of truth for a test run — every key it sets
	overrides MapGen.DefaultConfig (src/shared/MapGen/init.luau), so edit values
	HERE, not there, when tweaking a playtest. DefaultConfig only fills in keys
	CONFIG omits.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DEFAULT_ON = true

if not (workspace:GetAttribute("RunMapGen") or DEFAULT_ON) then
	return
end

local MapGen = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapGen"))

local CONFIG = {
	width = 100,
	height = 100,
	cellSize = 16,
	origin = Vector3.new(-250, 1, -250), -- lift the whole map up off the baseplate
	seed = 1, --nil :: number?, -- set a number for a fixed, repeatable layout

	spacing = 6, -- cells between parallel corridors
	hallWidth = 2, -- corridor width in cells (2 * cellSize = 16-stud halls)
	spacingJitter = 2, -- +/- cells per lattice interval, for room size variety
	loopChance = 0.2, -- corridor-grid density; higher = smaller/more numerous rooms

	-- room rectangle bounds, independent per axis (in cells; x cellSize = studs)
	minWidth = 3,
	maxWidth = 10,
	minLength = 3,
	maxLength = 10,

	-- leftover pockets too small for the bounds above: touching one room merges
	-- into it, touching none is culled into the hallway, touching 2+ rooms rolls
	-- this chance to become a connecting hallway segment instead of extending one
	pocketHallwayChance = 0.8,
	-- a room stops accepting pocket merges once it's grown by this fraction of
	-- its original area (e.g. 0.5 = 50% bigger); rejected merges become hallway
	irregularityThreshold = 0.5,
	-- cells wide per door opened between a forced/connecting hallway pocket and
	-- each room it touches -- NOT the whole shared boundary
	pocketDoorWidth = 2,

	-- rooms packed directly edge-to-edge (no hallway between them) normally get
	-- a plain wall; this is the chance each such pair instead gets its own door
	roomLinkChance = 0.6,
	roomLinkDoorWidth = 2,
}

local BUILD_CONFIG = {
	wallThickness = 1, -- studs
	wallHeight = 20, -- studs
	doorWidth = 1, -- cells wide per door opening

	ceilingThickness = 1, -- studs

	-- Ceiling lights: with cellSize=16, spacing 4 cells = 64 studs between
	-- fixtures. lightRange must clear half that (32 studs) with real margin or
	-- the roof (which blocks the outdoor sun) leaves dark gaps between lights --
	-- Ambient is (0,0,0) in this game, so these are the only indoor light source.
	lightSpacing = 4, -- cells
	lightRange = 55, -- studs
	lightBrightness = 0.1,
}

-- Debug-overlay toggle: the client fires this when G is pressed; the server
-- owns the Visualizer instance (see MapGenToggleDebug.client.luau).
local toggleDebugEvent = ReplicatedStorage:FindFirstChild("MapGenToggleDebug")
if not toggleDebugEvent then
	toggleDebugEvent = Instance.new("RemoteEvent")
	toggleDebugEvent.Name = "MapGenToggleDebug"
	toggleDebugEvent.Parent = ReplicatedStorage
end

-- was expecting game:GetService("ServerScriptService")

task.spawn(function()
	local result = MapGen.visualizeAnimated(CONFIG)

	print(string.format(
		"[MapGen] hallways done: %d hallway cells, %d regions, %d candidate rooms",
		result.grid:count(MapGen.Grid.HALL),
		#result.regions,
		#result.rooms
	))

	MapGen.Builder.build(result.grid, result.rooms, {
		cellSize = CONFIG.cellSize,
		origin = CONFIG.origin,
		wallThickness = BUILD_CONFIG.wallThickness,
		wallHeight = BUILD_CONFIG.wallHeight,
		doorWidth = BUILD_CONFIG.doorWidth,
		ceilingThickness = BUILD_CONFIG.ceilingThickness,
		lightSpacing = BUILD_CONFIG.lightSpacing,
		lightRange = BUILD_CONFIG.lightRange,
		lightBrightness = BUILD_CONFIG.lightBrightness,
		seed = CONFIG.seed,
		openEdges = result.openEdges,
	})

	-- hide the debug preview now that real geometry exists (avoids overlapping
	-- the same floor space); G brings it back for comparison
	result.visualizer:setEnabled(false)
	toggleDebugEvent.OnServerEvent:Connect(function()
		result.visualizer:toggle()
	end)

	print("[MapGen] build complete — press G to toggle the debug overlay")
end)
