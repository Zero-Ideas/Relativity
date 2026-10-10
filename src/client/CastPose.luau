--!strict
--[[
	CastPose (client)
	While a spell is charging or channelling (the LocalPlayer's "Casting"
	attribute, set by SpellAssemblerGui), the caster:
	  - turns side-on: the body faces TORSO_TURN to the left of the aim, so
	    the right shoulder leads,
	  - raises the right arm straight (elbow and wrist unbent) so it points
	    at the aim point,
	  - turns the head toward the aim, side to side only (never up / down).
	It eases in and out over BLEND_TIME.

	The body turn is your own root (it replicates like any movement). The
	arm and head are joint Transforms, which don't replicate: your client
	sends the aim point (remote "CastAim", at most SEND_RATE a second) and
	the server puts it on your character's "CastTarget" attribute, which
	every other client poses from. Your own pose uses your live mouse.

	Replaces the root-facing line in StarterGui.MainGui.Animation (kept
	there, commented out, as the backup).

	  CastPose.start()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CastPose = {}

local TORSO_TURN = math.rad(45) -- the body faces this far left of the aim
local HEAD_LIMIT = math.rad(80) -- the head turns at most this far from the torso
local BLEND_TIME = 0.12 -- seconds to ease the pose in / out
local SEND_RATE = 15 -- aim updates a second, at most
local SEND_MOVE = 0.25 -- studs the aim point must move to be sent again
local REMOTE_SMOOTH = 15 -- other casters' aim points ease toward the latest (1/s)

local player = Players.LocalPlayer

-- One joint: Part1 = Frame * Transform * Offset:Inverse(), where Frame is
-- the joint's frame on Part0 (Motor6D: Part0.CFrame * C0; AnimationConstraint:
-- Attachment0.WorldCFrame) and Offset its frame on Part1 (C1 / Attachment1).
type Joint = Motor6D | AnimationConstraint

local function jointFrames(joint: Joint): (CFrame?, CFrame?)
	if joint:IsA("Motor6D") then
		local part0 = joint.Part0
		if not part0 then
			return nil, nil
		end
		return part0.CFrame * joint.C0, joint.C1
	else
		local a0, a1 = joint.Attachment0, joint.Attachment1
		if not (a0 and a1) then
			return nil, nil
		end
		return a0.WorldCFrame, a1.CFrame
	end
end

local function findJoint(character: Model, names: { string }): Joint?
	for _, name in names do
		local found = character:FindFirstChild(name, true)
		if found and (found:IsA("Motor6D") or found:IsA("AnimationConstraint")) and found.Enabled then
			return found
		end
	end
	return nil
end

type Pose = {
	Weight: number, -- 0..1 blend of the pose over the animation
	Target: Vector3?, -- the aim point (smoothed for other casters)
}
local poses: { [Model]: Pose } = {}

-- The rotation taking direction `from` onto `to` by the shortest arc.
local function arc(from: Vector3, to: Vector3): CFrame
	local axis = from:Cross(to)
	local dot = math.clamp(from:Dot(to), -1, 1)
	if axis.Magnitude < 1e-6 then
		if dot > 0 then
			return CFrame.identity
		end
		-- opposite: any perpendicular axis
		local other = if math.abs(from.X) < 0.9 then Vector3.xAxis else Vector3.zAxis
		return CFrame.fromAxisAngle(from:Cross(other).Unit, math.pi)
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(dot))
end

local function blend(joint: Joint, posed: CFrame, weight: number)
	joint.Transform = if weight >= 1 then posed else joint.Transform:Lerp(posed, weight)
end

