--!strict
-- Code-built quadcopter: charcoal chassis, four guarded rotors, landing
-- skids, navigation lamps, and a small two-jointed arm on the underside
-- WeaponMount that holds the weapon. Pose() swings the arm so the weapon
-- points along the aim whatever the chassis is doing (upside down included).
-- Cosmetic, anchored parts only; no scripts/physics from the equipped Tool.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DroneRig = require(ReplicatedStorage.Shared.DroneRig)

local DroneVisual = {}
export type Rotor = {part: BasePart, offset: CFrame, direction: number}
export type Rig = {
	shoulder: BasePart, upper: BasePart, elbow: BasePart, fore: BasePart, wrist: BasePart,
	weapon: Model?,
}
-- Arm lengths (studs): shoulder -> elbow hangs below the chassis and leans
-- along the aim, elbow -> hand points straight along it.
local UPPER_LENGTH, FORE_LENGTH = 0.5, 0.45
local ARM_THICKNESS = 0.11
local ROTOR_SPEED = 90 -- cosmetic radians/sec; diagonally opposite motors match
local DARK = Color3.fromRGB(34, 38, 44)
local METAL = Color3.fromRGB(82, 88, 95)
local COLORS: {[string]: Color3} = {
	Railgun = Color3.fromRGB(100, 220, 255),
	TimeBlaster = Color3.fromRGB(255, 190, 75),
	Pheonix = Color3.fromRGB(255, 100, 65),
}

local function cosmetic(part: BasePart)
	part.Anchored = true
	part.CanCollide, part.CanQuery, part.CanTouch, part.CastShadow = false, false, false, false
	part.LocalTransparencyModifier = 0
end

-- Only copy geometry. Never clone scripts, sounds, joints, emitters or Tools
-- into the world/portal, where they could execute or produce duplicate VFX.
-- (built around the hand at the origin: Pose moves its pivot to the hand)
local function mountWeapon(model: Model, tool: Tool)
	local handle = tool:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		handle = tool:FindFirstChildWhichIsA("BasePart", true)
	end
	if not handle or not handle:IsA("BasePart") then return end
	local weapon = Instance.new("Model")
	weapon.Name = "MountedWeapon"
	weapon:SetAttribute("ToolName", tool.Name)
	local offset = tool:GetAttribute("DroneMountOffset")
	local frame = if typeof(offset) == "CFrame" then offset else tool.Grip:Inverse()
	for _, original in tool:GetDescendants() do
		if not original:IsA("BasePart") or not original.Archivable then continue end
		local copy = original:Clone()
		for _, descendant in copy:GetDescendants() do
			if not (descendant:IsA("SpecialMesh") or descendant:IsA("Decal") or descendant:IsA("Texture")
				or descendant:IsA("SurfaceAppearance") or descendant:IsA("Attachment")) then
				descendant:Destroy()
			end
		end
		cosmetic(copy)
		copy.CFrame = frame * handle.CFrame:ToObjectSpace(original.CFrame)
		copy.Parent = weapon
	end
	weapon.WorldPivot = CFrame.identity
	weapon.Parent = model
end

