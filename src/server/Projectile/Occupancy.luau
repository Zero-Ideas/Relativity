--!strict
--!native
--!optimize 2
--[[
	Projectile/Occupancy.luau
	Skips movement raycasts through provably empty space. A sweep is only
	skipped when nothing a raycast could hit is anywhere near it, so the result
	is identical to casting (no hit) -- just without the engine call.

	Static geometry (anchored assemblies) is baked into a sparse two-level
	grid: COARSE-stud cells, each holding a 4096-bit mask (a 512-byte buffer)
	of FINE-stud sub-voxels. Masks are interned: a cell points at a shared,
	never-mutated mask (marking copies, edits and re-interns), so the many
	identical cells along a floor or wall cost one table slot each. One serial
	publisher bakes the grid; Actors import deduplicated masks and later deltas
	into local lookup tables. Every part is marked by its world AABB grown by PAD
	studs, which is what makes a centreline walk safe for sphere sweeps up to
	MaxRadius: any surface within that distance of the path lies in a marked
	voxel on the path. Marks are only ever added (a moved static part is
	re-marked at its new place, never cleared at the old one), so staleness
	can only cost a skipped skip, never a missed hit.

	Parts with CanQuery off are skipped (raycasts can't hit them) until it's
	turned on. A part bigger than REFINE_OVER studs whose shape isn't its box
	(meshes, unions, wedges, balls...) is baked by its real collision geometry:
	its box is split recursively and each piece tested with GetPartsInPart
	(the same geometry raycasts hit), so e.g. a tree's mostly-empty bounding
	box isn't marked solid. While that runs the part counts as dynamic (coarse,
	conservative). The base grid is usable immediately; expensive shape
	refinement continues in one background queue and publishes finished cells.

	Dynamic geometry -- anything unanchored, and every part of a model with a
	Humanoid (characters, dummies, ragdolls) -- is re-marked at coarse level
	once per physics frame, the first time a query needs it, grown by its
	speed so it can't outrun its mark. New parts count as dynamic from the
	moment they appear (until a deferred check finds them anchored), so a
	part spawned this frame is never skipped past.

	Terrain (any map that has it) is read in background batches with
	ReadVoxels over the area around the map's parts (or a default area for a
	terrain-only map) and marked like parts. While a map has terrain, a path
	that leaves the scanned area always raycasts. Terrain edited at runtime
	isn't detected: call Occupancy.BakeTerrain(min, max) over the edited area
	(marks only add, so removed terrain just stops being skipped through).

	SegmentClear(origin, displacement, radius) walks the path's coarse cells
	(the common case in open air: a handful of empty lookups) and only walks
	fine voxels through cells that have something in them.
]]

local Occupancy = {}
local isWorker = _G.__RelativityOccupancyWorker == true

local COARSE = 64 -- studs per coarse cell edge
local FINE = 4 -- studs per sub-voxel edge
local DIV = COARSE // FINE -- sub-voxels per coarse edge (16 -> 4096-bit masks)
local ROW_BYTES = DIV // 8 -- one x-row of a cell (16 bits)
local MASK_BYTES = DIV * DIV * ROW_BYTES -- 512
local PAD = FINE -- studs every part's AABB is grown by
local DYNAMIC_MARGIN = 2 -- extra studs around moving parts
local DYNAMIC_LOOKAHEAD = 1 / 15 -- seconds of travel added around moving parts
local DEMOTE_AFTER_MOVES = 20 -- a static part moved this often is treated as dynamic
local BAKE_BATCH = 400 -- parts baked per resumption
local TERRAIN_BLOCK = 256 -- studs per ReadVoxels block edge (64^3 voxels)
local TERRAIN_AROUND_PARTS = 512 -- studs of terrain scanned beyond the map's parts
local TERRAIN_DEFAULT_MIN = Vector3.new(-2048, -512, -2048) -- terrain-only maps
local TERRAIN_DEFAULT_MAX = Vector3.new(2048, 1024, 2048)
local REFINE_OVER = 32 -- studs: bigger non-box parts are baked by their real shape
local REFINE_DIVISIONS = 16 -- a part is refined down to about 1/16 of its size (power-of-two pieces)
local REFINE_MAX_PROBES = 6000 -- per part; past this the rest is kept whole
local REFINE_SLICE = 0.004 -- seconds of shape probing per resumption

