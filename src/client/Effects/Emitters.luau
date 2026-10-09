--!strict
--[[
	Effects/Emitters.luau
	Pooled particle layers. One ParticleEmitter per (layer, colour, time
	scale) on its own Attachment under Terrain; an effect moves the
	attachment, aims its +Y, and calls :Emit. Emitted particles keep their
	world position, so one emitter serves every impact of that kind.

	Colour and time scale apply to an emitter's live particles, so they're
	part of the pool key (colours quantized, time scales bucketed). Speed and
	spread only touch new particles, so they vary per emit.

	A layer can be authored instead of built here: put a ParticleEmitter
	named after the layer in ReplicatedStorage.Effects.Layers. Its colour is
	still replaced by the effect's tint unless it has a KeepColor attribute.

	Emitters.Emit(layer, frame, count, color?, timeScale?, speedScale?)
	Emitters.Has(layer) -> boolean
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Presentation = require(Shared.ClientPresentation)

local Emitters = {}

local SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"

type Layer = {
	Texture: string,
	Lifetime: NumberRange,
	Speed: NumberRange,
	Spread: Vector2,
	Size: NumberSequence,
	Transparency: NumberSequence,
	Acceleration: Vector3,
	Drag: number,
	LightEmission: number,
	LightInfluence: number,
	Brightness: number?,
	Squash: NumberSequence?,
	Parallel: boolean?, -- particles face along their velocity (streaks)
	RotSpeed: NumberRange?,
	Rotation: NumberRange?,
	ZOffset: number?,
	Flash: boolean?, -- silenced by Reduced flashes
	Tint: Color3?, -- fixed colour (else the effect's colour)
	Hot: boolean?, -- white-hot core fading to the effect's colour
}

local function seq(...: number): NumberSequence
	local values = { ... }
	local points = {}
	for index = 1, #values, 2 do
		table.insert(points, NumberSequenceKeypoint.new(values[index], values[index + 1]))
	end
	return NumberSequence.new(points)
end

local GRAVITY = Vector3.new(0, -workspace.Gravity * 0.35, 0)

local LAYERS: { [string]: Layer } = {
	Sparks = {
		Texture = SPARK, Lifetime = NumberRange.new(0.18, 0.45), Speed = NumberRange.new(28, 70),
		Spread = Vector2.new(38, 38), Size = seq(0, 0.16, 1, 0), Transparency = seq(0, 0, 0.7, 0.1, 1, 1),
		Acceleration = GRAVITY, Drag = 3, LightEmission = 1, LightInfluence = 0, Brightness = 3,
		Squash = seq(0, -2.4, 1, -1.2), Parallel = true, Flash = true, Hot = true, ZOffset = 0.5,
	},
	Embers = {
		Texture = SPARK, Lifetime = NumberRange.new(0.6, 1.4), Speed = NumberRange.new(6, 18),
		Spread = Vector2.new(60, 60), Size = seq(0, 0.14, 1, 0), Transparency = seq(0, 0, 0.8, 0.2, 1, 1),
		Acceleration = GRAVITY * 0.4, Drag = 1.5, LightEmission = 1, LightInfluence = 0, Brightness = 2,
		Flash = true, Hot = true,
	},
	Dust = {
		Texture = SMOKE, Lifetime = NumberRange.new(0.6, 1.3), Speed = NumberRange.new(4, 11),
		Spread = Vector2.new(55, 55), Size = seq(0, 0.6, 1, 3.2), Transparency = seq(0, 0.45, 0.4, 0.65, 1, 1),
		Acceleration = Vector3.new(0, 1.5, 0), Drag = 4, LightEmission = 0, LightInfluence = 1,
		Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-40, 40),
	},
	DustFall = {
		Texture = SMOKE, Lifetime = NumberRange.new(0.8, 1.6), Speed = NumberRange.new(2, 6),
		Spread = Vector2.new(40, 40), Size = seq(0, 0.4, 1, 2.2), Transparency = seq(0, 0.5, 0.5, 0.7, 1, 1),
		Acceleration = Vector3.new(0, -8, 0), Drag = 2, LightEmission = 0, LightInfluence = 1,
		Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-30, 30),
	},
	Grit = {
		Texture = SPARK, Lifetime = NumberRange.new(0.35, 0.8), Speed = NumberRange.new(14, 34),
		Spread = Vector2.new(42, 42), Size = seq(0, 0.12, 1, 0.08), Transparency = seq(0, 0, 0.8, 0, 1, 1),
		Acceleration = GRAVITY * 1.6, Drag = 1, LightEmission = 0, LightInfluence = 1,
	},
	Splash = {
		Texture = SPARK, Lifetime = NumberRange.new(0.4, 0.9), Speed = NumberRange.new(16, 34),
		Spread = Vector2.new(24, 24), Size = seq(0, 0.25, 1, 0.12), Transparency = seq(0, 0.1, 0.8, 0.3, 1, 1),
		Acceleration = GRAVITY * 2.2, Drag = 0.6, LightEmission = 0.3, LightInfluence = 1,
		Squash = seq(0, -1, 1, -0.5), Parallel = true,
	},
	Mist = {
		Texture = SMOKE, Lifetime = NumberRange.new(0.5, 1), Speed = NumberRange.new(5, 12),
		Spread = Vector2.new(70, 70), Size = seq(0, 0.8, 1, 3.5), Transparency = seq(0, 0.55, 1, 1),
		Acceleration = Vector3.zero, Drag = 3, LightEmission = 0.2, LightInfluence = 1,
		Rotation = NumberRange.new(0, 360),
	},
	Bubbles = {
		Texture = SPARK, Lifetime = NumberRange.new(0.8, 1.8), Speed = NumberRange.new(4, 12),
		Spread = Vector2.new(80, 80), Size = seq(0, 0.12, 1, 0.3), Transparency = seq(0, 0.2, 0.85, 0.4, 1, 1),
		Acceleration = Vector3.new(0, 14, 0), Drag = 3, LightEmission = 0.4, LightInfluence = 0.6,
		Tint = Color3.fromRGB(220, 245, 255), RotSpeed = NumberRange.new(-90, 90),
	},
	Murk = {
		Texture = SMOKE, Lifetime = NumberRange.new(1.2, 2.2), Speed = NumberRange.new(2, 5),
		Spread = Vector2.new(80, 80), Size = seq(0, 0.8, 1, 3), Transparency = seq(0, 0.5, 1, 1),
		Acceleration = Vector3.zero, Drag = 2, LightEmission = 0, LightInfluence = 1,
		Rotation = NumberRange.new(0, 360),
	},
	Glint = {
		Texture = SPARK, Lifetime = NumberRange.new(0.25, 0.6), Speed = NumberRange.new(8, 22),
		Spread = Vector2.new(50, 50), Size = seq(0, 0.25, 1, 0), Transparency = seq(0, 0, 1, 1),
		Acceleration = GRAVITY, Drag = 2, LightEmission = 1, LightInfluence = 0.2, Flash = true,
		RotSpeed = NumberRange.new(-200, 200),
	},
	Fibers = {
		Texture = SPARK, Lifetime = NumberRange.new(0.8, 1.6), Speed = NumberRange.new(3, 9),
		Spread = Vector2.new(70, 70), Size = seq(0, 0.12, 1, 0.1), Transparency = seq(0, 0.1, 1, 1),
		Acceleration = Vector3.new(0, -3, 0), Drag = 4, LightEmission = 0, LightInfluence = 1,
		RotSpeed = NumberRange.new(-120, 120),
	},
	Pulse = {
		Texture = SPARK, Lifetime = NumberRange.new(0.12, 0.2), Speed = NumberRange.new(0, 0),
		Spread = Vector2.new(0, 0), Size = seq(0, 0.5, 1, 3.2), Transparency = seq(0, 0.1, 1, 1),
		Acceleration = Vector3.zero, Drag = 0, LightEmission = 1, LightInfluence = 0, Flash = true,
		Rotation = NumberRange.new(0, 360), ZOffset = 1,
	},
	Streaks = { -- energy hits: sparks in the projectile's own colour
		Texture = SPARK, Lifetime = NumberRange.new(0.15, 0.35), Speed = NumberRange.new(30, 80),
		Spread = Vector2.new(50, 50), Size = seq(0, 0.2, 1, 0), Transparency = seq(0, 0, 1, 1),
		Acceleration = Vector3.zero, Drag = 6, LightEmission = 1, LightInfluence = 0, Brightness = 2,
		Squash = seq(0, -2, 1, -1), Parallel = true, Flash = true, ZOffset = 0.5,
	},
}

local TIME_BUCKETS = { 1, 0.6, 0.3, 0.12, 0.04, 0 }
local MAX_EMITTERS = 120

type Entry = {
	Attachment: Attachment,
	Emitter: ParticleEmitter,
	LastUsed: number,
	Keep: number, -- seconds its particles can live
}

local pool: { [string]: Entry } = {}
local poolSize = 0
local terrain = workspace.Terrain

local function authored(name: string): ParticleEmitter?
	local effects = ReplicatedStorage:FindFirstChild("Effects")
	local layers = effects and effects:FindFirstChild("Layers")
	local template = layers and layers:FindFirstChild(name)
	if template and template:IsA("ParticleEmitter") then
		return template
	end
	return nil
end

local function colorSequence(layer: Layer?, color: Color3): ColorSequence
	if layer and layer.Hot then
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(0.25, color),
			ColorSequenceKeypoint.new(1, color:Lerp(Color3.new(0, 0, 0), 0.4)),
		})
	end
	return ColorSequence.new(color)
