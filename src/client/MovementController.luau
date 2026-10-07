--!optimize 2
--[[
	MovementController.luau  (client)
	Makes the local character move in dilated time. Roblox's own character
	physics run in real time, so on their own WalkSpeed/JumpPower would ignore
	chunk time scales and the player's own personal time ratio. This controller
	re-derives the character's motion from the same clock every other system
	uses:

	    effScale = worldScale * chunk scale under the character * personalScale

	worldScale is the true Heartbeat global time scale (a dev/world-level knob,
	1 unless something explicitly changes it) and personalScale is this
	player's own ratio, set via SetPersonalTimeScale -- TimeControlGui calls
	that directly for instant feedback and it's the only thing the slider
	actually drives. Because only the *local* character is touched here (each
	client owns/predicts its own, per Roblox's network ownership model),
	personalScale only ever affects this player's own movement on every
	client's screen -- other players see it via ordinary Humanoid property
	replication, but their own movement is driven by their own client's own
	personalScale, so one player's dial can never affect anyone else's.

	Each frame it:
	  • scales WalkSpeed by effScale            (walking slows with time)
	  • scales the jump impulse by effScale      (jumps launch slower)
	  • applies a custom-gravity VectorForce so the character's *net* downward
	    acceleration becomes g₀ · effScale²      (falls float in slow time)

	The effScale² on gravity is the physically correct scaling: with jump
	velocity scaled by effScale and gravity by effScale², jump height is
	preserved but the whole arc plays out in dilated time. At effScale = 0 the
	upward force exactly cancels gravity, so the character freezes in place.

	------------------------------------------------------------------------
	Speed / jump API (sprint, slows, dashes, abilities...)
	------------------------------------------------------------------------
	Because this rewrites WalkSpeed / JumpPower / JumpHeight EVERY frame,
	setting those Humanoid properties directly from another script doesn't
	stick. Use modifiers instead -- they stack, and time dilation still
	applies on top (a sprint slows down in a slow chunk like everything else).

	    local MovementController = require(
	        Players.LocalPlayer.PlayerScripts:WaitForChild("Client"):WaitForChild("MovementController"))

	    -- sprint while Shift is held
	    local sprint = nil
	    UserInputService.InputBegan:Connect(function(input, processed)
	        if not processed and input.KeyCode == Enum.KeyCode.LeftShift then
	            sprint = MovementController.AddModifier("Sprint", { WalkSpeedMultiplier = 1.6 })
	        end
	    end)
	    UserInputService.InputEnded:Connect(function(input)
	        if input.KeyCode == Enum.KeyCode.LeftShift and sprint then
	            sprint:Remove()
	            sprint = nil
	        end
	    end)

	  AddModifier(id, modifier) -> handle      add (or replace) modifier `id`
	      handle:Update(modifier)  handle:Remove()
	  SetModifier(id, modifier) / RemoveModifier(id) / GetModifier(id)
	  ClearModifiers()
	  SetBase({ WalkSpeed = n?, Jump = n? })   this life's base (see below)
	  GetBase() -> walkSpeed, jump, jumpMode   ("Power" | "Height")
	  GetWalkSpeed() / GetJump()               after modifiers, before dilation
	  GetTimeScale()                           effScale applied last frame

	  Modifier fields (all optional):
	    WalkSpeedMultiplier  x the walk speed      (1.6 = sprint, 0.5 = slow)
	    WalkSpeedAdd         + studs/s             (applied before multipliers)
	    WalkSpeed            exact walk speed, ignores base/adds/multipliers
	                         (highest Priority wins if several set one; 0 = rooted)
	    JumpMultiplier / JumpAdd / Jump   the same for the jump, in the
	                         Humanoid's own jump mode (power, or height)
	    Priority             tie-break for exact overrides (default 0)
	    KeepOnRespawn        keep through death/respawn (default: cleared)

	  Result: walk = (base + sum of WalkSpeedAdd) x product of
	  WalkSpeedMultiplier, or the highest-priority WalkSpeed override; then x
	  effScale. Never below 0. Same for the jump.

	  Base, in priority order: the server's forced spawn stats while an admin
	  has them on (server/PlayerDefaults -> BaseWalkSpeed / BaseJumpPower /
	  BaseJumpHeight attributes); SetBase for this life; the values the
	  Humanoid spawned with.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Heartbeat = require(Shared.Heartbeat)
local ChunkManager = require(Shared.ChunkManager)

local MovementController = {}

local player = Players.LocalPlayer
local started = false
local personalScale = 1
local lastEffScale = 1

export type Modifier = {
	WalkSpeedMultiplier: number?,
	WalkSpeedAdd: number?,
	WalkSpeed: number?,
	JumpMultiplier: number?,
	JumpAdd: number?,
	Jump: number?,
	Priority: number?,
	KeepOnRespawn: boolean?,
}

export type ModifierHandle = {
	Id: string,
	Update: (self: ModifierHandle, modifier: Modifier) -> (),
	Remove: (self: ModifierHandle) -> (),
}

type CharacterState = {
	humanoid: Humanoid,
	root: BasePart,
	force: VectorForce,
	baseWalkSpeed: number,
	baseJumpPower: number?,
	baseJumpHeight: number?,
}

local state: CharacterState? = nil
local modifiers: { [string]: Modifier } = {}
local baseOverride: { WalkSpeed: number?, Jump: number? } = {} -- SetBase, this life only

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

local function finite(value: any): number?
	return if typeof(value) == "number" and value == value and math.abs(value) ~= math.huge then value else nil
end

-- (base + adds) x multipliers, or the highest-priority exact override.
local function resolve(base: number, addKey: string, multiplierKey: string, exactKey: string): number
	local add, multiplier = 0, 1
	local exact: number?, exactPriority = nil, -math.huge
	for _, modifier in modifiers do
		local m = modifier :: any
		add += finite(m[addKey]) or 0
		multiplier *= finite(m[multiplierKey]) or 1
		local value = finite(m[exactKey])
		local priority = finite(m.Priority) or 0
		if value and priority >= exactPriority then
			exact, exactPriority = value, priority
		end
	end
	return math.max(if exact then exact else (base + add) * multiplier, 0)
end

-- The undilated base: forced server stats > SetBase > spawn values.
local function bases(current: CharacterState): (number, number?, string)
	local humanoid = current.humanoid
	local forcedWalk = finite(humanoid:GetAttribute("BaseWalkSpeed"))
	local forcedPower = finite(humanoid:GetAttribute("BaseJumpPower"))
	local forcedHeight = finite(humanoid:GetAttribute("BaseJumpHeight"))
	local walk = forcedWalk or baseOverride.WalkSpeed or current.baseWalkSpeed
	if forcedPower then
		return walk, forcedPower, "Power"
	elseif forcedHeight then
		return walk, forcedHeight, "Height"
	end
	local mode = if current.baseJumpHeight then "Height" else "Power"
	local jump = baseOverride.Jump or current.baseJumpPower or current.baseJumpHeight
	return walk, jump, mode
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

	local effScale = Heartbeat.GetGlobalTimeScale() * ChunkManager.GetTimeScaleAt(root.Position) * personalScale
	lastEffScale = effScale

	-- Base (forced server stats > SetBase > spawn values), then modifiers
	-- (sprint, slows... -- see the API above), then dilation.
	local baseWalk, baseJump, jumpMode = bases(current)

	-- Horizontal movement dilation.
	humanoid.WalkSpeed = resolve(baseWalk, "WalkSpeedAdd", "WalkSpeedMultiplier", "WalkSpeed") * effScale

	-- Jump impulse dilation (velocity scales with effScale; height with its square).
	if baseJump then
		local jump = resolve(baseJump, "JumpAdd", "JumpMultiplier", "Jump")
		if jumpMode == "Power" then
			if not humanoid.UseJumpPower then
				humanoid.UseJumpPower = true
			end
			humanoid.JumpPower = jump * effScale
		else
			if humanoid.UseJumpPower then
				humanoid.UseJumpPower = false
			end
			humanoid.JumpHeight = jump * effScale * effScale
		end
	end

	-- Custom gravity: net downward accel should be g₀ · effScale².
	-- Roblox already applies g₀, so add upward (mass · g₀ · (1 − effScale²)).
	local g0 = workspace.Gravity
	local mass = root.AssemblyMass
	current.force.Force = Vector3.new(0, mass * g0 * (1 - effScale * effScale), 0)
end

-- This player's own time ratio (see TimeControlGui.luau), independent of the
-- shared Heartbeat global scale -- see the module doc comment.
function MovementController.SetPersonalTimeScale(scale: number)
	personalScale = math.max(scale, 0)
end

function MovementController.GetPersonalTimeScale(): number
	return personalScale
end

--------------------------------------------------------------------------------
-- Speed / jump API (see the module doc comment)
--------------------------------------------------------------------------------

function MovementController.SetModifier(id: string, modifier: Modifier)
	assert(typeof(id) == "string", "MovementController.SetModifier: id must be a string")
	assert(typeof(modifier) == "table", "MovementController.SetModifier: modifier must be a table")
	modifiers[id] = table.clone(modifier)
end

function MovementController.RemoveModifier(id: string)
	modifiers[id] = nil
end

function MovementController.GetModifier(id: string): Modifier?
	local modifier = modifiers[id]
	return if modifier then table.clone(modifier) else nil
end

function MovementController.ClearModifiers()
	table.clear(modifiers)
end

-- Adds (or replaces) modifier `id`; the handle updates or removes it. A handle
-- only touches its own entry: once something else replaced `id`, its Remove
-- and Update do nothing.
function MovementController.AddModifier(id: string, modifier: Modifier): ModifierHandle
	MovementController.SetModifier(id, modifier)
	local owned = modifiers[id]
	local handle = { Id = id }
	function handle.Update(_, changed: Modifier)
		if modifiers[id] == owned then
			MovementController.SetModifier(id, changed)
			owned = modifiers[id]
		end
	end
	function handle.Remove()
		if modifiers[id] == owned then
			modifiers[id] = nil
		end
	end
	return handle :: any
end

-- This life's undilated base walk speed / jump (in the Humanoid's jump mode).
-- Forced server spawn stats still win while an admin has them on. Leave a
-- field nil to fall back to the spawn value.
function MovementController.SetBase(base: { WalkSpeed: number?, Jump: number? })
	baseOverride.WalkSpeed = finite(base.WalkSpeed)
	baseOverride.Jump = finite(base.Jump)
end

-- Undilated base: walk speed, jump, and jump mode ("Power" | "Height").
function MovementController.GetBase(): (number?, number?, string?)
	local current = state
	if not current then
		return nil, nil, nil
	end
	return bases(current)
end

-- Undilated walk speed after modifiers (what the character walks at in 1x time).
function MovementController.GetWalkSpeed(): number?
	local current = state
	if not current then
		return nil
	end
	local walk = bases(current)
	return resolve(walk, "WalkSpeedAdd", "WalkSpeedMultiplier", "WalkSpeed")
end

-- Undilated jump (power or height -- see GetBase) after modifiers.
function MovementController.GetJump(): number?
	local current = state
	if not current then
		return nil
	end
	local _, jump = bases(current)
	return if jump then resolve(jump, "JumpAdd", "JumpMultiplier", "Jump") else nil
end

-- The time scale applied to the character last frame (world x chunk x personal).
function MovementController.GetTimeScale(): number
	return lastEffScale
end

function MovementController.start()
	if started then
		return
	end
	started = true

	local function onCharacter(character)
		teardown()
		-- a new life: drop this life's SetBase and every modifier not marked
		-- KeepOnRespawn (a slow shouldn't outlive the character it slowed)
		table.clear(baseOverride)
		for id, modifier in modifiers do
			if not modifier.KeepOnRespawn then
				modifiers[id] = nil
			end
		end
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