-- Sweeps wider than this always raycast (the padding wouldn't cover them).
Occupancy.MaxRadius = PAD - 0.25
Occupancy.Enabled = true

local OFFSET = 32768
local STRIDE = 65536
local STRIDE2 = STRIDE * STRIDE

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local bor, btest, lshift = bit32.bor, bit32.btest, bit32.lshift
local readu16, writeu16 = buffer.readu16, buffer.writeu16

local function cellKey(cx: number, cy: number, cz: number): number
	return (cx + OFFSET) + (cy + OFFSET) * STRIDE + (cz + OFFSET) * STRIDE2
end

local static: { [number]: buffer } = {} -- coarse key -> interned sub-voxel mask
local masks: { [string]: buffer } = {} -- mask contents -> the one shared buffer
local FULL = buffer.create(MASK_BYTES)
buffer.fill(FULL, 0, 255)
masks[buffer.tostring(FULL)] = FULL
local scratch = buffer.create(MASK_BYTES)
-- coarse key -> the padded boxes of whatever moves through that cell this
-- frame, as (lo, hi, owner) triples; a fine voxel is only blocked if it
-- overlaps one. `owner` is the part's top-level ancestor under workspace (a
-- character, a model...): a query whose raycast filter excludes that owner
-- ignores its boxes (see SegmentClear), so e.g. slow shots hanging around
-- their own shooter still skip.
local dynamic: { [number]: { any } } = {}
local ownerOf: { [BasePart]: Instance } = {}
local currentIgnore: { [Instance]: boolean }? = nil -- the running query's excluded instances
local dynamicParts: { [BasePart]: boolean } = {}
local staticMoves: { [BasePart]: number } = {}
local watchedRoots: { [BasePart]: { BasePart } } = {} -- anchored root -> parts welded to it
local dynamicStamp = -1 -- workspace.DistributedGameTime the dynamic marks belong to
local ready = false
local startupDone = false
local importedReady = false
local hasSnapshot = false
local revision = 0
local dirtyCells: {[number]: boolean} = {}
local publishedParts: {[BasePart]: {any}} = {}
local dirtyParts: {[BasePart]: boolean} = {}
local schedulePublish: (() -> ())? = nil
-- While the map has terrain: the scanned area; outside it nothing is skipped.
local hasTerrain = false
local terrainMin, terrainMax = Vector3.zero, Vector3.zero

local stats = { Checks = 0, Skipped = 0, Coarse = 0, StaticCells = 0, DistinctMasks = 1, DynamicParts = 0,
	-- why a check wasn't skipped (Stats tab)
	NotReady = 0, TooWide = 0, OutsideTerrain = 0, Blocked = 0, BlockedMoving = 0,
	LargestDynamic = nil :: string?, -- (diagnostic: the biggest moving part, by name)
}
local blockedByMoving = false -- set by fineOccupied when a moving part's cell is what blocked
local refineCpu, refineProbes, refineYields = 0, 0, 0

local function setStatic(key: number, mask: buffer)
	if static[key] == mask then return end
	static[key] = mask
	if not isWorker then
		dirtyCells[key] = true
		if schedulePublish then schedulePublish() end
	end
end

local function rememberPart(part: BasePart)
	publishedParts[part] = {part, part.CFrame, part.Size}
	dirtyParts[part] = true
	if schedulePublish then schedulePublish() end
end

local function intern(mask: buffer): buffer
	local contents = buffer.tostring(mask)
	local existing = masks[contents]
	if existing then
		return existing
	end
	local copy = buffer.fromstring(contents)
	masks[contents] = copy
	stats.DistinctMasks += 1
	return copy
end

--------------------------------------------------------------------------------
-- Marking
--------------------------------------------------------------------------------

-- World AABB of a part's oriented box, grown by `grow`.
local function bounds(part: BasePart, grow: number): (Vector3, Vector3)
	local cf = part.CFrame
	local half = part.Size * 0.5
	local xv, yv, zv = cf.XVector, cf.YVector, cf.ZVector
	local extent = Vector3.new(
		abs(xv.X) * half.X + abs(yv.X) * half.Y + abs(zv.X) * half.Z,
		abs(xv.Y) * half.X + abs(yv.Y) * half.Y + abs(zv.Y) * half.Z,
		abs(xv.Z) * half.X + abs(yv.Z) * half.Y + abs(zv.Z) * half.Z
	) + Vector3.one * grow
	local centre = cf.Position
	return centre - extent, centre + extent
end

-- Sets every sub-voxel overlapping [lo, hi]. Bit (fx + fy*16 + fz*256) is bit
-- fx of the u16 row at (fy + fz*16), so one x-row of a cell is one write.
local function markStatic(lo: Vector3, hi: Vector3)
	local fx0, fy0, fz0 = floor(lo.X / FINE), floor(lo.Y / FINE), floor(lo.Z / FINE)
	local fx1, fy1, fz1 = floor(hi.X / FINE), floor(hi.Y / FINE), floor(hi.Z / FINE)
	for cz = fz0 // DIV, fz1 // DIV do
		local az, bz = max(fz0 - cz * DIV, 0), min(fz1 - cz * DIV, DIV - 1)
		for cy = fy0 // DIV, fy1 // DIV do
			local ay, by = max(fy0 - cy * DIV, 0), min(fy1 - cy * DIV, DIV - 1)
			for cx = fx0 // DIV, fx1 // DIV do
				local ax, bx = max(fx0 - cx * DIV, 0), min(fx1 - cx * DIV, DIV - 1)
				local k = cellKey(cx, cy, cz)
				local current = static[k]
				if current == FULL then
					continue
				end
				if not current then
					stats.StaticCells += 1
				end
				if ax == 0 and bx == DIV - 1 and ay == 0 and by == DIV - 1 and az == 0 and bz == DIV - 1 then
					setStatic(k, FULL)
					continue
				end
				-- shared masks are never edited in place: edit a copy, re-intern
				if current then
					buffer.copy(scratch, 0, current, 0, MASK_BYTES)
				else
					buffer.fill(scratch, 0, 0)
				end
				local row = lshift(lshift(1, bx - ax + 1) - 1, ax)
				for fz = az, bz do
					for fy = ay, by do
						local offset = (fy + fz * DIV) * ROW_BYTES
						writeu16(scratch, offset, bor(readu16(scratch, offset), row))
					end
				end
				setStatic(k, intern(scratch))
			end
		end
	end
