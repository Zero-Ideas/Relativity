--!optimize 2
-- Authored Entity test dummies with a coalesced, server-owned damage display.
-- Driven by the Studio debug panel's Dummies tab (src/client/DebugPanel.luau)
-- over the "DummySpawner" channel; Studio only, like the rest of the panel.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Entity = require(Shared.Entity)
local SafeMath = require(Shared.SafeMath)
local VisualOffload = require(Shared.VisualOffload)
local DebugAccess = require(script.Parent.DebugAccess)

-- Duplicate Studio Script instances must never install a second handler.
if Shared:GetAttribute("DummySpawnerRunning") then return end
Shared:SetAttribute("DummySpawnerRunning", true)

local folder = Instance.new("Folder")
folder.Name = "SpawnedTestDummies"
folder.Parent = workspace
local owned, lastCommand, counters = {}, {}, {}
local GOLD = Color3.fromRGB(235, 199, 150)
local BLUE = Color3.fromRGB(28, 56, 88)

local function round(parent, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function text(parent, name, value, position, size, fontSize)
	local label = Instance.new("TextLabel")
	label.Name, label.Text = name, value
	label.Position, label.Size = position, size
	label.BackgroundTransparency = 1
	label.TextColor3 = GOLD
	label.Font = Enum.Font.GothamMedium
	label.TextSize = fontSize
	label.TextScaled = true
	label.Parent = parent
	return label
end

local function makeDisplay(model, root)
	local gui = Instance.new("BillboardGui")
	gui.Name = "DamageCounter"
	gui.Adornee = root
	-- Scale components of BillboardGui.Size are studs, so native projection
	-- makes this shrink with distance instead of keeping a large pixel panel.
	gui.Size = UDim2.fromScale(3.5, 2.53)
	gui.StudsOffset = Vector3.new(3.8, 0.5, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 200
	gui.Parent = root
	local title = Instance.new("Frame")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 20 / 112)
	title.BackgroundColor3 = BLUE
	title.BackgroundTransparency = 0.25
	title.BorderSizePixel = 0
	title.Parent = gui
	round(title, 6)
	text(title, "Name", "- " .. model.Name .. " -", UDim2.new(), UDim2.fromScale(1, 1), 12)
	local panel = Instance.new("Frame")
	panel.Name = "Stats"
	panel.Position = UDim2.fromScale(0, 24 / 112)
	panel.Size = UDim2.fromScale(1, 88 / 112)
	panel.BackgroundColor3 = BLUE
	panel.BackgroundTransparency = 0.2
	panel.BorderSizePixel = 0
	panel.Parent = gui
	round(panel, 7)
	text(panel, "Heart", "♥", UDim2.fromScale(8 / 155, 0), UDim2.fromScale(44 / 155, 45 / 88), 36)
	local hp = text(panel, "Health", "", UDim2.fromScale(54 / 155, 0), UDim2.fromScale(95 / 155, 45 / 88), 27)
	local damage = text(panel, "Damage", "", UDim2.fromScale(8 / 155, 48 / 88), UDim2.fromScale(139 / 155, 32 / 88), 12)
	local highlight = Instance.new("Highlight")
	highlight.Name = "TestDummyOutline"
	highlight.Adornee = model
	highlight.FillTransparency = 1
	highlight.OutlineColor = GOLD
	highlight.OutlineTransparency = 0.15
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = model
	return hp, damage
end

local function clear(player)
	local list = owned[player]
	if list then
		for _, model in list do model:Destroy() end
		table.clear(list)
	end
end

local DEFAULT_MODEL = "Dummy"
local DEFAULT_HEALTH = 1000

-- Spawnable templates: rigged (Humanoid) Models directly under
-- ReplicatedStorage or inside a ReplicatedStorage folder named "Dummies".
local function templates(): { [string]: Model }
	local found = {}
	local function consider(instance: Instance)
		if instance:IsA("Model") and instance:FindFirstChildOfClass("Humanoid") and not found[instance.Name] then
			found[instance.Name] = instance
		end
	end
	for _, child in ReplicatedStorage:GetChildren() do
		consider(child)
		if child:IsA("Folder") and child.Name == "Dummies" then
			for _, nested in child:GetChildren() do consider(nested) end
		end
	end
	return found
end

local function resolveTemplate(name: any): Model?
	local template = templates()[if typeof(name) == "string" then name else DEFAULT_MODEL]
	if template then return template end
	warn("[DummySpawner] no rigged Model named", name, "under ReplicatedStorage")
	return nil
end

local function spawn(player, data, playerRoot, target)
	local template = resolveTemplate(data.Model)
	if not template then return end
	local model = template:Clone()
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if not humanoid or not root or not root:IsA("BasePart") then
		model:Destroy()
		warn("[DummySpawner] Template needs a Humanoid and root BasePart")
		return
	end
	-- Keep authored rig geometry/joints, but avoid template scripts installing
	-- their own spawners or damage systems.
	for _, instance in model:GetDescendants() do
		if instance:IsA("BaseScript") then instance:Destroy()
		elseif instance:IsA("BillboardGui") and instance.Name == "DamageCounter" then instance:Destroy() end
	end
	model.PrimaryPart = root
	humanoid.WalkSpeed = 0
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	local health = SafeMath.number(data.Health, DEFAULT_HEALTH, 1, 1000000)
	humanoid.MaxHealth, humanoid.Health = health, health
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character, folder }
	local ground = workspace:Raycast(target + Vector3.new(0, 20, 0), Vector3.new(0, -100, 0), params)
	if not ground then model:Destroy(); return end
	local pivot = model:GetPivot()
	local box, size = model:GetBoundingBox()
	local feetOffset = pivot.Position.Y - (box.Position.Y - size.Y * 0.5)
	local position = ground.Position + Vector3.new(0, feetOffset + 0.05, 0)
	local facing = Vector3.new(playerRoot.Position.X, position.Y, playerRoot.Position.Z)
	model:PivotTo(if (facing - position).Magnitude > 0.01 then CFrame.lookAt(position, facing) else CFrame.new(position))
	local list = owned[player] or {}
	owned[player] = list
	for i = #list, 1, -1 do if not list[i].Parent then table.remove(list, i) end end
	model:SetAttribute("SpawnedBy", player.UserId)
	model.Parent = folder
	for _, instance in model:GetDescendants() do
		if instance:IsA("BasePart") then
			local canSet = instance:CanSetNetworkOwnership()
			if canSet then instance:SetNetworkOwner(nil) end
		end
	end
	local entity = Entity.new(model, { Team = "Undead", ScaleHumanoid = true })
	entity:AddTag("Enemy")
	entity:AddTag("TestDummy")
	table.insert(list, model)
	local hp, damage = makeDisplay(model, root)
	local state = { HealthLabel = hp, DamageLabel = damage, Entity = entity, Total = 0, Last = 0, Hits = 0, Dirty = true, FeetOffset = feetOffset }
	counters[model] = state
	model:SetAttribute("TotalDamage", 0)
	model:SetAttribute("HitCount", 0)
	model:SetAttribute("DamagePulse", 0)
	entity.Damaged:Connect(function(amount)
		state.Total += amount
		state.Last = amount
		state.Hits += 1
		state.Dirty = true
		model:SetAttribute("DamagePulse", state.Hits)
	end)
	humanoid.HealthChanged:Connect(function() state.Dirty = true end)
	model.Destroying:Connect(function()
		counters[model] = nil
		if not entity.IsDestroyed then entity:Destroy() end
	end)
