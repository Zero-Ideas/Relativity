--!optimize 2
--[[
	MapGen/RoomFinder.luau
	Empty-space detection. After the hallways are carved, this figures out where
	rooms can go.

	Three stages:
	  1. detectRegions(grid) — 4-connected flood fill over EMPTY cells, grouping
	     the leftover space into distinct pockets. Each region records its bounding
	     box and whether it borders a hallway (a region with no hall neighbour is
	     unreachable and shouldn't get a room / door).

	  2. findRooms(grid, config) — greedy rectangle packing. Repeatedly finds the
	     largest axis-aligned rectangle of EMPTY cells within [minWidth,maxWidth] x
	     [minLength,maxLength] and reserves it, so the scan always makes progress.
	     A rectangle is only published as a Room if it borders at least one hallway
	     cell (a sealed rectangle with zero doorCells would be an unreachable room —
	     that floor space is left reserved-but-unused instead). This guarantees
	     every returned Room has >=1 doorCell and is reachable from the (fully
	     connected) hallway network.

	  3. resolvePockets(grid, rooms, rng, config) — findRooms always leaves some
	     EMPTY cells unclaimed (pockets too small to satisfy minWidth/minLength).
	     This flood-fills each leftover pocket and resolves it by what it borders:
	       touches exactly one room  -> merged into that room (extra floor space),
	                                     if the room isn't past its irregularity cap
	       touches two+ rooms        -> a chance to become a connecting hallway
	                                     segment (doorWidth-cell opening to every
	                                     room it touches, NOT the whole shared
	                                     boundary), otherwise merged into one
	                                     eligible room at random
	       touches no room, or every touching room is past its irregularity cap
	                                  -> becomes plain hallway (still gets a
	                                     doorWidth-cell opening to any rooms it
	                                     touches, so it's never a sealed dead end
	                                     even when it can't merge)
	     Each merge grows the room's `irregularity` rating by the merged pocket's
	     size relative to the room's original area; once a room's rating reaches
	     `irregularityThreshold` it stops accepting further merges (it can still
	     gain connecting-hallway doorways, which don't change its shape). This is
	     step one of a planned irregularity system -- eventually a room past the
	     cap might get something fancier (e.g. a portal to another irregular room)
	     instead of just being cut off from merges.
	     Rooms merge irregular pockets by simply growing their `cells` list past
	     the original rectangle (x/y/w/h stays the original packed rectangle, used
	     only for the primary door's side geometry). Returns a list of edges that
	     must stay open regardless of the normal one-door-per-room rule, for the
	     "connecting hallway" and "forced hallway" cases.

	  4. connectAdjacentRooms(grid, rooms, rng, config) — findRooms can pack two
	     rooms edge-to-edge with no hallway between them (same for pockets that
	     resolvePockets merges into one room but leave another room bordering the
	     result), which normally get a plain solid wall between them. This finds
	     every such directly-touching room pair and rolls `chance` to punch a
	     connecting door between them, widened up to `doorWidth` cells along their
	     shared boundary. Returns edges in the same {ax,ay,bx,by} shape as
	     resolvePockets, so the two lists can just be concatenated before handing
	     them to Builder.

	Everything works in cell space; the caller maps cells to world studs.
]]

local Grid = require(script.Parent.Grid)

local RoomFinder = {}

export type Region = {
	cells: { { number } },
	minX: number,
	maxX: number,
	minY: number,
	maxY: number,
	touchesHall: boolean,
}

export type Room = {
	x: number, -- min corner of the original packed rectangle (used for door geometry)
	y: number,
	w: number, -- width/height of the original packed rectangle, in cells
	h: number,
	cells: { { number } }, -- every cell this room owns: the rectangle plus any merged pockets
	doorCells: { { number } }, -- hallway cells adjacent to this room's original rectangle border
	irregularity: number, -- cumulative merged-pocket size / original area; see resolvePockets
}

export type RoomConfig = {
	minWidth: number?, -- min room edge along X, in cells
	maxWidth: number?, -- max room edge along X, in cells
	minLength: number?, -- min room edge along Y (Z in world), in cells
	maxLength: number?, -- max room edge along Y (Z in world), in cells
}

export type PocketConfig = {
	-- probability a pocket touching 2+ rooms becomes a connecting hallway
	-- segment instead of extending one of the rooms it touches
	hallwayChance: number?,
	-- a room stops accepting pocket merges once its irregularity rating (see
	-- resolvePockets) reaches this. Merges rejected this way become hallway
	-- instead, still opened to the room they couldn't merge into.
	irregularityThreshold: number?,
	-- cells wide per door opened between a forced/connecting hallway pocket and
	-- each room it touches -- NOT the whole shared boundary (a large pocket
	-- could otherwise blow out an entire wall run).
	doorWidth: number?,
}

export type RoomLinkConfig = {
	chance: number?, -- probability each directly-adjacent room pair gets a connecting door
	doorWidth: number?, -- cells wide per connecting door
}

local NEIGHBORS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

--------------------------------------------------------------------------------
-- Stage 1: connected empty regions
--------------------------------------------------------------------------------

function RoomFinder.detectRegions(grid): { Region }
	local visited = {} -- [index] = true
	local regions = {}

	for sy = 1, grid.height do
		for sx = 1, grid.width do
			local startIdx = grid:index(sx, sy)
			if not visited[startIdx] and grid.cells[startIdx] == Grid.EMPTY then
				-- BFS this pocket
				local cells = {}
				local minX, maxX, minY, maxY = sx, sx, sy, sy
				local touchesHall = false
				local stack = { { sx, sy } }
				visited[startIdx] = true
				while #stack > 0 do
					local c = table.remove(stack) :: any
					local cx, cy = c[1], c[2]
					table.insert(cells, c)
					minX, maxX = math.min(minX, cx), math.max(maxX, cx)
					minY, maxY = math.min(minY, cy), math.max(maxY, cy)
					for _, d in NEIGHBORS do
						local nx, ny = cx + d[1], cy + d[2]
						local v = grid:get(nx, ny)
						if v == Grid.HALL then
							touchesHall = true
						elseif v == Grid.EMPTY then
							local ni = grid:index(nx, ny)
							if not visited[ni] then
								visited[ni] = true
								table.insert(stack, { nx, ny })
							end
						end
					end
				end
				table.insert(regions, {
					cells = cells,
					minX = minX,
					maxX = maxX,
					minY = minY,
					maxY = maxY,
					touchesHall = touchesHall,
				})
			end
		end
	end

	return regions
end

--------------------------------------------------------------------------------
-- Stage 2: greedy room-rectangle packing
--------------------------------------------------------------------------------

-- Hallway cells orthogonally adjacent to the rectangle border (door candidates).
local function collectDoors(grid, x, y, w, h): { { number } }
	local doors = {}
	for cx = x, x + w - 1 do
		if grid:get(cx, y - 1) == Grid.HALL then
			table.insert(doors, { cx, y - 1 })
		end
		if grid:get(cx, y + h) == Grid.HALL then
			table.insert(doors, { cx, y + h })
		end
	end
	for cy = y, y + h - 1 do
		if grid:get(x - 1, cy) == Grid.HALL then
			table.insert(doors, { x - 1, cy })
		end
		if grid:get(x + w, cy) == Grid.HALL then
			table.insert(doors, { x + w, cy })
		end
	end
	return doors
end

function RoomFinder.findRooms(grid, config: RoomConfig?): { Room }
	config = config or {}
	local minWidth = config.minWidth or 2
	local maxWidth = config.maxWidth or 6
	local minLength = config.minLength or 2
	local maxLength = config.maxLength or 6

	-- Working "is this cell still free for a room" matrix.
	local W, H = grid.width, grid.height
	local free = table.create(W * H, false)
	for i = 1, W * H do
		free[i] = grid.cells[i] == Grid.EMPTY
	end
	local function isFree(x, y)
		return x >= 1 and x <= W and y >= 1 and y <= H and free[(y - 1) * W + x]
	end

	local rooms = {}

	while true do
		-- Find the largest rectangle within [minWidth,maxWidth] x [minLength,maxLength]
		-- of free cells.
		local best = { area = 0, x = 0, y = 0, w = 0, h = 0 }
		for y = 1, H do
			for x = 1, W do
				if isFree(x, y) then
					-- Grow a rectangle anchored at (x,y). Track the running min width
					-- as height increases (classic anchored maximal-rectangle scan).
					local minW = maxWidth
					for h = 1, maxLength do
						local ry = y + h - 1
						if ry > H then
							break
						end
						-- width of free run on row ry starting at x, capped
						local w = 0
						while w < minW and isFree(x + w, ry) do
							w += 1
						end
						if w == 0 then
							break
						end
						minW = math.min(minW, w)
						if minW >= minWidth and h >= minLength then
							local area = minW * h
							if area > best.area then
								best.area = area
								best.x, best.y, best.w, best.h = x, y, minW, h
							end
						end
					end
				end
			end
		end

		if best.area == 0 then
			break -- nothing room-sized left
		end

		-- Reserve the rectangle unconditionally so the scan always makes progress,
		-- even if it turns out to have no door (see doc comment above).
		for cy = best.y, best.y + best.h - 1 do
			for cx = best.x, best.x + best.w - 1 do
				free[(cy - 1) * W + cx] = false
			end
		end

		local doorCells = collectDoors(grid, best.x, best.y, best.w, best.h)
		if #doorCells > 0 then
			local cells = {}
			for cy = best.y, best.y + best.h - 1 do
				for cx = best.x, best.x + best.w - 1 do
					table.insert(cells, { cx, cy })
				end
			end
			table.insert(rooms, {
				x = best.x,
				y = best.y,
				w = best.w,
				h = best.h,
				cells = cells,
				doorCells = doorCells,
				irregularity = 0,
			})
		end
	end

	return rooms
end

--------------------------------------------------------------------------------
-- Stage 3: resolve leftover pockets findRooms couldn't claim
--------------------------------------------------------------------------------

-- Returns a list of {ax, ay, bx, by} cell-pair edges that must stay open (never
-- walled), for pockets that became a connecting hallway between rooms.
function RoomFinder.resolvePockets(grid, rooms, rng: Random, config: PocketConfig?): { { number } }
	config = config or {}
	local hallwayChance = config.hallwayChance or 0.4
	local irregularityThreshold = config.irregularityThreshold or 0.5
	local doorWidth = config.doorWidth or 2

	local W, H = grid.width, grid.height

	-- Which room (if any) currently owns each cell. Updated as pockets merge in,
	-- so a later pocket adjacent to an earlier merge is correctly seen as
	-- touching that room too.
	local owner = table.create(W * H, 0)
	for roomIndex, room in rooms do
		for _, c in room.cells do
			owner[grid:index(c[1], c[2])] = roomIndex
		end
	end

	local openEdges = {}
	local visited = {}

	-- Opens a doorWidth-cell run between `cells` (already converted to HALL) and
	-- each room in roomList -- NOT the whole shared boundary, so a large pocket
	-- doesn't blow out an entire wall run. Keeps a forced/culled hallway pocket
	-- from being sealed off from rooms it happens to touch.
	local function openToRooms(cells, roomList)
		for _, r in roomList do
			local edges = {}
			for _, c in cells do
				local cx, cy = c[1], c[2]
				for _, d in NEIGHBORS do
					local nx, ny = cx + d[1], cy + d[2]
					if grid:inBounds(nx, ny) and owner[grid:index(nx, ny)] == r then
						table.insert(edges, { cx, cy, nx, ny })
					end
				end
			end
			if #edges > 0 then
				local idx = rng:NextInteger(1, #edges)
				local half = math.floor((doorWidth - 1) / 2)
				local lo = math.max(1, math.min(idx - half, #edges - doorWidth + 1))
				local hi = math.min(#edges, lo + doorWidth - 1)
				for i = lo, hi do
					table.insert(openEdges, edges[i])
				end
			end
		end
	end

	for sy = 1, H do
		for sx = 1, W do
			local startIdx = grid:index(sx, sy)
			if not visited[startIdx] and grid.cells[startIdx] == Grid.EMPTY and owner[startIdx] == 0 then
				-- BFS this leftover pocket, noting every room it borders along the way.
				local cells = {}
				local touching = {} -- set of room indices
				local stack = { { sx, sy } }
				visited[startIdx] = true
				while #stack > 0 do
					local c = table.remove(stack) :: any
					local cx, cy = c[1], c[2]
					table.insert(cells, c)
					for _, d in NEIGHBORS do
						local nx, ny = cx + d[1], cy + d[2]
						if grid:inBounds(nx, ny) and grid.cells[grid:index(nx, ny)] == Grid.EMPTY then
							local ni = grid:index(nx, ny)
							local o = owner[ni]
							if o ~= 0 then
								touching[o] = true
							elseif not visited[ni] then
								visited[ni] = true
								table.insert(stack, { nx, ny })
							end
						end
					end
				end

				local roomList = {}
				for r in touching do
					table.insert(roomList, r)
				end

				local eligible = {}
				for _, r in roomList do
					if rooms[r].irregularity < irregularityThreshold then
						table.insert(eligible, r)
					end
				end

				if #roomList == 0 then
					-- not connected to any room -- becomes plain hallway
					for _, c in cells do
						grid:set(c[1], c[2], Grid.HALL)
					end
				elseif #roomList >= 2 and #eligible > 0 and rng:NextNumber() < hallwayChance then
					-- between 2+ rooms, won the coin flip -- becomes a connecting
					-- hallway segment, left fully open to every room it touches
					for _, c in cells do
						grid:set(c[1], c[2], Grid.HALL)
					end
					openToRooms(cells, roomList)
				elseif #eligible > 0 then
					-- adjoins exactly one (eligible) room, or lost the coin flip --
					-- extend a random eligible room, growing its irregularity
					local pick = eligible[rng:NextInteger(1, #eligible)]
					local room = rooms[pick]
					room.irregularity += #cells / (room.w * room.h)
					for _, c in cells do
						table.insert(room.cells, c)
						owner[grid:index(c[1], c[2])] = pick
					end
				else
					-- every room it touches is past its irregularity cap -- can't
					-- merge, so it becomes hallway instead (still opened to those
					-- rooms so it's not a sealed dead end)
					for _, c in cells do
						grid:set(c[1], c[2], Grid.HALL)
					end
					openToRooms(cells, roomList)
				end
			end
		end
	end

	return openEdges
end

--------------------------------------------------------------------------------
-- Stage 4: chance to connect directly-adjacent rooms with their own door
--------------------------------------------------------------------------------

local function pairKey(a: number, b: number): number
	if a > b then
		a, b = b, a
	end
	return a * 1e6 + b
end

function RoomFinder.connectAdjacentRooms(grid, rooms, rng: Random, config: RoomLinkConfig?): { { number } }
	config = config or {}
	local chance = config.chance or 0.15
	local doorWidth = config.doorWidth or 2

	local W, H = grid.width, grid.height
	local owner = table.create(W * H, 0)
	for roomIndex, room in rooms do
		for _, c in room.cells do
			owner[grid:index(c[1], c[2])] = roomIndex
		end
	end

	-- Every boundary edge between two DIFFERENT rooms, grouped by room pair.
	-- Only checking east/south neighbours visits each internal edge once.
	local pairEdges = {} -- [pairKey] = { {ax,ay,bx,by}, ... }
	for y = 1, H do
		for x = 1, W do
			local a = owner[grid:index(x, y)]
			if a ~= 0 then
				for _, d in { { 1, 0 }, { 0, 1 } } do
					local nx, ny = x + d[1], y + d[2]
					if grid:inBounds(nx, ny) then
						local b = owner[grid:index(nx, ny)]
						if b ~= 0 and b ~= a then
							local key = pairKey(a, b)
							pairEdges[key] = pairEdges[key] or {}
							table.insert(pairEdges[key], { x, y, nx, ny })
						end
					end
				end
			end
		end
	end

	local openEdges = {}
	for _, edges in pairEdges do
		if rng:NextNumber() < chance then
			-- Open a doorWidth-cell run centered on a random edge along their
			-- shared boundary (row/column scan order keeps a straight shared
			-- wall's entries array-adjacent, so this is a real contiguous gap
			-- for the common case of two rectangular rooms sharing a wall).
			local idx = rng:NextInteger(1, #edges)
			local half = math.floor((doorWidth - 1) / 2)
			local lo = math.max(1, math.min(idx - half, #edges - doorWidth + 1))
			local hi = math.min(#edges, lo + doorWidth - 1)
			for i = lo, hi do
				table.insert(openEdges, edges[i])
			end
		end
	end

	return openEdges
end

return RoomFinder