-- Poses one character this frame (after the animator wrote its Transforms).
local function apply(character: Model, target: Vector3, weight: number)
	local shoulder = findJoint(character, { "RightShoulder", "Right Shoulder" })
	if shoulder then
		local frame, offset = jointFrames(shoulder)
		if frame and offset then
			-- the arm hangs along its -Y; in the joint's frame, with no
			-- Transform, that's this direction:
			local hang = offset:Inverse():VectorToWorldSpace(-Vector3.yAxis)
			local aim = target - frame.Position
			if aim.Magnitude > 0.5 then
				blend(shoulder, arc(hang.Unit, frame:VectorToObjectSpace(aim.Unit)), weight)
			end
		end
		-- a straight arm: elbow and wrist unbent
		for _, names in { { "RightElbow" }, { "RightWrist" } } do
			local joint = findJoint(character, names)
			if joint then
				blend(joint, CFrame.identity, weight)
			end
		end
	end
	local neck = findJoint(character, { "Neck" })
	if neck then
		local frame, offset = jointFrames(neck)
		if frame and offset then
			-- turn about world up from where the head looks unposed to the aim
			local look = (frame * offset:Inverse()).LookVector * Vector3.new(1, 0, 1)
			local head = character:FindFirstChild("Head")
			local from = if head and head:IsA("BasePart") then head.Position else frame.Position
			local aim = (target - from) * Vector3.new(1, 0, 1)
			if look.Magnitude > 1e-3 and aim.Magnitude > 0.5 then
				look, aim = look.Unit, aim.Unit
				local angle = math.atan2(look:Cross(aim).Y, look:Dot(aim))
				angle = math.clamp(angle, -HEAD_LIMIT, HEAD_LIMIT)
				blend(neck, CFrame.fromAxisAngle(frame:VectorToObjectSpace(Vector3.yAxis), angle), weight)
			end
		end
	end
end

local function canPose(character: Model): boolean
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0 and not humanoid.PlatformStand
end

local function localCasting(character: Model): boolean
	return player:GetAttribute("Casting") == true and canPose(character)
end

function CastPose.start()
	local remote = ReplicatedStorage:WaitForChild("CastAim") :: RemoteEvent
	local mouse = player:GetMouse()

	-- your own aim: face it (root) and send it
	local lastSent: Vector3? = nil
	local sendAt = 0
	RunService.RenderStepped:Connect(function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local casting = character ~= nil and localCasting(character)
		if casting and root and root:IsA("BasePart") then
			local target = mouse.Hit.Position
			local flat = (target - root.Position) * Vector3.new(1, 0, 1)
			if flat.Magnitude > 0.1 then
				-- (the old MainGui.Animation line faced it head-on; now side-on)
				root.CFrame = CFrame.lookAt(root.Position, root.Position + flat) * CFrame.Angles(0, TORSO_TURN, 0)
			end
			local now = os.clock()
			if now >= sendAt and (not lastSent or (lastSent - target).Magnitude > SEND_MOVE) then
				sendAt = now + 1 / SEND_RATE
				lastSent = target
				remote:FireServer(target)
			end
		elseif lastSent then
			lastSent = nil
			remote:FireServer(nil)
		end
	end)

	-- every character's arm and head, after the animator each frame
	RunService.Stepped:Connect(function(_, dt)
		local step = dt / BLEND_TIME
		local follow = 1 - math.exp(-REMOTE_SMOOTH * dt)
		local mine = player.Character
		for _, other in Players:GetPlayers() do
			local character = other.Character
			if not character then
				continue
			end
			local active: boolean, target: Vector3?
			if character == mine then
				active = localCasting(character)
				target = if active then mouse.Hit.Position else nil
			else
				local value = character:GetAttribute("CastTarget")
				target = if typeof(value) == "Vector3" then value else nil
				active = target ~= nil and canPose(character)
			end
			local pose = poses[character]
			if not pose then
				if not active then
					continue
				end
				pose = { Weight = 0, Target = target }
				poses[character] = pose
			end
			if target then
				pose.Target = if pose.Target and character ~= mine then pose.Target:Lerp(target, follow) else target
			end
			pose.Weight = math.clamp(pose.Weight + (if active then step else -step), 0, 1)
			if pose.Weight <= 0 or not pose.Target then
				poses[character] = nil
				continue
			end
			-- (eased, so the arm swings up rather than snapping)
			local weight = pose.Weight * pose.Weight * (3 - 2 * pose.Weight)
			apply(character, pose.Target, weight)
		end
		for character in poses do
			if not character.Parent then
				poses[character] = nil
			end
		end
	end)
end

return CastPose
