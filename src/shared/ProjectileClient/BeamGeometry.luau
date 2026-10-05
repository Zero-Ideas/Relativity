--!strict
-- Pure geometry union for a sustained channel. Overlapping collinear packet
-- tails become one cylinder, not stacked bars/glow. Distinct paths stay
-- distinct: never invent a connecting chord through untraveled geometry.
local Geometry = {}
Geometry.MaxSegmentLength = 12

-- Tessellate after union, so overlaps are removed but no pooled cylinder can
-- grow into an enormous bar on a flick or a stretched time-field boundary.
function Geometry.Split(segments: { any }): { any }
	local result = {}
	for _, span in segments do
		local a, b = span[1], span[2]
		local count = math.max(1, math.ceil((b-a).Magnitude/(Geometry.MaxSegmentLength-.01)))
		for index = 1, count do
			table.insert(result, { a:Lerp(b,(index-1)/count), a:Lerp(b,index/count) })
		end
	end
	return result
end

function Geometry.Merge(paths: { any }, radius: number): ({ any }, { Vector3 })
	local families: { [string]: any } = {}
	local order: { any } = {}
	local tolerance = math.max(radius * .15, .005)
	local function quant(value: number, scale: number): number return math.floor(value / scale + .5) end
	for _, points in paths do
		-- A point is a control endpoint, not a beam body. Rounded caps are
		-- generated only for nonzero segments below; singleton snapshots must
		-- not leave floating glow dots (especially after retirement/freeze).
		for index = 1, #points - 1 do
			local a, b = points[index], points[index + 1]
			local offset = b - a
			if offset.Magnitude < 1e-4 then continue end
			local direction = offset.Unit
			local abs = Vector3.new(math.abs(direction.X), math.abs(direction.Y), math.abs(direction.Z))
			local main = if abs.X >= abs.Y and abs.X >= abs.Z then direction.X elseif abs.Y >= abs.Z then direction.Y else direction.Z
			if main < 0 then direction = -direction end
			local directionKey = `{quant(direction.X, 1/4096)}:{quant(direction.Y, 1/4096)}:{quant(direction.Z, 1/4096)}`
			local family = families[directionKey]
			if not family then
				family = { direction = direction, cells = {} }
				families[directionKey] = family
			end
			-- Use one representative direction for spatial hashing. Computing a
			-- perpendicular origin with EACH segment's float-rounded direction
			-- amplified tiny angle errors at long range and split a straight beam
			-- back into dozens of bars. Neighbor cells handle grid boundaries.
			local origin = a - family.direction * a:Dot(family.direction)
			local x, y, z = quant(origin.X, tolerance), quant(origin.Y, tolerance), quant(origin.Z, tolerance)
			local function cellKey(dx, dy, dz) return `{x+dx}:{y+dy}:{z+dz}` end
			local function fits(candidate)
				for _, point in { a, b } do
					local delta = point - candidate.origin
					if (delta - candidate.direction * delta:Dot(candidate.direction)).Magnitude > tolerance then return false end
				end
				return true
			end
			local bucket
			local key = cellKey(0,0,0)
			for _, candidate in family.cells[key] or {} do if fits(candidate) then bucket = candidate; break end end
			if not bucket then
				for dx = -1, 1 do
					for dy = -1, 1 do
						for dz = -1, 1 do
							for _, candidate in family.cells[cellKey(dx,dy,dz)] or {} do
								if fits(candidate) then bucket = candidate; break end
							end
							if bucket then break end
						end
						if bucket then break end
					end
					if bucket then break end
				end
			end
			if not bucket then
				bucket = { key = directionKey .. ":" .. key .. ":" .. tostring(#order + 1), origin = a, direction = direction, intervals = {} }
				local cell = family.cells[key]
				if not cell then cell = {}; family.cells[key] = cell end
				table.insert(cell, bucket)
				table.insert(order, bucket)
			end
			local from = (a - bucket.origin):Dot(bucket.direction)
			local to = (b - bucket.origin):Dot(bucket.direction)
			table.insert(bucket.intervals, { math.min(from, to), math.max(from, to) })
		end
	end
	table.sort(order, function(a, b) return a.key < b.key end)
	local segments, joints, seenJoints = {}, {}, {}
	local function addJoint(point: Vector3)
		local key = `{quant(point.X,tolerance)}:{quant(point.Y,tolerance)}:{quant(point.Z,tolerance)}`
		if not seenJoints[key] then seenJoints[key] = true; table.insert(joints, point) end
	end
	local function add(bucket, from, to)
		local a = bucket.origin + bucket.direction * from
		local b = bucket.origin + bucket.direction * to
		table.insert(segments, { a, b })
		for _, point in { a, b } do
			addJoint(point)
		end
	end
	for _, bucket in order do
		table.sort(bucket.intervals, function(a, b) return a[1] < b[1] end)
		local from, to = bucket.intervals[1][1], bucket.intervals[1][2]
		for index = 2, #bucket.intervals do
			local interval = bucket.intervals[index]
			if interval[1] <= to + tolerance then to = math.max(to, interval[2])
			else add(bucket, from, to); from, to = interval[1], interval[2] end
		end
		add(bucket, from, to)
	end
	return Geometry.Split(segments), joints
end

return Geometry