end

-- Marks many boxes at once (`boxes`: lo, hi pairs on the FINE grid, e.g.
-- from refineShape). Each touched cell is edited in one private copy and
-- interned once at the end -- marking them one by one through markStatic
-- would intern (and keep forever) every intermediate state of every cell,
-- which for a big mesh's ~10^5 voxels was gigabytes.
local function markVoxels(boxes: { Vector3 })
	local pending: { [number]: buffer } = {}
	for index = 1, #boxes, 2 do
		local lo, hi = boxes[index], boxes[index + 1]
		local fx0, fy0, fz0 = math.round(lo.X / FINE), math.round(lo.Y / FINE), math.round(lo.Z / FINE)
		local fx1, fy1, fz1 = math.round(hi.X / FINE) - 1, math.round(hi.Y / FINE) - 1, math.round(hi.Z / FINE) - 1
		for cz = fz0 // DIV, fz1 // DIV do
			local az, bz = max(fz0 - cz * DIV, 0), min(fz1 - cz * DIV, DIV - 1)
			for cy = fy0 // DIV, fy1 // DIV do
				local ay, by = max(fy0 - cy * DIV, 0), min(fy1 - cy * DIV, DIV - 1)
				for cx = fx0 // DIV, fx1 // DIV do
					local ax, bx = max(fx0 - cx * DIV, 0), min(fx1 - cx * DIV, DIV - 1)
					local k = cellKey(cx, cy, cz)
					local mask = pending[k]
					if not mask then
						local current = static[k]
						if current == FULL then
							continue
						end
						mask = buffer.create(MASK_BYTES)
						if current then
							buffer.copy(mask, 0, current, 0, MASK_BYTES)
						end
						pending[k] = mask
					end
					local row = lshift(lshift(1, bx - ax + 1) - 1, ax)
					for fz = az, bz do
						for fy = ay, by do
							local offset = (fy + fz * DIV) * ROW_BYTES
							writeu16(mask, offset, bor(readu16(mask, offset), row))
						end
					end
				end
			end
		end
	end
	for k, mask in pending do
		if not static[k] then
			stats.StaticCells += 1
		end
		setStatic(k, intern(mask))
	end
end

local function markDynamicBox(lo: Vector3, hi: Vector3, owner: Instance)
	for cz = floor(lo.Z / COARSE), floor(hi.Z / COARSE) do
		for cy = floor(lo.Y / COARSE), floor(hi.Y / COARSE) do
			for cx = floor(lo.X / COARSE), floor(hi.X / COARSE) do
				local k = cellKey(cx, cy, cz)
				local boxes = dynamic[k]
				if not boxes then
					boxes = {}
					dynamic[k] = boxes
				end
				table.insert(boxes, lo)
				table.insert(boxes, hi)
				table.insert(boxes, owner)
			end
		end
	end
end

-- Re-marks every moving part, once per physics frame (all queries in one
-- Heartbeat see the same world).
local function refreshDynamic()
	local stamp = workspace.DistributedGameTime
	if stamp == dynamicStamp then
		return
	end
	dynamicStamp = stamp
	table.clear(dynamic)
	local count = 0
	local largest, largestSize = nil, 0
	for part in dynamicParts do
		if not part.Parent then
			dynamicParts[part] = nil
			continue
		end
		count += 1
		local size = part.Size.Magnitude
		if size > largestSize then
			largest, largestSize = part, size
		end
		local reach = PAD + DYNAMIC_MARGIN + part.AssemblyLinearVelocity.Magnitude * DYNAMIC_LOOKAHEAD
		local lo, hi = bounds(part, reach)
		local owner = ownerOf[part]
		if not owner or not owner.Parent then
			local node: Instance = part
			while node.Parent and node.Parent ~= workspace do
				node = node.Parent :: Instance
			end
			owner = node
			ownerOf[part] = node
		end
		markDynamicBox(lo, hi, owner :: Instance)
	end
	stats.DynamicParts = count
	stats.LargestDynamic = if largest then `{largest:GetFullName()} ({math.floor(largestSize)})` else nil
