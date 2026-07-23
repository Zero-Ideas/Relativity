--!optimize 2
--[[
	MapGen/HallwayGenerator.luau
	Carves the hallway network into a Grid using a coarse lattice + a randomized
	spanning tree (plus a few extra "loop" edges).

	The model
	---------
	Overlay a lattice of nodes spaced `spacing` cells apart (each interval jittered
	by +/-spacingJitter so blocks vary in size instead of all being identical --
	see buildAxis). Corridors are the straight, `hallWidth`-cell-wide runs between
	orthogonally adjacent nodes ("edges"). A randomized Prim's algorithm grows a
	spanning tree over the nodes, so every carved corridor connects back to the
	rest — the whole hallway network is one connected component (important:
	every hallway must be reachable in a real map).
	After the tree, leftover edges are carved with probability `loopChance` to add
	loops, because pure trees feel like a maze and hotels have loops.

	The big cell blocks *between* the corridor lines are left EMPTY — those are the
	pockets the RoomFinder later fills with rooms.

	Steppable
	---------
	Generation is driven one edge at a time via :step(). Each call carves at most
	one corridor segment and records the affected cells in `self.lastCarved`, so a
	visualizer can animate the network growing. :step() returns false when done.

	Usage:
		local gen = HallwayGenerator.new(grid, { spacing = 5, loopChance = 0.12 }, rng)
		while gen:step() do
			-- gen.lastCarved : { {x,y}, ... } cells carved this step
			-- gen.frontier   : current Prim frontier node cells (for markers)
		end
]]

local Grid = require(script.Parent.Grid)

local HallwayGenerator = {}
HallwayGenerator.__index = HallwayGenerator

export type Config = {
	spacing: number?, -- cells between parallel corridors (lattice pitch)
	-- corridor width in cells (must be < spacing). Without spacingJitter, a
	-- single un-merged block is exactly (spacing - hallWidth) cells square in
	-- BOTH directions -- that's the size RoomFinder's minWidth/maxWidth/
	-- minLength/maxLength bound against. Since only one axis stretches when a
	-- loop edge merges two blocks (the other stays walled in), most rooms would
	-- end up "(spacing-hallWidth) x something" -- e.g. spacing=6,hallWidth=2
	-- gives a fixed 4-cell edge on ~most rooms.
	hallWidth: number?,
	-- Randomizes each lattice interval by +/-spacingJitter cells (per column and
	-- per row) so un-merged blocks vary in size instead of all being identical.
	-- Defaults to floor(spacing/3). Set 0 for a perfectly uniform grid.
	spacingJitter: number?,
	loopChance: number?, -- probability of carving each non-tree edge
	margin: number?, -- cells of empty border kept clear around the lattice
}

local function tryCarve(grid, x, y, out)
	local v = grid:get(x, y)
	if v ~= nil and v ~= Grid.HALL then
		grid:set(x, y, Grid.HALL)
		table.insert(out, { x, y })
	end
end

-- Carve a straight corridor `width` cells wide between two node cell-coords.
-- Corridors grow toward +X/+Y off their lattice line (perpendicular to travel):
-- a horizontal run widens in Y, a vertical run widens in X. Consistent growth
-- direction keeps parallel corridors and their room gaps uniform.
local function carveSegment(grid, ax, ay, bx, by, width, out)
	local dx = math.sign(bx - ax)
	local dy = math.sign(by - ay)
	local px, py = if dx ~= 0 then 0 else 1, if dx ~= 0 then 1 else 0 -- perpendicular
	local x, y = ax, ay
	while true do
		for w = 0, width - 1 do
			tryCarve(grid, x + px * w, y + py * w, out)
		end
		if x == bx and y == by then
			break
		end
		x += dx
		y += dy
	end
end

-- Fill the width x width junction block at a node so corners stay solid where
-- corridors of different orientations meet.
local function carveNodeBlock(grid, ax, ay, width, out)
	for wy = 0, width - 1 do
		for wx = 0, width - 1 do
			tryCarve(grid, ax + wx, ay + wy, out)
		end
	end
end

-- Build one axis of lattice-line positions from `origin` up to `maxCoord`,
-- jittering each interval by +/-jitter cells (floored at `minStep` so a block
-- never collapses to zero/negative size). The last line is clamped exactly to
-- maxCoord so the far edge always closes with a real corridor instead of
-- trailing into an un-subdivided leftover strip.
local function buildAxis(origin: number, maxCoord: number, spacing: number, jitter: number, minStep: number, rng: Random): { number }
	local positions = { origin }
	local pos = origin
	while pos < maxCoord do
		local step = spacing
		if jitter > 0 then
			step += rng:NextInteger(-jitter, jitter)
		end
		step = math.max(step, minStep)
		pos = math.min(pos + step, maxCoord)
		table.insert(positions, pos)
	end
	return positions
end

