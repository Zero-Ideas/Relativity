--!optimize 2
--[[
	ProjectileClient/VisualModel.luau
	Builds and positions the actual Instance a projectile visual renders as.
	Pure presentation -- no networking, no gameplay state.
]]

local VisualModel = {}

-- Defaults for ActivateParticlesOnCreate (see VisualModel.ActivateParticles)
-- when a ParticleEmitter doesn't carry its own EmitCount/EmitDelay attribute.
local DEFAULT_EMIT_COUNT = 5
local DEFAULT_EMIT_DELAY = 0

local function safeUnit(v: Vector3, fallback: Vector3): Vector3
	local magnitude = v.Magnitude
	if magnitude < 1e-5 then
		return fallback
	end
	return v / magnitude
end

local function poseFrom(position: Vector3, velocity: Vector3): CFrame
	return CFrame.new(position, position + safeUnit(velocity, Vector3.zAxis))
end

-- Built-in (non-Model) visuals are pooled per appearance: a burst otherwise
-- creates two Parts and a Motor6D per projectile and destroys them all on
-- impact. Custom Models aren't pooled -- their effects/transparency state is
-- mutated by FadeOut and would need a full restore.
local POOL_LIMIT = 4096
local pools: { [string]: { any } } = {}

local function builtinPoolKey(data): string
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

local function styledModel(spec: any): Model?
	local core = spec.Core or Color3.new(1, 1, 1)
	local glow = spec.Color or core
	local key = `{spec.Style}|{core}|{glow}`
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

function VisualModel.Build(data): (Instance, any)
	local model
	local styled = data.Visual and data.Visual.Style and not data.Model and styledModel(data.Visual)
	local poolKey = if data.Model or styled then nil else builtinPoolKey(data)

	local pooledRig = poolKey and pools[poolKey] and table.remove(pools[poolKey])
	if pooledRig then
		pooledRig.driver.CFrame = CFrame.new(data.Position)
		pooledRig.motor.Transform =
			pooledRig.driver.CFrame:ToObjectSpace(poseFrom(data.Position, data.Velocity) * pooledRig.rootOffset)
		pooledRig.root.Transparency = 0
		pooledRig.model.Parent = workspace
		return pooledRig.model, pooledRig
	end

	if styled then
		model = styled
	elseif data.Model then
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

	-- Scale the cloned presentation once at construction. This does not add
	-- any per-frame work and keeps gameplay collision radius server-owned.
	local visualScale = math.clamp(data.VisualScale or 1, 0.05, 20)
	if visualScale ~= 1 then
		if model:IsA("Model") then
			pcall(model.ScaleTo, model, model:GetScale() * visualScale)
		elseif model:IsA("BasePart") then
			model.Size *= visualScale
		end
	end
	local root: BasePart?
	local pivot: CFrame
	if model:IsA("Model") then
		root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
		pivot = model:GetPivot()
		for _, part in { model, table.unpack(model:GetDescendants()) } do
			if part:IsA("BasePart") then
				part.Anchored = false
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.CastShadow = false
			end
		end
	else
		root = model
		pivot = model.CFrame
		model.Anchored = false
		model.CanCollide = false
		model.CanQuery = false
		model.CanTouch = false
		model.CastShadow = false
	end

	-- Drive the visual as an assembly from one stationary, invisible root. A
	-- Motor6D Transform is considerably cheaper to update every render frame
	-- than creating/cancelling Tween instances or repeatedly moving a model
	-- pivot. rootOffset preserves a custom Model's authored pivot.
	local rig
	if root then
		local driver = Instance.new("Part")
		driver.Name = "ProjectileMotorRoot"
		driver.Size = Vector3.one * 0.05
		driver.Transparency = 1
		driver.Anchored = true
		driver.CanCollide = false
		driver.CanQuery = false
		driver.CanTouch = false
		driver.CastShadow = false
		driver.CFrame = CFrame.new(data.Position)
		driver.Parent = model

		local motor = Instance.new("Motor6D")
		motor.Name = "ProjectileTransform"
		motor.Part0 = driver
		motor.Part1 = root
		motor.Parent = driver

		local rootOffset = pivot:ToObjectSpace(root.CFrame)
		motor.Transform = driver.CFrame:ToObjectSpace(poseFrom(data.Position, data.Velocity) * rootOffset)
		rig = {
			driver = driver,
			motor = motor,
			rootOffset = rootOffset,
			model = model,
			root = root,
			poolKey = poolKey,
		}
	end

	model.Parent = workspace
	return model, rig
end

local function transformFor(visual, pose: CFrame): CFrame?
	local rig = visual.rig
	if not rig then
		return nil
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

function VisualModel.Place(visual, position: Vector3, velocity: Vector3)
	visual.transformFrom = nil
	visual.transformTo = nil

	local pose = poseFrom(position, velocity)
	local transform = transformFor(visual, pose)
	if transform then
		visual.rig.motor.Transform = transform
	else
		placeFallback(visual.model, pose)
	end
end