function DroneVisual.Create(tool: Tool?): Model
	local model = Instance.new("Model")
	model.Name = if tool then tool.Name .. "Drone" else "QuadcopterDrone"
	model:SetAttribute("Weapon", if tool then tool.Name else "None")
	local accent = if tool then COLORS[tool.Name] or Color3.fromRGB(110, 230, 255) else Color3.fromRGB(110, 230, 255)
	local function part(name: string, size: Vector3, frame: CFrame, color: Color3, material: Enum.Material?): Part
		local made = Instance.new("Part")
		made.Name, made.Size, made.CFrame, made.Color = name, size, frame, color
		made.Material = material or Enum.Material.Metal
		cosmetic(made)
		made.Parent = model
		return made
	end
	local body = part("Chassis", Vector3.new(1.15, 0.38, 1.5), CFrame.identity, DARK)
	model.PrimaryPart = body
	part("TopPlate", Vector3.new(0.9, 0.08, 1.2), CFrame.new(0, 0.23, 0), METAL)
	part("Battery", Vector3.new(0.55, 0.16, 0.7), CFrame.new(0, 0.34, 0.05), DARK)
	part("StatusStrip", Vector3.new(0.07, 0.05, 0.65), CFrame.new(0, 0.44, 0.05), accent, Enum.Material.Neon)
	for _, x in {-1, 1} do
		for _, z in {-1, 1} do
			local centre = Vector3.new(x * 1.05, 0.08, z * 1.05)
			local start = Vector3.new(x * 0.4, 0, z * 0.45)
			local delta = centre - start
			part("RotorArm", Vector3.new(0.18, 0.16, delta.Magnitude), CFrame.lookAt((start + centre) / 2, centre), DARK)
			local hub = part("RotorMotor", Vector3.new(0.22, 0.3, 0.3), CFrame.new(centre) * CFrame.Angles(0, 0, math.pi / 2), METAL)
			hub.Shape = Enum.PartType.Cylinder
			local disc = part("RotorBlur", Vector3.new(0.025, 1.02, 1.02), CFrame.new(centre + Vector3.yAxis * 0.16) * CFrame.Angles(0, 0, math.pi / 2), DARK, Enum.Material.SmoothPlastic)
			disc.Shape, disc.Transparency = Enum.PartType.Cylinder, 0.55
			local blade = part("RotorBlade", Vector3.new(0.94, 0.035, 0.095), CFrame.new(centre + Vector3.yAxis * 0.17) * CFrame.Angles(0, x * z * 0.5, 0), METAL)
			blade:SetAttribute("RotorDirection", x * z)
			-- Segmented prop guard, open underneath for the weapon mount.
			for index = 0, 7 do
				local angle = index * math.pi / 4
				local position = centre + Vector3.new(math.cos(angle) * 0.56, 0.07, math.sin(angle) * 0.56)
				part("PropGuard", Vector3.new(0.46, 0.075, 0.055), CFrame.new(position) * CFrame.Angles(0, -angle + math.pi / 2, 0), DARK)
			end
		end
		part("LandingSkid", Vector3.new(0.09, 0.09, 1.35), CFrame.new(x * 0.72, -0.6, 0.05), METAL)
		for _, z in {-0.45, 0.45} do
			part("LandingStrut", Vector3.new(0.075, 0.4, 0.075), CFrame.new(x * 0.72, -0.36, z), DARK)
		end
		part("FrontLamp", Vector3.new(0.17, 0.1, 0.06), CFrame.new(x * 0.37, 0, -0.78), accent, Enum.Material.Neon)
		part("RearLamp", Vector3.new(0.1, 0.08, 0.06), CFrame.new(x * 0.4, 0, 0.78), Color3.fromRGB(255, 65, 55), Enum.Material.Neon)
	end
	part("WeaponCoupler", Vector3.new(0.35, 0.2, 0.42), CFrame.new(0, -0.29, 0), METAL)
	local mount = Instance.new("Attachment")
	mount.Name = "WeaponMount"
	mount.CFrame = DroneRig.WeaponMountOffset
	mount.Parent = body
	-- the arm (posed every frame by Pose; laid out hanging for now)
	local shoulderAt = DroneRig.WeaponMountOffset.Position
	local function joint(name: string, at: Vector3, size: number): Part
		local made = part(name, Vector3.one * size, CFrame.new(at), METAL)
		made.Shape = Enum.PartType.Ball
		return made
	end
	joint("ArmShoulder", shoulderAt, 0.22)
	part("ArmUpper", Vector3.new(ARM_THICKNESS, ARM_THICKNESS, UPPER_LENGTH), CFrame.new(shoulderAt), DARK)
	joint("ArmElbow", shoulderAt, 0.16)
	part("ArmFore", Vector3.new(ARM_THICKNESS, ARM_THICKNESS, FORE_LENGTH), CFrame.new(shoulderAt), DARK)
	local wrist = joint("ArmWrist", shoulderAt, 0.14)
	wrist.Color = accent
	wrist.Material = Enum.Material.Neon
	if tool then mountWeapon(model, tool) end
	-- (resting pose, pointing ahead; Pose takes over once it flies)
	DroneVisual.Pose(DroneVisual.Rig(model), CFrame.identity, Vector3.new(0, 0, -1))
	return model