end

local function build(name: string, color: Color3, timeScale: number): Entry?
	local layer = LAYERS[name]
	local template = authored(name)
	if not layer and not template then
		return nil
	end
	local emitter: ParticleEmitter
	if template then
		emitter = template:Clone()
		if not template:GetAttribute("KeepColor") then
			emitter.Color = colorSequence(layer, color)
		end
	else
		local spec = layer :: Layer
		emitter = Instance.new("ParticleEmitter")
		emitter.Texture = spec.Texture
		emitter.Lifetime = spec.Lifetime
		emitter.Speed = spec.Speed
		emitter.SpreadAngle = spec.Spread
		emitter.Size = spec.Size
		emitter.Transparency = spec.Transparency
		emitter.Acceleration = spec.Acceleration
		emitter.Drag = spec.Drag
		emitter.LightEmission = spec.LightEmission
		emitter.LightInfluence = spec.LightInfluence
		emitter.Brightness = spec.Brightness or 1
		if spec.Squash then
			emitter.Squash = spec.Squash
		end
		if spec.Parallel then
			emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
		end
		if spec.Rotation then
			emitter.Rotation = spec.Rotation
		end
		if spec.RotSpeed then
			emitter.RotSpeed = spec.RotSpeed
		end
		emitter.ZOffset = spec.ZOffset or 0
		emitter.Color = colorSequence(spec, spec.Tint or color)
	end
	emitter.Name = name
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.LockedToPart = false
	emitter.TimeScale = timeScale
	local attachment = Instance.new("Attachment")
	attachment.Name = "Effect_" .. name
	emitter.Parent = attachment
	attachment.Parent = terrain
	return {
		Attachment = attachment,
		Emitter = emitter,
		LastUsed = 0,
		Keep = emitter.Lifetime.Max / math.max(timeScale, 0.05) + 0.5,
	}
