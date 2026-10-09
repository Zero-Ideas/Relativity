--!strict
--!optimize 2
--[[
	Projectile/Client/VisualModel.luau
	Builds and positions the actual Instance a projectile visual renders as.
	Pure presentation -- no networking, no gameplay state.
]]

local Protocol = require(script.Parent.Parent.Parent:WaitForChild("Projectile"):WaitForChild("Protocol"))
local SafeMath = require(script.Parent.Parent.Parent:WaitForChild("SafeMath"))
local Presentation = require(script.Parent.Parent.Parent:WaitForChild("ClientPresentation"))

local Types = require(script.Parent.Types)
local BeamVisual = require(script.Parent.BeamVisual)

type Visual = Types.Visual
type Rig = Types.Rig

local VisualModel = {}

-- Defaults for ActivateParticlesOnCreate (see VisualModel.ActivateParticles)
-- when a ParticleEmitter doesn't carry its own EmitCount/EmitDelay attribute.
local DEFAULT_EMIT_COUNT = 5
local DEFAULT_EMIT_DELAY = 0

local function poseFrom(position: Vector3, velocity: Vector3): CFrame
	return CFrame.lookAt(position, position + SafeMath.direction(velocity, Vector3.zAxis))
end

-- `model` itself plus every descendant, without first copying them all into
-- one table (unpacking GetDescendants() also errors on very large models).
local function forSelfAndDescendants(model: Instance, fn: (Instance) -> ())
	fn(model)
	for _, instance in model:GetDescendants() do
		fn(instance)
	end
end

-- Built-in visuals are pooled per appearance: a burst otherwise creates the
-- parts, joints and effects of every projectile and destroys them all on
-- impact. Styled ones (Orb / Bullet: a dozen instances each) are pooled too,
-- with everything FadeOut changes recorded at construction and restored on
-- reuse (see gatherEffects). Authored Models aren't pooled.
local POOL_LIMIT = 4096
local STYLED_POOL_LIMIT = 512
local pools: { [string]: { Rig } } = {}

-- Particle rate per detail tier (see VisualModel.SetDetail; the bare tier
-- switches emitters off outright: an enabled emitter at rate 0 still costs
-- nearly as much to render as a busy one).
local PARTICLE_SCALE = { 1, 0.25 }

local function builtinPoolKey(data: Protocol.SpawnPayload): string
	local spec = data.Visual
	local scale = math.clamp(data.VisualScale or 1, 0.05, 20)
	if spec then
		return `{spec.Shape}|{spec.Size}|{spec.Color}|{scale}`
	end
	return `default|{scale}`
end

--------------------------------------------------------------------------------
-- Styled visuals: Visual = { Style = "Orb" | "Bullet", Color, Core }
-- Built procedurally once per (style, colours) as a template Model, then
-- cloned like an authored Model. Every part is welded to a hot neon core so
-- the whole thing rides the core's Motor6D; trails/particles fade out
-- naturally on impact via FadeOut. Not pooled (their effects state changes).
--------------------------------------------------------------------------------

local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local WISP_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local styledTemplates: { [string]: Model } = {}

local function effectPart(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Material = Enum.Material.Neon
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Anchored = false
	for key, value in props do
		(part :: any)[key] = value
	end
	return part
end

local function weld(part: BasePart, to: BasePart)
	local constraint = Instance.new("WeldConstraint")
	constraint.Part0 = to
	constraint.Part1 = part
	constraint.Parent = part
end

local function trail(parent: BasePart, halfWidth: number, lifetime: number, core: Color3, glow: Color3)
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, halfWidth, 0)
	a0.Parent = parent
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -halfWidth, 0)
	a1.Parent = parent
	local effect = Instance.new("Trail")
	effect.Attachment0 = a0
	effect.Attachment1 = a1
	effect.Lifetime = lifetime
	effect.MinLength = 0
	effect.FaceCamera = true
	effect.LightEmission = 1
	effect.LightInfluence = 0
	effect.Color = ColorSequence.new(core, glow)
	effect.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1) })
	effect.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.1) })
	effect.Parent = parent
