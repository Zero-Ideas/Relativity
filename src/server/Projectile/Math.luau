--!optimize 2
--[[
	Projectile/Math.luau
	Pure geometry helpers shared by the other Projectile server modules
	(Homing, Raycast, RewindHit). No projectile/entity state, no side effects.
]]

local Math = {}

function Math.safeUnit(v: Vector3, fallback: Vector3): Vector3
	local magnitude = v.Magnitude
	if magnitude < 1e-5 then
		return fallback
	end
	return v / magnitude
end

-- Rotate `from` toward `to` by at most `maxAngle` radians, preserving length.
function Math.rotateTowards(from: Vector3, to: Vector3, maxAngle: number): Vector3
	local fromDir = Math.safeUnit(from, Vector3.zAxis)
	local toDir = Math.safeUnit(to, fromDir)
	local dot = math.clamp(fromDir:Dot(toDir), -1, 1)
	local angle = math.acos(dot)
	if angle <= maxAngle or angle < 1e-4 then
		return toDir
	end
	local axis = fromDir:Cross(toDir)
	if axis.Magnitude < 1e-4 then
		-- opposite directions: pick an arbitrary perpendicular axis
		axis = math.abs(fromDir.Y) < 0.99 and fromDir:Cross(Vector3.yAxis) or fromDir:Cross(Vector3.xAxis)
	end
	axis = axis.Unit
	return CFrame.fromAxisAngle(axis, maxAngle):VectorToWorldSpace(fromDir)
end

-- Closest point on segment [a,b] to point p, and the distance to it. Used by
-- lag-compensated hit detection to test a rewound entity position against a
-- substep's movement segment.
function Math.closestPointOnSegment(p: Vector3, a: Vector3, b: Vector3): (Vector3, number)
	local ab = b - a
	local lengthSq = ab:Dot(ab)
	local t = lengthSq > 1e-8 and math.clamp((p - a):Dot(ab) / lengthSq, 0, 1) or 0
	local closest = a + ab * t
	return closest, (p - closest).Magnitude
end

function Math.coneDirection(dir: Vector3, spreadDeg: number): Vector3
	if spreadDeg <= 0 then
		return dir
	end
	local spread = math.rad(spreadDeg)
	-- sqrt for an even areal distribution across the cone
	local theta = math.sqrt(math.random()) * spread
	local roll = math.random() * 2 * math.pi
	local up = math.abs(dir.Y) < 0.99 and Vector3.yAxis or Vector3.xAxis
	local right = dir:Cross(up).Unit
	local realUp = right:Cross(dir).Unit
	local radial = (right * math.cos(roll) + realUp * math.sin(roll)) * math.tan(theta)
	return Math.safeUnit(dir + radial, dir)
end

return Math
