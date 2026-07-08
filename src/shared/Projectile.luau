--!optimize 2
--[[
	Projectile.luau
	Server-authoritative, raycast-driven projectiles that live in dilated time.
	Every projectile steps in the local time of the chunk it currently occupies,
	so a bullet flying through a 0.2x slow zone crawls, its gravity floats, and
	its fuse burns slower — all for free.

	Supported behaviours (mix and match): straight shots, ballistic gravity,
	bouncing (restitution), homing (explicit target or auto-acquire by tag),
	piercing with falloff, and cone bursts. Rendering can be offloaded to
	clients (Visualize = true): the server keeps only the logic, streams spawn /
	sync / hit events through VisualOffload, and clients simulate the visual
	with the exact same chunk/global time scales.

	API:
	 Projectile.new(config) -> projectile
	 Projectile.Burst(config, count) -> { projectile }
	 Projectile.EnableClientRendering()          -- call once on the client
	 Projectile.SetImpactHandler(fn(position, normal, model))  -- client VFX hook

	 config (all optional unless noted):
	   Origin: Vector3          (required)
	   Direction: Vector3       (required unless TargetPosition given)
	   TargetPosition: Vector3  (aim at a world point instead of a direction)
	   Speed = 100
	   Lifetime = 5             (dilated seconds)
	   Damage = 0
	   Source = entity          (deals the damage; never hits itself)
	   Filter = (entity)->bool  (which entities count as targets)
	   Gravity = 0              (studs/s² downward, integrated with dilated dt)
	   Radius = 0               (>0 uses a spherecast)
	   Bounces = 0              (world bounces before it dies)
	   Restitution = 0.5        (velocity kept per bounce)
	   MaxPierces = 0           (enemies passed through)
	   PierceFalloff = 0        (damage lost per pierce, 0..1)
	   Homing = { Target?, TargetTag?, AcquireRadius?, Retarget?, ReacquireRate?,
	              TurnRate = rad/s, Delay = 0 }
	   Visualize = false, VisualRange = math.huge
	   Model = Instance?        (cloned client-side) or Visual = {Shape,Size,Color}
	   DestroyDelay = 0         (client keeps the visual this long after impact)
	   OnHit = fn(projectile, result, hitEntity?)
	   OnBounce = fn(projectile, result)
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Heartbeat = require(script.Parent.Heartbeat)
local ChunkManager = require(script.Parent.ChunkManager)
local Entity = require(script.Parent.Entity)
local VisualOffload = require(script.Parent.VisualOffload)

local Projectile = {}
Projectile.__index = Projectile

local active = {} -- server-side live projectiles
local nextId = 0

-- When on, every movement raycast is streamed to rendering clients so the hit
-- detection can be seen as lines (see ProjRay in the client renderer). Toggle
-- from a client via the "SetProjectileDebug" channel.
local debugRays = true

function Projectile.SetDebugRays(enabled: boolean)
	debugRays = enabled and true or false
end

-- Adaptive raycast resolution. In chunks that contain entities we step finely so
-- fast bullets can't tunnel through a target; in empty chunks we take one long
-- cast per frame (walls still register, but we skip the wasted fine checks).
local HIGH_RES_STEP = 4 -- studs per raycast near entities
local LOW_RES_STEP = 64 -- studs per raycast in empty space
local MAX_SUBSTEPS = 16

--------------------------------------------------------------------------------
-- Geometry helpers
--------------------------------------------------------------------------------

local function safeUnit(v: Vector3, fallback: Vector3): Vector3
	local magnitude = v.Magnitude
	if magnitude < 1e-5 then
		return fallback
	end
	return v / magnitude
end

-- Rotate `from` toward `to` by at most `maxAngle` radians, preserving length.
local function rotateTowards(from: Vector3, to: Vector3, maxAngle: number): Vector3
	local fromDir = safeUnit(from, Vector3.zAxis)
	local toDir = safeUnit(to, fromDir)
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

local function coneDirection(dir: Vector3, spreadDeg: number): Vector3
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
	return safeUnit(dir + radial, dir)
end

--------------------------------------------------------------------------------
-- Homing target resolution
--------------------------------------------------------------------------------

local function targetPosition(target): Vector3?
	if target == nil then
		return nil
	end
	if typeof(target) == "Vector3" then
		return target
	end
	if typeof(target) == "Instance" then
		if target:IsA("BasePart") then
			return target.Position
		elseif target:IsA("Model") then
			return target:GetPivot().Position
		end
		return nil
	end
	-- assume an Entity
	if target.IsDestroyed then
		return nil
	end
	if target.GetPosition then
		return target:GetPosition()
	end
	return nil
end

local function acquireTarget(homing, position: Vector3)
	local best, bestDist = nil, homing.AcquireRadius or math.huge
	local candidates = homing.TargetTag and Entity.GetTagged(homing.TargetTag) or Entity.GetAll()
	for _, entity in candidates do
		if not entity.IsDestroyed then
			local distance = (entity:GetPosition() - position).Magnitude
			if distance <= bestDist then
				best, bestDist = entity, distance
			end
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Raycasting
--------------------------------------------------------------------------------

local function buildRayParams(projectile)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	local source = projectile.Source
	if source and source.Instance then
		table.insert(ignore, source.Instance)
	end
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	return params
end

local function castMovement(projectile, origin: Vector3, displacement: Vector3)
	local params = buildRayParams(projectile)
	if projectile.Radius > 0 then
		return workspace:Spherecast(origin, projectile.Radius, displacement, params)
	end
	return workspace:Raycast(origin, displacement, params)
end

-- Does the chunk containing `position` currently hold any entities? Drives the
-- high/low resolution decision each frame.
local function chunkHasEntities(position: Vector3): boolean
	local chunk = ChunkManager.GetChunk(position)
	return chunk ~= nil and chunk.EntityCount > 0
end

--------------------------------------------------------------------------------
-- Visual replication (server -> clients)
--------------------------------------------------------------------------------

local function streamTo(projectile, channel: string, payload: any)
	if not projectile.Visualize then
		return
	end
	if projectile.VisualRange >= math.huge then
		VisualOffload.Fire(channel, payload)
		return
	end
	local origin = projectile.Position
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character.PrimaryPart
		if root and (root.Position - origin).Magnitude <= projectile.VisualRange then
			VisualOffload.FireClient(player, channel, payload)
		end
	end
end

local function spawnVisual(projectile)
	streamTo(projectile, "ProjSpawn", {
		Id = projectile.Id,
		Position = projectile.Position,
		Velocity = projectile.Velocity,
		Gravity = projectile.Gravity,
		Lifetime = projectile.Lifetime,
		Model = projectile.Model,
		Visual = projectile.Visual,
		DestroyDelay = projectile.DestroyDelay,
	})
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function Projectile.new(config)
	nextId += 1

	local origin = config.Origin or Vector3.zero
	local direction
	if config.TargetPosition then
		direction = safeUnit(config.TargetPosition - origin, Vector3.zAxis)
	else
		direction = safeUnit(config.Direction or Vector3.zAxis, Vector3.zAxis)
	end
	local speed = config.Speed or 100

	local bounces = config.Bounces or 0

	local self = setmetatable({
		Id = nextId,
		Position = origin,
		Velocity = direction * speed,
		Speed = speed,
		Gravity = config.Gravity or 0,
		Radius = config.Radius or 0,

		Lifetime = config.Lifetime or 5,
		Age = 0,

		Damage = config.Damage or 0,
		DamageMultiplier = 1,
		Source = config.Source,
		Filter = config.Filter,

		BouncesLeft = bounces,
		Restitution = config.Restitution or 0.5,

		PiercesLeft = config.MaxPierces or 0,
		PierceFalloff = config.PierceFalloff or 0,

		Homing = config.Homing,
		HomingDelay = config.Homing and (config.Homing.Delay or 0) or 0,
		HomingTarget = config.Homing and config.Homing.Target,
		ReacquireTimer = 0,

		Visualize = config.Visualize == true,
		VisualRange = config.VisualRange or math.huge,
		Model = config.Model,
		Visual = config.Visual,
		DestroyDelay = config.DestroyDelay or 0,

		OnHit = config.OnHit,
		OnBounce = config.OnBounce,

		_ignore = {}, -- entities already pierced
		_syncTimer = 0,
		Dead = false,
	}, Projectile)

	table.insert(active, self)
	spawnVisual(self)
	return self
end

-- Cone burst: `count` projectiles spread around the base direction.
function Projectile.Burst(config, count: number)
	local origin = config.Origin or Vector3.zero
	local baseDir
	if config.TargetPosition then
		baseDir = safeUnit(config.TargetPosition - origin, Vector3.zAxis)
	else
		baseDir = safeUnit(config.Direction or Vector3.zAxis, Vector3.zAxis)
	end

	local spread = config.Spread or 0
	local shots = {}
	for _ = 1, count do
		local pelletConfig = table.clone(config)
		pelletConfig.TargetPosition = nil
		pelletConfig.Direction = coneDirection(baseDir, spread)
		table.insert(shots, Projectile.new(pelletConfig))
	end
	return shots
end

--------------------------------------------------------------------------------
-- Per-projectile step
--------------------------------------------------------------------------------

function Projectile:_dealDamage(entity, result)
	local damage = self.Damage * self.DamageMultiplier
	if damage <= 0 then
		return
	end
	local info = { Type = "Projectile", Source = self.Source, Position = result.Position }
	if self.Source and self.Source.DealDamage then
		self.Source:DealDamage(entity, damage, info)
	else
		entity:TakeDamage(damage, info)
	end
end

-- Broadcasts a hit marker to rendering clients. Fired on real collisions
-- (entity/world/bounce) but NOT when a projectile merely expires in the air, so
-- the client can distinguish an impact from a fizzle. Respects Visualize/Range.
function Projectile:_streamImpact(position: Vector3, normal: Vector3, kind: string)
	streamTo(self, "ProjImpact", { Position = position, Normal = normal, Kind = kind })
end

-- Broadcasts a single movement raycast segment for debug visualization.
-- lowRes marks the coarse casts taken through empty (entity-free) chunks.
function Projectile:_streamRay(from: Vector3, to: Vector3, lowRes: boolean)
	streamTo(self, "ProjRay", { From = from, To = to, LowRes = lowRes })
end

-- Returns "continue" | "destroy" after resolving a hit.
function Projectile:_resolveHit(result)
	local instance = result.Instance
	local entity = instance and Entity.Get(instance)

	if entity then
		if entity == self.Source or self._ignore[entity] then
			-- can't collide with ourselves or an already-pierced target;
			-- nudge past the surface and keep going
			self.Position = result.Position + safeUnit(self.Velocity, Vector3.zAxis) * (self.Radius + 0.1)
			return "continue"
		end
		if not self.Filter or self.Filter(entity) then
			self:_dealDamage(entity, result)
			self:_streamImpact(result.Position, result.Normal, "entity")
			if self.OnHit then
				task.spawn(self.OnHit, self, result, entity)
			end
			if self.PiercesLeft > 0 then
				self.PiercesLeft -= 1
				self.DamageMultiplier *= (1 - self.PierceFalloff)
				self._ignore[entity] = true
				self.Position = result.Position + safeUnit(self.Velocity, Vector3.zAxis) * (self.Radius + 0.1)
				return "continue"
			end
			return "destroy"
		end
	end

	-- world geometry (or a filtered-out entity): bounce if we can
	if self.BouncesLeft > 0 then
		self.BouncesLeft -= 1
		local normal = result.Normal
		local reflected = self.Velocity - 2 * self.Velocity:Dot(normal) * normal
		self.Velocity = reflected * self.Restitution
		self.Position = result.Position + normal * (self.Radius + 0.05)
		self:_streamImpact(result.Position, normal, "bounce")
		if self.OnBounce then
			task.spawn(self.OnBounce, self, result)
		end
		return "continue"
	end

	self:_streamImpact(result.Position, result.Normal, "world")
	if self.OnHit then
		task.spawn(self.OnHit, self, result, entity)
	end
	return "destroy"
end

function Projectile:_updateHoming(dt: number)
	local homing = self.Homing
	if not homing then
		return
	end

	if self.HomingDelay > 0 then
		self.HomingDelay -= dt
		return
	end

	-- (re)acquire a target when none / auto-targeting
	local target = self.HomingTarget
	if target == nil or targetPosition(target) == nil then
		if homing.AcquireRadius or homing.TargetTag then
			self.HomingTarget = acquireTarget(homing, self.Position)
			target = self.HomingTarget
		end
	elseif homing.Retarget then
		self.ReacquireTimer -= dt
		if self.ReacquireTimer <= 0 then
			self.ReacquireTimer = homing.ReacquireRate or 0.3
			self.HomingTarget = acquireTarget(homing, self.Position) or target
			target = self.HomingTarget
		end
	end

	local goal = targetPosition(target)
	if not goal then
		return
	end
	local desired = goal - self.Position
	local turn = (homing.TurnRate or math.rad(120)) * dt
	local speed = self.Velocity.Magnitude
	local newDir = rotateTowards(self.Velocity, desired, turn)
	self.Velocity = newDir * speed
end

-- Advances the projectile; returns false when it should be removed.
function Projectile:Step(globalDt: number): boolean
	if self.Dead then
		return false
	end

	local dt = ChunkManager.ScaleDt(globalDt, self.Position)
	if dt <= 0 then
		return true -- frozen chunk / paused: keep it alive, don't move it
	end

	self.Age += dt
	if self.Age >= self.Lifetime then
		local result = { Position = self.Position, Normal = Vector3.yAxis, Instance = nil }
		if self.OnHit then
			task.spawn(self.OnHit, self, result, nil)
		end
		return false
	end

	self:_updateHoming(dt)

	if self.Gravity > 0 then
		self.Velocity -= Vector3.new(0, self.Gravity * dt, 0)
	end

	-- Adaptive stepping: fine casts near entities (accurate hit detection),
	-- one coarse cast per frame in empty chunks (skip the wasted checks). The
	-- step size is chosen from whether the chunk we're in / moving into holds
	-- entities.
	local highRes = chunkHasEntities(self.Position)
		or chunkHasEntities(self.Position + self.Velocity * dt)
	local maxStep = highRes and HIGH_RES_STEP or LOW_RES_STEP

	local remaining = dt
	local guard = 0
	while remaining > 1e-4 and guard < MAX_SUBSTEPS do
		guard += 1
		local speed = self.Velocity.Magnitude
		local stepDt = remaining
		if speed * stepDt > maxStep then
			stepDt = maxStep / math.max(speed, 1e-3)
		end

		local from = self.Position
		local displacement = self.Velocity * stepDt
		local result = castMovement(self, from, displacement)
		if debugRays then
			self:_streamRay(from, result and result.Position or (from + displacement), not highRes)
		end

		if not result then
			self.Position = from + displacement
			remaining -= stepDt
		else
			local verdict = self:_resolveHit(result)
			if verdict == "destroy" then
				return false
			end
			-- pierce/bounce/ignore already advanced self.Position past the surface
			remaining -= stepDt
		end
	end

	-- Stream the authoritative position each frame; the client tweens the visual
	-- toward it (see ProjMove in the renderer).
	streamTo(self, "ProjMove", { Id = self.Id, Position = self.Position, Velocity = self.Velocity })

	return true
end

function Projectile:Destroy(result)
	if self.Dead then
		return
	end
	self.Dead = true
	local hitResult = result or { Position = self.Position, Normal = Vector3.yAxis }
	streamTo(self, "ProjHit", { Id = self.Id, Position = hitResult.Position, Normal = hitResult.Normal })
end

--------------------------------------------------------------------------------
-- Server step loop
--------------------------------------------------------------------------------

if RunService:IsServer() then
	Heartbeat.Connect(function(globalDt)
		for i = #active, 1, -1 do
			local projectile = active[i]
			local alive = projectile:Step(globalDt)
			if not alive then
				local last = #active
				active[i] = active[last]
				active[last] = nil
				projectile:Destroy({ Position = projectile.Position, Normal = Vector3.yAxis })
			end
		end
	end, { Name = "ProjectileSystem.Step", Priority = 5 })
end

--------------------------------------------------------------------------------
-- Client-side visual rendering (opt-in)
--------------------------------------------------------------------------------

local clientRendering = false
local visuals = {} -- [id] = { model, position, velocity, gravity, life }

-- Custom impact hook: fn(position, normal, model?, kind). When set, it replaces
-- the built-in effect below. (model is nil for impacts; kind is
-- "entity" | "world" | "bounce".)
local impactHandler: ((Vector3, Vector3, Instance?, string?) -> ())? = nil

function Projectile.SetImpactHandler(fn)
	impactHandler = fn
end

-- Built-in hit visualization: a short, real-time neon flash at the impact point
-- plus a ring spreading along the surface, color-coded by what was struck.
local IMPACT_COLORS = {
	entity = Color3.fromRGB(255, 80, 80), -- hit a damageable target
	world = Color3.fromRGB(255, 225, 150), -- hit geometry
	bounce = Color3.fromRGB(120, 220, 255), -- ricochet
}

local function defaultImpact(position: Vector3, normal: Vector3, kind: string?)
	local color = IMPACT_COLORS[kind or "world"] or IMPACT_COLORS.world
	local big = kind ~= "bounce"
	local info = TweenInfo.new(big and 0.28 or 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	-- expanding core flash
	local burst = Instance.new("Part")
	burst.Shape = Enum.PartType.Ball
	burst.Size = Vector3.one * (big and 0.6 or 0.3)
	burst.CFrame = CFrame.new(position)
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanQuery = false
	burst.CanTouch = false
	burst.CastShadow = false
	burst.Material = Enum.Material.Neon
	burst.Color = color
	burst.Transparency = 0.1
	burst.Parent = workspace
	TweenService:Create(burst, info, { Size = Vector3.one * (big and 3.5 or 1.5), Transparency = 1 }):Play()

	-- flat ring spreading along the surface (Cylinder's length runs along local X,
	-- so aim X down the normal and keep it thin there)
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.12, 0.5, 0.5)
	local n = normal.Magnitude > 1e-3 and normal.Unit or Vector3.yAxis
	ring.CFrame = CFrame.new(position, position + n) * CFrame.Angles(0, math.rad(90), 0)
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.2
	ring.Parent = workspace
	local ringSpan = big and 4 or 2
	TweenService:Create(ring, info, { Size = Vector3.new(0.12, ringSpan, ringSpan), Transparency = 1 }):Play()

	task.delay(info.Time, function()
		burst:Destroy()
		ring:Destroy()
	end)
end

local function playImpact(position: Vector3, normal: Vector3?, kind: string?)
	local n = normal or Vector3.yAxis
	if impactHandler then
		task.spawn(impactHandler, position, n, nil, kind)
	else
		defaultImpact(position, n, kind)
	end
end

-- Debug: draw one raycast segment as a thin fading line, colored by resolution.
-- Red = coarse cast through an empty chunk; green = fine cast near entities.
local RAY_LOWRES_COLOR = Color3.fromRGB(255, 70, 70)
local RAY_HIGHRES_COLOR = Color3.fromRGB(90, 255, 140)

local function drawRay(from: Vector3, to: Vector3, lowRes: boolean?)
	local delta = to - from
	local dist = delta.Magnitude
	if dist < 1e-3 then
		return
	end
	local line = Instance.new("Part")
	line.Anchored = true
	line.CanCollide = false
	line.CanQuery = false
	line.CanTouch = false
	line.CastShadow = false
	line.Material = Enum.Material.Neon
	line.Color = lowRes and RAY_LOWRES_COLOR or RAY_HIGHRES_COLOR
	line.Size = Vector3.new(0.08, 0.08, dist)
	line.CFrame = CFrame.lookAt((from + to) * 0.5, to)
	line.Transparency = 0.15
	line.Parent = workspace
	TweenService:Create(line, TweenInfo.new(0.3, Enum.EasingStyle.Linear), { Transparency = 1 }):Play()
	task.delay(0.3, function()
		line:Destroy()
	end)
end

local function buildVisualModel(data): Instance
	local model
	if data.Model then
		model = data.Model:Clone()
	else
		local part = Instance.new("Part")
		local spec = data.Visual
		if spec then
			if spec.Shape == "Ball" then
				part.Shape = Enum.PartType.Ball
			elseif spec.Shape == "Cylinder" then
				part.Shape = Enum.PartType.Cylinder
			end
			part.Size = spec.Size or Vector3.one * 0.5
			part.Color = spec.Color or Color3.new(1, 1, 1)
		else
			part.Size = Vector3.one * 0.4
			part.Color = Color3.fromRGB(255, 220, 120)
		end
		part.Material = Enum.Material.Neon
		model = part
	end

	for _, part in { model, table.unpack(model:GetDescendants()) } do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
		end
	end
	model.Parent = workspace
	return model
end

local function placeVisual(model: Instance, position: Vector3, velocity: Vector3)
	local look = position + safeUnit(velocity, Vector3.zAxis)
	local cframe = CFrame.new(position, look)
	if model:IsA("Model") then
		model:PivotTo(cframe)
	elseif model:IsA("BasePart") then
		model.CFrame = cframe
	end
end

-- Smoothly move a bullet visual toward the latest authoritative pose via a tween.
-- Duration adapts to how often updates arrive, so motion stays continuous whether
-- the server is stepping fast (near entities) or coarsely (empty space), and it
-- naturally slows when the world's time ratio drops (updates arrive slower).
local function tweenVisual(visual, position: Vector3, velocity: Vector3, duration: number)
	local look = position + safeUnit(velocity, Vector3.zAxis)
	local goal = CFrame.new(position, look)
	local info = TweenInfo.new(duration, Enum.EasingStyle.Linear)

	if visual.tween then
		visual.tween:Cancel()
		visual.tween = nil
	end

	local model = visual.model
	local target = model
	if model:IsA("Model") then
		target = model.PrimaryPart
	end
	if target and target:IsA("BasePart") then
		visual.tween = TweenService:Create(target, info, { CFrame = goal })
		visual.tween:Play()
	elseif model:IsA("Model") then
		model:PivotTo(goal) -- no primary part to tween; snap
	end
end

-- Removes the flying tracer. Impact VFX is handled separately by ProjImpact, so
-- this fires for real hits AND harmless expiry without ever flashing in mid-air.
local function destroyVisual(id)
	local visual = visuals[id]
	if not visual then
		return
	end
	visuals[id] = nil
	local delay = visual.destroyDelay or 0
	if delay > 0 then
		task.delay(delay, function()
			visual.model:Destroy()
		end)
	else
		visual.model:Destroy()
	end
end

function Projectile.EnableClientRendering()
	if clientRendering or RunService:IsServer() then
		return
	end
	clientRendering = true

	VisualOffload.On("ProjSpawn", function(data)
		local model = buildVisualModel(data)
		placeVisual(model, data.Position, data.Velocity)
		visuals[data.Id] = {
			model = model,
			destroyDelay = data.DestroyDelay or 0,
			lastUpdate = os.clock(),
			tween = nil,
		}
	end)

	-- Authoritative pose each frame -> tween the visual toward it. The tween
	-- duration matches the real time since the previous update, so movement is
	-- smooth across coarse (empty-chunk) steps and slows with the time ratio.
	VisualOffload.On("ProjMove", function(data)
		local visual = visuals[data.Id]
		if not visual then
			return
		end
		local now = os.clock()
		local duration = math.clamp(now - visual.lastUpdate, 0.03, 0.2)
		visual.lastUpdate = now
		tweenVisual(visual, data.Position, data.Velocity, duration)
	end)

	VisualOffload.On("ProjHit", function(data)
		destroyVisual(data.Id)
	end)

	VisualOffload.On("ProjImpact", function(data)
		playImpact(data.Position, data.Normal, data.Kind)
	end)

	VisualOffload.On("ProjRay", function(data)
		drawRay(data.From, data.To, data.LowRes)
	end)

	-- Janitor: clear visuals that stopped receiving updates (e.g. the projectile
	-- left our VisualRange, so no ProjHit will arrive). Real-time, not dilated.
	task.spawn(function()
		while clientRendering do
			local now = os.clock()
			for id, visual in visuals do
				if now - visual.lastUpdate > 1.5 then
					destroyVisual(id)
				end
			end
			task.wait(0.5)
		end
	end)
end

return Projectile
