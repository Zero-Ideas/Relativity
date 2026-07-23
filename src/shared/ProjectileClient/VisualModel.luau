--!optimize 2
--[[
	ProjectileClient/VisualModel.luau
	Builds and positions the actual Instance a projectile visual renders as.
	Pure presentation -- no networking, no gameplay state.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

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

function VisualModel.Build(data): Instance
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
	if model:IsA("Model") then
		for _, part in { model, table.unpack(model:GetDescendants()) } do
			if part:IsA("BasePart") then
				part.Anchored = part == model.PrimaryPart
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.CastShadow = false
			end
		end
	else
		model.Anchored = true
		model.CanCollide = false
		model.CanQuery = false
		model.CanTouch = false
		model.CastShadow = false
	end
	model.Parent = workspace
	RunService.RenderStepped:Wait()
	return model
end

function VisualModel.Place(model: Instance, position: Vector3, velocity: Vector3)
	local look = position + safeUnit(velocity, Vector3.zAxis)
	local cframe = CFrame.new(position, look)
	if model:IsA("Model") then
		model:PivotTo(cframe)
	elseif model:IsA("BasePart") then
		model.CFrame = cframe
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

-- Smoothly moves a SYNCED bullet visual toward the latest authoritative pose
-- via a tween. Duration adapts to how often updates arrive, so motion stays
-- continuous whether the server is stepping fast or coarsely, and it naturally
-- slows when the world's time ratio drops. Unsynced visuals never call this --
-- see init.luau's per-frame local-physics loop.
function VisualModel.Tween(visual, position: Vector3, velocity: Vector3, duration: number)
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

return VisualModel
