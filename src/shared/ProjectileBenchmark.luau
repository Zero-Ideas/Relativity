--!strict
-- Serializable benchmark inputs only. Entity/source, callbacks, ignore lists
-- and beam IDs are constructed by the server, never supplied by the client.
local Schema = {}
Schema.MaxCount = math.huge -- No benchmark count cap; validation still requires finite integers.
Schema.Fields = {} :: {any}
local function field(group: string, key: string, label: string, kind: string, default: any, min: number?, max: number?, choices: {string}?)
	table.insert(Schema.Fields, {Group = group, Key = key, Label = label, Kind = kind, Default = default, Min = min, Max = max, Choices = choices})
end
local function n(group: string, key: string, default: number, min: number, max: number, label: string?)
	field(group, key, label or key, "number", default, min, max)
end
local function b(group: string, key: string, default: boolean, label: string?)
	field(group, key, label or key, "boolean", default)
end
local function v(group: string, key: string, default: string, limit: number)
	field(group, key, key .. " (x, y, z)", "vector", default, -limit, limit)
end
local function choice(group: string, key: string, default: string, choices: {string})
	field(group, key, key, "choice", default, nil, nil, choices)
end
n("Launch", "Count", 10000, 1, Schema.MaxCount)
n("Launch", "BatchSize", 0, 0, Schema.MaxCount, "Spawns / frame (0 = all at once)")
n("Launch", "Seed", 1, 0, 2147483647)
choice("Launch", "Pattern", "Sphere", {"Sphere", "Cone", "Parallel", "Ring", "Grid"})
n("Launch", "Spread", 20, 0, 180, "Cone half-angle (degrees)")
n("Launch", "SpawnRadius", 3, 0, 1000)
n("Launch", "GridSpacing", 1, 0, 100)
v("Launch", "SpawnOffset", "0, 0, 0", 10000)
b("Launch", "SpawnInSky", false, "Spawn in the sky")
n("Launch", "SkyHeight", 1000, 0, 1e7, "Sky height above character (studs)")
b("Launch", "CustomDirection", false)
v("Launch", "Direction", "0, 0, -1", 1e6)
b("Launch", "UseTargetPosition", false, "Aim at explicit world position")
v("Launch", "TargetPosition", "0, 0, 0", 1e7)
b("Launch", "IgnoreSelf", true)
b("Launch", "LivingEntitiesOnly", true)
b("Motion", "Efficient", true)
n("Motion", "Speed", 220, 0, 100000)
n("Motion", "Acceleration", 0, -100000, 100000, "Forward acceleration (studs/s²)")
b("Motion", "VectorAcceleration", false)
v("Motion", "AccelerationVector", "0, 0, 0", 100000)
b("Motion", "UseAccelerationDirection", false)
v("Motion", "AccelerationDirection", "0, 1, 0", 1e6)
n("Motion", "MinSpeed", 0, 0, 100000)
n("Motion", "MaxSpeed", 0, 0, 100000, "MaxSpeed (0 = unlimited)")
n("Motion", "Gravity", 0, -100000, 100000, "Downward gravity (studs/s²)")
b("Motion", "VectorGravity", false)
v("Motion", "GravityVector", "0, -196.2, 0", 100000)
n("Motion", "Lifetime", 4, 0.01, 300, "Dilated lifetime (seconds)")
n("Motion", "MaxRealLifetime", 30, 0.01, 300, "Real lifetime cap (seconds)")
n("Motion", "TimeScale", 1, 0, 100)
n("Motion", "RewindSeconds", 0, 0, 1)
n("Collision", "Damage", 0, 0, 100000, "Damage (0 = harmless)")
n("Collision", "Radius", 0, 0, 100)
n("Collision", "Bounces", 0, 0, 1000)
n("Collision", "Restitution", 0.5, 0, 5)
n("Collision", "Penetration", 0, 0, 10000)
n("Collision", "MaxPierces", 0, 0, 1000)
n("Collision", "PierceFalloff", 0.2, 0, 1)
b("Homing", "HomingEnabled", false)
b("Homing", "HomingExplicitTarget", false, "Home to explicit world position")
v("Homing", "HomingTarget", "0, 0, 0", 1e7)
field("Homing", "TargetTags", "Target tags (comma separated; blank = all)", "string", "Enemy", nil, 256)
n("Homing", "AcquireRadius", 150, 0, 10000, "Acquire radius (0 = unbounded)")
b("Homing", "Retarget", true)
n("Homing", "ReacquireRate", 0.3, 0, 60)
n("Homing", "AcquireInterval", 0.1, 0, 60)
b("Homing", "Permalock", false)
n("Homing", "TurnRate", 140, 0, 10000, "Turn rate (degrees/s)")
n("Homing", "HomingDelay", 0.05, 0, 300)
b("Beam", "BeamEnabled", false, "Cylinder beam projectiles (independent sections)")
n("Beam", "BeamLength", 24, 0.05, 512)
b("Visuals", "Visualize", true, "Replicate visuals (off = server-only)")
n("Visuals", "VisualRange", 8000, 0, 100000, "Visual range (0 = unlimited)")
field("Visuals", "Model", "Effects model name (blank = generated)", "string", "", nil, 100)
choice("Visuals", "Shape", "Ball", {"Ball", "Block", "Cylinder"})
choice("Visuals", "Style", "Plain", {"Plain", "Orb", "Bullet"})
v("Visuals", "VisualSize", "0.4, 0.4, 0.4", 100)
field("Visuals", "Color", "Tint (#RRGGBB)", "color", "#ff8c3c")
field("Visuals", "Core", "Core (#RRGGBB)", "color", "#fff4dc")
n("Visuals", "VisualScale", 1, 0.05, 20)
n("Visuals", "DestroyDelay", 0, 0, 30)
b("Visuals", "WaitForParticles", true)
b("Visuals", "WaitForTrails", true)
b("Visuals", "ActivateParticlesOnCreate", false)

