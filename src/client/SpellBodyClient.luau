--!strict
--[[
	SpellBodyClient (client)
	What spells do to your own character -- which only your client can move
	(it owns its physics) -- and the visuals of spells on bodies:

	 - VisualOffload "SpellImpulse" { Velocity, Set? } (server/SpellWorld.Push,
	   Halt): a Force on you. Added to your velocity (Set replaces it); a
	   mostly sideways shove is held for a moment so walking can't brake it.
	 - Humanoid attributes (server/SpellBody): SpellWalk / SpellJump multiply
	   walk speed and jump (MovementController modifier "SpellBody"; 0 =
	   rooted), SpellLevitate lifts you (a VectorForce cancelling most of
	   your -- dilated -- gravity), SpellTime scales your personal time.
	 - VisualOffload "SpellFX": Kind "Blink" (a flash at both ends and a
	   streak between), "Force" (a shockwave ring / dash streak, and a flash
	   on each body shoved) and "Effect" (a coloured glow on the body for the
	   effect's duration; Heal and Cleanse sparkle once).

	Self-registers at require time (client/SpellEffects requires it).
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)
local Heartbeat = require(Shared.Heartbeat)
local MovementController = require(script.Parent:WaitForChild("MovementController"))

local SpellBodyClient = {}

local player = Players.LocalPlayer
local MODIFIER = "SpellBody"
local LIFT = 0.92 -- share of your gravity levitation cancels
local HOLD_MIN, HOLD_MAX = 0.12, 0.35 -- seconds a sideways shove is held (longer when faster)
local HOLD_PER_SPEED = 1 / 350
local AURA_FADE = 0.4

--------------------------------------------------------------------------------
-- Your own body
--------------------------------------------------------------------------------

local function rootOf(): (BasePart?, Humanoid?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = humanoid and humanoid.RootPart
	return root, humanoid
end

VisualOffload.On("SpellImpulse", function(data)
	if typeof(data) ~= "table" or typeof(data.Velocity) ~= "Vector3" then
		return
	end
	local root, humanoid = rootOf()
	if not root or not humanoid or humanoid.Health <= 0 then
		return
	end
	local deltaV = data.Velocity * MovementController.GetTimeScale()
	if data.Set then
		root.AssemblyLinearVelocity = deltaV
		return
	end
	-- standing on the ground: a shove aimed down at the floor ahead (a dash
	-- toward the mouse) goes level instead, just as fast
	local flat = Vector3.new(deltaV.X, 0, deltaV.Z)
	if deltaV.Y < 0 and humanoid.FloorMaterial ~= Enum.Material.Air and flat.Magnitude > 1e-3 then
		deltaV = flat.Unit * deltaV.Magnitude
	end
	local velocity = root.AssemblyLinearVelocity + deltaV
	local sideways = Vector3.new(deltaV.X, 0, deltaV.Z).Magnitude
	if sideways > 20 then
		local attachment = Instance.new("Attachment")
		attachment.Name = "SpellShove"
		attachment.Parent = root
		local hold = Instance.new("LinearVelocity")
		hold.Name = "SpellShove"
		hold.Attachment0 = attachment
		hold.RelativeTo = Enum.ActuatorRelativeTo.World
		hold.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		hold.MaxForce = math.huge
		hold.VectorVelocity = velocity
		hold.Parent = root
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		task.delay(math.clamp(sideways * HOLD_PER_SPEED, HOLD_MIN, HOLD_MAX), function()
			attachment:Destroy()
			hold:Destroy()
		end)
	end
	root.AssemblyLinearVelocity = velocity
end)

local lift: VectorForce? = nil
local watched: Humanoid? = nil
local timeApplied = false
local connections: { RBXScriptConnection } = {}

local function finite(value: any): number?
	return if typeof(value) == "number" and value == value and math.abs(value) < math.huge then value else nil
end

local function applyAttributes()
	local humanoid = watched
	if not humanoid then
		MovementController.RemoveModifier(MODIFIER)
		return
	end
	local walk = finite(humanoid:GetAttribute("SpellWalk"))
	local jump = finite(humanoid:GetAttribute("SpellJump"))
	if walk or jump then
		MovementController.SetModifier(MODIFIER, {
			WalkSpeedMultiplier = walk or 1,
			JumpMultiplier = jump or 1,
		})
	else
		MovementController.RemoveModifier(MODIFIER)
	end
	-- Quicken / Dilate: your personal time ratio x the spell's
	local time = finite(humanoid:GetAttribute("SpellTime"))
	local personal = finite(player:GetAttribute("PersonalTimeScale")) or 1
	if time then
		MovementController.SetPersonalTimeScale(personal * time)
		timeApplied = true
	elseif timeApplied then
		MovementController.SetPersonalTimeScale(personal)
		timeApplied = false
	end
end

local function setLevitating(on: boolean)
	local root = rootOf()
	if on and root then
		if not lift or lift.Parent ~= root then
			local attachment = Instance.new("Attachment")
			attachment.Name = "SpellLift"
			attachment.Parent = root
			local force = Instance.new("VectorForce")
			force.Name = "SpellLift"
			force.Attachment0 = attachment
			force.RelativeTo = Enum.ActuatorRelativeTo.World
			force.ApplyAtCenterOfMass = true
			force.Parent = root
			lift = force
		end
	elseif lift then
		local attachment = lift.Attachment0
		lift:Destroy()
		if attachment then attachment:Destroy() end
		lift = nil
	end
end

-- the lift follows your (dilated) gravity and mass every frame
Heartbeat.Connect(function()
	local force = lift
	if not force or not force.Parent then
		return
	end
	local root = force.Parent :: BasePart
	local scale = MovementController.GetTimeScale()
	force.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity * scale * scale * LIFT, 0)
end, { Name = "SpellBodyClient", Priority = 21 })

local function watch(character: Model)
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	setLevitating(false)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") or player.Character ~= character then
		return
	end
	watched = humanoid
	for _, name in { "SpellWalk", "SpellJump", "SpellTime" } do
		table.insert(connections, humanoid:GetAttributeChangedSignal(name):Connect(applyAttributes))
	end
	table.insert(connections, humanoid:GetAttributeChangedSignal("SpellLevitate"):Connect(function()
		setLevitating(humanoid:GetAttribute("SpellLevitate") == true)
	end))
	applyAttributes()
	setLevitating(humanoid:GetAttribute("SpellLevitate") == true)
end

player.CharacterAdded:Connect(watch)
if player.Character then
	task.spawn(watch, player.Character)
end

--------------------------------------------------------------------------------
-- Visuals
--------------------------------------------------------------------------------

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
	part.Parent = workspace
	return part
end

local function flash(position: Vector3, color: Color3, size: number)
	local ball = neon({ Shape = Enum.PartType.Ball, Size = Vector3.one * size, CFrame = CFrame.new(position), Color = color, Transparency = 0.15 })
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = size * 4
	light.Brightness = 3
	light.Parent = ball
	local info = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(ball, info, { Size = Vector3.one * size * 2.6, Transparency = 1 }):Play()
	TweenService:Create(light, info, { Brightness = 0 }):Play()
	Debris:AddItem(ball, 0.45)
end

local function streak(a: Vector3, b: Vector3, color: Color3, width: number)
	local length = (b - a).Magnitude
	if length < 0.2 then
		return
	end
	local frame = CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.rad(90), 0)
	local beam = neon({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(length, width, width), CFrame = frame, Color = color, Transparency = 0.3 })
	TweenService:Create(beam, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { Size = Vector3.new(length, 0.05, 0.05), Transparency = 1 }):Play()
	Debris:AddItem(beam, 0.35)
end

local function ring(position: Vector3, radius: number, color: Color3, normal: Vector3)
	local frame = CFrame.lookAt(position, position + normal) * CFrame.Angles(0, math.rad(90), 0)
	local disc = neon({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, 1, 1), CFrame = frame, Color = color, Transparency = 0.35 })
	TweenService:Create(disc, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.05, radius * 2, radius * 2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(disc, 0.45)
end

local auras: { [Instance]: { [string]: { highlight: Highlight, token: number } } } = {}

local function aura(target: Instance, effect: string, color: Color3, seconds: number)
	local byEffect = auras[target]
	if not byEffect then
		byEffect = {}
		auras[target] = byEffect
	end
	local existing = byEffect[effect]
	local highlight: Highlight
	if existing and existing.highlight.Parent then
		highlight = existing.highlight
	else
		highlight = Instance.new("Highlight")
		highlight.Name = "SpellAura" .. effect
		highlight.FillColor = color
		highlight.OutlineColor = color
		highlight.FillTransparency = 1
		highlight.OutlineTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Adornee = target
		highlight.Parent = target
		TweenService:Create(highlight, TweenInfo.new(0.2), { FillTransparency = 0.75, OutlineTransparency = 0.2 }):Play()
	end
	local token = (if existing then existing.token else 0) + 1
	byEffect[effect] = { highlight = highlight, token = token }
	task.delay(math.max(seconds, 0.1), function()
		local current = byEffect[effect]
		if not current or current.token ~= token then
			return
		end
		byEffect[effect] = nil
		TweenService:Create(highlight, TweenInfo.new(AURA_FADE), { FillTransparency = 1, OutlineTransparency = 1 }):Play()
		Debris:AddItem(highlight, AURA_FADE + 0.05)
	end)
end

local function sparkle(target: Instance, color: Color3)
	local model = if target:IsA("Model") then target else nil
	local root = model and (model.PrimaryPart or model:FindFirstChild("HumanoidRootPart"))
	if not root or not root:IsA("BasePart") then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Parent = root
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 1
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new(0, 1)
	emitter.Lifetime = NumberRange.new(0.5, 0.9)
	emitter.Speed = NumberRange.new(4, 8)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, 6, 0)
	emitter.Rate = 0
	emitter.Parent = attachment
	emitter:Emit(24)
	Debris:AddItem(attachment, 1.2)
