--!optimize 2
--[[
	SpellEffects (client, purely cosmetic)
	Renders instant Explosions and legacy SpellBeam flashes. New traveling
	Beams use ProjectileClient/BeamVisual and the regular projectile protocol;
	SpellRuntime no longer emits fixed SpellBeam rays.
	Self-registers its listeners at require time, same as WeaponEffects.luau.

	"SpellBeam" payload (server -> all clients):
	 - Points: { Vector3 } -- start, each bounce point, end
	 - Width: number -- the beam's hit diameter
	 - Color: Color3 (glow), Core: Color3 (hot centre)
	 - Normal: Vector3? -- surface normal where it stopped
	 - Kind: "entity" | "world" | nil -- what stopped it (nil = ran out of range)

	"SpellExplosions" payload (server -> each client, once a frame): a list of
	 "SpellExplosion" payloads -- the blasts that client can see or hear.
	"SpellExplosion" payload (one blast; still accepted):
	 - Position: Vector3, Radius: number (blast radius), Color: Color3,
	   Power: number? (centre damage), Normal: Vector3? (struck surface)
	 Rendered by ExplosionVFX (through Effects.Explosion, which adds what the
	 struck surface calls for), scaling size/colour/layers with Power.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)
local Impact = require(Shared.Projectile.Client.Impact)
local Effects = require(script.Parent.Effects)
local _SpellCircleVFX = require(script.Parent.SpellCircleVFX) -- self-registers "SpellCircle"
local _SpellBodyClient = require(script.Parent.SpellBodyClient) -- impulses, body effects, "SpellFX"

local SpellEffects = {}

local FADE_TIME = 0.35
local MIN_WIDTH = 0.35

local fadeInfo = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function neon(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	for key, value in props do
		(part :: any)[key] = value
	end
	return part
end

-- A Cylinder's length runs along its X axis, so turn the segment's look
-- frame 90 degrees to lay it along a -> b.
local function cylinderAlong(a: Vector3, b: Vector3): CFrame
	return CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.rad(90), 0)
end

local function segment(a: Vector3, b: Vector3, width: number, core: Color3, glow: Color3)
	local length = (b - a).Magnitude
	if length < 0.05 then
		return
	end
	local frame = cylinderAlong(a, b)
	local inner = neon({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(length, width * 0.45, width * 0.45), CFrame = frame, Color = core })
	local outer = neon({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(length, width * 1.4, width * 1.4), CFrame = frame, Color = glow, Transparency = 0.5 })
	inner.Parent = workspace
	outer.Parent = workspace
	-- Thin to nothing while the glow swells and fades: a flash, then gone.
	TweenService:Create(inner, fadeInfo, { Size = Vector3.new(length, 0.02, 0.02), Transparency = 1 }):Play()
	TweenService:Create(outer, fadeInfo, { Size = Vector3.new(length, width * 2.4, width * 2.4), Transparency = 1 }):Play()
	Debris:AddItem(inner, FADE_TIME + 0.1)
	Debris:AddItem(outer, FADE_TIME + 0.1)
end

local function flare(position: Vector3, width: number, color: Color3)
	local ball = neon({ Shape = Enum.PartType.Ball, Size = Vector3.one * width * 2, CFrame = CFrame.new(position), Color = color, Transparency = 0.2 })
	local glow = Instance.new("PointLight")
	glow.Color = color
	glow.Range = 16
	glow.Brightness = 4
	glow.Parent = ball
	ball.Parent = workspace
	TweenService:Create(ball, fadeInfo, { Size = Vector3.one * width * 5, Transparency = 1 }):Play()
	TweenService:Create(glow, fadeInfo, { Brightness = 0 }):Play()
	Debris:AddItem(ball, FADE_TIME + 0.1)
end

-- The beam's heading into a point, at a nominal beam speed (impacts lean
-- their spray along it).
local function travel(from: Vector3, to: Vector3): Vector3?
	local offset = to - from
	return if offset.Magnitude > 1e-3 then offset.Unit * 600 else nil
end

VisualOffload.On("SpellBeam", function(data)
	local points = data.Points
	if typeof(points) ~= "table" or #points < 2 then
		return
	end
	local width = math.max(data.Width or MIN_WIDTH, MIN_WIDTH)
	local core = data.Core or Color3.new(1, 1, 1)
	local glow = data.Color or core
	for index = 1, #points - 1 do
		segment(points[index], points[index + 1], width, core, glow)
	end
	flare(points[1], width, glow)
	for index = 2, #points - 1 do
		Impact.Play(points[index], nil, "bounce", { Velocity = travel(points[index - 1], points[index]), Color = glow })
	end
	if data.Kind then
		flare(points[#points], width * 1.5, glow)
		Impact.Play(points[#points], data.Normal, data.Kind,
			{ Velocity = travel(points[#points - 1], points[#points]), Color = glow })
	end
end)

local function playExplosion(data: any)
	if typeof(data) ~= "table" then
		return
	end
	local position = data.Position
	if typeof(position) ~= "Vector3" then
		return
	end
	Effects.Explosion(position, {
		Power = if typeof(data.Power) == "number" then data.Power else nil,
		Radius = math.max(if typeof(data.Radius) == "number" then data.Radius else 6, 1),
		Theme = if typeof(data.Element) == "string" then data.Element else nil,
		Color = if typeof(data.Color) == "Color3" then data.Color else nil,
		Normal = if typeof(data.Normal) == "Vector3" then data.Normal else nil,
	})
end

VisualOffload.On("SpellExplosion", playExplosion)
-- (the server's per-frame batch: this frame's blasts in range of us)
VisualOffload.On("SpellExplosions", function(list)
	if typeof(list) ~= "table" then
		return
	end
	for _, data in list do
		playExplosion(data)
	end
end)

return SpellEffects
