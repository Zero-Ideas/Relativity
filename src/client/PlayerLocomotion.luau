--!strict
-- Input and movement are local and independent of the selected HUD. The
-- server only validates requests and owns stamina/cooldowns; its reply must
-- never launch an already-predicted flip a second time.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Movement = require(script.Parent.MovementController)
local SpellEditor = require(script.Parent.SpellAssemblerGui)
local remote = ReplicatedStorage:WaitForChild("PlayerMovement") :: RemoteEvent
local player = Players.LocalPlayer
local Locomotion = {}
local started = false
local sprinting = false
local pendingSprint: number? = nil
local sequence = 0
local lastForward, lastFlip = -math.huge, -math.huge
local pendingFlips: { [number]: { character: Model, cost: number, delta: Vector3, startedAt: number, scale: number, track: AnimationTrack? } } = {}

local function nextId(): number
	sequence += 1
	return sequence
end

local function setting(name: string, default: number): number
	local value = remote:GetAttribute(name)
	return if typeof(value) == "number" then value else default
end

local function characterParts(): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return character, humanoid, if root and root:IsA("BasePart") then root else nil
end

local function availableStamina(): number
	local amount = player:GetAttribute("Stamina") or 0
	for _, pending in pendingFlips do amount -= pending.cost end
	return math.max(amount, 0)
end

local function applySprint(on: boolean)
	sprinting = on
	Movement.SetSprintMultiplier(if on then setting("SprintMultiplier", 1.6) else 1)
end

local function toggleSprint()
	local character, humanoid = characterParts()
	if not character or not humanoid or humanoid.Health <= 0 or humanoid.PlatformStand or Movement.GetTimeScale() <= 0 then return end
	local desired = not sprinting and availableStamina() > 0
	local id = nextId()
	pendingSprint = id
	applySprint(desired)
	remote:FireServer("SetSprint", id, desired, character)
end

local function flip()
	local character, humanoid, root = characterParts()
	local now = os.clock()
	local scale = Movement.GetTimeScale()
	local cost = setting("FlipCost", 60)
	if not character or not humanoid or not root or humanoid.Health <= 0 or humanoid.PlatformStand
		or humanoid.FloorMaterial == Enum.Material.Air or scale <= 0
		or now - lastFlip < setting("FlipCooldown", 1.15) or availableStamina() < cost then return end
	lastFlip = now
	local camera = workspace.CurrentCamera
	local look = if camera then camera.CFrame.LookVector else root.CFrame.LookVector
	local direction = look * Vector3.new(1, 0, 1)
	if direction.Magnitude < 0.001 then direction = Vector3.zAxis end
	local delta = (Vector3.yAxis * 110 + direction.Unit * 125) * scale
	local id = nextId()
	local pending = { character = character, cost = cost, delta = delta, startedAt = now, scale = scale, track = nil :: AnimationTrack? }
	pendingFlips[id] = pending
	-- Request first, but do not wait for the round trip before moving.
	remote:FireServer("Flip", id, nil, character)
	root.AssemblyLinearVelocity += delta
	local storage = game:GetService("Lighting"):FindFirstChild("AnimationStorage")
	local animation = storage and storage:FindFirstChild("FrontFlip")
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animation and animation:IsA("Animation") and animator then
		pcall(function()
			local track = animator:LoadAnimation(animation)
			pending.track = track
			track:Play()
			track:AdjustSpeed(scale)
			track.Stopped:Once(function() track:Destroy() end)
		end)
	end
end

function Locomotion.start()
	if started then return end
	started = true
	applySprint(player:GetAttribute("Sprinting") == true)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() or SpellEditor.IsOpen() then return end
		if input.KeyCode == Enum.KeyCode.LeftControl then
			toggleSprint()
		elseif input.KeyCode == Enum.KeyCode.W then
			local now = os.clock()
			if now - lastForward < 0.2 then lastForward = -math.huge; flip() else lastForward = now end
		end
	end)
	remote.OnClientEvent:Connect(function(action, id, accepted)
		if action == "SprintResult" and id == pendingSprint then
			pendingSprint = nil
			applySprint(accepted == true)
		elseif action == "FlipResult" then
			local pending = pendingFlips[id]
			if not pending then return end
			pendingFlips[id] = nil
			if accepted ~= true then
				local character, humanoid, root = characterParts()
				if character == pending.character and humanoid and humanoid.Health > 0 and not humanoid.PlatformStand and root
					and os.clock() - pending.startedAt < 0.3 and math.abs(Movement.GetTimeScale() - pending.scale) < 1e-4
					and root.AssemblyLinearVelocity:Dot(pending.delta) > pending.delta:Dot(pending.delta) * 0.5 then
					-- Best-effort early cancellation only. After a collision, freeze,
					-- or late reply the impulse is no longer safely subtractable.
					root.AssemblyLinearVelocity -= pending.delta
				end
				if pending.track then pcall(function() pending.track:Stop(0.1) end) end
			end
		end
	end)
	player:GetAttributeChangedSignal("Sprinting"):Connect(function()
		if not pendingSprint then applySprint(player:GetAttribute("Sprinting") == true) end
	end)
	player:GetAttributeChangedSignal("Stamina"):Connect(function()
		if (player:GetAttribute("Stamina") or 0) <= 0 then applySprint(false) end
	end)
	local function reset()
		pendingSprint = nil
		lastForward, lastFlip = -math.huge, -math.huge
		table.clear(pendingFlips)
		applySprint(false)
	end
	player.CharacterRemoving:Connect(reset)
	player.CharacterAdded:Connect(reset)
	UserInputService.WindowFocusReleased:Connect(function() lastForward = -math.huge end)
end

return Locomotion
