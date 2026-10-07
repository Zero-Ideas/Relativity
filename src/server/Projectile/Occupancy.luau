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
	identical cells along a floor or wall cost one table slot each -- which
	matters because every parallel projectile worker bakes its own copy. Every part is marked by its world AABB grown by PAD
	studs, which is what makes a centreline walk safe for sphere sweeps up to
	MaxRadius: any surface within that distance of the path lies in a marked
	voxel on the path. Marks are only ever added (a moved static part is
	re-marked at its new place, never cleared at the old one), so staleness
	can only cost a skipped skip, never a missed hit.

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
local dynamic: { [number]: boolean } = {} -- coarse key -> something moving there this frame
local dynamicParts: { [BasePart]: boolean } = {}
local staticMoves: { [BasePart]: number } = {}
local watchedRoots: { [BasePart]: { BasePart } } = {} -- anchored root -> parts welded to it
local dynamicStamp = -1 -- workspace.DistributedGameTime the dynamic marks belong to
local ready = false
-- While the map has terrain: the scanned area; outside it nothing is skipped.
local hasTerrain = false
local terrainMin, terrainMax = Vector3.zero, Vector3.zero

local stats = { Checks = 0, Skipped = 0, Coarse = 0, StaticCells = 0, DistinctMasks = 1, DynamicParts = 0 }

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
					static[k] = FULL
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
				static[k] = intern(scratch)
			end
		end
	end
end

local function markDynamicBox(lo: Vector3, hi: Vector3)
	for cz = floor(lo.Z / COARSE), floor(hi.Z / COARSE) do
		for cy = floor(lo.Y / COARSE), floor(hi.Y / COARSE) do
			for cx = floor(lo.X / COARSE), floor(hi.X / COARSE) do
				dynamic[cellKey(cx, cy, cz)] = true
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
	for part in dynamicParts do
		if not part.Parent then
			dynamicParts[part] = nil
			continue
		end
		count += 1
		local reach = PAD + DYNAMIC_MARGIN + part.AssemblyLinearVelocity.Magnitude * DYNAMIC_LOOKAHEAD
		local lo, hi = bounds(part, reach)
		markDynamicBox(lo, hi)
	end
	stats.DynamicParts = count
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

function classify(part: BasePart)
	if part:IsA("Terrain") or not part:IsDescendantOf(workspace) then
		return
	end
	local root = part.AssemblyRootPart
	local anchored = part.Anchored or (root ~= nil and root.Anchored)
	if not anchored or inCharacter(part) then
		makeDynamic(part)
		return
	end
	dynamicParts[part] = nil
	local lo, hi = bounds(part, PAD)
	markStatic(lo, hi)
	watchStatic(part)
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
	if dynamic[k] then
		return true
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
	return dynamic[k] == true or static[k] ~= nil
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
function Occupancy.SegmentClear(origin: Vector3, displacement: Vector3, radius: number): boolean
	stats.Checks += 1
	if not ready or not Occupancy.Enabled or radius > Occupancy.MaxRadius then
		return false
	end
	if hasTerrain and not insideTerrainScan(origin, origin + displacement) then
		return false
	end
	refreshDynamic()
	if walk(origin, displacement, COARSE, coarseOccupied) then
		stats.Coarse += 1
		if walk(origin, displacement, FINE, fineOccupied) then
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
	local ok, cells = pcall(function()
		return workspace.Terrain:CountCells()
	end)
	if not ok or cells > 0 then
		hasTerrain = true
		terrainMin, terrainMax = terrainScanArea(parts)
		Occupancy.BakeTerrain(terrainMin, terrainMax)
	end
	ready = true
	print(string.format("[Projectile] occupancy baked: %d parts%s, %d cells, %.0f ms", #parts,
		if hasTerrain then " + terrain" else "", stats.StaticCells, (os.clock() - started) * 1000))
end)

return Occupancy
