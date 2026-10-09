--!strict
--!native
--!optimize 2
--[[
	BarrierShapes.luau (shared: the server judges, clients watch -- client/BarrierWatch)
	Spots phallic sculptures built out of spell barriers (one player's or
	several players' together). Barriers are the only thing looked at -- the
	map never is -- and only when new ones appear, so it costs nothing per
	frame.

	How a group is judged:
	 1. Cluster: every live barrier touching (bounding spheres within GAP)
	    the new one, whoever cast it. Fewer than MIN_PARTS: nothing to judge.
	 2. Voxelize: the cluster's solid silhouette on a grid sized to the
	    cluster (about GRID cells along its longest side). Domes and spheres
	    count as solid, rings as solid cylinders: a hollow outline still
	    reads as its outline.
	 3. For each principal axis (PCA of the voxels) and each end as the base,
	    slice it into SLICES slabs and test the profile:
	     - shaft: the middle slabs are all filled, about one width
	       (max/min <= SHAFT_VARIATION), and the whole thing is at least
	       ELONGATION shaft widths long;
	     - base: the base slabs are at least BASE_WIDE shaft widths across,
	       side by side (much wider one way than the other: BASE_FLAT -- a
	       pedestal is wide both ways), with mass on BOTH sides of the
	       shaft beyond its edge (each side >= LOBE_SHARE of the base, the
	       two within LOBE_BALANCE), and each side roughly round in the
	       plane of the shape (not a long flat bar: that's a "⊥", not lobes);
	     - tip: no wider than TIP_WIDE shaft widths (not a "T" / mushroom).
	    Any axis and end that passes flags the cluster.

	Expect some false positives (a tower flanked by two domes really is
	that shape) and misses (players adapt). SpellWorld's response is gentle
	for that reason: dissolve, tell the casters, and only after repeated
	flags a short barrier cooldown.

	BarrierShapes.Analyze(primitives) -> (flagged, report)
	  primitive: { Frame: CFrame, Shape: "Box"|"Dome"|"Sphere"|"Ring", Size: Vector3 }
	BarrierShapes.AnalyzeLayout(primitives) -> (flagged, report)
	  splits a whole layout (every barrier one spell would raise) into
	  touching clusters and judges each: SpellService's per-spell check
	BarrierShapes.Clusters(primitives) -> { { index } }
	  the touching clusters themselves (indices into primitives)
	BarrierShapes.Bound(primitive) -> number   -- bounding-sphere radius
]]

local BarrierShapes = {}

BarrierShapes.Enabled = true
BarrierShapes.MIN_PARTS = 2
BarrierShapes.MIN_LENGTH = 8 -- studs: anything smaller is ignored
BarrierShapes.GAP = 2 -- studs between bounding spheres that still counts as touching

local GRID = 28 -- cells along the cluster's longest side
local MIN_VOXEL = 0.4
local MAX_TESTS = 400000 -- inside-tests per analysis (worst case ~10 ms)
local SLICES = 16
local BASE_TO = 4 -- slabs [0, BASE_TO) are the base
local SHAFT_FROM, SHAFT_TO = 6, 12 -- [SHAFT_FROM, SHAFT_TO] must be shaft
local TIP_FROM = 13
local ELONGATION = 3
local SHAFT_VARIATION = 1.8
local BASE_WIDE = 1.7
local TIP_WIDE = 1.7
local LOBE_SHARE = 0.15
local LOBE_BALANCE = 0.4
local LOBE_ROUND = 2.8 -- max ratio of a lobe's extents in the shape's plane
local BASE_FLAT = 0.75 -- the base's depth / its width at most: side by side, not a pedestal

export type Primitive = { Frame: CFrame, Shape: string, Size: Vector3 }
export type Report = {
	Voxels: number,
	Voxel: number,
	Length: number?,
	ShaftWidth: number?,
	BaseWidth: number?,
	TipWidth: number?,
	Lobes: { number }?,
	Ms: number,
}

local function halfExtents(p: Primitive): Vector3
	local size = p.Size
	if p.Shape == "Box" then
		return size / 2
	end
	return Vector3.new(size.X / 2, size.Y / 2, size.X / 2)
end

function BarrierShapes.Bound(p: Primitive): number
	return halfExtents(p).Magnitude
end

local function inside(p: Primitive, l: Vector3, h: Vector3): boolean
	local shape = p.Shape
	if shape == "Box" then
		return math.abs(l.X) <= h.X and math.abs(l.Y) <= h.Y and math.abs(l.Z) <= h.Z
	elseif shape == "Ring" then
		return math.abs(l.Y) <= h.Y and l.X * l.X + l.Z * l.Z <= h.X * h.X
	elseif shape == "Dome" then
		-- an ellipsoid cap: base at -h.Y, radius h.X, height 2 h.Y
		local y = l.Y + h.Y
		if y < 0 then
			return false
		end
		local ry = h.Y * 2
		return (l.X / h.X) ^ 2 + (y / ry) ^ 2 + (l.Z / h.X) ^ 2 <= 1
	else -- Sphere
		return (l.X / h.X) ^ 2 + (l.Y / h.Y) ^ 2 + (l.Z / h.X) ^ 2 <= 1
	end
end

local function worldBox(p: Primitive): (Vector3, Vector3)
	local h = halfExtents(p)
	local f = p.Frame
	-- |R| * h: the world half-size of a rotated box
	local ex = math.abs(f.RightVector.X) * h.X + math.abs(f.UpVector.X) * h.Y + math.abs(f.LookVector.X) * h.Z
	local ey = math.abs(f.RightVector.Y) * h.X + math.abs(f.UpVector.Y) * h.Y + math.abs(f.LookVector.Y) * h.Z
	local ez = math.abs(f.RightVector.Z) * h.X + math.abs(f.UpVector.Z) * h.Y + math.abs(f.LookVector.Z) * h.Z
	local e = Vector3.new(ex, ey, ez)
	return f.Position - e, f.Position + e
end

-- Eigenvectors of a symmetric 3x3 (Jacobi rotations).
local function principalAxes(c: { { number } }): { Vector3 }
	local a = { { c[1][1], c[1][2], c[1][3] }, { c[2][1], c[2][2], c[2][3] }, { c[3][1], c[3][2], c[3][3] } }
	local v = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
	for _ = 1, 24 do
		-- largest off-diagonal
		local p, q = 1, 2
		local best = math.abs(a[1][2])
		if math.abs(a[1][3]) > best then
			p, q, best = 1, 3, math.abs(a[1][3])
		end
		if math.abs(a[2][3]) > best then
			p, q, best = 2, 3, math.abs(a[2][3])
		end
		if best < 1e-9 then
			break
		end
		local theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
		local t = (if theta >= 0 then 1 else -1) / (math.abs(theta) + math.sqrt(theta * theta + 1))
		local cs = 1 / math.sqrt(t * t + 1)
		local sn = t * cs
		for k = 1, 3 do
			local akp, akq = a[k][p], a[k][q]
			a[k][p] = cs * akp - sn * akq
			a[k][q] = sn * akp + cs * akq
		end
		for k = 1, 3 do
			local apk, aqk = a[p][k], a[q][k]
			a[p][k] = cs * apk - sn * aqk
			a[q][k] = sn * apk + cs * aqk
		end
		for k = 1, 3 do
			local vkp, vkq = v[k][p], v[k][q]
			v[k][p] = cs * vkp - sn * vkq
			v[k][q] = sn * vkp + cs * vkq
		end
	end
	return {
		Vector3.new(v[1][1], v[2][1], v[3][1]).Unit,
		Vector3.new(v[1][2], v[2][2], v[3][2]).Unit,
		Vector3.new(v[1][3], v[2][3], v[3][3]).Unit,
	}
end

type Slab = { n: number, minB: number, maxB: number, minC: number, maxC: number, sumB: number, sumC: number }

local function median(values: { number }): number
	table.sort(values)
	return values[(#values + 1) // 2]
end

-- The profile test along `a` (b, c: the other two axes), base at the low
-- end when `flip` is false.
local function profile(points: { Vector3 }, voxel: number, a: Vector3, b: Vector3, c: Vector3, flip: boolean, report: Report): boolean
	local n = #points
	local ta, tb, tc = table.create(n, 0), table.create(n, 0), table.create(n, 0)
	local lo, hi = math.huge, -math.huge
	for i, p in points do
		local x = p:Dot(a)
		if flip then
			x = -x
		end
		ta[i], tb[i], tc[i] = x, p:Dot(b), p:Dot(c)
		lo, hi = math.min(lo, x), math.max(hi, x)
	end
	local length = hi - lo + voxel
	if length < BarrierShapes.MIN_LENGTH then
		return false
	end
	local slabs: { Slab } = {}
	for s = 0, SLICES - 1 do
		slabs[s] = { n = 0, minB = math.huge, maxB = -math.huge, minC = math.huge, maxC = -math.huge, sumB = 0, sumC = 0 }
	end
	local slabOf = table.create(n, 0)
	for i = 1, n do
		local s = math.clamp(math.floor((ta[i] - lo) / (hi - lo + 1e-6) * SLICES), 0, SLICES - 1)
		slabOf[i] = s
		local slab = slabs[s]
		slab.n += 1
		local y, z = tb[i], tc[i]
		if y < slab.minB then slab.minB = y end
		if y > slab.maxB then slab.maxB = y end
		if z < slab.minC then slab.minC = z end
		if z > slab.maxC then slab.maxC = z end
		slab.sumB += y
		slab.sumC += z
	end
	local function width(s: number): number
		local slab = slabs[s]
		if slab.n == 0 then
			return 0
		end
		return math.max(slab.maxB - slab.minB, slab.maxC - slab.minC) + voxel
	end

	-- shaft
	local widths, centresB, centresC = {}, {}, {}
	local thinnest, thickest = math.huge, 0
	for s = SHAFT_FROM, SHAFT_TO do
		local slab = slabs[s]
		if slab.n == 0 then
			return false
		end
		local w = width(s)
		table.insert(widths, w)
		table.insert(centresB, slab.sumB / slab.n)
		table.insert(centresC, slab.sumC / slab.n)
		thinnest, thickest = math.min(thinnest, w), math.max(thickest, w)
	end
	if thickest > thinnest * SHAFT_VARIATION then
		return false
	end
	local shaft = median(widths)
	if length < shaft * ELONGATION then
		return false
	end

	-- tip
	local tip = 0
	for s = TIP_FROM, SLICES - 1 do
		tip = math.max(tip, width(s))
	end
	if tip > shaft * TIP_WIDE then
		return false
	end

	-- base: wide, with a roughly round lobe either side of the shaft
	local base = 0
	local spreadB, spreadC = 0, 0
	for s = 0, BASE_TO - 1 do
		base = math.max(base, width(s))
		local slab = slabs[s]
		if slab.n > 0 then
			spreadB = math.max(spreadB, slab.maxB - slab.minB)
			spreadC = math.max(spreadC, slab.maxC - slab.minC)
		end
	end
	if base < shaft * BASE_WIDE then
		return false
	end
	local wideIsB = spreadB >= spreadC
	-- two lobes sit side by side: wide one way, about a lobe deep the other
	-- (a square or round pedestal is wide both ways)
	if math.min(spreadB, spreadC) > math.max(spreadB, spreadC) * BASE_FLAT then
		return false
	end
	local centre = if wideIsB then median(centresB) else median(centresC)
	local edge = shaft * 0.5
	local counts = { 0, 0 }
	local dMin, dMax = { math.huge, math.huge }, { -math.huge, -math.huge }
	local aMin, aMax = { math.huge, math.huge }, { -math.huge, -math.huge }
	local baseCount = 0
	for i = 1, n do
		if slabOf[i] < BASE_TO then
			baseCount += 1
			local d = (if wideIsB then tb[i] else tc[i]) - centre
			local side = if d < -edge then 1 elseif d > edge then 2 else 0
			if side > 0 then
				counts[side] += 1
				local ad = math.abs(d)
				dMin[side], dMax[side] = math.min(dMin[side], ad), math.max(dMax[side], ad)
				aMin[side], aMax[side] = math.min(aMin[side], ta[i]), math.max(aMax[side], ta[i])
			end
		end
	end
	if baseCount == 0 then
		return false
	end
	local left, right = counts[1], counts[2]
	if left < baseCount * LOBE_SHARE or right < baseCount * LOBE_SHARE then
		return false
	end
	if math.min(left, right) < math.max(left, right) * LOBE_BALANCE then
		return false
	end
	for side = 1, 2 do
		-- in-plane extents: outward from the shaft, and along the shaft
		-- (the lobe's full height, not just the base slabs')
		local across = dMax[side] - dMin[side] + voxel
		local along = aMax[side] - aMin[side] + voxel
		if math.max(across, along) > math.min(across, along) * LOBE_ROUND then
			return false
		end
	end

	report.Length, report.ShaftWidth, report.BaseWidth, report.TipWidth = length, shaft, base, tip
	report.Lobes = { left, right }
	return true
end

function BarrierShapes.Analyze(primitives: { Primitive }): (boolean, Report)
	local started = os.clock()
	local report: Report = { Voxels = 0, Voxel = 0, Ms = 0 }
	if not BarrierShapes.Enabled or #primitives < BarrierShapes.MIN_PARTS then
		return false, report
	end
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	local boxes = {}
	for i, p in primitives do
		local a, b = worldBox(p)
		boxes[i] = { a, b }
		lo, hi = lo:Min(a), hi:Max(b)
	end
	local extent = hi - lo
	local longest = math.max(extent.X, extent.Y, extent.Z)
	if longest < BarrierShapes.MIN_LENGTH then
		return false, report
	end
	local voxel = math.max(longest / GRID, MIN_VOXEL)
	local nx = math.floor(extent.X / voxel) + 1
	local ny = math.floor(extent.Y / voxel) + 1

	-- solid silhouette: one entry per filled cell
	local filled: { [number]: boolean } = {}
	local points: { Vector3 } = {}
	local tests = 0
	for i, p in primitives do
		local h = halfExtents(p)
		local inverse = p.Frame:Inverse()
		local a, b = boxes[i][1], boxes[i][2]
		local x0, x1 = math.floor((a.X - lo.X) / voxel), math.floor((b.X - lo.X) / voxel)
		local y0, y1 = math.floor((a.Y - lo.Y) / voxel), math.floor((b.Y - lo.Y) / voxel)
		local z0, z1 = math.floor((a.Z - lo.Z) / voxel), math.floor((b.Z - lo.Z) / voxel)
		for x = x0, x1 do
			for y = y0, y1 do
				for z = z0, z1 do
					tests += 1
					if tests > MAX_TESTS then
						break
					end
					local key = (z * ny + y) * nx + x
					if not filled[key] then
						local world = lo + Vector3.new(x + 0.5, y + 0.5, z + 0.5) * voxel
						if inside(p, inverse * world, h) then
							filled[key] = true
							table.insert(points, world)
						end
					end
				end
			end
		end
	end
	report.Voxels, report.Voxel = #points, voxel
	if #points < 20 then
		report.Ms = (os.clock() - started) * 1000
		return false, report
	end

	-- centre and principal axes
	local mean = Vector3.zero
	for _, p in points do
		mean += p
	end
	mean /= #points
	local sxx, syy, szz, sxy, sxz, syz = 0, 0, 0, 0, 0, 0
	for i, p in points do
		local d = p - mean
		points[i] = d
		sxx += d.X * d.X
		syy += d.Y * d.Y
		szz += d.Z * d.Z
		sxy += d.X * d.Y
		sxz += d.X * d.Z
		syz += d.Y * d.Z
	end
	local axes = principalAxes({ { sxx, sxy, sxz }, { sxy, syy, syz }, { sxz, syz, szz } })

	local flagged = false
	for i = 1, 3 do
		local a, b, c = axes[i], axes[i % 3 + 1], axes[(i + 1) % 3 + 1]
		if profile(points, voxel, a, b, c, false, report) or profile(points, voxel, a, b, c, true, report) then
			flagged = true
			break
		end
	end
	report.Ms = (os.clock() - started) * 1000
	return flagged, report
end

-- The touching clusters of `primitives` (bounding spheres within GAP,
-- transitively), as lists of indices; at most MAX_LAYOUT primitives looked at.
local MAX_LAYOUT = 200
function BarrierShapes.Clusters(primitives: { Primitive }): { { number } }
	local count = math.min(#primitives, MAX_LAYOUT)
	local bounds = table.create(count, 0)
	for i = 1, count do
		bounds[i] = BarrierShapes.Bound(primitives[i])
	end
	local clusters = {}
	local seen = table.create(count, false)
	for seed = 1, count do
		if seen[seed] then
			continue
		end
		seen[seed] = true
		local members = { seed }
		local index = 1
		while index <= #members do
			local current = members[index]
			local position = primitives[current].Frame.Position
			for other = 1, count do
				if not seen[other] and (primitives[other].Frame.Position - position).Magnitude
					<= bounds[current] + bounds[other] + BarrierShapes.GAP then
					seen[other] = true
					table.insert(members, other)
				end
			end
			index += 1
		end
		table.insert(clusters, members)
	end
	return clusters
end

-- Every touching cluster of `primitives`, each judged on its own; flagged
-- if any one is.
function BarrierShapes.AnalyzeLayout(primitives: { Primitive }): (boolean, Report)
	local report: Report = { Voxels = 0, Voxel = 0, Ms = 0 }
	if not BarrierShapes.Enabled or #primitives < BarrierShapes.MIN_PARTS then
		return false, report
	end
	for _, members in BarrierShapes.Clusters(primitives) do
		if #members >= BarrierShapes.MIN_PARTS then
			local cluster = table.create(#members)
			for _, index in members do
				table.insert(cluster, primitives[index])
			end
			local flagged, clusterReport = BarrierShapes.Analyze(cluster)
			if flagged then
				return true, clusterReport
			end
		end
	end
	return false, report
end

return BarrierShapes