function HallwayGenerator.new(grid, config: Config?, rng: Random)
	config = config or {}
	local spacing = config.spacing or 5
	local margin = config.margin or 1

	-- Corridor width must leave at least one empty cell between parallel
	-- corridors, otherwise rooms have nowhere to go.
	local hallWidth = math.clamp(config.hallWidth or 1, 1, spacing - 1)
	local minStep = hallWidth + 1
	local jitter = math.clamp(config.spacingJitter or math.floor(spacing / 3), 0, math.max(spacing - minStep, 0))

	-- Lay out lattice nodes along each axis independently (see buildAxis). Every
	-- row shares the same column positions and vice versa -- still a strict
	-- rectangular grid, just with non-uniform pitch -- so corridors stay straight
	-- and fully aligned while block sizes vary.
	local originX = 1 + margin
	local originY = 1 + margin
	local maxNodeX = grid.width - margin
	local maxNodeY = grid.height - margin
	local nodeXs = buildAxis(originX, maxNodeX, spacing, jitter, minStep, rng)
	local nodeYs = buildAxis(originY, maxNodeY, spacing, jitter, minStep, rng)
	local cols = #nodeXs
	local rows = #nodeYs

	local self = setmetatable({
		grid = grid,
		rng = rng,
		spacing = spacing,
		hallWidth = hallWidth,
		loopChance = config.loopChance or 0.12,
		cols = cols,
		rows = rows,
		nodeXs = nodeXs,
		nodeYs = nodeYs,

		inSet = {}, -- [nodeId] = true once the node joined the tree
		carvedEdges = {}, -- [edgeKey] = true
		frontier = {}, -- Prim frontier: list of {fromId, ni, nj}
		loopQueue = {}, -- non-tree edges discovered during Prim, tried later
		phase = "tree", -- "tree" -> "loops" -> "done"

		lastCarved = {}, -- cells carved on the most recent :step()
		nodeCount = cols * rows,
		joined = 0,
	}, HallwayGenerator)

	-- Seed Prim from a random node near the middle for a centered network.
	local startI = math.clamp(math.floor(cols / 2) + rng:NextInteger(-1, 1), 1, cols)
	local startJ = math.clamp(math.floor(rows / 2) + rng:NextInteger(-1, 1), 1, rows)
	self:_join(startI, startJ)

	return self
end

function HallwayGenerator._nodeId(self, i: number, j: number): number
	return (j - 1) * self.cols + i
end

function HallwayGenerator._nodeCell(self, i: number, j: number): (number, number)
	return self.nodeXs[i], self.nodeYs[j]
end

-- Add node (i,j) to the tree and push its outward edges onto the frontier.
function HallwayGenerator._join(self, i: number, j: number)
	local id = self:_nodeId(i, j)
	if self.inSet[id] then
		return
	end
	self.inSet[id] = true
	self.joined += 1
	local neighbors = { { i + 1, j }, { i - 1, j }, { i, j + 1 }, { i, j - 1 } }
	for _, n in neighbors do
		local ni, nj = n[1], n[2]
		if ni >= 1 and ni <= self.cols and nj >= 1 and nj <= self.rows then
			table.insert(self.frontier, { id, ni, nj })
		end
	end
end

local function edgeKey(a: number, b: number): number
	-- canonical, order-independent key for the undirected edge {a,b}
	if a < b then
		return a * 1e6 + b
	end
	return b * 1e6 + a
end

-- Carve the edge between two nodes given by node indices. Returns true if it
-- actually carved (edge not already carved).
function HallwayGenerator._carveEdge(self, ai, aj, bi, bj): boolean
	local key = edgeKey(self:_nodeId(ai, aj), self:_nodeId(bi, bj))
	if self.carvedEdges[key] then
		return false
	end
	self.carvedEdges[key] = true
	local ax, ay = self:_nodeCell(ai, aj)
	local bx, by = self:_nodeCell(bi, bj)
	table.clear(self.lastCarved)
	carveSegment(self.grid, ax, ay, bx, by, self.hallWidth, self.lastCarved)
	-- keep both junctions solid at this corridor width
	carveNodeBlock(self.grid, ax, ay, self.hallWidth, self.lastCarved)
	carveNodeBlock(self.grid, bx, by, self.hallWidth, self.lastCarved)
	return true
end

-- Advance generation by one carved corridor. Returns false when finished.
function HallwayGenerator.step(self): boolean
	if self.phase == "tree" then
		-- Pop random frontier edges until we find one reaching a new node.
		while #self.frontier > 0 do
			local idx = self.rng:NextInteger(1, #self.frontier)
			local edge = self.frontier[idx]
			-- swap-remove for O(1)
			self.frontier[idx] = self.frontier[#self.frontier]
			self.frontier[#self.frontier] = nil

			local fromId, ni, nj = edge[1], edge[2], edge[3]
			local toId = self:_nodeId(ni, nj)
			-- recover from-node indices
			local fi = ((fromId - 1) % self.cols) + 1
			local fj = math.floor((fromId - 1) / self.cols) + 1

			if self.inSet[toId] then
				-- both endpoints already in tree -> candidate loop edge for later
				table.insert(self.loopQueue, { fi, fj, ni, nj })
			else
				self:_carveEdge(fi, fj, ni, nj)
				self:_join(ni, nj)
				return true
			end
		end
		-- frontier exhausted: tree complete, move to loop phase
		self.phase = "loops"
	end

	if self.phase == "loops" then
		while #self.loopQueue > 0 do
			local edge = table.remove(self.loopQueue) :: any
			local key = edgeKey(self:_nodeId(edge[1], edge[2]), self:_nodeId(edge[3], edge[4]))
			if not self.carvedEdges[key] and self.rng:NextNumber() < self.loopChance then
				self:_carveEdge(edge[1], edge[2], edge[3], edge[4])
				return true
			end
		end
		self.phase = "done"
	end

	return false
end

-- Convenience: run to completion in one call (no animation).
function HallwayGenerator.run(self)
	while self:step() do
	end
end

return HallwayGenerator