function Schema.Defaults(): any
	local values = {}
	for _, f in Schema.Fields do values[f.Key] = f.Default end
	return values
end

local function finite(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

function Schema.Validate(raw: any): (any?, string?)
	if typeof(raw) ~= "table" then return nil, "Settings must be a table" end
	local result, known = {}, {}
	for _, f in Schema.Fields do
		known[f.Key] = true
		local value = raw[f.Key]
		if value == nil then value = f.Default end
		local valid = true
		if f.Kind == "number" then
			valid = finite(value) and value >= f.Min and value <= f.Max
		elseif f.Kind == "boolean" then
			valid = typeof(value) == "boolean"
		elseif f.Kind == "choice" then
			valid = typeof(value) == "string" and table.find(f.Choices, value) ~= nil
		elseif f.Kind == "vector" then
			if typeof(value) == "string" and #value <= 128 then
				local parts = string.split(value, ",")
				if #parts == 3 then
					local x, y, z = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])
					if finite(x) and finite(y) and finite(z) then value = Vector3.new(x, y, z) end
				end
			end
			valid = typeof(value) == "Vector3"
			if valid then
				for _, component in {value.X, value.Y, value.Z} do
					if not finite(component) or component < f.Min or component > f.Max then valid = false end
				end
			end
		elseif f.Kind == "color" then
			valid = typeof(value) == "string" and string.match(value, "^#%x%x%x%x%x%x$") ~= nil
			if valid then value = Color3.fromHex(string.sub(value, 2)) end
		else
			valid = typeof(value) == "string" and #value <= (f.Max or 256)
		end
		if not valid then return nil, "Invalid " .. f.Label end
		result[f.Key] = value
	end
	for key in raw do if not known[key] then return nil, "Unknown setting: " .. tostring(key) end end
	for _, key in {"Count", "BatchSize", "Seed", "Bounces", "MaxPierces"} do
		if result[key] % 1 ~= 0 then return nil, key .. " must be an integer" end
	end
	if result.MaxSpeed > 0 and result.MaxSpeed < result.MinSpeed then return nil, "MaxSpeed must be >= MinSpeed" end
	if result.CustomDirection and result.Direction.Magnitude < 0.001 then return nil, "Direction cannot be zero" end
	if result.UseAccelerationDirection and result.AccelerationDirection.Magnitude < 0.001 then return nil, "AccelerationDirection cannot be zero" end
	if result.VisualSize.X <= 0 or result.VisualSize.Y <= 0 or result.VisualSize.Z <= 0 then return nil, "VisualSize must be positive" end
	return result, nil
end

