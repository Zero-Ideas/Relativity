--!strict
--[[
	Projectile/Config.luau
	Turns a caller's Projectile.new config into validated settings. Every
	value is treated as untrusted -- configs are assembled from weapon data,
	spell graphs and (in Studio) a client-tunable debug panel -- so NaN,
	+-inf, wrong types and out-of-range numbers are all normalized here, once,
	and nothing downstream has to re-check them.

	Numbers clamp to SafeMath.Limit (1e9) instead of being rejected, so an
	absurd value still behaves predictably; NaN falls back to the default.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local SafeMath = require(Shared:WaitForChild("SafeMath"))

local Types = require(script.Parent.Types)

local Config = {}

local DEFAULT_SPEED = 100
local DEFAULT_LIFETIME = 5
local DEFAULT_RESTITUTION = 0.5
local DEFAULT_TURN_RATE = math.rad(120)
local DEFAULT_REACQUIRE_RATE = 0.3
-- Dilated seconds between searches while no target is held; see Homing.
local DEFAULT_ACQUIRE_INTERVAL = 0.1

export type Settings = {
	Origin: Vector3,
	Direction: Vector3,
	Speed: number,
	Acceleration: Types.Acceleration,
	AccelerationDirection: Vector3?,
	MinSpeed: number,
	MaxSpeed: number,
	Gravity: Types.Acceleration,
	Radius: number,
	Lifetime: number,
	MaxRealLifetime: number,
	TimeScale: number,
	Damage: number,
	Source: Types.EntityLike?,
	IgnoreInstances: { Instance }?,
	Filter: ((entity: Types.EntityLike) -> boolean)?,
	Bounces: number,
	Restitution: number,
	Penetration: number,
	MaxPierces: number,
	PierceFalloff: number,
	Homing: Types.Homing?,
	Visualize: boolean,
	VisualRange: number,
	Model: Instance?,
	Visual: Types.VisualSpec?,
	VisualScale: number,
	DestroyDelay: number,
	WaitForParticles: boolean,
	WaitForTrails: boolean,
	ActivateParticlesOnCreate: boolean,
	OnBounce: ((projectile: any, contact: Types.Contact) -> ())?,
	RewindSeconds: number,
}

local function acceleration(value: unknown): Types.Acceleration
	if typeof(value) == "Vector3" then
		return SafeMath.vector(value, Vector3.zero)
	end
	return SafeMath.number(value, 0)
end

local function count(value: unknown): number
	return math.floor(SafeMath.number(value, 0, 0))
end

local function optionalDirection(value: unknown): Vector3?
	if typeof(value) ~= "Vector3" then
		return nil
	end
	local direction = SafeMath.unit(value, Vector3.zero)
	return if direction == Vector3.zero then nil else direction
end

-- Keeps only real Instances; anything else in the list is dropped.
local function instanceList(value: unknown): { Instance }?
	if typeof(value) ~= "table" then
		return nil
	end
	local list: { Instance } = {}
	for _, item in value :: { any } do
		if typeof(item) == "Instance" then
			table.insert(list, item)
		end
	end
	return list
end

local function optionalFunction<T>(value: T?): T?
	return if typeof(value) == "function" then value else nil
end

-- The launch direction: toward TargetPosition when given, else Direction.
-- Degenerate aims (zero, NaN) fall back to +Z rather than producing NaN.
function Config.direction(raw: Types.Config, origin: Vector3): Vector3
	if typeof(raw.TargetPosition) == "Vector3" then
		local target = SafeMath.vector(raw.TargetPosition, origin)
		return SafeMath.direction(target - origin, Vector3.zAxis)
	end
	return SafeMath.unit(raw.Direction, Vector3.zAxis)
end

function Config.normalizeHoming(raw: Types.HomingOptions?): Types.Homing?
	if typeof(raw) ~= "table" then
		return nil
	end
	local target = raw.Target
	if typeof(target) == "Vector3" then
		target = SafeMath.vector(target, Vector3.zero)
	end
	local acquireRadius = raw.AcquireRadius
	return {
		Target = target,
		TargetTag = if typeof(raw.TargetTag) == "string" then raw.TargetTag else nil,
		TargetTags = if typeof(raw.TargetTags) == "table" then raw.TargetTags else nil,
		-- nil keeps its meaning of "unbounded"; NaN is treated as unset.
		AcquireRadius = if typeof(acquireRadius) == "number" and acquireRadius == acquireRadius
			then SafeMath.number(acquireRadius, 0, 0)
			else nil,
		Retarget = raw.Retarget == true,
		ReacquireRate = SafeMath.number(raw.ReacquireRate, DEFAULT_REACQUIRE_RATE, 0),
		AcquireInterval = SafeMath.number(raw.AcquireInterval, DEFAULT_ACQUIRE_INTERVAL, 0),
		Permalock = raw.Permalock == true,
		TurnRate = SafeMath.number(raw.TurnRate, DEFAULT_TURN_RATE, 0),
		Delay = SafeMath.number(raw.Delay, 0, 0),
	}
end

function Config.normalize(raw: Types.Config, defaultMaxRealLifetime: number): Settings
	local origin = SafeMath.vector(raw.Origin, Vector3.zero)
	local minSpeed = SafeMath.number(raw.MinSpeed, 0, 0)
	local visual = raw.Visual
	local model = raw.Model
	return {
		Origin = origin,
		Direction = Config.direction(raw, origin),
		Speed = SafeMath.number(raw.Speed, DEFAULT_SPEED, 0),
		Acceleration = acceleration(raw.Acceleration),
		AccelerationDirection = optionalDirection(raw.AccelerationDirection),
		MinSpeed = minSpeed,
		-- math.huge stays the "no cap" sentinel; a cap below MinSpeed is raised to it.
		MaxSpeed = SafeMath.cap(raw.MaxSpeed, minSpeed),
		Gravity = acceleration(raw.Gravity),
		Radius = SafeMath.number(raw.Radius, 0, 0),
		Lifetime = SafeMath.number(raw.Lifetime, DEFAULT_LIFETIME, 0),
		MaxRealLifetime = SafeMath.number(raw.MaxRealLifetime, defaultMaxRealLifetime, 0),
		TimeScale = SafeMath.number(raw.TimeScale, 1, 0),
		Damage = SafeMath.number(raw.Damage, 0),
		Source = if typeof(raw.Source) == "table" then raw.Source else nil,
		IgnoreInstances = instanceList(raw.IgnoreInstances),
		Filter = optionalFunction(raw.Filter),
		Bounces = count(raw.Bounces),
		Restitution = SafeMath.number(raw.Restitution, DEFAULT_RESTITUTION, 0),
		Penetration = SafeMath.number(raw.Penetration, 0, 0),
		MaxPierces = count(raw.MaxPierces),
		PierceFalloff = SafeMath.number(raw.PierceFalloff, 0, 0, 1),
		Homing = Config.normalizeHoming(raw.Homing),
		Visualize = raw.Visualize == true,
		VisualRange = SafeMath.cap(raw.VisualRange, 0),
		Model = if typeof(model) == "Instance" then model else nil,
		Visual = if typeof(visual) == "table" then visual else nil,
		VisualScale = SafeMath.number(raw.VisualScale, 1, 0.05, 20),
		DestroyDelay = SafeMath.number(raw.DestroyDelay, 0, 0),
		WaitForParticles = raw.WaitForParticles ~= false,
		WaitForTrails = raw.WaitForTrails ~= false,
		ActivateParticlesOnCreate = raw.ActivateParticlesOnCreate == true,
		OnBounce = optionalFunction(raw.OnBounce),
		RewindSeconds = SafeMath.number(raw.RewindSeconds, 0, 0),
	}
end

-- Burst cone half-angle in degrees.
function Config.spread(raw: Types.Config): number
	return SafeMath.number(raw.Spread, 0, 0, 180)
end

return Config