end

local function light(parent: BasePart, color: Color3, range: number, brightness: number)
	local effect = Instance.new("PointLight")
	effect.Color = color
	effect.Range = range
	effect.Brightness = brightness
	effect.Shadows = false
	effect.Parent = parent
end

local function buildOrb(core: Color3, glow: Color3): Model
	local model = Instance.new("Model")
	model.Name = "SpellOrb"
	local center = effectPart({ Name = "Core", Shape = Enum.PartType.Ball, Size = Vector3.one * 0.9, Color = core })
	center.Parent = model
	model.PrimaryPart = center
	local shell = effectPart({ Name = "Glow", Shape = Enum.PartType.Ball, Size = Vector3.one * 1.9, Color = glow, Transparency = 0.55 })
	shell.Parent = model
	weld(shell, center)
	local halo = effectPart({ Name = "Halo", Shape = Enum.PartType.Ball, Size = Vector3.one * 3, Color = glow, Transparency = 0.85 })
	halo:SetAttribute("LodDecor", true) -- (dropped at the lowest detail)
	halo.Parent = model
	weld(halo, center)
	light(center, glow, 14, 3)
	trail(center, 0.55, 0.3, core, glow)

	local sparks = Instance.new("ParticleEmitter")
	sparks.Name = "Sparks"
	sparks.Texture = SPARK_TEXTURE
	sparks.Color = ColorSequence.new(core, glow)
	sparks.LightEmission = 1
	sparks.LightInfluence = 0
	sparks.Rate = 45
	sparks.Lifetime = NumberRange.new(0.25, 0.5)
	sparks.Speed = NumberRange.new(2, 5)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Drag = 4
	sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 0) })
	sparks.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	sparks.Parent = center

	local wisps = Instance.new("ParticleEmitter")
	wisps.Name = "Wisps"
	wisps.Texture = WISP_TEXTURE
	wisps.Color = ColorSequence.new(glow)
	wisps.LightEmission = 0.8
	wisps.LightInfluence = 0
	wisps.Rate = 30
	wisps.Lifetime = NumberRange.new(0.3, 0.5)
	wisps.Speed = NumberRange.new(0.3, 1)
	wisps.SpreadAngle = Vector2.new(180, 180)
	wisps.Rotation = NumberRange.new(0, 360)
	wisps.RotSpeed = NumberRange.new(-90, 90)
	wisps.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.6), NumberSequenceKeypoint.new(1, 0.2) })
	wisps.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) })
	wisps.Parent = center
	return model
end

local function buildBullet(core: Color3, glow: Color3): Model
	local model = Instance.new("Model")
	model.Name = "SpellBullet"
	-- Long axis is Z: the pose CFrame looks along the velocity.
	local center = effectPart({ Name = "Core", Size = Vector3.new(0.22, 0.22, 1.8), Color = core })
	center.Parent = model
	model.PrimaryPart = center
	local shell = effectPart({ Name = "Glow", Size = Vector3.new(0.55, 0.55, 2.4), Color = glow, Transparency = 0.6 })
	shell.Parent = model
	weld(shell, center)
	light(center, glow, 8, 2)
	trail(center, 0.14, 0.14, core, glow)
	return model
end

local function styledKey(spec: Protocol.VisualSpec): string
	local core = spec.Core or Color3.new(1, 1, 1)
	return `{spec.Style}|{core}|{spec.Color or core}`
end

local function styledModel(spec: Protocol.VisualSpec): Model?
	local core = spec.Core or Color3.new(1, 1, 1)
	local glow = spec.Color or core
	local key = styledKey(spec)
	local template = styledTemplates[key]
	if not template then
		if spec.Style == "Orb" then
			template = buildOrb(core, glow)
		elseif spec.Style == "Bullet" then
			template = buildBullet(core, glow)
		else
			return nil
		end
		styledTemplates[key] = template
	end
	return template:Clone()
