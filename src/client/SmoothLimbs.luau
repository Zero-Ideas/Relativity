--!strict
--[[
	SmoothLimbs (client, visual only)
	Our R15 characters walk, idle and jump with R6-style animations: the
	elbows, knees, wrists, ankles and waist stay straight, so each limb
	reads as one block -- but drawn as three R15 segments, with ridges
	where they meet. While a body group is in that straight rest pose, this
	hides its segments (LocalTransparencyModifier, this client only) and
	draws one smooth R6 piece over them instead:

	  Torso      UpperTorso + LowerTorso                 (Waist)
	  Left Arm   LeftUpperArm + LeftLowerArm + LeftHand  (LeftElbow, LeftWrist)
	  Right Arm, Left Leg, Right Leg  the same

	The moment a real R15 animation bends one of those joints (flips,
	cartwheels, emotes), or a ragdoll pulls the segments apart, that group
	shows its real segments again; it goes back once they're straight. The
	check is the segments' actual placement against their rest placement,
	so it doesn't care what moved them.

	The pieces live in a client-only R6 model (a Humanoid, so the avatar's
	Shirt / Pants / T-shirt draw on them) beside the character, anchored,
	never queried or touched, moved every frame just before rendering. Each
	piece is the box around its segments at rest, coloured like its top
	segment. Not used: far away (the ridges don't show), on your own
	character while the camera is close enough that the engine fades it
	(first person), or while turned off (Settings > Effects, SmoothAvatars).

	  SmoothLimbs.start()
	  SmoothLimbs.SetEnabled(on)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local SmoothLimbs = {}

local MAX_DISTANCE = 300 -- studs from the camera: past this, real segments
-- a group counts as straight within these (degrees, studs); it must get
-- back within the tighter pair before smoothing again (no flicker at the edge)
local BEND_ANGLE, BEND_OFFSET = math.rad(8), 0.12
local REST_ANGLE, REST_OFFSET = math.rad(4), 0.06

type GroupSpec = { Name: string, Parts: { string } } -- Parts[1]: the piece follows it
local GROUPS: { GroupSpec } = {
	{ Name = "Torso", Parts = { "UpperTorso", "LowerTorso" } },
	{ Name = "Left Arm", Parts = { "LeftUpperArm", "LeftLowerArm", "LeftHand" } },
	{ Name = "Right Arm", Parts = { "RightUpperArm", "RightLowerArm", "RightHand" } },
	{ Name = "Left Leg", Parts = { "LeftUpperLeg", "LeftLowerLeg", "LeftFoot" } },
	{ Name = "Right Leg", Parts = { "RightUpperLeg", "RightLowerLeg", "RightFoot" } },
}

type Group = {
	Anchor: BasePart,
	Segments: { BasePart }, -- (Anchor first)
	Rest: { CFrame }, -- each segment relative to Anchor at rest
	Offset: CFrame, -- the piece relative to Anchor
	Piece: BasePart,
	Smooth: boolean, -- piece shown, segments hidden
}

type Rig = {
	Character: Model,
	Head: BasePart?,
	Model: Model, -- the R6 stand-in holding the pieces and clothing
	Groups: { Group },
	Connections: { RBXScriptConnection },
	PartConnections: { RBXScriptConnection }, -- (the current body's size / colour)
	Dirty: boolean, -- rebuild next frame (the body or clothing changed)
}

local enabled = true
local started = false
local rigs: { [Model]: Rig } = {}
local folder: Folder? = nil

-- Joint placement with Transform at identity: where `child` sits relative
-- to `parent` when one joint connects them (either way round). Avatars
-- come with Motor6Ds or, with the newer avatar joints, AnimationConstraints
-- between two attachments (with a BallSocket beside each, unused here).
local function restBetween(parent: BasePart, child: BasePart): CFrame?
	for _, holder in { child, parent } do
		for _, joint in holder:GetChildren() do
			if joint:IsA("Motor6D") then
				if joint.Part0 == parent and joint.Part1 == child then
					return joint.C0 * joint.C1:Inverse()
				elseif joint.Part0 == child and joint.Part1 == parent then
					return joint.C1 * joint.C0:Inverse()
				end
			elseif joint:IsA("AnimationConstraint") then
				local a0, a1 = joint.Attachment0, joint.Attachment1
				if a0 and a1 then
					if a0.Parent == parent and a1.Parent == child then
						return a0.CFrame * a1.CFrame:Inverse()
					elseif a0.Parent == child and a1.Parent == parent then
						return a1.CFrame * a0.CFrame:Inverse()
					end
				end
			end
		end
	end
	return nil
end

local function setSmooth(group: Group, smooth: boolean)
	group.Smooth = smooth
	group.Piece.LocalTransparencyModifier = if smooth then 0 else 1
	for _, segment in group.Segments do
		segment.LocalTransparencyModifier = if smooth then 1 else 0
	end
end

local function clearRig(rig: Rig)
	for _, group in rig.Groups do
		if group.Smooth then
			for _, segment in group.Segments do
				segment.LocalTransparencyModifier = 0
			end
		end
	end
	table.clear(rig.Groups)
	for _, connection in rig.PartConnections do
		connection:Disconnect()
	end
	table.clear(rig.PartConnections)
	rig.Model:ClearAllChildren()
end

local function syncClothing(rig: Rig)
	for _, child in rig.Model:GetChildren() do
		if child:IsA("Clothing") or child:IsA("ShirtGraphic") then
			child:Destroy()
		end
	end
	for _, child in rig.Character:GetChildren() do
		if child:IsA("Clothing") or child:IsA("ShirtGraphic") then
			child:Clone().Parent = rig.Model
		end
	end
end

local function build(rig: Rig)
	clearRig(rig)
	rig.Dirty = false
	local character = rig.Character
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return
	end
	local head = character:FindFirstChild("Head")
	rig.Head = if head and head:IsA("BasePart") then head else nil

	local standIn = Instance.new("Humanoid")
	standIn.RigType = Enum.HumanoidRigType.R6
	standIn.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	standIn.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	standIn.RequiresNeck = false
	standIn.BreakJointsOnDeath = false
	standIn.EvaluateStateMachine = false
	standIn.Parent = rig.Model

	for _, spec in GROUPS do
		local segments: { BasePart } = {}
		for _, name in spec.Parts do
			local part = character:FindFirstChild(name)
			if not (part and part:IsA("BasePart")) then
				break
			end
			table.insert(segments, part)
		end
		if #segments ~= #spec.Parts then
			continue
		end
		-- rest placement of each segment relative to the first, along the chain
		local rest = { CFrame.identity }
		for index = 2, #segments do
			local step = restBetween(segments[index - 1], segments[index])
			if not step then
				break
			end
			rest[index] = rest[index - 1] * step
		end
		if #rest ~= #segments then
			continue
		end
		-- the piece: the box around every segment at rest, in the anchor's axes
		local low, high = Vector3.one * math.huge, -Vector3.one * math.huge
		for index, segment in segments do
			local half = segment.Size / 2
			for _, corner in { Vector3.new(1, 1, 1), Vector3.new(1, 1, -1), Vector3.new(1, -1, 1), Vector3.new(1, -1, -1),
				Vector3.new(-1, 1, 1), Vector3.new(-1, 1, -1), Vector3.new(-1, -1, 1), Vector3.new(-1, -1, -1) } do
				local point = rest[index] * (half * corner)
				low, high = low:Min(point), high:Max(point)
			end
		end
		local anchor = segments[1]
		local piece = Instance.new("Part")
		piece.Name = spec.Name
		piece.Size = high - low
		piece.Anchored = true
		piece.CanCollide, piece.CanQuery, piece.CanTouch = false, false, false
		piece.Massless = true
		piece.Material = anchor.Material
		piece.Color = anchor.Color
		piece.CastShadow = anchor.CastShadow
		piece.TopSurface, piece.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
		piece.LocalTransparencyModifier = 1
		piece.Parent = rig.Model
		for _, segment in segments do
			for _, property in { "Size", "Color", "Material" } do
				table.insert(rig.PartConnections, segment:GetPropertyChangedSignal(property):Connect(function()
					rig.Dirty = true
				end))
			end
		end
		table.insert(rig.Groups, {
			Anchor = anchor,
			Segments = segments,
			Rest = rest,
			Offset = CFrame.new((low + high) / 2),
			Piece = piece,
			Smooth = false,
		})
	end
	syncClothing(rig)
end

-- Straight within the given limits: every segment where its rest pose puts it.
local function isStraight(group: Group, angle: number, offset: number): boolean
	local anchorCFrame = group.Anchor.CFrame
	for index = 2, #group.Segments do
		local relative = anchorCFrame:ToObjectSpace(group.Segments[index].CFrame)
		local difference = group.Rest[index]:ToObjectSpace(relative)
		if difference.Position.Magnitude > offset then
			return false
		end
		local _, turned = difference:ToAxisAngle()
		if math.abs(turned) > angle then
			return false
		end
	end
	return true
end

local function release(character: Model)
	local rig = rigs[character]
	if not rig then
		return
	end
	rigs[character] = nil
	for _, connection in rig.Connections do
		connection:Disconnect()
	end
	clearRig(rig)
	rig.Model:Destroy()
end

local function track(character: Model)
	if rigs[character] or not folder then
		return
	end
	local model = Instance.new("Model")
	model.Name = character.Name
	local rig: Rig = {
		Character = character,
		Head = nil,
		Model = model,
		Groups = {},
		Connections = {},
		PartConnections = {},
		Dirty = true,
	}
	rigs[character] = rig
	local function onChange(instance: Instance)
		-- body parts, joints, scaling or clothing changed (ApplyDescription,
		-- respawn assembly, scale values): rebuild from the new body
		if instance:IsA("BasePart") or instance:IsA("Clothing")
			or instance:IsA("ShirtGraphic") or instance:IsA("Humanoid") then
			rig.Dirty = true
		end
	end
	table.insert(rig.Connections, character.ChildAdded:Connect(onChange))
	table.insert(rig.Connections, character.ChildRemoved:Connect(onChange))
	table.insert(rig.Connections, character.DescendantAdded:Connect(function(instance)
		if instance:IsA("Motor6D") or instance:IsA("AnimationConstraint") then
			rig.Dirty = true
		end
	end))
	table.insert(rig.Connections, character.AncestryChanged:Connect(function()
		if not character:IsDescendantOf(workspace) then
			release(character)
		end
	end))
	model.Parent = folder
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		if enabled then
			track(character)
		end
	end)
	player.CharacterRemoving:Connect(release)
	if player.Character and enabled then
		track(player.Character)
	end
end

local pieces: { BasePart } = {}
local placements: { CFrame } = {}

local function step()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	local localCharacter = Players.LocalPlayer.Character
	table.clear(pieces)
	table.clear(placements)
	for character, rig in rigs do
		if rig.Dirty then
			build(rig)
		end
		local use = #rig.Groups > 0
		if use and rig.Head then
			-- your own body while the engine fades it (first person / zoomed in):
			-- leave it alone, the engine owns its transparency then
			if character == localCharacter and rig.Head.LocalTransparencyModifier > 0 then
				use = false
			elseif (rig.Head.Position - eye).Magnitude > MAX_DISTANCE then
				use = false
			end
		end
		for _, group in rig.Groups do
			local smooth = use
				and isStraight(group, if group.Smooth then BEND_ANGLE else REST_ANGLE,
					if group.Smooth then BEND_OFFSET else REST_OFFSET)
			if smooth ~= group.Smooth then
				if not use and character == localCharacter then
					-- (the engine is writing these; just stop hiding them)
					group.Smooth = false
					group.Piece.LocalTransparencyModifier = 1
				else
					setSmooth(group, smooth)
				end
			end
			if smooth then
				-- (re-hidden every frame: the camera's zoom fade rewrites your
				-- own character's transparency when it changes)
				for _, segment in group.Segments do
					if segment.LocalTransparencyModifier ~= 1 then
						segment.LocalTransparencyModifier = 1
					end
				end
				local piece = group.Piece
				piece.Transparency = group.Anchor.Transparency
				table.insert(pieces, piece)
				table.insert(placements, group.Anchor.CFrame * group.Offset)
			end
		end
	end
	if #pieces > 0 then
		workspace:BulkMoveTo(pieces, placements, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function trackAll()
	for _, player in Players:GetPlayers() do
		if player.Character then
			track(player.Character)
		end
	end
end

function SmoothLimbs.SetEnabled(on: boolean)
	if enabled == on then
		return
	end
	enabled = on
	if not started then
		return
	end
	if on then
		trackAll()
	else
		for character in rigs do
			release(character)
		end
	end
end

function SmoothLimbs.start()
	if started then
		return
	end
	started = true
	local container = Instance.new("Folder")
	container.Name = "SmoothLimbs"
	container.Parent = workspace
	folder = container
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	-- just before drawing: animation and physics have placed the segments
	RunService.PreRender:Connect(step)
end

return SmoothLimbs
