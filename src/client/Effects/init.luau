--!strict
--[[
	Effects (client, purely cosmetic: nothing here collides, replicates or
	touches hit detection)

	One front door for the game's one-shot and attached effects, sharing one
	budget, one set of pools and one time model:

	 Effects.Impact(position, normal?, options?)
	     A hit that adapts to what it hit and how: the surface is probed
	     (material family, colour, floor / wall / ceiling, terrain water,
	     underwater) and a recipe per family plays (see Recipes). Every
	     projectile and beam impact comes through here.
	     options: { Kind?, Strength?, Velocity?, Color?, Surface? }
	 Effects.Explosion(position, options)
	     ExplosionVFX.Play plus surface-aware extras (a splash column off
	     water, bubbles underwater, dust off sand, shards off glass, ...).
	 Effects.Swing(options) -> handle
	     Smooth blade arcs at any swing speed, with contact sparks / dust /
	     splash where the blade drags through something (see Swing).
	 Effects.AttachStreak(part, rootOffset, getVelocity, color?, width?) -> detach
	     Speed streaks for very fast projectiles (see Streak); the projectile
	     renderer attaches one to every visual it builds.
	 Effects.Register(name, fn) / Effects.Play(name, context)
	     Named, data-driven effects. "Impact.<Family>" (e.g. "Impact.Metal")
	     replaces that family's built-in impact recipe: fn(surface, context).
	 Effects.Configure({ SurfaceImpacts?, ProjectileStreaks?, BladeTrails? })
	 Effects.GetStats()

	Budget: impacts are queued and flushed once per frame. Ones within
	MERGE_RADIUS of each other in the same frame merge into one stronger
	impact; the nearest FULL_PER_FRAME (within FULL_DISTANCE) get the full
	recipe, the rest up to MAX_PER_FRAME a reduced one, and anything far or
	behind the camera is skipped. Particle counts follow the Particle effects
	intensity setting; Reduced flashes dims lights and sparks. Debris, marks,
	lights and emitters are pooled with hard caps.

	Time: everything advances on the local time scale (global x chunk), so an
	impact inside a slowed zone plays slowly and a frozen one hangs in place.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FrameProfiler = require(Shared.FrameProfiler)
local ProjectileClient = require(Shared.Projectile.Client)

local Debris = require(script.Debris)
local Emitters = require(script.Emitters)
local Recipes = require(script.Recipes)
local Streak = require(script.Streak)
local Surface = require(script.Surface)
local Swing = require(script.Swing)
local Util = require(script.Util)
local ExplosionVFX = require(script.Parent.ExplosionVFX)
local SpatialAudio = require(script.Parent.SpatialAudio)

local Effects = {}

local MERGE_RADIUS = 2.5
local FULL_PER_FRAME = 10
local FULL_DISTANCE = 160
local MAX_PER_FRAME = 40
local MAX_DISTANCE = 450
local BEHIND_DISTANCE = 60 -- behind the camera, only this close still plays
local MAX_QUEUE = 256
local EXPLOSION_DETAIL_DISTANCE = 500

local KIND_STRENGTH: { [string]: number } = {
	world = 1,
	entity = 0.8,
	bounce = 0.6,
	detonate = 0.9,
	scrape = 0.6,
}

local config = {
	SurfaceImpacts = true,
	ProjectileStreaks = true,
	BladeTrails = true,
}

local registry: { [string]: (any) -> any } = {}

export type ImpactOptions = {
	Kind: string?,
	Strength: number?,
	Velocity: Vector3?,
	Color: Color3?,
	Surface: Surface.Info?,
}

type Queued = {
	Position: Vector3,
	Normal: Vector3?,
	Kind: string,
	Strength: number,
	Velocity: Vector3?,
	Color: Color3?,
	Surface: Surface.Info?,
	Distance: number,
}

local queue: { Queued } = {}
local stats = { Impacts = 0, Merged = 0, Skipped = 0, Reduced = 0 }

function Effects.Register(name: string, fn: (any) -> any)
	registry[name] = fn
end

function Effects.Play(name: string, context: any): any
	local fn = registry[name]
	if fn then
		return fn(context)
	end
	warn(`[Effects] no effect named {name}`)
	return nil
end

function Effects.Configure(options: { [string]: boolean? })
	for key, value in options do
		if config[key] ~= nil and value ~= nil then
			config[key] = value
		end
	end
	Streak.Enabled = config.ProjectileStreaks
	Swing.Enabled = config.BladeTrails
end

function Effects.Impact(position: Vector3, normal: Vector3?, options: ImpactOptions?)
	if not config.SurfaceImpacts or #queue >= MAX_QUEUE then
		return
	end
	local opts: ImpactOptions = options or {}
	local kind = opts.Kind or "world"
	local strength = opts.Strength or KIND_STRENGTH[kind] or 1
	local velocity = opts.Velocity
	if not opts.Strength and velocity and kind ~= "scrape" then
		-- by Mach number (1 stud = 0.28 m): a ~60 m/s blaster bolt ~0.7,
		-- a supersonic railgun slug ~1.2, ~3x the speed of sound and up 1.8
		strength *= math.clamp(0.6 + 0.6 * velocity.Magnitude / SpatialAudio.SpeedOfSound, 0.6, 1.8)
	end
	table.insert(queue, {
		Position = position,
		Normal = normal,
		Kind = kind,
		Strength = strength,
		Velocity = velocity,
		Color = opts.Color,
		Surface = opts.Surface,
		Distance = 0,
	})
end

local kept: { Queued } = {}

local function flushImpacts()
	if #queue == 0 then
		return
	end
	table.clear(kept)
	for _, item in queue do
		local merged = false
		for _, other in kept do
			if other.Kind == item.Kind and (other.Position - item.Position).Magnitude < MERGE_RADIUS then
				other.Strength = math.min(other.Strength + item.Strength * 0.35, 3)
				merged = true
				break
			end
		end
		if merged then
			stats.Merged += 1
		else
			local distance, front = Util.View(item.Position)
			if distance > MAX_DISTANCE or (not front and distance > BEHIND_DISTANCE) then
				stats.Skipped += 1
			else
				item.Distance = distance
				table.insert(kept, item)
			end
		end
	end
	table.clear(queue)
	if #kept > FULL_PER_FRAME then
		table.sort(kept, function(a, b)
			return a.Distance < b.Distance
		end)
	end
	for index, item in kept do
		if index > MAX_PER_FRAME then
			stats.Skipped += #kept - MAX_PER_FRAME
			break
		end
		local tier = if index <= FULL_PER_FRAME and item.Distance <= FULL_DISTANCE then 1 else 2
		if tier == 2 then
			stats.Reduced += 1
		end
		local surface = item.Surface or Surface.Probe(item.Position, item.Normal, item.Velocity)
		if item.Kind == "entity" then
			surface.Family = "Flesh"
		end
		local context: Recipes.Context = {
			Kind = item.Kind,
			Strength = item.Strength,
			Velocity = item.Velocity,
			Color = item.Color,
			Tier = tier,
			TimeScale = Util.TimeScaleAt(item.Position),
		}
		local custom = registry["Impact." .. surface.Family]
		if custom then
			custom(surface, context)
		else
			Recipes.Impact(surface, context)
		end
		stats.Impacts += 1
	end
	table.clear(kept)
end

function Effects.Explosion(position: Vector3, options: any?)
	local opts = options or {}
	ExplosionVFX.Play(position, opts)
	if not config.SurfaceImpacts then
		return
	end
	local radius = opts.Radius or ExplosionVFX.Describe(opts.Power or 50, nil).Radius
	local distance = Util.View(position)
	if distance > EXPLOSION_DETAIL_DISTANCE * 2 then
		return
	end
	local down = -Util.Unit(opts.Normal, Vector3.yAxis)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = false
	params.FilterDescendantsInstances = Util.IgnoreList()
	local hit = workspace:Raycast(position - down * 0.5, down * (radius * 0.8 + 2), params)
	local underwater = Surface.Underwater(position)
	local surface = if hit then Surface.FromResult(hit, underwater) else Surface.Probe(position, nil, nil, params)
	if not hit and not surface.Underwater then
		return -- mid-air: ExplosionVFX already covers it
	end
	Recipes.Explosion(surface, radius, Util.TimeScaleAt(position), distance <= EXPLOSION_DETAIL_DISTANCE)
end

function Effects.Swing(options: Swing.Options): Swing.Handle
	return Swing.Start(options)
end

function Effects.AttachStreak(part: BasePart, rootOffset: CFrame, getVelocity: () -> Vector3, color: Color3?, width: number?): () -> ()
	return Streak.Attach(part, rootOffset, getVelocity, color, width)
end

function Effects.GetStats()
	local debris = Debris.GetStats()
	local swing = Swing.GetStats()
	local streak = Streak.GetStats()
	return {
		Impacts = stats.Impacts,
		Merged = stats.Merged,
		Skipped = stats.Skipped,
		Reduced = stats.Reduced,
		Emitters = Emitters.GetStats().Pooled,
		Debris = debris.Pieces,
		Marks = debris.Marks,
		Lights = debris.Lights,
		Swings = swing.Swings,
		SwingSegments = swing.Segments,
		Streaks = streak.Attached,
		StreaksActive = streak.Active,
	}
end

registry.Impact = function(context)
	Effects.Impact(context.Position, context.Normal, context)
end
registry.Explosion = function(context)
	Effects.Explosion(context.Position, context)
end
registry.Swing = function(context)
	return Effects.Swing(context)
end

local function step(dt: number)
	flushImpacts()
	Swing.Step(dt)
	Debris.Step(dt)
	Streak.Step(dt)
end

local started = false
function Effects.start()
	if started then
		return
	end
	started = true
	ProjectileClient.SetImpactHandler(function(position, normal, _model, kind, info)
		Effects.Impact(position, normal, {
			Kind = kind,
			Velocity = info and info.Velocity,
			Color = info and info.Color,
		})
	end)
	ProjectileClient.SetStreakHandler(function(part, rootOffset, getVelocity, color, width)
		-- only shots that start out fast (half the threshold, so a little
		-- acceleration still earns one): slow ones never pay for it
		if getVelocity().Magnitude * Util.TimeScaleAt(part.Position) < Streak.MinSpeed * 0.5 then
			return nil
		end
		return Streak.Attach(part, rootOffset, getVelocity, color, width)
	end)
	Swing.SetContactHandler(function(position, normal, velocity, strength)
		Effects.Impact(position, normal, {
			Kind = "scrape",
			Velocity = velocity,
			Strength = strength * math.clamp(velocity.Magnitude / 120, 0.4, 1.6),
		})
	end)
	-- Last: after the camera and any viewmodel have been posed this frame,
	-- so blade samples match what's drawn.
	RunService:BindToRenderStep("Effects", Enum.RenderPriority.Last.Value, FrameProfiler.Wrap("Effects.Step", step))
end

return Effects