end

--------------------------------------------------------------------------------
-- Classification
--------------------------------------------------------------------------------

local function inCharacter(part: BasePart): boolean
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if model:FindFirstChildOfClass("Humanoid") then
			return true
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return false
end

-- Is this part's collision shape its own box?
local function boxShaped(part: BasePart): boolean
	return part:IsA("Part") and (part :: Part).Shape == Enum.PartType.Block
end

-- The boxes (lo, hi pairs on the FINE grid) covering `part`'s real
-- collision geometry, each tested grown by PAD (so marking them needs no
-- further padding): its box is split into octants and a piece is kept only
-- if GetPartsInPart finds the part in it. Pieces stop at a power-of-two
-- `leaf` near 1/REFINE_DIVISIONS of the part (so a 900-stud tree costs about
-- what a 50-stud rock does), and past REFINE_MAX_PROBES whatever is left is
-- kept whole (still safe, just coarser). Yields every REFINE_SLICE; nil if the
-- part left the world meanwhile.
local probe = Instance.new("Part")
probe.Anchored = true

local function leafFor(part: BasePart): number
	local size = part.Size
	local wanted = max(size.X, size.Y, size.Z) / REFINE_DIVISIONS
	local leaf = FINE
	while leaf < wanted and leaf < COARSE do
		leaf *= 2
	end
	return leaf
end