-- Preserve exactly which trails were emitting, then clear their positional
-- history before a culled visual is moved. Keeping them disabled until a later
-- render turn prevents Roblox from drawing a segment between the old and new
-- transforms.
function VisualModel.SuspendTrails(visual)
	if visual.suspendedTrails then
		return
	end
	local suspended = {}
	for _, instance in visual.model:GetDescendants() do
		if instance:IsA("Trail") and instance.Enabled then
			instance.Enabled = false
			instance:Clear()
			table.insert(suspended, instance)
		end
	end
	visual.suspendedTrails = suspended
end

function VisualModel.ResumeTrails(visual)
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
function VisualModel.GetLongestEffectLifetime(model: Instance): number
	local longest = 0
	for _, instance in model:GetDescendants() do
		if instance:IsA("ParticleEmitter") then
			local emitDelay = instance:GetAttribute("EmitDelay")
			if typeof(emitDelay) ~= "number" then
				emitDelay = 0
			end
			longest = math.max(longest, math.max(emitDelay, 0) + instance.Lifetime.Max)
		elseif instance:IsA("Trail") then
			longest = math.max(longest, instance.Lifetime)
		end
	end
	return longest
end

-- Off-screen culling eventually stops both continuous particle emission and
-- trails, but only after GetLongestEffectLifetime has elapsed. Remember the
-- exact enabled set so authored-disabled effects stay disabled on re-entry.
function VisualModel.SuspendEffects(visual)
	VisualModel.SuspendTrails(visual)
	if visual.suspendedParticles then
		return
	end
	local suspended = {}
	for _, instance in visual.model:GetDescendants() do
		if instance:IsA("ParticleEmitter") and instance.Enabled then
			instance.Enabled = false
			table.insert(suspended, instance)
		end
	end
	visual.suspendedParticles = suspended
end

function VisualModel.ResumeEffects(visual)
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

-- Unparenting is a cheap, exact visual cull: the projectile cannot remain
-- frozen at its last on-screen transform, and Roblox has nothing to draw for
-- it while it is outside the camera. Place it before restoring the parent so
-- re-entry can never flash the stale exit pose for one frame.
function VisualModel.SetCulled(visual, culled: boolean)
	local model = visual.model
	if culled then
		if model.Parent then
			model.Parent = nil
		end
	elseif not model.Parent then
		model.Parent = workspace
	end
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
	for _, inst in { model, table.unpack(model:GetDescendants()) } do
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
	end
	return grace
end

local function release(visual)
	local rig = visual.rig
	local poolKey = rig and rig.poolKey
	local pool = poolKey and pools[poolKey]
	if poolKey and not pool then
		pool = {}
		pools[poolKey] = pool
	end
	if pool and #pool < POOL_LIMIT then
		visual.model.Parent = nil
		table.insert(pool, rig)
	else
		visual.model:Destroy()
	end
end

-- Hides a finished visual, then destroys it (or returns a built-in one to the
-- pool) after max(destroyDelay, FadeOut's effect grace period).
function VisualModel.Retire(visual, destroyDelay: number)
	local rig = visual.rig
	local delay = destroyDelay
	if rig and rig.poolKey then
		-- Built-in visuals are a bare Part: nothing to fade, only to hide.
		if delay > 0 then
			rig.root.Transparency = 1
		end
	else
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
	for _, inst in { model, table.unpack(model:GetDescendants()) } do
		if inst:IsA("ParticleEmitter") then
			local emitCount = inst:GetAttribute("EmitCount")
			if typeof(emitCount) ~= "number" then
				emitCount = DEFAULT_EMIT_COUNT
			end
			local emitDelay = inst:GetAttribute("EmitDelay")
			if typeof(emitDelay) ~= "number" then
				emitDelay = DEFAULT_EMIT_DELAY
			end
			if emitDelay > 0 then
				task.delay(emitDelay, function()
					if inst.Parent then
						inst:Emit(emitCount)
					end
				end)
			else
				inst:Emit(emitCount)
			end
		end
	end
end

-- Starts a linear pose interpolation for a server-synced visual. The render
-- loop advances it by writing Motor6D.Transform; no Tween objects are created.
function VisualModel.SetTarget(visual, position: Vector3, velocity: Vector3, duration: number)
	local target = transformFor(visual, poseFrom(position, velocity))
	if not target or duration <= 0 then
		VisualModel.Place(visual, position, velocity)
		return
	end

	visual.transformFrom = visual.rig.motor.Transform
	visual.transformTo = target
	visual.transformElapsed = 0
	visual.transformDuration = duration
end

function VisualModel.Step(visual, dt: number)
	local from = visual.transformFrom
	local target = visual.transformTo
	if not from or not target then
		return
	end

	local elapsed = visual.transformElapsed + dt
	local alpha = math.min(elapsed / visual.transformDuration, 1)
	visual.rig.motor.Transform = from:Lerp(target, alpha)
	visual.transformElapsed = elapsed
	if alpha >= 1 then
		visual.transformFrom = nil
		visual.transformTo = nil
	end
end

return VisualModel
