--!strict
-- Shared *physical* centerline of a continuous stream. A newer sample is the
-- back of its section; the preceding sample is its front. Turning the input
-- therefore bends the stream instead of emitting unrelated parallel bars.
-- Shared projectile geometry: both server collision and client cylinders use
-- these exact endpoints. Kept replicated because the client needs the same math.
local BeamPath = {}
BeamPath.MaxStretch = 32
BeamPath.MaxJoinersPerLink = 32

export type Joiner = { Position: Vector3 }

-- Plan against the real bounce corners, never a shortcut through a wall.
-- Count before allocating joiners so a huge flick is rejected in bounded work.
function BeamPath.Plan(back: Vector3, front: Vector3, backTurns: { Vector3 }?, frontTurns: { Vector3 }?): ({ Vector3 }?, number)
	local behind, ahead = backTurns or {}, frontTurns or {}
	if #behind > #ahead then return nil, 0 end
	local corners = { back }
	local count = 0
	local function append(point: Vector3): boolean
		local distance = (point - corners[#corners]).Magnitude
		if distance <= 1e-4 then return true end
		count += math.max(math.ceil(distance / BeamPath.MaxStretch) - 1, 0)
		if count > BeamPath.MaxJoinersPerLink then return false end
		table.insert(corners, point)
		return true
	end
	for index = #behind + 1, #ahead do
		if not append(ahead[index]) then return nil, count end
	end
	if not append(front) then return nil, count end
	return corners, count
end

-- Pool only lightweight control points: no projectile, Instance, damage
-- handler or thread per joiner. Retained pool entries are reused after shrink.
function BeamPath.Fill(corners: { Vector3 }, pool: { Joiner }?, output: { Vector3 }?, cornerIndices: { number }?): { Vector3 }
	local points = output or {}
	table.clear(points)
	if cornerIndices then table.clear(cornerIndices); table.insert(cornerIndices, 1) end
	table.insert(points, corners[1])
	local used = 0
	for index = 1, #corners - 1 do
		local a, b = corners[index], corners[index + 1]
		local pieces = math.max(1, math.ceil((b - a).Magnitude / BeamPath.MaxStretch))
		for piece = 1, pieces - 1 do
			local position = a:Lerp(b, piece / pieces)
			used += 1
			if pool then
				local joiner = pool[used]
				if not joiner then joiner = { Position = position }; pool[used] = joiner
				else joiner.Position = position end
			end
			table.insert(points, position)
		end
		table.insert(points, b)
		if cornerIndices then table.insert(cornerIndices, #points) end
	end
	return points
end

-- Joiners are deterministic collinear subdivisions. Send only real corners
-- and the clipped endpoint, not a larger network payload for every joiner.
-- The index map preserves exact bends without approximate angle tests.
function BeamPath.Compact(points: { Vector3 }, cornerIndices: { number }?): { Vector3 }
	if not cornerIndices or #points <= 2 then return points end
	local result = { points[1] }
	for index = 2, #cornerIndices do
		local at = cornerIndices[index]
		if at >= #points then break end
		table.insert(result, points[at])
	end
	if (points[#points] - result[#result]).Magnitude > 1e-4 then table.insert(result, points[#points]) end
	return result
end

function BeamPath.Connect(back: Vector3, front: Vector3, backTurns: { Vector3 }?, frontTurns: { Vector3 }?): { Vector3 }?
	local corners = BeamPath.Plan(back, front, backTurns, frontTurns)
	return if corners then BeamPath.Fill(corners) else nil
end

return BeamPath