end

local function builtinPart(spec: Protocol.VisualSpec?): Part
	local part = Instance.new("Part")
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
	return part
end

local function makeCosmetic(part: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
end

-- One pass over a new model: makes its parts cosmetic, tracks its emitters,
-- and records its effects and everything FadeOut will change.
local function gatherEffects(model: Instance): Types.Effects
	local effects: Types.Effects = {
		parts = {}, emitters = {}, trails = {}, lights = {}, decor = {},
		restoreInstances = {}, restoreProperties = {}, restoreValues = {},
		lifetime = 0,
	}
	local function remember(instance: Instance, property: string, value: any)
		table.insert(effects.restoreInstances, instance)
		table.insert(effects.restoreProperties, property)
		table.insert(effects.restoreValues, value)
	end
	forSelfAndDescendants(model, function(instance)
		if instance:IsA("BasePart") then
			makeCosmetic(instance)
			table.insert(effects.parts, instance)
			remember(instance, "Transparency", instance.Transparency)
			if instance:GetAttribute("LodDecor") == true then
				table.insert(effects.decor, instance)
			end
		elseif instance:IsA("ParticleEmitter") then
			Presentation.TrackEmitter(instance)
			table.insert(effects.emitters, instance)
			remember(instance, "Enabled", instance.Enabled)
			local rawDelay = instance:GetAttribute("EmitDelay")
			local emitDelay = if typeof(rawDelay) == "number" then math.max(rawDelay, 0) else 0
			effects.lifetime = math.max(effects.lifetime, emitDelay + instance.Lifetime.Max)
		elseif instance:IsA("Trail") then
			table.insert(effects.trails, instance)
			remember(instance, "Enabled", instance.Enabled)
			effects.lifetime = math.max(effects.lifetime, instance.Lifetime)
		elseif instance:IsA("Light") then
			table.insert(effects.lights, instance)
			remember(instance, "Enabled", instance.Enabled)
		elseif instance:IsA("Beam") then
			remember(instance, "Enabled", instance.Enabled)
		end
	end)
	return effects
end

-- A pooled model back as it was built. Its trails stay off (and cleared)
-- until the visual is placed, or they'd draw a streak from where it was.
local function restoreEffects(effects: Types.Effects)
	local instances, properties, values = effects.restoreInstances, effects.restoreProperties, effects.restoreValues
	local pending = {}
	for index = 1, #instances do
		local instance = instances[index] :: any
		if instance:IsA("Trail") then
			instance:Clear()
			if values[index] then
				table.insert(pending, instance)
			end
		else
			instance[properties[index]] = values[index]
		end
	end
	for _, part in effects.decor do
		part.LocalTransparencyModifier = 0
	end
	effects.pendingTrails = if #pending > 0 then pending else nil
end

function VisualModel.Build(data: Protocol.SpawnPayload): (Instance, Rig?)
	if data.Beam then return BeamVisual.Build(data) end
	local spec = data.Visual
	local authored = data.Model
	local style = spec and not authored and spec.Style
	local styledPool = if style == "Orb" or style == "Bullet"
		then `styled|{styledKey(spec :: Protocol.VisualSpec)}|{math.clamp(data.VisualScale or 1, 0.05, 20)}`
		else nil
	local poolKey = if authored then nil else styledPool or builtinPoolKey(data)

	local pool = if poolKey then pools[poolKey] else nil
	local pooledRig = if pool then table.remove(pool) else nil
	if pooledRig then
		-- (C0 is the spawn point: no part to move, just the joint's offset)
		pooledRig.motor.C0 = CFrame.new(data.Position)
		pooledRig.origin = data.Position
		pooledRig.motor.Transform = poseFrom(data.Position, data.Velocity) * pooledRig.rootOffset - data.Position
		local effects = pooledRig.effects
		if effects then
			restoreEffects(effects)
		else
			pooledRig.root.Transparency = 0
		end
		pooledRig.model.Parent = workspace
		return pooledRig.model, pooledRig
	end

	local styled = if styledPool then styledModel(spec :: Protocol.VisualSpec) else nil
	if styledPool and not styled then
		poolKey = builtinPoolKey(data)
	end
	local model: Instance = styled or (if authored then authored:Clone() else builtinPart(spec))

	-- Scale the cloned presentation once at construction. This does not add
	-- any per-frame work and keeps gameplay collision radius server-owned.
	local visualScale = math.clamp(data.VisualScale or 1, 0.05, 20)
	local root: BasePart?
	local pivot: CFrame
	local effects: Types.Effects? = nil
	if model:IsA("Model") then
		if visualScale ~= 1 then
			pcall(model.ScaleTo, model, model:GetScale() * visualScale)
		end
		root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
		pivot = model:GetPivot()
		effects = gatherEffects(model)
	elseif model:IsA("BasePart") then
		if visualScale ~= 1 then
			model.Size *= visualScale
		end
		root = model
		pivot = model.CFrame
		makeCosmetic(model)
		for _, instance in model:GetDescendants() do
			if instance:IsA("ParticleEmitter") then Presentation.TrackEmitter(instance) end
		end
	else
		pivot = CFrame.identity
	end

	-- Drive the visual from Terrain with one Motor6D: Part0 = Terrain (always
	-- there, anchored, at the world origin), Part1 = the visual's root. No
	-- per-projectile driver part. C0 holds the spawn point, so the joint's
	-- frame is a pure translation and a pose's Transform is just pose -
	-- origin (see transformFor); and until the engine applies the first
	-- Transform, the visual already sits at its spawn point, not at the
	-- world origin. A Motor6D Transform is far cheaper to update every
	-- render frame than tweens or moving a model pivot. rootOffset preserves
	-- a custom Model's authored pivot.
	local rig: Rig? = nil
	if root then
		local terrain = workspace.Terrain
		local rootOffset = pivot:ToObjectSpace(root.CFrame)
		local motor = Instance.new("Motor6D")
		motor.Name = "ProjectileTransform"
		motor.C0 = CFrame.new(data.Position)
		motor.Transform = poseFrom(data.Position, data.Velocity) * rootOffset - data.Position
		motor.Part0 = terrain
		motor.Part1 = root
		motor.Parent = root -- (inside the model: destroyed and pooled with it)
		rig = {
			driver = terrain,
			motor = motor,
			rootOffset = rootOffset,
			model = model,
			root = root,
			poolKey = poolKey,
			effects = effects,
			origin = data.Position,
			identityOffset = rootOffset == CFrame.identity,
		}
	end

	model.Parent = workspace
	return model, rig
end

local function transformFor(rig: Rig, pose: CFrame): CFrame
	local origin = rig.origin
	if origin then
		-- (the joint frame is a pure translation, Terrain + C0: no Instance
		-- read, no inverse)
		return (if rig.identityOffset then pose else pose * rig.rootOffset) - origin
	end
	return rig.driver.CFrame:ToObjectSpace(pose * rig.rootOffset)
end

local function placeFallback(model: Instance, pose: CFrame)
	if model:IsA("Model") then
		model:PivotTo(pose)
	elseif model:IsA("BasePart") then
		model.CFrame = pose
	end
end

function VisualModel.Place(visual: Visual, position: Vector3, velocity: Vector3)
	visual.transformFrom = nil
	visual.transformTo = nil
	BeamVisual.Update(visual, position, velocity)
	-- (a beam draws its own cylinders; its head part is invisible, so posing
	-- it every frame was a joint update for nothing)
	if visual.rig and visual.rig.beam then return end

	local pose = poseFrom(position, velocity)
	local rig = visual.rig
	if rig then
		rig.motor.Transform = transformFor(rig, pose)
	else
		placeFallback(visual.model, pose)
	end
end

-- Preserve exactly which trails were emitting, then clear their positional
-- history before a culled visual is moved. Keeping them disabled until a later
-- render turn prevents Roblox from drawing a segment between the old and new
-- transforms.
function VisualModel.SuspendTrails(visual: Visual)
	if visual.suspendedTrails then
		return
	end
	local suspended: { Trail } = {}
	local effects = visual.rig and visual.rig.effects
	for _, instance in (if effects then effects.trails else visual.model:GetDescendants()) :: { Instance } do
		if instance:IsA("Trail") and instance.Enabled then
			instance.Enabled = false
			instance:Clear()
			table.insert(suspended, instance)
		end
	end
	visual.suspendedTrails = suspended
end

function VisualModel.ResumeTrails(visual: Visual)
	local suspended = visual.suspendedTrails
	if not suspended then
		return
	end
	for _, trail in suspended do
		if trail.Parent then
			trail:Clear()
			trail.Enabled = true
		end
	end
	visual.suspendedTrails = nil
end

-- Returns the real-time grace period a visual should remain alive and
-- emitting after it first leaves the viewport. EmitDelay is included because
-- one-shot particle bursts may not have fired yet when the projectile exits.
function VisualModel.GetLongestEffectLifetime(model: Instance, rig: Rig?): number
	if rig and rig.effects then
		return rig.effects.lifetime
	end
	local longest = 0
	for _, instance in model:GetDescendants() do
		if instance:IsA("ParticleEmitter") then
			local rawDelay = instance:GetAttribute("EmitDelay")
			local emitDelay = if typeof(rawDelay) == "number" then math.max(rawDelay, 0) else 0
			longest = math.max(longest, emitDelay + instance.Lifetime.Max)
		elseif instance:IsA("Trail") then
			longest = math.max(longest, instance.Lifetime)
		end
	end
	return longest
end

-- Off-screen culling eventually stops both continuous particle emission and
-- trails, but only after GetLongestEffectLifetime has elapsed. Remember the
-- exact enabled set so authored-disabled effects stay disabled on re-entry.
function VisualModel.SuspendEffects(visual: Visual)
	VisualModel.SuspendTrails(visual)
	if visual.suspendedParticles then
		return
	end
	local suspended: { ParticleEmitter } = {}
	local effects = visual.rig and visual.rig.effects
	for _, instance in (if effects then effects.emitters else visual.model:GetDescendants()) :: { Instance } do
		if instance:IsA("ParticleEmitter") and instance.Enabled then
			instance.Enabled = false
			table.insert(suspended, instance)
		end
	end
	visual.suspendedParticles = suspended
end

function VisualModel.ResumeEffects(visual: Visual)
	VisualModel.ResumeTrails(visual)
	local suspended = visual.suspendedParticles
	if not suspended then
		return
	end
	for _, emitter in suspended do
		if emitter.Parent then
			emitter.Enabled = true
		end
	end
	visual.suspendedParticles = nil
end

-- Instantly hides a bullet visual without destroying it: every BasePart goes
-- fully transparent, and every Trail/ParticleEmitter/Beam (and Light) is
-- either faded or deleted outright depending on waitForParticles/
-- waitForTrails (see the Projectile config's WaitForParticles/WaitForTrails --
-- both default true). Returns how many seconds of grace the caller should
-- wait before actually :Destroy()ing the model:
--  - waitForParticles/waitForTrails true (default): disabling a
--    Trail/ParticleEmitter only stops NEW emission, while everything already
--    emitted keeps fading out naturally over its Lifetime, so destroying any
--    earlier would cut those remnants off mid-air (the "unnatural deletion"
--    this exists to prevent) -- contributes that Lifetime to the grace period.
--  - waitForParticles/waitForTrails false: the instance is :Destroy()d
--    immediately instead of just disabled -- no lingering remnants, no grace
--    contribution from it.
-- Beams/Lights have no lingering emission (disabling hides them instantly)
-- and never contribute grace. Returns 0 (safe to destroy immediately) when
-- nothing in the model still needs to wait -- e.g. both flags false, or one
-- flag false and the model has none of the other kind.
function VisualModel.FadeOut(model: Instance, waitForParticles: boolean, waitForTrails: boolean): number
	local grace = 0
	forSelfAndDescendants(model, function(inst)
		if inst:IsA("BasePart") then
			inst.Transparency = 1
		elseif inst:IsA("ParticleEmitter") then
			if waitForParticles then
				if inst.Enabled then
					grace = math.max(grace, inst.Lifetime.Max)
				end
				inst.Enabled = false
			else
				inst:Destroy()
			end
		elseif inst:IsA("Trail") then
			if waitForTrails then
				if inst.Enabled then
					grace = math.max(grace, inst.Lifetime)
				end
				inst.Enabled = false
			else
				inst:Destroy()
			end
		elseif inst:IsA("Beam") then
			inst.Enabled = false
		elseif inst:IsA("Light") then
			inst.Enabled = false
		end
	end)
	return grace
end

local function release(visual: Visual)
	local rig = visual.rig
	local poolKey = rig and rig.poolKey
	if rig and poolKey then
		local pool = pools[poolKey]
		if not pool then
			pool = {}
			pools[poolKey] = pool
		end
		if #pool < (if rig.effects then STYLED_POOL_LIMIT else POOL_LIMIT) then
			visual.model.Parent = nil
			table.insert(pool, rig)
			return
		end
	end
	visual.model:Destroy()
end

-- Hides a finished visual, then destroys it (or returns a built-in one to the
-- pool) after max(destroyDelay, FadeOut's effect grace period).
function VisualModel.Retire(visual: Visual, destroyDelay: number)
	if BeamVisual.Retire(visual, destroyDelay) then return end
	local rig = visual.rig
	local delay = destroyDelay
	if rig and rig.poolKey and not rig.effects then
		-- Built-in visuals are a bare Part: nothing to fade, only to hide.
		if delay > 0 then
			rig.root.Transparency = 1
		end
	else
		if rig and rig.effects and not (visual.waitForParticles and visual.waitForTrails) then
			rig.poolKey = nil -- (FadeOut destroys those effects: not reusable)
		end
		delay = math.max(delay, VisualModel.FadeOut(visual.model, visual.waitForParticles, visual.waitForTrails))
	end
	if delay > 0 then
		task.delay(delay, release, visual)
	else
		release(visual)
	end
end

-- ActivateParticlesOnCreate support: fires every ParticleEmitter under
-- `model` exactly once via :Emit(), per its own EmitCount/EmitDelay
-- attributes (defaulting to 5 / 0s when either is missing). EmitDelay is
-- seconds from THIS call until that emitter actually emits -- 0 emits
-- inline, synchronously. Call once, right after VisualModel.Build.
function VisualModel.ActivateParticles(model: Instance)
	forSelfAndDescendants(model, function(inst)
		if inst:IsA("ParticleEmitter") then
			local rawCount = inst:GetAttribute("EmitCount")
			local emitCount = if typeof(rawCount) == "number" then rawCount else DEFAULT_EMIT_COUNT
			local rawDelay = inst:GetAttribute("EmitDelay")
			local emitDelay = if typeof(rawDelay) == "number" then rawDelay else DEFAULT_EMIT_DELAY
			if emitDelay > 0 then
				task.delay(emitDelay, function()
					if inst.Parent then
						inst:Emit(Presentation.BurstCount(emitCount))
					end
				end)
			else
				inst:Emit(Presentation.BurstCount(emitCount))
			end
		end
	end)
end

-- Bare tier: its emitters and trails off. One already off because the
-- visual is suspended (off screen, see SuspendEffects) moves from that list
-- to this one, so resuming can't switch it back on behind the budget's back.
local function switchOff(visual: Visual, effects: Types.Effects)
	local off: { Instance } = {}
	local function take(instance: Instance, suspended: { Instance }?)
		local enabled = (instance :: any).Enabled
		if enabled then
			(instance :: any).Enabled = false
			table.insert(off, instance)
		elseif suspended then
			local index = table.find(suspended, instance)
			if index then
				table.remove(suspended, index)
				table.insert(off, instance)
			end
		end
	end
	for _, emitter in effects.emitters do
		take(emitter, visual.suspendedParticles :: any)
	end
	for _, trail in effects.trails do
		take(trail, visual.suspendedTrails :: any)
		trail:Clear()
	end
	visual.lodOff = off
end

-- Out of the bare tier: back on, or back to the suspended lists if the
-- visual is still suspended.
local function switchOn(visual: Visual)
	local off = visual.lodOff
	if not off then
		return
	end
	visual.lodOff = nil
	for _, instance in off do
		if not instance.Parent then
			continue
		end
		if instance:IsA("ParticleEmitter") then
			local suspended = visual.suspendedParticles
			if suspended then
				table.insert(suspended, instance)
			else
				instance.Enabled = true
			end
		elseif instance:IsA("Trail") then
			local suspended = visual.suspendedTrails
			if suspended then
				table.insert(suspended, instance)
			else
				instance:Clear()
				instance.Enabled = true
			end
		end
	end
end

-- The effects budget (see ProjectileClient's refreshDetail): tier 1 full,
-- 2 a quarter of the particles, 3 no particles, trails or LodDecor parts;
-- `light` says whether its lights may shine. Only writes what changed.
function VisualModel.SetDetail(visual: Visual, tier: number, light: boolean)
	local effects = visual.rig and visual.rig.effects
	if not effects then
		return
	end
	if visual.lodTier ~= tier then
		visual.lodTier = tier
		if tier >= 3 then
			switchOff(visual, effects)
		else
			switchOn(visual)
			local scale = PARTICLE_SCALE[tier] or 1
			for _, emitter in effects.emitters do
				Presentation.ScaleEmitter(emitter, scale)
			end
		end
		local hide = if tier >= 3 then 1 else 0
		for _, part in effects.decor do
			part.LocalTransparencyModifier = hide
		end
	end
	if visual.lodLight ~= light then
		visual.lodLight = light
		for _, effect in effects.lights do
			effect.Enabled = light
		end
	end
end

-- Starts a linear pose interpolation for a server-synced visual. The render
-- loop advances it by writing Motor6D.Transform; no Tween objects are created.
function VisualModel.SetTarget(visual: Visual, position: Vector3, velocity: Vector3, duration: number)
	local rig = visual.rig
	-- Cylinders use their own traveled path, never a pose tween that rotates
	-- an entire tail across a corner. Homing still adopts every server pose.
	if rig and rig.beam then VisualModel.Place(visual, position, velocity); return end
	if not rig or not (duration > 0) then
		VisualModel.Place(visual, position, velocity)
		return
	end

	visual.transformFrom = rig.motor.Transform
	visual.transformTo = transformFor(rig, poseFrom(position, velocity))
	visual.transformElapsed = 0
	visual.transformDuration = duration
end

function VisualModel.Step(visual: Visual, dt: number)
	local from = visual.transformFrom
	local target = visual.transformTo
	local rig = visual.rig
	if not from or not target or not rig then
		return
	end

	local elapsed = visual.transformElapsed + dt
	-- SetTarget only starts a tween with a positive duration.
	local alpha = math.min(elapsed / visual.transformDuration, 1)
	rig.motor.Transform = from:Lerp(target, alpha)
	visual.transformElapsed = elapsed
	if alpha >= 1 then
		visual.transformFrom = nil
		visual.transformTo = nil
	end
end

return VisualModel
