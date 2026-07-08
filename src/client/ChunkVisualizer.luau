--!optimize 2
--[[
	ChunkVisualizer.luau  (client)
	Draws a translucent box over every chunk whose TimeScale differs from 1, so
	you can see the dilation field at a glance. Colour encodes the local time
	rate: blue = slow (< 1x), red/orange = fast (> 1x). A floating label shows
	the exact multiplier.

	Chunk scales arrive on the client via ChunkManager.EnableReplication(), so
	this just reconciles a pool of parts against ChunkManager.GetAllChunks()
	each refresh. Toggle with the V key (or ChunkVisualizer.setEnabled).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared.ChunkManager)

local ChunkVisualizer = {}

local REFRESH_INTERVAL = 0.25
local BOX_HEIGHT = 64 -- visual height for 2D (XZ) chunking
local started = false
local enabled = true

local folder: Folder? = nil
local parts: { [Vector3]: BasePart } = {} -- keyed by chunk.Key

-- Slow (0x) -> cyan, normal (1x) -> green-ish, fast (>1x) -> red.
local function colorForScale(scale: number): Color3
	if scale < 1 then
		-- 0 -> deep blue, 1 -> teal
		return Color3.fromRGB(40, 120, 255):Lerp(Color3.fromRGB(60, 220, 200), math.clamp(scale, 0, 1))
	else
		-- 1 -> amber, >=2 -> red
		return Color3.fromRGB(255, 200, 60):Lerp(Color3.fromRGB(255, 70, 60), math.clamp(scale - 1, 0, 1))
	end
end

local function makeBox(key: Vector3): BasePart
	local size = ChunkManager.ChunkSize
	local box = Instance.new("Part")
	box.Name = `Chunk_{key.X}_{key.Y}_{key.Z}`
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false
	box.CanTouch = false
	box.CastShadow = false
	box.Material = Enum.Material.ForceField
	box.Transparency = 0.7
	box.Size = Vector3.new(size, ChunkManager.UseY and size or BOX_HEIGHT, size)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.fromOffset(80, 24)
	billboard.AlwaysOnTop = true
	billboard.Parent = box
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextStrokeTransparency = 0.4
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = billboard

	box.Parent = folder
	return box
end

local function positionFor(key: Vector3): Vector3
	local size = ChunkManager.ChunkSize
	local origin = key * size
	local halfHeight = (ChunkManager.UseY and size or BOX_HEIGHT) / 2
	return Vector3.new(origin.X + size / 2, ChunkManager.UseY and origin.Y + size / 2 or halfHeight, origin.Z + size / 2)
end

local function clearAll()
	for _, box in parts do
		box:Destroy()
	end
	table.clear(parts)
end

local function refresh()
	if not enabled then
		return
	end

	local seen: { [Vector3]: boolean } = {}
	for _, chunk in ChunkManager.GetAllChunks() do
		if chunk.TimeScale ~= 1 then
			seen[chunk.Key] = true
			local box = parts[chunk.Key]
			if not box then
				box = makeBox(chunk.Key)
				box.Position = positionFor(chunk.Key)
				parts[chunk.Key] = box
			end
			local color = colorForScale(chunk.TimeScale)
			box.Color = color
			local label = box:FindFirstChild("Label")
			local text = label and label:FindFirstChildWhichIsA("TextLabel")
			if text then
				text.Text = string.format("x%.2f", chunk.TimeScale)
			end
		end
	end

	-- drop boxes for chunks that returned to normal or vanished
	for key, box in parts do
		if not seen[key] then
			box:Destroy()
			parts[key] = nil
		end
	end
end

function ChunkVisualizer.setEnabled(value: boolean)
	enabled = value
	if folder then
		folder.Parent = value and workspace or nil
	end
	if not value then
		clearAll()
	end
end

function ChunkVisualizer.toggle()
	ChunkVisualizer.setEnabled(not enabled)
end

function ChunkVisualizer.start()
	if started then
		return
	end
	started = true

	folder = Instance.new("Folder")
	folder.Name = "ChunkVisualizer"
	folder.Parent = workspace

	-- Refresh on a real-time loop (NOT the dilated Heartbeat) so the overlay
	-- stays responsive even when the world is frozen (global scale 0).
	task.spawn(function()
		while started do
			refresh()
			task.wait(REFRESH_INTERVAL)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.V then
			ChunkVisualizer.toggle()
		end
	end)
end

return ChunkVisualizer