end

-- The arm and weapon parts of a drone made by Create (or a clone of one).
function DroneVisual.Rig(model: Model): Rig
	local function get(name: string): BasePart
		return model:FindFirstChild(name) :: BasePart
	end
	local weapon = model:FindFirstChild("MountedWeapon")
	return {
		shoulder = get("ArmShoulder"), upper = get("ArmUpper"), elbow = get("ArmElbow"),
		fore = get("ArmFore"), wrist = get("ArmWrist"),
		weapon = if weapon and weapon:IsA("Model") then weapon else nil,
	}
end

local function segment(part: BasePart, from: Vector3, to: Vector3)
	local offset = to - from
	if offset.Magnitude < 1e-4 then
		part.CFrame = CFrame.new(from)
		return
	end
	local up = if math.abs(offset.Unit.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
	part.CFrame = CFrame.lookAt((from + to) * 0.5, to, up)
end

-- Places the arm under `body` (the chassis frame, already pivoted) so the
-- weapon in its hand points along `aim` (a unit vector, world space).
-- "Under" follows the chassis: flipped upside down, the arm reaches up.
function DroneVisual.Pose(rig: Rig, body: CFrame, aim: Vector3)
	local shoulder = (body * DroneRig.WeaponMountOffset).Position
	local down = -body.UpVector
	local elbow = shoulder + (down * 0.8 + aim * 0.45).Unit * UPPER_LENGTH
	local hand = elbow + aim * FORE_LENGTH
	rig.shoulder.CFrame = CFrame.new(shoulder)
	segment(rig.upper, shoulder, elbow)
	rig.elbow.CFrame = CFrame.new(elbow)
	segment(rig.fore, elbow, hand)
	rig.wrist.CFrame = CFrame.new(hand)
	if rig.weapon then
		-- (kept upright in the world, not rolled with the chassis)
		local up = if math.abs(aim.Y) > 0.98 then body.LookVector else Vector3.yAxis
		rig.weapon:PivotTo(CFrame.lookAt(hand, hand + aim, up))
	end
end

function DroneVisual.Parts(model: Model): {BasePart}
	local parts = {}
	for _, instance in model:GetDescendants() do
		if instance:IsA("BasePart") then table.insert(parts, instance) end
	end
	return parts
end

function DroneVisual.SetHidden(parts: {BasePart}, hidden: boolean)
	for _, part in parts do part.LocalTransparencyModifier = if hidden then 1 else 0 end
end

function DroneVisual.Rotors(model: Model): {Rotor}
	local rotors = {}
	local pivot = model:GetPivot()
	for _, instance in model:GetDescendants() do
		if instance:IsA("BasePart") then
			local direction = instance:GetAttribute("RotorDirection")
			if typeof(direction) == "number" then
				table.insert(rotors, {part = instance, offset = pivot:ToObjectSpace(instance.CFrame), direction = direction})
			end
		end
	end
	return rotors
end

function DroneVisual.Spin(rotors: {Rotor}, frame: CFrame, clock: number)
	local angle = (clock * ROTOR_SPEED) % (math.pi * 2)
	for _, rotor in rotors do
		rotor.part.CFrame = frame * rotor.offset * CFrame.Angles(0, angle * rotor.direction, 0)
	end
end

return DroneVisual
