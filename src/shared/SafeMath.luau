--!strict
--!optimize 2
--[[
	SafeMath.luau
	Finite-number guards for anything that feeds projectile motion. Roblox
	Vector3 components are float32, so a NaN or inf that slips into a
	position/velocity poisons every Dot/Magnitude/raycast after it, and a
	value that is merely enormous can still overflow once squared. Everything
	here clamps to Limit instead of rejecting, so a client aiming at
	Vector3.new(math.huge, 0, 0) still gets a sensible +X shot.

	API:
	 SafeMath.Limit                          -- 1e9; see below
	 SafeMath.isFinite(x) -> boolean
	 SafeMath.isFiniteVector(v) -> boolean   -- every component within +-Limit
	 SafeMath.number(value, fallback, min?, max?) -> number
	 SafeMath.cap(value, min?) -> number     -- like number(), but >= Limit means "no cap" (math.huge)
	 SafeMath.vector(value, fallback) -> Vector3
	 SafeMath.direction(v, fallback) -> Vector3  -- unit vector of an already-finite v
	 SafeMath.unit(value, fallback) -> Vector3   -- sanitize, then direction()
]]

local SafeMath = {}

-- Absurdly large for any real gameplay value, yet its square (1e18) is far
-- inside float32 range (~3.4e38), so Magnitude/Dot on a clamped Vector3 can
-- never overflow to inf.
local LIMIT = 1e9
SafeMath.Limit = LIMIT

-- Below this largest-component size a vector is treated as having no
-- direction. It sits above float32's subnormal range, where dividing stops
-- being exact; anything larger -- however tiny -- still normalizes exactly.
local TINY = 1e-30

function SafeMath.isFinite(x: number): boolean
	return x == x and x > -math.huge and x < math.huge
end

function SafeMath.hasNaN(v: Vector3): boolean
	return v.X ~= v.X or v.Y ~= v.Y or v.Z ~= v.Z
end

-- NaN fails every comparison, so `<=` doubles as the NaN check.
function SafeMath.isFiniteVector(v: Vector3): boolean
	return math.abs(v.X) <= LIMIT and math.abs(v.Y) <= LIMIT and math.abs(v.Z) <= LIMIT
end

-- Non-numbers and NaN fall back; +-inf and anything past +-Limit clamp to
-- the nearest bound. `min`/`max` narrow the range further (never widen it).
function SafeMath.number(value: unknown, fallback: number, min: number?, max: number?): number
	if typeof(value) ~= "number" or value ~= value then
		return fallback
	end
	local low = math.max(min or -LIMIT, -LIMIT)
	local high = math.max(math.min(max or LIMIT, LIMIT), low)
	return math.clamp(value, low, high)
end

-- For fields where math.huge is a meaningful "unlimited" sentinel (MaxSpeed,
-- VisualRange): NaN and anything at or past Limit become math.huge.
function SafeMath.cap(value: unknown, min: number?): number
	if typeof(value) ~= "number" or value ~= value or value >= LIMIT then
		return math.huge
	end
	return math.max(value, min or 0)
end

local function clampComponent(x: number): number
	if x ~= x then
		return 0
	end
	return math.clamp(x, -LIMIT, LIMIT)
end

-- Non-Vector3 values fall back; NaN components become 0 and +-inf/huge
-- components clamp to +-Limit.
function SafeMath.vector(value: unknown, fallback: Vector3): Vector3
	if typeof(value) ~= "Vector3" then
		return fallback
	end
	if SafeMath.isFiniteVector(value) then
		return value
	end
	return Vector3.new(clampComponent(value.X), clampComponent(value.Y), clampComponent(value.Z))
end

-- Unit vector along `v`, or `fallback` when it has no usable direction.
-- Rescaling by the largest component first means neither a tiny vector
-- (whose squared magnitude would underflow) nor a huge one (which would
-- overflow) loses its direction. Hot-path safe for internally maintained,
-- already-finite vectors; use unit() for anything from outside.
function SafeMath.direction(v: Vector3, fallback: Vector3): Vector3
	local largest = math.max(math.abs(v.X), math.abs(v.Y), math.abs(v.Z))
	if largest >= TINY and largest < math.huge then
		local unit = (v / largest).Unit
		-- math.max can swallow a NaN component, so check the result itself.
		if unit.X == unit.X and unit.Y == unit.Y and unit.Z == unit.Z then
			return unit
		end
	end
	return fallback
end

function SafeMath.unit(value: unknown, fallback: Vector3): Vector3
	return SafeMath.direction(SafeMath.vector(value, Vector3.zero), fallback)
end

return SafeMath