end

VisualOffload.On("SpellFX", function(data)
	if typeof(data) ~= "table" then
		return
	end
	local color = if typeof(data.Color) == "Color3" then data.Color else Color3.new(1, 1, 1)
	if data.Kind == "Blink" and typeof(data.From) == "Vector3" and typeof(data.To) == "Vector3" then
		flash(data.From, color, 3)
		flash(data.To, color, 3.5)
		streak(data.From, data.To, color, 0.8)
	elseif data.Kind == "Force" and typeof(data.Position) == "Vector3" then
		local radius = if typeof(data.Radius) == "number" then data.Radius else 0
		local direction = if typeof(data.Direction) == "Vector3" and data.Direction.Magnitude > 1e-3 then data.Direction.Unit else Vector3.yAxis
		if radius > 0 then
			ring(data.Position, radius, color, Vector3.yAxis)
		else
			ring(data.Position + direction * 2, 2.5, color, direction)
		end
		for _, target in (if typeof(data.Targets) == "table" then data.Targets else {}) do
			if typeof(target) == "Instance" and target:IsA("Model") then
				local pivot = target:GetPivot().Position
				ring(pivot, 2, color, direction)
			end
		end
	elseif data.Kind == "Effect" and typeof(data.Target) == "Instance" and typeof(data.Effect) == "string" then
		local seconds = if typeof(data.Duration) == "number" then data.Duration else 1
		if data.Effect == "Heal" or data.Effect == "Cleanse" then
			sparkle(data.Target, color)
			aura(data.Target, data.Effect, color, 0.6)
		else
			aura(data.Target, data.Effect, color, seconds)
		end
	end
end)

return SpellBodyClient
