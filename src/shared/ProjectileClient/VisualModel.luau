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

function VisualModel.Build(data): (Instance, any)
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
