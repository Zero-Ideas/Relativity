--!native
--!strict
--!optimize 2
--[[
	Projectile/Math.luau
	Pure geometry helpers shared by the other Projectile server modules
	(Homing, RewindHit, init). No projectile/entity state, no side effects.
	Finite-number guards live in Shared.SafeMath.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local SafeMath = require(Shared:WaitForChild("SafeMath"))

local Math = {}

-- Rotate `from` toward `to` by at most `maxAngle` radians; returns a unit vector.
function Math.rotateTowards(from: Vector3, to: Vector3, maxAngle: number): Vector3
	local fromDir = SafeMath.direction(from, Vector3.zAxis)
	local toDir = SafeMath.direction(to, fromDir)
	local dot = math.clamp(fromDir:Dot(toDir), -1, 1)
	local angle = math.acos(dot)
	if angle <= maxAngle or angle < 1e-4 then
		return toDir
	end
	local axis = fromDir:Cross(toDir)
	if axis.Magnitude < 1e-4 then
		-- opposite directions: pick an arbitrary perpendicular axis
		axis = if math.abs(fromDir.Y) < 0.99 then fromDir:Cross(Vector3.yAxis) else fromDir:Cross(Vector3.xAxis)
	end
	return CFrame.fromAxisAngle(axis.Unit, maxAngle):VectorToWorldSpace(fromDir)
end

-- Closest point on segment [a,b] to point p, and the distance to it. Used by
-- lag-compensated hit detection to test a rewound entity position against a
-- substep's movement segment.
function Math.closestPointOnSegment(p: Vector3, a: Vector3, b: Vector3): (Vector3, number)
	local ab = b - a
	local lengthSq = ab:Dot(ab)
	local t = if lengthSq > 1e-8 then math.clamp((p - a):Dot(ab) / lengthSq, 0, 1) else 0
	local closest = a + ab * t
	return closest, (p - closest).Magnitude
end

-- How far along the chord from `from` to `from + displacement` the point
-- lies, as a 0..1 fraction (0 for a degenerate chord).
function Math.chordFraction(from: Vector3, displacement: Vector3, point: Vector3): number
	local lengthSq = displacement:Dot(displacement)
	if not (lengthSq >= 1e-10) then
		return 0
	end
	return math.clamp((point - from):Dot(displacement) / lengthSq, 0, 1)
end

-- Uniformly random direction within `spreadDeg` of the unit vector `dir`.
function Math.coneDirection(dir: Vector3, spreadDeg: number): Vector3
	if not (spreadDeg > 0) then
		return dir
	end
	local spread = math.rad(math.min(spreadDeg, 180))
	-- sqrt for an even areal distribution across the cone
	local theta = math.sqrt(math.random()) * spread
	local roll = math.random() * 2 * math.pi
	local up = if math.abs(dir.Y) < 0.99 then Vector3.yAxis else Vector3.xAxis
	local right = dir:Cross(up).Unit
	local realUp = right:Cross(dir).Unit
	-- Rotate rather than offset by tan(theta): tan blows up toward 90 degrees.
	local radial = right * math.cos(roll) + realUp * math.sin(roll)
	return SafeMath.direction(dir * math.cos(theta) + radial * math.sin(theta), dir)
end

return Math