end

-- Drops emitters whose particles are all gone, oldest first, until there's room.
local function makeRoom(now: number): boolean
	if poolSize < MAX_EMITTERS then
		return true
	end
	local oldestKey, oldestTime = nil, math.huge
	for key, entry in pool do
		if now - entry.LastUsed > entry.Keep and entry.LastUsed < oldestTime then
			oldestKey, oldestTime = key, entry.LastUsed
		end
	end
	if not oldestKey then
		return false
	end
	pool[oldestKey].Attachment:Destroy()
	pool[oldestKey] = nil
	poolSize -= 1
	return true
end

local function bucket(timeScale: number): number
	for _, value in TIME_BUCKETS do
		if timeScale >= value * 0.8 then
			return value
		end
	end
	return 0
end

local function colorKey(color: Color3): number
	-- 3 bits per channel: close colours share an emitter
	return math.floor(color.R * 7 + 0.5) * 64 + math.floor(color.G * 7 + 0.5) * 8 + math.floor(color.B * 7 + 0.5)
end

function Emitters.Has(name: string): boolean
	return LAYERS[name] ~= nil or authored(name) ~= nil
end

function Emitters.IsFlash(name: string): boolean
	local layer = LAYERS[name]
	return layer ~= nil and layer.Flash == true
end

-- Emits `count` particles (before the intensity setting) from `frame`, along
-- its +Y. Returns how many were emitted.
function Emitters.Emit(name: string, frame: CFrame, count: number, color: Color3?, timeScale: number?, speedScale: number?): number
	if Presentation.ReducedFlashes and Emitters.IsFlash(name) then
		count *= 0.35
	end
	local amount = Presentation.BurstCount(count)
	if amount <= 0 then
		return 0
	end
	local tint = color or Color3.new(1, 1, 1)
	local scale = bucket(timeScale or 1)
	local key = name .. "|" .. colorKey(tint) .. "|" .. scale
	local now = os.clock()
	local entry = pool[key]
	if not entry then
		if not makeRoom(now) then
			return 0
		end
		entry = build(name, tint, scale)
		if not entry then
			return 0
		end
		pool[key] = entry
		poolSize += 1
	end
	local item = entry :: Entry
	item.LastUsed = now
	local emitter = item.Emitter
	local layer = LAYERS[name]
	if layer and speedScale and speedScale ~= 1 then
		emitter.Speed = NumberRange.new(layer.Speed.Min * speedScale, layer.Speed.Max * speedScale)
	elseif layer then
		emitter.Speed = layer.Speed
	end
	if Presentation.ReducedFlashes then
		emitter.Brightness = math.min(layer and layer.Brightness or 1, 0.6)
	elseif layer then
		emitter.Brightness = layer.Brightness or 1
	end
	item.Attachment.CFrame = frame
	emitter:Emit(amount)
	return amount
end

function Emitters.GetStats(): { Pooled: number }
	return { Pooled = poolSize }
end

return Emitters
