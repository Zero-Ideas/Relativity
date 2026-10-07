--!optimize 2
--[[
	ExplosionVFX.luau  (client, purely cosmetic)
	Explosions built from the hand-authored template
	ReplicatedStorage.Effects.ExplosionBase: a Part whose attachments group
	its ParticleEmitters by role (Energy, Sparks, Dust, Shockwaves, Debris,
	Smoke, Wind, GroundCrack). The template's +Y is the impact surface's
	normal. One number, Power (roughly the blast's centre damage), decides
	everything else:

	  intensity  0..1 on a log curve (POWER_FLOOR .. POWER_CEILING).
	  radius     ~ power^(1/3), unless the caller passes the gameplay Radius,
	             which wins so visuals match the hitbox. The template is
	             authored at REFERENCE_RADIUS; every emitter's Size, Speed,
	             Acceleration, ZOffset and source height scale by
	             radius / REFERENCE_RADIUS.
	  groups     which role attachments play, by intensity (GROUP_TIERS), in
	             this order: energy + sparks, smoke, dust, wind, debris,
	             shockwaves, then ground cracks on the biggest (GroundCrack
	             also needs ground under it).
	  detail     how many of a group's emitters play: they're ranked once by
	             visual weight (largest particle size x sqrt(EmitCount)) and a
	             blast uses the top share of each group, from MIN_EMITTER_SHARE
	             of it when the group first appears up to all of it at full
	             power -- small blasts are a handful of key emitters, big
	             ones the whole authored effect.
	  counts     each chosen emitter's EmitCount attribute x a count factor
	             that grows with intensity (fractional remainders emit with
	             that probability, so tiny blasts still get the odd particle).
	  shake      camera shake above SHAKE_FROM intensity, by distance.

	Template attributes honoured per emitter (all optional):
	  EmitCount, EmitDelay (s), EmitDuration (s; > 0 = enable at Rate for
	  that long instead of a burst), TimeScale_Start / TimeScale_End /
	  TimeScale_Duration (emitter time-scale ramp after it fires),
	  SourceHeight (studs above the surface it was authored at).

	Time dilation: each blast runs on its own clock (global x chunk/zone
	scale at its position); delays, durations and the time-scale ramps use
	that clock and every emitter's TimeScale follows it.

	Budget: past LOD_DISTANCE only Energy plays; past MAX_DETAILED_ACTIVE
	concurrent blasts counts halve and Smoke/Wind are dropped.

	API:
	 ExplosionVFX.Play(position, { Power, Radius?, Color?, Shake?, Normal? })
	     Normal: the struck surface's normal (e.g. from a projectile hit). The
	     effect is built on that surface with its +Y along the normal -- walls,
	     ceilings and slopes included. Without it, it looks straight down for
	     ground and is an upright air burst if there is none.
	 ExplosionVFX.Describe(power, radius?) -> table   -- derived parameters (debug)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared.ChunkManager)
local Heartbeat = require(Shared.Heartbeat)
local SpatialAudio = require(script.Parent.SpatialAudio)
local Crater = require(script.Parent.Crater)

local ExplosionVFX = {}

local TEMPLATE_NAME = "ExplosionBase"
local REFERENCE_RADIUS = 66 -- the template's shockwave spans ~132 studs
-- Intensity 0 and 1. The ceiling is about what a strong single-Mana-Well
-- spell reaches (1000 mana, 90% into an explosion ~ 650 Fire / 810 Arcane),
-- so every group -- GroundCrack included -- is attainable in play.
local POWER_FLOOR, POWER_CEILING = 5, 600
ExplosionVFX.PowerFloor, ExplosionVFX.PowerCeiling = POWER_FLOOR, POWER_CEILING
local MIN_RADIUS, MAX_RADIUS = 1.5, 120
local LOD_DISTANCE = 600
local MAX_DETAILED_ACTIVE = 12
local SHAKE_FROM = 0.2
local SHAKE_RANGE_RADII = 11
local MAX_SHAKE_DEGREES = 2.6
local SHAKE_JOLT = 0.35 -- studs of positional jolt at full strength, on top of the rotation
-- The shake hits when the shockwave reaches the camera. Inside the blast
-- radius that follows the template's expanding ring (Shockwaves.ShockwaveOut2:
-- its size curve, as a fraction of its final size, over its ~0.375s life --
-- its final radius is the blast radius); past it the wave carries on at the
-- speed of sound, like the boom (SpatialAudio).
local SHOCKWAVE_TIME = 0.375
local SHOCKWAVE_CURVE = { -- { fraction of SHOCKWAVE_TIME, fraction of the radius reached }
	{ 0, 0 }, { 0.1, 0.47 }, { 0.2, 0.663 }, { 0.3, 0.778 }, { 0.4, 0.852 }, { 0.5, 0.902 },
	{ 0.6, 0.936 }, { 0.7, 0.96 }, { 0.8, 0.977 }, { 0.9, 0.989 }, { 1, 1 },
}
local MAX_REAL_LIFETIME = 30

-- Intensity at which each role group starts playing, and its count factor
-- ramp (fraction of EmitCount at the threshold -> at intensity 1).
local GROUP_TIERS: { [string]: { From: number, Counts: { number } } } = {
	Energy = { From = 0, Counts = { 0.35, 1 } },
	Sparks = { From = 0, Counts = { 0.2, 1 } },
	Smoke = { From = 0.12, Counts = { 0.3, 1 } },
	Dust = { From = 0.25, Counts = { 0.3, 1 } },
	Wind = { From = 0.38, Counts = { 0.5, 1 } },
	Debris = { From = 0.5, Counts = { 0.3, 1 } },
	Shockwaves = { From = 0.62, Counts = { 1, 1 } },
	GroundCrack = { From = 0.72, Counts = { 1, 1 } },
}
local LOW_DETAIL_SKIP = { Smoke = true, Wind = true }
-- Share of a group's (ranked) emitters used when the group first appears;
-- ramps to 1 at full intensity. Always at least one emitter.
local MIN_EMITTER_SHARE = 0.12

local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

local function intensityFor(power: number): number
	return math.clamp(math.log(math.max(power, POWER_FLOOR) / POWER_FLOOR) / math.log(POWER_CEILING / POWER_FLOOR), 0, 1)
end

-- Everything an explosion of this power looks like, as plain numbers.
function ExplosionVFX.Describe(power: number, radius: number?)
	local intensity = intensityFor(power)
	local size = radius or math.clamp(1.2 * power ^ (1 / 3), MIN_RADIUS, MAX_RADIUS)
	local groups, shares = {}, {}
	for name, tier in GROUP_TIERS do
		if intensity >= tier.From then
			local t = if tier.From < 1 then (intensity - tier.From) / (1 - tier.From) else 1
			groups[name] = tier.Counts[1] + (tier.Counts[2] - tier.Counts[1]) * t
			shares[name] = MIN_EMITTER_SHARE + (1 - MIN_EMITTER_SHARE) * t * t
		end
	end
	return {
		Intensity = intensity,
		Radius = size,
		Scale = size / REFERENCE_RADIUS,
		Groups = groups, -- [group] = count factor
		Shares = shares, -- [group] = fraction of the group's ranked emitters used
		Shake = if intensity > SHAKE_FROM then smoothstep(SHAKE_FROM, 1, intensity) else 0,
	}
end

--------------------------------------------------------------------------------
-- Template + scaling helpers
--------------------------------------------------------------------------------

local function template(): BasePart?
	local effects = ReplicatedStorage:FindFirstChild("Effects")
	local found = (effects and effects:FindFirstChild(TEMPLATE_NAME)) or workspace:FindFirstChild(TEMPLATE_NAME)
	return if found and found:IsA("BasePart") then found else nil
end

-- A group's emitters, heaviest first: largest particle size x sqrt(count).
-- Cached per template attachment (rebuilt if its children change).
local rankedCache: { [Instance]: { ParticleEmitter } } = {}
local function rankedEmitters(group: Instance): { ParticleEmitter }
	local cached = rankedCache[group]
	if cached and #cached == #group:GetChildren() then
		return cached
	end
	local weights: { [ParticleEmitter]: number } = {}
	local list: { ParticleEmitter } = {}
	for _, child in group:GetChildren() do
		if child:IsA("ParticleEmitter") then
			local largest = 0
			for _, point in child.Size.Keypoints do
				largest = math.max(largest, point.Value + point.Envelope)
			end
			local count = (child:GetAttribute("EmitCount") :: number?) or 1
			weights[child] = largest * math.sqrt(math.max(count, 0.5))
			table.insert(list, child)
		end
	end
	table.sort(list, function(a, b)
		return weights[a] > weights[b]
	end)
	rankedCache[group] = list
	return list
end

local function scaledSequence(sequence: NumberSequence, factor: number): NumberSequence
	local points = {}
	for _, point in sequence.Keypoints do
		table.insert(points, NumberSequenceKeypoint.new(point.Time, point.Value * factor, point.Envelope * factor))
	end
	return NumberSequence.new(points)
end

local function tinted(sequence: ColorSequence, tint: Color3, amount: number): ColorSequence
	local points = {}
	for _, point in sequence.Keypoints do
		table.insert(points, ColorSequenceKeypoint.new(point.Time, point.Value:Lerp(tint, amount)))
	end
	return ColorSequence.new(points)
end

local folder: Folder? = nil
local function vfxFolder(): Folder
	if not folder or not folder.Parent then
		local created = Instance.new("Folder")
		created.Name = "ExplosionVFX"
		created.Parent = workspace
		folder = created
	end
	return folder :: Folder
end

local function surfaceAlong(position: Vector3, direction: Vector3, reach: number): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = { vfxFolder() }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	params.FilterDescendantsInstances = ignore
	return workspace:Raycast(position, direction.Unit * reach, params)
end

-- A frame at `position` whose +Y is `up` (the template's surface normal).
local function upright(position: Vector3, up: Vector3): CFrame
	local right = up:Cross(if math.abs(up.Z) < 0.9 then Vector3.zAxis else Vector3.xAxis).Unit
	return CFrame.fromMatrix(position, right, up)
end

--------------------------------------------------------------------------------
-- Active explosions + the shared animation loop
--------------------------------------------------------------------------------

type Shot = {
	Emitter: ParticleEmitter,
	Delay: number,
	Duration: number,
	Count: number,
	Fired: boolean,
	StopAt: number?,
	FiredAt: number,
	RampStart: number,
	RampEnd: number,
	RampDuration: number,
}
type Blast = {
	Position: Vector3,
	Spec: any,
	Root: BasePart,
	Light: PointLight,
	Shots: { Shot },
	Age: number, -- dilated seconds
	RealAge: number,
	Life: number,
	Shake: number,
}

local active: { Blast } = {}
local connection: RBXScriptConnection? = nil
local shakeBound = false

local function localScale(position: Vector3): number
	return Heartbeat.GetGlobalTimeScale() * ChunkManager.GetTimeScaleAt(position)
end

local function updateBlast(blast: Blast, dt: number): boolean
	local dilation = localScale(blast.Position)
	blast.Age += dt * dilation
	blast.RealAge += dt
	local age = blast.Age

	for _, shot in blast.Shots do
		local emitter = shot.Emitter
		if not shot.Fired and age >= shot.Delay then
			shot.Fired, shot.FiredAt = true, age
			if shot.Duration > 0 then
				emitter.Enabled = true
				shot.StopAt = age + shot.Duration
			elseif shot.Count > 0 then
				emitter:Emit(shot.Count)
			end
		end
		if shot.StopAt and age >= shot.StopAt then
			emitter.Enabled = false
			shot.StopAt = nil
		end
		-- authored time-scale ramp (after firing) x local dilation
		local ramp = 1
		if shot.Fired and shot.RampDuration > 0 then
			local t = math.clamp((age - shot.FiredAt) / shot.RampDuration, 0, 1)
			ramp = shot.RampStart + (shot.RampEnd - shot.RampStart) * t
		elseif shot.RampDuration > 0 then
			ramp = shot.RampStart
		end
		emitter.TimeScale = math.clamp(ramp * dilation, 0, 1)
	end

	-- the light flashes with the blast and decays over its first second
	local spec = blast.Spec
	blast.Light.Brightness = (2 + 8 * spec.Intensity) * math.clamp(1 - age / (0.4 + 0.8 * spec.Intensity), 0, 1) ^ 2

	if age >= blast.Life or blast.RealAge >= MAX_REAL_LIFETIME then
		blast.Root:Destroy()
		return false
	end
	return true
end

-- Seconds (blast clock) until the shockwave front reaches `distance` studs out.
local function shockwaveArrival(radius: number, distance: number): number
	if distance >= radius then
		return SHOCKWAVE_TIME + (distance - radius) / SpatialAudio.SpeedOfSound
	end
	local reached = distance / radius
	for index = 2, #SHOCKWAVE_CURVE do
		local previous, point = SHOCKWAVE_CURVE[index - 1], SHOCKWAVE_CURVE[index]
		if reached <= point[2] then
			local t = (reached - previous[2]) / (point[2] - previous[2])
			return (previous[1] + (point[1] - previous[1]) * t) * SHOCKWAVE_TIME
		end
	end
	return SHOCKWAVE_TIME
end

-- Camera shake: the strongest nearby blast wins; applied after the camera
-- scripts each frame, so it never accumulates into the camera's own state.
-- Each blast's shake starts when its shockwave reaches the camera, hitting
-- hardest on arrival and dying away after.
local function applyShake()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local strength = 0
	for _, blast in active do
		if blast.Shake > 0 then
			local distance = (camera.CFrame.Position - blast.Position).Magnitude
			local since = blast.Age - shockwaveArrival(blast.Spec.Radius, distance)
			local envelope = if since < 0 then 0 else math.clamp(1 - since / (0.4 + 1.1 * blast.Spec.Intensity), 0, 1)
			local reach = blast.Spec.Radius * SHAKE_RANGE_RADII
			local falloff = 1 - math.clamp(distance / reach, 0, 1)
			strength = math.max(strength, blast.Shake * envelope * envelope * falloff)
		end
	end
	if strength > 0.001 then
		local now = os.clock() * 37
		local amplitude = math.rad(MAX_SHAKE_DEGREES) * strength
		local jolt = SHAKE_JOLT * strength
		camera.CFrame *= CFrame.new(
			math.noise(now, 1.9) * jolt,
			math.noise(2.3, now) * jolt,
			0
		) * CFrame.Angles(
			math.noise(now, 0.3) * amplitude,
			math.noise(0.7, now) * amplitude,
			math.noise(now, now * 0.5) * amplitude * 0.5
		)
	end
end

local function step(dt: number)
	local index = 1
	while index <= #active do
		if updateBlast(active[index], dt) then
			index += 1
		else
			table.remove(active, index)
		end
	end
	if #active == 0 then
		if connection then
			connection:Disconnect()
			connection = nil
		end
		if shakeBound then
			RunService:UnbindFromRenderStep("ExplosionVFXShake")
			shakeBound = false
		end
	end
end

--------------------------------------------------------------------------------
-- Play
--------------------------------------------------------------------------------

type PlayOptions = { Power: number?, Radius: number?, Color: Color3?, Shake: boolean?, Normal: Vector3? }

function ExplosionVFX.Play(position: Vector3, options: PlayOptions?)
	local source = template()
	if not source then
		warn("[ExplosionVFX] ReplicatedStorage.Effects." .. TEMPLATE_NAME .. " not found")
		return
	end
	local opts = options or {}
	local radius = opts.Radius
	local power = opts.Power or (if radius then (radius / 1.2) ^ 3 else 50)
	local spec = ExplosionVFX.Describe(power, radius)
	SpatialAudio.Explosion(position, spec.Intensity) -- arrives distance / speed of sound later
	local scale = spec.Scale
	local camera = workspace.CurrentCamera
	local distance = if camera then (camera.CFrame.Position - position).Magnitude else 0
	local far = distance > LOD_DISTANCE
	local busy = #active >= MAX_DETAILED_ACTIVE

	-- Sit on the struck surface when the caller knows it (search back along
	-- its normal for the exact contact), else on the ground below; with no
	-- surface in reach it's an air burst: upright, and no ground cracks.
	local reach = spec.Radius * 0.75 + 2
	local normal = opts.Normal
	local hasNormal = normal ~= nil and normal.Magnitude > 1e-3
	local up = if hasNormal then (normal :: Vector3).Unit else Vector3.yAxis
	local surface = surfaceAlong(position + up * 0.5, -up, reach)
	local frame = if surface then upright(surface.Position, surface.Normal)
		elseif hasNormal then upright(position, up)
		else upright(position, Vector3.yAxis)
	if surface then
		Crater.Spawn(surface, spec.Radius, spec.Intensity, far or busy) -- rim, scorch and flying rubble
	end

	local root = Instance.new("Part")
	root.Name = "Explosion"
	root.Anchored, root.CanCollide, root.CanQuery, root.CanTouch, root.CastShadow = true, false, false, false, false
	root.Transparency = 1
	root.Size = Vector3.one
	root.CFrame = frame

	local light = Instance.new("PointLight")
	light.Range = math.min(spec.Radius * 4, 60)
	light.Color = Color3.fromRGB(255, 190, 110):Lerp(opts.Color or Color3.fromRGB(255, 190, 110), 0.4)
	light.Shadows = spec.Intensity > 0.6
	light.Parent = root

	local blast: Blast = {
		Position = position,
		Spec = spec,
		Root = root,
		Light = light,
		Shots = {},
		Age = 0,
		RealAge = 0,
		Life = 1,
		Shake = if opts.Shake == false or far then 0 else spec.Shake,
	}

	-- One attachment per (group, authored height), so plumes and fire that
	-- were authored above the ground stay above it at every scale.
	local heights: { [string]: Attachment } = {}
	local function attachmentFor(group: string, height: number): Attachment
		local key = group .. "@" .. height
		local existing = heights[key]
		if existing then
			return existing
		end
		local attachment = Instance.new("Attachment")
		attachment.Name = group
		attachment.Position = Vector3.new(0, height * scale, 0)
		attachment.Parent = root
		heights[key] = attachment
		return attachment
	end

	for group, countFactor in spec.Groups do
		if (far and group ~= "Energy") or (busy and LOW_DETAIL_SKIP[group]) or (group == "GroundCrack" and not surface) then
			continue
		end
		local groupTemplate = source:FindFirstChild(group)
		if not groupTemplate then
			continue
		end
		local factor = countFactor * (if busy then 0.5 else 1)
		local ranked = rankedEmitters(groupTemplate)
		local share = (spec.Shares[group] or 1) * (if busy then 0.5 else 1)
		local limit = math.max(1, math.ceil(#ranked * share))
		for index, original in ranked do
			if index > limit then
				break
			end
			local base = (original:GetAttribute("EmitCount") :: number?) or 1
			local exact = base * factor
			local count = math.floor(exact) + (if math.random() < exact % 1 then 1 else 0)
			local duration = (original:GetAttribute("EmitDuration") :: number?) or 0
			if count <= 0 and duration <= 0 then
				continue
			end
			local emitter = original:Clone()
			emitter.Enabled = false
			emitter.Size = scaledSequence(emitter.Size, scale)
			emitter.Speed = NumberRange.new(emitter.Speed.Min * scale, emitter.Speed.Max * scale)
			emitter.Acceleration *= scale
			emitter.ZOffset *= scale
			if duration > 0 then
				emitter.Rate *= factor
			end
			if opts.Color and emitter:GetAttribute("recolorable") then
				emitter.Color = tinted(emitter.Color, opts.Color, 0.6)
			end
			emitter.Parent = attachmentFor(group, (original:GetAttribute("SourceHeight") :: number?) or 0)

			local delay = (original:GetAttribute("EmitDelay") :: number?) or 0
			local rampDuration = (original:GetAttribute("TimeScale_Duration") :: number?) or 0
			table.insert(blast.Shots, {
				Emitter = emitter,
				Delay = delay,
				Duration = duration,
				Count = count,
				Fired = false,
				StopAt = nil,
				FiredAt = 0,
				RampStart = (original:GetAttribute("TimeScale_Start") :: number?) or emitter.TimeScale,
				RampEnd = (original:GetAttribute("TimeScale_End") :: number?) or emitter.TimeScale,
				RampDuration = rampDuration,
			})
			-- Particles live in emitter time; at a low authored TimeScale they
			-- last proportionally longer in blast time.
			local slowest = math.max(math.min(emitter.TimeScale, (original:GetAttribute("TimeScale_End") :: number?) or 1), 0.05)
			blast.Life = math.max(blast.Life, delay + duration + emitter.Lifetime.Max / slowest + 0.2)
		end
	end

	root.Parent = vfxFolder()
	table.insert(active, blast)
	updateBlast(blast, 0) -- fire zero-delay emitters before the first render

	if not connection then
		connection = RunService.RenderStepped:Connect(step)
	end
	if blast.Shake > 0 and not shakeBound then
		RunService:BindToRenderStep("ExplosionVFXShake", Enum.RenderPriority.Camera.Value + 1, applyShake)
		shakeBound = true
	end
end

return ExplosionVFX
