--!optimize 2
--[[
	ProjectileClient/VisualModel.luau
	Builds and positions the actual Instance a projectile visual renders as.
	Pure presentation -- no networking, no gameplay state.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local VisualModel = {}

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
-- fully transparent and every Trail/ParticleEmitter/Beam (and Light) is
-- disabled. Returns how many seconds of grace the caller should wait before
-- actually :Destroy()ing the model: the longest lifetime among the effects
-- that were still enabled -- disabling a Trail/ParticleEmitter only stops NEW
-- emission, while everything already emitted keeps fading out naturally over
-- its Lifetime, so destroying any earlier would cut those remnants off
-- mid-air (the "unnatural deletion" this exists to prevent). Beams/Lights
-- have no lingering emission (disabling hides them instantly) and contribute
-- no grace. Returns 0 for an effectless model -- safe to destroy immediately.
function VisualModel.FadeOut(model: Instance): number
	local grace = 0
	for _, inst in { model, table.unpack(model:GetDescendants()) } do
		if inst:IsA("BasePart") then
			inst.Transparency = 1
		elseif inst:IsA("ParticleEmitter") then
			if inst.Enabled then
				grace = math.max(grace, inst.Lifetime.Max)
			end
			inst.Enabled = false
		elseif inst:IsA("Trail") then
			if inst.Enabled then
				grace = math.max(grace, inst.Lifetime)
			end
			inst.Enabled = false
		elseif inst:IsA("Beam") then
			inst.Enabled = false
		elseif inst:IsA("Light") then
			inst.Enabled = false
		end
	end
	return grace
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
