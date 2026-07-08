--!optimize 2
--[[
	MovementController.luau  (client)
	Makes the local character move in dilated time. Roblox's own character
	physics run in real time, so on their own WalkSpeed/JumpPower would ignore
	the global time ratio and chunk time scales. This controller re-derives the
	character's motion from the same clock every other system uses:

	    effScale = Heartbeat.globalScale * chunk scale under the character

	Each frame it:
	  • scales WalkSpeed by effScale            (walking slows with time)
	  • scales the jump impulse by effScale      (jumps launch slower)
	  • applies a custom-gravity VectorForce so the character's *net* downward
	    acceleration becomes g₀ · effScale²      (falls float in slow time)

	The effScale² on gravity is the physically correct scaling: with jump
	velocity scaled by effScale and gravity by effScale², jump height is
	preserved but the whole arc plays out in dilated time. At effScale = 0 the
	upward force exactly cancels gravity, so the character freezes in place.

	Only the *local* character is driven here — each client owns its own, which
	is how Roblox network ownership already works.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Heartbeat = require(Shared.Heartbeat)
local ChunkManager = require(Shared.ChunkManager)

local MovementController = {}

local player = Players.LocalPlayer
local started = false

type CharacterState = {
	humanoid: Humanoid,
	root: BasePart,
	force: VectorForce,
	baseWalkSpeed: number,
	baseJumpPower: number?,
	baseJumpHeight: number?,
}

local state: CharacterState? = nil

local function teardown()
	if state and state.force then
		state.force:Destroy()
	end
	state = nil
end

local function setup(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not humanoid or not root then
		return
	end

	-- A VectorForce (in world space, at the center of mass) supplies the
	-- gravity *correction*: real gravity always pulls with g₀; we add an
	-- upward force so the remainder matches g₀ · effScale².
	local attachment = root:FindFirstChild("MovementGravityAttachment") :: Attachment?
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = "MovementGravityAttachment"
		attachment.Parent = root
	end

	local force = Instance.new("VectorForce")
	force.Name = "MovementGravityForce"
	force.Attachment0 = attachment
	force.ApplyAtCenterOfMass = true
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.Force = Vector3.zero
	force.Parent = root

	state = {
		humanoid = humanoid,
		root = root,
		force = force,
		baseWalkSpeed = humanoid.WalkSpeed > 0 and humanoid.WalkSpeed or 16,
		baseJumpPower = humanoid.UseJumpPower and humanoid.JumpPower or nil,
		baseJumpHeight = (not humanoid.UseJumpPower) and humanoid.JumpHeight or nil,
	}
end

local function step()
	local current = state
	if not current then
		return
	end
	local humanoid, root = current.humanoid, current.root
	if humanoid.Health <= 0 or not root.Parent then
		return
	end

	local effScale = ChunkManager.GetEffectiveTimeScaleAt(root.Position)

	-- Horizontal movement dilation.
	humanoid.WalkSpeed = current.baseWalkSpeed * effScale

	-- Jump impulse dilation (velocity scales with effScale).
	if current.baseJumpPower then
		humanoid.JumpPower = current.baseJumpPower * effScale
	elseif current.baseJumpHeight then
		humanoid.JumpHeight = current.baseJumpHeight * effScale * effScale
	end

	-- Custom gravity: net downward accel should be g₀ · effScale².
	-- Roblox already applies g₀, so add upward (mass · g₀ · (1 − effScale²)).
	local g0 = workspace.Gravity
	local mass = root.AssemblyMass
	current.force.Force = Vector3.new(0, mass * g0 * (1 - effScale * effScale), 0)
end

function MovementController.start()
	if started then
		return
	end
	started = true

	local function onCharacter(character)
		teardown()
		task.defer(setup, character)
	end

	if player.Character then
		onCharacter(player.Character)
	end
	player.CharacterAdded:Connect(onCharacter)
	player.CharacterRemoving:Connect(teardown)

	Heartbeat.Connect(step, { Name = "MovementController", Priority = 20 })
end

return MovementController
