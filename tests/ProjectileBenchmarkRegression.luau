-- Run in Studio (either side); pure schema tests, no gameplay mutation.
local Schema = require(game.ReplicatedStorage.Shared.ProjectileBenchmark)
local defaults = Schema.Defaults()
local s, err = Schema.Validate(defaults)
assert(s, err)
assert(s.Count == 10000 and s.BatchSize == 0)
local config = Schema.Config(s)
assert(config.Damage == 0 and config.Efficient and config.Visualize)
assert(config.MaxSpeed == math.huge and config.Speed == 220)
for key, value in {Count = 50001, BatchSize = -1, Speed = 0/0, Lifetime = math.huge, Efficient = "true", CountBad = 1} do
	local raw = table.clone(defaults); raw[key] = value
	assert(not Schema.Validate(raw), "Accepted malformed " .. key)
end
for _, raw in {
	{Count = 1.5}, {VisualSize = "0, 1, 1"}, {Direction = "nan, 0, 1"},
	{Color = "red"}, {MinSpeed = 200, MaxSpeed = 100}, {Source = workspace},
	{CustomDirection = true, Direction = "0, 0, 0"},
} do
	local full = table.clone(defaults)
	for key, value in raw do full[key] = value end
	assert(not Schema.Validate(full), "Malformed payload accepted")
end
local raw = table.clone(defaults)
raw.VectorAcceleration, raw.AccelerationVector = true, "10, -20, 30"
raw.VectorGravity, raw.GravityVector = true, "-5, 0, 0"
raw.HomingEnabled, raw.TargetTags, raw.TurnRate = true, "Enemy, Player", 180
raw.BeamEnabled, raw.BeamLength = true, 12
local settings, problem = Schema.Validate(raw)
assert(settings, problem)
local special = Schema.Config(settings)
assert(special.Acceleration == Vector3.new(10, -20, 30) and special.Gravity == Vector3.new(-5, 0, 0))
assert(special.Homing.TargetTags[2] == "Player" and special.Homing.TurnRate == math.pi)
assert(special.Beam.Length == 12)
local origin, aim = Vector3.new(1, 2, 3), Vector3.new(0, 0, -1)
for _, pattern in {"Sphere", "Cone", "Parallel", "Ring", "Grid"} do
	s.Pattern = pattern
	local a, b = Random.new(123), Random.new(123)
	for index = 1, 20 do
		local p, d = Schema.Sample(s, index, origin, aim, a)
		local p2, d2 = Schema.Sample(s, index, origin, aim, b)
		assert((p - p2).Magnitude < 1e-5 and (d - d2).Magnitude < 1e-5, "Pattern not deterministic")
		assert(math.abs(d.Magnitude - 1) < 1e-5, "Non-unit direction")
		if pattern == "Cone" then assert(d:Dot(aim) >= math.cos(math.rad(s.Spread)) - 1e-5) end
	end
end
print("[ProjectileBenchmarkRegression] PASS: validation, defaults, full configs, deterministic patterns")