function Schema.Origin(s: any, characterPosition: Vector3): Vector3
	return characterPosition + s.SpawnOffset + Vector3.new(0, if s.SpawnInSky then s.SkyHeight else 0, 0)
end

function Schema.Config(s: any): any
	local tags = {}
	for tag in string.gmatch(s.TargetTags, "[^,]+") do
		local trimmed = string.match(tag, "^%s*(.-)%s*$")
		if trimmed and trimmed ~= "" then table.insert(tags, trimmed) end
	end
	return {
		Efficient = s.Efficient, Speed = s.Speed,
		Acceleration = if s.VectorAcceleration then s.AccelerationVector else s.Acceleration,
		AccelerationDirection = if s.UseAccelerationDirection then s.AccelerationDirection else nil,
		MinSpeed = s.MinSpeed, MaxSpeed = if s.MaxSpeed == 0 then math.huge else s.MaxSpeed,
		Gravity = if s.VectorGravity then s.GravityVector else s.Gravity,
		Lifetime = s.Lifetime, MaxRealLifetime = s.MaxRealLifetime, TimeScale = s.TimeScale,
		Damage = s.Damage, Radius = s.Radius, Bounces = s.Bounces, Restitution = s.Restitution,
		Penetration = s.Penetration, MaxPierces = s.MaxPierces, PierceFalloff = s.PierceFalloff,
		RewindSeconds = s.RewindSeconds, Spread = s.Spread,
		Homing = if s.HomingEnabled then {
			Target = if s.HomingExplicitTarget then s.HomingTarget else nil,
			TargetTags = if #tags > 0 then tags else nil,
			AcquireRadius = if s.AcquireRadius > 0 then s.AcquireRadius else nil,
			Retarget = s.Retarget, ReacquireRate = s.ReacquireRate, AcquireInterval = s.AcquireInterval,
			Permalock = s.Permalock, TurnRate = math.rad(s.TurnRate), Delay = s.HomingDelay,
		} else nil,
		Beam = if s.BeamEnabled then {Length = s.BeamLength} else nil,
		Visualize = s.Visualize, VisualRange = if s.VisualRange == 0 then math.huge else s.VisualRange,
		Visual = {Shape = s.Shape, Style = if s.Style ~= "Plain" then s.Style else nil,
			Size = s.VisualSize, Color = s.Color, Core = s.Core},
		VisualScale = s.VisualScale, DestroyDelay = s.DestroyDelay,
		WaitForParticles = s.WaitForParticles, WaitForTrails = s.WaitForTrails,
		ActivateParticlesOnCreate = s.ActivateParticlesOnCreate,
	}
end

-- Deterministic patterns: no replication of per-shot aim from the client.
function Schema.Sample(s: any, index: number, origin: Vector3, aim: Vector3, rng: Random): (Vector3, Vector3)
	if s.Pattern == "Sphere" then
		local direction = rng:NextUnitVector()
		return origin + direction * s.SpawnRadius, direction
	elseif s.Pattern == "Parallel" then return origin + aim * s.SpawnRadius, aim end
	local basis = CFrame.lookAt(Vector3.zero, aim)
	local direction = aim
	local offset = Vector3.zero
	if s.Pattern == "Ring" then
		local angle = (index - 1) / s.Count * math.pi * 2
		direction = basis:VectorToWorldSpace(Vector3.new(math.cos(angle), math.sin(angle), 0))
		offset = direction * s.SpawnRadius
	elseif s.Pattern == "Cone" then
		local cosTheta = rng:NextNumber(math.cos(math.rad(s.Spread)), 1)
		local sinTheta, phi = math.sqrt(math.max(0, 1 - cosTheta * cosTheta)), rng:NextNumber(0, math.pi * 2)
		direction = basis:VectorToWorldSpace(Vector3.new(sinTheta * math.cos(phi), sinTheta * math.sin(phi), -cosTheta))
		offset = direction * s.SpawnRadius
	elseif s.Pattern == "Grid" then
		local width = math.ceil(math.sqrt(s.Count))
		local x, y = (index - 1) % width, math.floor((index - 1) / width)
		offset = basis:VectorToWorldSpace(Vector3.new((x - (width - 1) / 2) * s.GridSpacing, (y - (width - 1) / 2) * s.GridSpacing, -s.SpawnRadius))
	else offset = aim * s.SpawnRadius end
	return origin + offset, direction
end
return Schema