end

local function moveDummy(player, model, target)
	-- Only server-owned dummies belonging to the requester can move.
	if typeof(model) ~= "Instance" or not model:IsA("Model") or model.Parent ~= folder then return end
	local state = counters[model]
	if not state or model:GetAttribute("SpawnedBy") ~= player.UserId then return end
	local root = model.PrimaryPart
	if not root then return end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character, folder }
	local ground = workspace:Raycast(target + Vector3.new(0, 20, 0), Vector3.new(0, -100, 0), params)
	if not ground then return end
	local from = model:GetPivot()
	local position = ground.Position + Vector3.new(0, state.FeetOffset + 0.05, 0)
	local wasAnchored = if state.Move then state.Move.WasAnchored else root.Anchored
	root.Anchored = true
	for _, instance in model:GetDescendants() do
		if instance:IsA("BasePart") then
			instance.AssemblyLinearVelocity = Vector3.zero
			instance.AssemblyAngularVelocity = Vector3.zero
		end
	end
	state.Move = { From = from, To = CFrame.new(position) * from.Rotation, Elapsed = 0, WasAnchored = wasAnchored }
end

local MAX_PLACE_DISTANCE = 500

VisualOffload.On("DummySpawner", function(data, player)
	-- Debug-panel feature: only for players who may use its Dummies tab (see
	-- DebugAccess.CanUseTab).
	if not DebugAccess.CanUseTab(player, "Dummies") or typeof(data) ~= "table" then return end
	if data.Action == "Models" then
		local names = {}
		for name in templates() do table.insert(names, name) end
		table.sort(names)
		VisualOffload.FireClient(player, "DummyModels", { Models = names, Default = DEFAULT_MODEL, Health = DEFAULT_HEALTH })
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then return end
	if data.Action ~= "Spawn" and data.Action ~= "Clear" and data.Action ~= "Move" and data.Action ~= "Delete" then return end
	local now = os.clock()
	if lastCommand[player] and now - lastCommand[player] < 0.25 then return end
	lastCommand[player] = now
	if data.Action == "Clear" then clear(player); return end
	if data.Action == "Delete" then
		local model = data.Dummy
		if typeof(model) ~= "Instance" or not model:IsA("Model") or model.Parent ~= folder then return end
		if not counters[model] or model:GetAttribute("SpawnedBy") ~= player.UserId then return end
		local list = owned[player]
		local index = list and table.find(list, model)
		if index then table.remove(list, index) end
		model:Destroy()
		return
	end
	local target = data.Position
	if typeof(target) ~= "Vector3" or not SafeMath.isFiniteVector(target) then return end
	if (target - root.Position).Magnitude > MAX_PLACE_DISTANCE then return end
	if data.Action == "Move" then moveDummy(player, data.Dummy, target)
	else spawn(player, data, root, target) end
end)

local elapsed = 0
RunService.Heartbeat:Connect(function(dt)
	for model, state in counters do
		local move = state.Move
		if move then
			move.Elapsed += dt
			local alpha = math.min(move.Elapsed / 0.2, 1)
			model:PivotTo(move.From:Lerp(move.To, alpha * (2 - alpha)))
			if alpha >= 1 then
				if model.PrimaryPart then model.PrimaryPart.Anchored = move.WasAnchored end
				state.Move = nil
			end
		end
	end
	elapsed += dt
	if elapsed < 0.1 then return end
	elapsed = 0
	for model, state in counters do
		if state.Dirty then
			state.Dirty = false
			state.HealthLabel.Text = string.format("%.0f", state.Entity.Health)
			state.DamageLabel.Text = string.format("Damage %.1f  ·  Hits %d\nLast %.1f", state.Total, state.Hits, state.Last)
			model:SetAttribute("TotalDamage", state.Total)
			model:SetAttribute("LastDamage", state.Last)
			model:SetAttribute("HitCount", state.Hits)
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	clear(player)
	owned[player] = nil
	lastCommand[player] = nil
end)