local function refineShape(part: BasePart): { Vector3 }?
	local initialFrame, initialSize = part.CFrame, part.Size
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { part }
	local grow = Vector3.one * (2 * PAD)
	local leaf = leafFor(part)
	local lo, hi = bounds(part, 0)
	lo = Vector3.new(floor(lo.X / leaf) * leaf, floor(lo.Y / leaf) * leaf, floor(lo.Z / leaf) * leaf)
	hi = Vector3.new(math.ceil(hi.X / leaf) * leaf, math.ceil(hi.Y / leaf) * leaf, math.ceil(hi.Z / leaf) * leaf)
	local boxes: { Vector3 } = {}
	local stack: { Vector3 } = { lo, hi }
	local sliceStarted = os.clock()
	local probes = 0
	-- an axis range split in two on the leaf grid (one range if it's one leaf)
	local function halves(a: number, b: number): { number }
		if b - a <= leaf then
			return { a, b }
		end
		local m = a + math.ceil((b - a) / leaf / 2) * leaf
		return { a, m, m, b }
	end
	while #stack > 0 do
		local nodeHi = table.remove(stack) :: Vector3
		local nodeLo = table.remove(stack) :: Vector3
		if probes >= REFINE_MAX_PROBES then
			-- out of budget: keep the rest whole
			table.insert(boxes, nodeLo)
			table.insert(boxes, nodeHi)
			continue
		end
		if os.clock() - sliceStarted > REFINE_SLICE then
			refineCpu += os.clock() - sliceStarted
			refineYields += 1
			task.wait()
			sliceStarted = os.clock()
			if not part.Parent or part.CFrame ~= initialFrame or part.Size ~= initialSize then
				return nil
			end
		end
		probes += 1
		refineProbes += 1
		probe.Size = nodeHi - nodeLo + grow
		probe.CFrame = CFrame.new((nodeLo + nodeHi) * 0.5)
		if #workspace:GetPartsInPart(probe, params) == 0 then
			continue
		end
		local size = nodeHi - nodeLo
		if size.X <= leaf and size.Y <= leaf and size.Z <= leaf then
			table.insert(boxes, nodeLo)
			table.insert(boxes, nodeHi)
			continue
		end
		local xs, ys, zs = halves(nodeLo.X, nodeHi.X), halves(nodeLo.Y, nodeHi.Y), halves(nodeLo.Z, nodeHi.Z)
		for i = 1, #xs, 2 do
			for j = 1, #ys, 2 do
				for k = 1, #zs, 2 do
					table.insert(stack, Vector3.new(xs[i], ys[j], zs[k]))
					table.insert(stack, Vector3.new(xs[i + 1], ys[j + 1], zs[k + 1]))
				end
			end
		end
	end
	refineCpu += os.clock() - sliceStarted
	return boxes
end

-- Workers never bake: static parts stay dynamic until a current mask/pose
-- record arrives from the publisher (ApplyBake).
local shaped: { [BasePart]: boolean } = {} -- (worker) boxes already applied
local watched: { [BasePart]: boolean } = {}

local function actorsFolder(): Instance?
	return game:GetService("ServerScriptService"):FindFirstChild("ProjectileActors", true)
end

-- Bake masks once. Transfer deduplicated immutable buffers at startup and
-- changed-cell deltas afterwards; workers keep ordinary local table/buffer
-- reads in the hot path (no SharedTable lookup/string conversion per sweep).
local function packet(full: boolean): any
	local keys, ids, unique, indices, parts = {}, {}, {}, {}, {}
	local source = if full then static else dirtyCells
	for key in source do
		local mask = static[key]
		if mask then
			local index = indices[mask]
			if not index then
				index = #unique + 1; indices[mask] = index; unique[index] = mask
			end
			table.insert(keys, key); table.insert(ids, index)
		end
	end
	local partSource = if full then publishedParts else dirtyParts
	for part in partSource do
		local record = publishedParts[part]
		if record and part.Parent then table.insert(parts, record) end
	end
	return {Version = revision, Full = full, Keys = keys, MaskIds = ids, Masks = unique, Parts = parts,
		Ready = ready, HasTerrain = hasTerrain, TerrainMin = terrainMin, TerrainMax = terrainMax}
end

local publishQueued = false
local function publish()
	publishQueued = false
	if isWorker or not startupDone then return end
	local folder = actorsFolder()
	if not folder then return end
	revision += 1
	local update = packet(revision == 1)
	table.clear(dirtyCells); table.clear(dirtyParts)
	for _, actor in folder:GetChildren() do
		if actor:IsA("Actor") then actor:SendMessage("OccupancyBake", update) end
	end
end
schedulePublish = function()
	if isWorker or not startupDone or publishQueued then return end
	publishQueued = true
	task.defer(publish)
end

if not isWorker then
	task.spawn(function()
		local folder = actorsFolder()
		while not folder do task.wait(0.5); folder = actorsFolder() end
		local function sendAll(actor: Actor)
			if startupDone and actor.Parent then actor:SendMessage("OccupancyBake", packet(true)) end
		end
		local hello = (folder :: Instance):WaitForChild("OccupancyHello") :: BindableEvent
		hello.Event:Connect(sendAll)
		for _, actor in (folder :: Instance):GetChildren() do
			if actor:IsA("Actor") then sendAll(actor) end
		end
	end)
end

local queryWatched: { [BasePart]: boolean } = {}

local function makeDynamic(part: BasePart)
	if not dynamicParts[part] then
		dynamicParts[part] = true
		dynamicStamp = -1 -- the current frame's marks no longer cover it
	end
end

local classify: (part: BasePart) -> ()

-- A static part moved (or its anchoring changed): mark where it is now, and
-- give up on it as static if it keeps moving or stopped being anchored.
local function staticChanged(part: BasePart)
	if not part.Parent or dynamicParts[part] then
		return
	end
	if isWorker then
		-- Until a current publisher record arrives, moved geometry is dynamic.
		-- Never trust a stale snapshot at its new location.
		makeDynamic(part)
		return
	end
	local root = part.AssemblyRootPart
	if not (part.Anchored or (root and root.Anchored)) then
		makeDynamic(part)
		return
	end
	local moves = (staticMoves[part] or 0) + 1
	staticMoves[part] = moves
	if moves >= DEMOTE_AFTER_MOVES then
		makeDynamic(part)
		return
	end
	local lo, hi = bounds(part, PAD)
	markStatic(lo, hi)
	rememberPart(part)
end

local function watchStatic(part: BasePart)
	part:GetPropertyChangedSignal("CFrame"):Connect(function()
		staticChanged(part)
	end)
	part:GetPropertyChangedSignal("Size"):Connect(function()
		staticChanged(part)
	end)
	part:GetPropertyChangedSignal("Anchored"):Connect(function()
		staticChanged(part)
	end)
	-- Parts welded to an anchored root move with it without their own CFrame
	-- signal firing, and become loose if the root is unanchored: watch the root.
	local root = part.AssemblyRootPart
	if root and root ~= part then
		local list = watchedRoots[root]
		if not list then
			list = {}
			watchedRoots[root] = list
			local function rootChanged()
				for _, member in list do
					staticChanged(member)
				end
			end
			root:GetPropertyChangedSignal("CFrame"):Connect(rootChanged)
			root:GetPropertyChangedSignal("Anchored"):Connect(rootChanged)
		end
		table.insert(list, part)
	end
end

local refineQueue: {BasePart} = {}
local refineQueued: {[BasePart]: boolean} = {}
local refining = false
local function queueRefinement(part: BasePart)
	if refineQueued[part] then return end
	refineQueued[part] = true
	table.insert(refineQueue, part)
	if refining then return end
	refining = true
	task.defer(function()
		local started, completed = os.clock(), 0
		local cpuBefore, probesBefore, yieldsBefore = refineCpu, refineProbes, refineYields
		for _, candidate in refineQueue do
			if candidate.Parent then
				local boxes = refineShape(candidate)
				local root = candidate.AssemblyRootPart
				if boxes and candidate.Parent and candidate.CanQuery
					and (candidate.Anchored or (root and root.Anchored)) and not inCharacter(candidate) then
					local markStarted = os.clock()
					markVoxels(boxes)
					refineCpu += os.clock() - markStarted
					rememberPart(candidate)
					dynamicParts[candidate] = nil
					if not watched[candidate] then watched[candidate] = true; watchStatic(candidate) end
					completed += 1
				end
			end
			refineQueued[candidate] = nil
		end
		table.clear(refineQueue)
		refining = false
		print(string.format("[Projectile] occupancy refinement complete: %d shapes, %d cells, %.0f ms wall / %.0f ms CPU, %d probes, %d yields (base grid already usable)",
			completed, stats.StaticCells, (os.clock() - started) * 1000, (refineCpu - cpuBefore) * 1000,
			refineProbes - probesBefore, refineYields - yieldsBefore))
	end)
end

function classify(part: BasePart)
	if part:IsA("Terrain") or not part:IsDescendantOf(workspace) then
		return
	end
	if not part.CanQuery then
		-- raycasts can't hit it: nothing to mark until that changes
		dynamicParts[part] = nil
		if not queryWatched[part] then
			queryWatched[part] = true
			part:GetPropertyChangedSignal("CanQuery"):Connect(function()
				if part.CanQuery and part.Parent then
					makeDynamic(part)
					task.spawn(classify, part)
				end
			end)
		end
		return
	end
	local root = part.AssemblyRootPart
	local anchored = part.Anchored or (root ~= nil and root.Anchored)
	if not anchored or inCharacter(part) then
		makeDynamic(part)
		return
	end
	if isWorker then
		if not shaped[part] then makeDynamic(part) end
		if not watched[part] then watched[part] = true; watchStatic(part) end
		return -- workers import finished masks; no box/shape/terrain bake
	end
	local size = part.Size
	if (size.X > REFINE_OVER or size.Y > REFINE_OVER or size.Z > REFINE_OVER) and not boxShaped(part) then
		makeDynamic(part) -- (conservative while its shape is probed)
		queueRefinement(part)
		return
	else
		local lo, hi = bounds(part, PAD)
		markStatic(lo, hi)
	end
	rememberPart(part)
	dynamicParts[part] = nil
	if not watched[part] then
		watched[part] = true
		watchStatic(part)
	end
end

-- Serial Actor handler. Buffers are already baked and deduplicated by the
-- publisher; adopt them directly, never rebuild voxel masks in each Actor.
function Occupancy.ApplyBake(update: any): boolean
	if not isWorker then return true end
	if update.Version < revision then return hasSnapshot end
	-- Never enable skipping from a partial/missed delta. A late worker (or a
	-- gap in delivery) requests a fresh snapshot and casts normally meanwhile.
	if not update.Full and (not hasSnapshot or update.Version > revision + 1) then
		ready = false
		hasSnapshot = false
		return false
	end
	if update.Full then hasSnapshot = true end
	local started = os.clock()
	local first = not importedReady
	revision = update.Version
	-- Intern once per received mask, not per cell/query. Deltas can contain a
	-- pattern already received in an earlier packet; keep just one local copy.
	local importedMasks = table.create(#update.Masks)
	for index, mask in update.Masks do importedMasks[index] = intern(mask) end
	for index, key in update.Keys do
		if not static[key] then stats.StaticCells += 1 end
		static[key] = importedMasks[update.MaskIds[index]]
	end
	for _, record in update.Parts do
		local part = record[1]
		if part.Parent and part.CFrame == record[2] and part.Size == record[3] and part.CanQuery
			and (part.Anchored or (part.AssemblyRootPart and part.AssemblyRootPart.Anchored)) and not inCharacter(part) then
			shaped[part] = true
			dynamicParts[part] = nil
			if not watched[part] then watched[part] = true; watchStatic(part) end
		end
	end
	dynamicStamp = -1
	hasTerrain, terrainMin, terrainMax = update.HasTerrain, update.TerrainMin, update.TerrainMax
	importedReady = update.Ready
	ready = startupDone and importedReady
	if first and importedReady then
		print(string.format("[Projectile] occupancy imported (no bake): %d cells, %.2f ms", stats.StaticCells, (os.clock() - started) * 1000))
	end
	return true
end

-- A joint went away: its parts may now be loose, so stop trusting them as static.
local function jointRemoved(joint: Instance)
	for _, name in { "Part0", "Part1" } do
		local part = (joint :: any)[name]
		if typeof(part) == "Instance" and part:IsA("BasePart") and not part.Anchored then
			makeDynamic(part)
		end
	end
end

--------------------------------------------------------------------------------
-- Query
--------------------------------------------------------------------------------

local function fineOccupied(fx: number, fy: number, fz: number): boolean
	local cx, cy, cz = fx // DIV, fy // DIV, fz // DIV
	local k = cellKey(cx, cy, cz)
	local moving = dynamic[k]
	if moving then
		local x0, y0, z0 = fx * FINE, fy * FINE, fz * FINE
		local x1, y1, z1 = x0 + FINE, y0 + FINE, z0 + FINE
		local ignore = currentIgnore
		for index = 1, #moving, 3 do
			local lo, hi = moving[index], moving[index + 1]
			if x1 > lo.X and x0 < hi.X and y1 > lo.Y and y0 < hi.Y and z1 > lo.Z and z0 < hi.Z
				and not (ignore and ignore[moving[index + 2]]) then
				blockedByMoving = true
				return true
			end
		end
	end
	local mask = static[k]
	if not mask then
		return false
	end
	local lx, ly, lz = fx - cx * DIV, fy - cy * DIV, fz - cz * DIV
	return btest(readu16(mask, (ly + lz * DIV) * ROW_BYTES), lshift(1, lx))
end

local function coarseOccupied(cx: number, cy: number, cz: number): boolean
	local k = cellKey(cx, cy, cz)
	return dynamic[k] ~= nil or static[k] ~= nil
end

-- Amanatides-Woo walk of every `size`-stud voxel the segment passes through;
-- true as soon as `occupied` says one is.
local function walk(origin: Vector3, displacement: Vector3, size: number, occupied: (number, number, number) -> boolean): boolean
	local x, y, z = origin.X / size, origin.Y / size, origin.Z / size
	local dx, dy, dz = displacement.X / size, displacement.Y / size, displacement.Z / size
	local ix, iy, iz = floor(x), floor(y), floor(z)
	local ex, ey, ez = floor(x + dx), floor(y + dy), floor(z + dz)
	local sx = if dx > 0 then 1 elseif dx < 0 then -1 else 0
	local sy = if dy > 0 then 1 elseif dy < 0 then -1 else 0
	local sz = if dz > 0 then 1 elseif dz < 0 then -1 else 0
	local inf = math.huge
	local tx = if dx > 0 then (ix + 1 - x) / dx elseif dx < 0 then (x - ix) / -dx else inf
	local ty = if dy > 0 then (iy + 1 - y) / dy elseif dy < 0 then (y - iy) / -dy else inf
	local tz = if dz > 0 then (iz + 1 - z) / dz elseif dz < 0 then (z - iz) / -dz else inf
	local ux = if dx ~= 0 then 1 / abs(dx) else inf
	local uy = if dy ~= 0 then 1 / abs(dy) else inf
	local uz = if dz ~= 0 then 1 / abs(dz) else inf
	local steps = abs(ex - ix) + abs(ey - iy) + abs(ez - iz) + 1
	for _ = 1, steps do
		if occupied(ix, iy, iz) then
			return true
		end
		if tx <= ty and tx <= tz then
			ix += sx
			tx += ux
		elseif ty <= tz then
			iy += sy
			ty += uy
		else
			iz += sz
			tz += uz
		end
	end
	-- floating-point slack: the end voxel is always checked
	return occupied(ex, ey, ez)
end

-- Is the whole segment (plus padding) inside the scanned terrain area?
local function insideTerrainScan(origin: Vector3, finish: Vector3): boolean
	local lo = origin:Min(finish) - Vector3.one * PAD
	local hi = origin:Max(finish) + Vector3.one * PAD
	return lo.X >= terrainMin.X and lo.Y >= terrainMin.Y and lo.Z >= terrainMin.Z
		and hi.X <= terrainMax.X and hi.Y <= terrainMax.Y and hi.Z <= terrainMax.Z
end

-- True when a sweep of `radius` from `origin` along `displacement` provably
-- hits nothing, so the caller can skip its raycast. Conservative: any doubt
-- (not baked yet, too wide, outside scanned terrain, anything near the path)
-- returns false.
-- `ignore` (optional): instances the caller's raycast excludes (with their
-- descendants); moving parts belonging to them don't block.
function Occupancy.SegmentClear(origin: Vector3, displacement: Vector3, radius: number,
	ignore: { [Instance]: boolean }?): boolean
	stats.Checks += 1
	if not ready or not Occupancy.Enabled then
		stats.NotReady += 1
		return false
	end
	if radius > Occupancy.MaxRadius then
		stats.TooWide += 1
		return false
	end
	if hasTerrain and not insideTerrainScan(origin, origin + displacement) then
		stats.OutsideTerrain += 1
		return false
	end
	refreshDynamic()
	if walk(origin, displacement, COARSE, coarseOccupied) then
		stats.Coarse += 1
		blockedByMoving = false
		currentIgnore = ignore
		local blocked = walk(origin, displacement, FINE, fineOccupied)
		currentIgnore = nil
		if blocked then
			stats.Blocked += 1
			if blockedByMoving then
				stats.BlockedMoving += 1
			end
			return false
		end
	end
	stats.Skipped += 1
	return true
end

-- Counters since the last call (DebugService's Stats tab), then reset.
function Occupancy.TakeStats()
	local snapshot = table.clone(stats)
	snapshot.Ready = ready
	stats.Checks, stats.Skipped, stats.Coarse = 0, 0, 0
	stats.NotReady, stats.TooWide, stats.OutsideTerrain, stats.Blocked, stats.BlockedMoving = 0, 0, 0, 0, 0
	return snapshot
end

--------------------------------------------------------------------------------
-- Terrain
--------------------------------------------------------------------------------

local function snap(value: number, toward: number): number
	return if toward < 0 then floor(value / FINE) * FINE else math.ceil(value / FINE) * FINE
end

-- Reads terrain between `lo` and `hi` in TERRAIN_BLOCK batches (yielding
-- between them) and marks every solid voxel; contiguous x-runs are marked as
-- one box. Water is skipped (projectile rays ignore it).
function Occupancy.BakeTerrain(lo: Vector3, hi: Vector3)
	local terrain = workspace.Terrain
	lo = Vector3.new(snap(lo.X, -1), snap(lo.Y, -1), snap(lo.Z, -1))
	hi = Vector3.new(snap(hi.X, 1), snap(hi.Y, 1), snap(hi.Z, 1))
	local air, water = Enum.Material.Air, Enum.Material.Water
	local pad = Vector3.one * PAD
	for bz = lo.Z, hi.Z - 1, TERRAIN_BLOCK do
		for by = lo.Y, hi.Y - 1, TERRAIN_BLOCK do
			for bx = lo.X, hi.X - 1, TERRAIN_BLOCK do
				local blockLo = Vector3.new(bx, by, bz)
				local blockHi = Vector3.new(min(bx + TERRAIN_BLOCK, hi.X), min(by + TERRAIN_BLOCK, hi.Y), min(bz + TERRAIN_BLOCK, hi.Z))
				local ok, materials = pcall(terrain.ReadVoxels, terrain, Region3.new(blockLo, blockHi), FINE)
				if ok then
					local size = materials.Size
					for z = 1, size.Z do
						for y = 1, size.Y do
							local runStart: number? = nil
							for x = 1, size.X + 1 do
								local material = if x <= size.X then materials[x][y][z] else air
								local solid = material ~= air and material ~= water
								if solid and not runStart then
									runStart = x
								elseif not solid and runStart then
									local voxelLo = blockLo + Vector3.new((runStart - 1) * FINE, (y - 1) * FINE, (z - 1) * FINE)
									local voxelHi = blockLo + Vector3.new((x - 1) * FINE, y * FINE, z * FINE)
									markStatic(voxelLo - pad, voxelHi + pad)
									runStart = nil
								end
							end
						end
					end
				else
					warn("[Projectile] occupancy: terrain read failed, that area stays unscanned:", materials)
				end
				task.wait()
			end
		end
	end
end

-- The area to scan: the map's anchored parts plus a margin, or the default area.
local function terrainScanArea(parts: { BasePart }): (Vector3, Vector3)
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, part in parts do
		if part.Parent and part.Anchored then
			lo, hi = lo:Min(part.Position), hi:Max(part.Position)
		end
	end
	if lo.X > hi.X then
		return TERRAIN_DEFAULT_MIN, TERRAIN_DEFAULT_MAX
	end
	local margin = Vector3.one * TERRAIN_AROUND_PARTS
	return lo - margin, hi + margin
end

--------------------------------------------------------------------------------
-- Startup: watch first (so nothing appears unseen), then bake in batches
--------------------------------------------------------------------------------

workspace.DescendantAdded:Connect(function(instance)
	if instance:IsA("BasePart") then
		-- dynamic until proven anchored: never skip past a part spawned this frame
		makeDynamic(instance)
		task.defer(function()
			if instance.Parent then
				classify(instance)
			end
		end)
	end
end)
workspace.DescendantRemoving:Connect(function(instance)
	if instance:IsA("BasePart") then
		dynamicParts[instance] = nil
		staticMoves[instance] = nil
		queryWatched[instance] = nil
		ownerOf[instance] = nil
		shaped[instance] = nil
		publishedParts[instance] = nil
		dirtyParts[instance] = nil
		watched[instance] = nil
	elseif instance:IsA("JointInstance") or instance:IsA("WeldConstraint") then
		jointRemoved(instance)
	end
end)

task.spawn(function()
	local started = os.clock()
	local parts = {}
	for _, descendant in workspace:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	for index, part in parts do
		if part.Parent then
			classify(part)
		end
		if index % BAKE_BATCH == 0 then
			task.wait()
		end
	end
	startupDone = true
	if isWorker then
		ready = importedReady
		return -- startup classification only; static masks come from the publisher
	end
	local ok, cells = pcall(function()
		return workspace.Terrain:CountCells()
	end)
	if not ok or cells > 0 then
		hasTerrain = true
		terrainMin, terrainMax = terrainScanArea(parts)
		publish() -- unready snapshot: terrain must remain conservative until scanned
		Occupancy.BakeTerrain(terrainMin, terrainMax)
	end
	ready = true
	publish()
	print(string.format("[Projectile] occupancy base baked once: %d parts%s, %d cells, %.0f ms (shape refinement continues safely in background)", #parts,
		if hasTerrain then " + terrain" else "", stats.StaticCells, (os.clock() - started) * 1000))
end)

return Occupancy
