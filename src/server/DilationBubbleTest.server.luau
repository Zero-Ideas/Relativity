--!optimize 2
-- Studio-only configurable time-dilation bubble tool and authoritative zones.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPack = game:GetService("StarterPack")

if not RunService:IsStudio() then
	return
end

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared.ChunkManager)
local VisualOffload = require(Shared.VisualOffload)

local TOOL_NAME = "DilationBubble"
local MAX_PLACEMENT_DISTANCE = 512
local MAX_BUBBLES_PER_PLAYER = 8
local CREATE_COOLDOWN = 0.15

local nextBubbleId = 0
local lastCreate: { [Player]: number } = {}
local bubblesByPlayer: { [Player]: { any } } = {}

local zoneFolder = workspace:FindFirstChild("DilationTestZones") or Instance.new("Folder")
zoneFolder.Name = "DilationTestZones"
zoneFolder.Parent = workspace

local function makeTool(): Tool
	local existing = StarterPack:FindFirstChild(TOOL_NAME)
	if existing and existing:IsA("Tool") then
		return existing
	end
	local tool = Instance.new("Tool")
	tool.Name = TOOL_NAME
	tool.ToolTip = "Create a configurable time-dilation test zone"
	tool.RequiresHandle = false
	tool.CanBeDropped = false
	tool.Parent = StarterPack
	return tool
end

local toolTemplate = makeTool()

local function ensureTool(player: Player)
	local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
	if not backpack then
		return
	end
	local character = player.Character
	if backpack:FindFirstChild(TOOL_NAME) or (character and character:FindFirstChild(TOOL_NAME)) then
		return
	end
	toolTemplate:Clone().Parent = backpack
end

local function watchPlayer(player: Player)
	task.defer(ensureTool, player)
	player.CharacterAdded:Connect(function()
		task.defer(ensureTool, player)
	end)
end

for _, player in Players:GetPlayers() do
	watchPlayer(player)
end
Players.PlayerAdded:Connect(watchPlayer)

local function removeBubble(bubble)
	if bubble.Removed then
		return
	end
	bubble.Removed = true
	if bubble.Visual then
		bubble.Visual:Destroy()
	end
	ChunkManager.RemoveTimeScaleZone(bubble.Id)

	local owned = bubblesByPlayer[bubble.Owner]
	if owned then
		local index = table.find(owned, bubble)
		if index then
			table.remove(owned, index)
		end
		if #owned == 0 then
			bubblesByPlayer[bubble.Owner] = nil
		end
	end
end

local function zoneColor(scale: number): Color3
	if scale == 0 then
		return Color3.fromRGB(165, 90, 255)
	elseif scale < 1 then
		return Color3.fromRGB(70, 170, 255)
	elseif scale > 1 then
		return Color3.fromRGB(255, 145, 55)
	end
	return Color3.fromRGB(125, 235, 150)
end

local function makeZoneVisual(position: Vector3, radius: number, scale: number, duration: number): BasePart
	local sphere = Instance.new("Part")
	sphere.Name = "DilationBubble"
	sphere.Shape = Enum.PartType.Ball
	sphere.Size = Vector3.one * radius * 2
	sphere.CFrame = CFrame.new(position)
	sphere.Anchored = true
	sphere.CanCollide = false
	sphere.CanQuery = false
	sphere.CanTouch = false
	sphere.CastShadow = false
	sphere.Material = Enum.Material.ForceField
	sphere.Color = zoneColor(scale)
	sphere.Transparency = 0.78
	sphere.Parent = zoneFolder

	local label = Instance.new("BillboardGui")
	label.Name = "Info"
	label.Size = UDim2.fromOffset(210, 48)
	label.StudsOffset = Vector3.new(0, radius + 3, 0)
	label.AlwaysOnTop = true
	label.Parent = sphere
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
	text.BackgroundTransparency = 0.2
	text.BorderSizePixel = 0
	text.Font = Enum.Font.GothamBold
	text.TextSize = 14
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Text = string.format("Time x%.2f  |  radius %.0f\n%.1fs exact radial zone", scale, radius, duration)
	text.Parent = label
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 7)
	corner.Parent = text

	return sphere
end

local function finiteNumber(value: any, fallback: number, minimum: number, maximum: number): number
	if typeof(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return fallback
	end
	return math.clamp(value, minimum, maximum)
end

local function createBubble(player: Player, data)
	local character = player.Character
	local root = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
	local equipped = character and character:FindFirstChild(TOOL_NAME)
	if not root or not equipped or not equipped:IsA("Tool") then
		return
	end

	local position = data.Position
	if
		typeof(position) ~= "Vector3"
		or position.X ~= position.X
		or position.Y ~= position.Y
		or position.Z ~= position.Z
		or (position - root.Position).Magnitude > MAX_PLACEMENT_DISTANCE
	then
		return
	end

	local now = os.clock()
	if lastCreate[player] and now - lastCreate[player] < CREATE_COOLDOWN then
		return
	end
	lastCreate[player] = now

	local radius = finiteNumber(data.Radius, 64, 8, 256)
	local scale = finiteNumber(data.Scale, 0.25, 0, 3)
	local duration = finiteNumber(data.Duration, 8, 0.25, 30)
	nextBubbleId += 1
	local bubble = {
		Id = `DilationBubble:{nextBubbleId}`,
		Owner = player,
		Removed = false,
	}
	ChunkManager.AddTimeScaleZone(bubble.Id, position, radius, scale)

	bubble.Visual = makeZoneVisual(position, radius, scale, duration)
	local owned = bubblesByPlayer[player]
	if not owned then
		owned = {}
		bubblesByPlayer[player] = owned
	end
	table.insert(owned, bubble)
	if #owned > MAX_BUBBLES_PER_PLAYER then
		removeBubble(owned[1])
	end
	task.delay(duration, removeBubble, bubble)
end

VisualOffload.On("DilationBubbleTest", function(data, player)
	if not player or typeof(data) ~= "table" then
		return
	end
	if data.Action == "Clear" then
		local owned = bubblesByPlayer[player]
		if owned then
			for i = #owned, 1, -1 do
				removeBubble(owned[i])
			end
		end
	elseif data.Action == "Create" then
		createBubble(player, data)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	local owned = bubblesByPlayer[player]
	if owned then
		for i = #owned, 1, -1 do
			removeBubble(owned[i])
		end
	end
	lastCreate[player] = nil
end)
