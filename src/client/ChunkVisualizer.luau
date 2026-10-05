--!optimize 2
--[[
	ChunkVisualizer.luau  (client)
	Outlines every chunk whose TimeScale differs from 1, so you can see the
	dilation field at a glance. Colour encodes the local time
	rate: blue = slow (< 1x), red/orange = fast (> 1x). A floating label shows
	the exact multiplier.

	Chunk scales arrive on the client via ChunkManager.EnableReplication(), so
	this just reconciles a pool of parts against ChunkManager.GetAllChunks()
	each refresh. Toggle with the V key (or ChunkVisualizer.setEnabled).

	With 2D (XZ) chunking a chunk is an infinite vertical column, drawn as four
	glowing corner posts COLUMN_HEIGHT tall (centered on the local character,
	so they always reach well above and below you) plus a rim around the
	footprint at your feet. With 3D chunking the outline is the cube's 12 edges.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared.ChunkManager)

local ChunkVisualizer = {}

local REFRESH_INTERVAL = 0.25
local COLUMN_HEIGHT = 2048 -- 2D corner post length (Roblox's max part size)
local EDGE_WIDTH = 0.35
local FEET_OFFSET = 3 -- rim height below the character's root
local started = false
local enabled = true

local folder: Folder? = nil
local parts: { [Vector3]: Model } = {} -- keyed by chunk.Key

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

local function edge(model: Model, offset: Vector3, size: Vector3)
	local part = Instance.new("Part")
	part.Name = "Edge"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Transparency = 0.25
	part.Size = size
	part.Position = offset -- relative to a model pivot at the origin; see makeOutline
	part.Parent = model
end

-- Builds the outline around the origin; refresh() PivotTo()s it into place.
ChunkVisualizer.ColorForScale = colorForScale -- shared with the debug panel's minimap

local function makeOutline(key: Vector3): Model
	local size = ChunkManager.ChunkSize
	local half = size / 2
	local model = Instance.new("Model")
	model.Name = `Chunk_{key.X}_{key.Y}_{key.Z}`

	local height = if ChunkManager.UseY then size else COLUMN_HEIGHT
	for _, corner in { Vector3.new(-half, 0, -half), Vector3.new(half, 0, -half), Vector3.new(-half, 0, half), Vector3.new(half, 0, half) } do
		edge(model, corner, Vector3.new(EDGE_WIDTH, height, EDGE_WIDTH))
	end
	-- 2D: one rim at the feet (pivot level). 3D: the cube's top and bottom rims.
	local rims = if ChunkManager.UseY then { -half, half } else { 0 }
	for _, y in rims do
		edge(model, Vector3.new(0, y, -half), Vector3.new(size, EDGE_WIDTH, EDGE_WIDTH))
		edge(model, Vector3.new(0, y, half), Vector3.new(size, EDGE_WIDTH, EDGE_WIDTH))
		edge(model, Vector3.new(-half, y, 0), Vector3.new(EDGE_WIDTH, EDGE_WIDTH, size))
		edge(model, Vector3.new(half, y, 0), Vector3.new(EDGE_WIDTH, EDGE_WIDTH, size))
	end

	local anchor = Instance.new("Part")
	anchor.Name = "LabelAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.Position = Vector3.zero -- the model pivots on its PrimaryPart
	anchor.Parent = model
	model.PrimaryPart = anchor

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.fromOffset(80, 24)
	billboard.AlwaysOnTop = true
	billboard.StudsOffset = Vector3.new(0, if ChunkManager.UseY then 0 else 6, 0)
	billboard.Parent = anchor
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextStrokeTransparency = 0.4
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = billboard

	model:SetAttribute("Scale", -1)
	model.Parent = folder
	return model
end

-- Where the outline's pivot goes: the chunk's XZ center, at the rim height
-- (2D: your feet) or the cube's center (3D).
local function pivotFor(key: Vector3, rimY: number): Vector3
	local size = ChunkManager.ChunkSize
	local origin = key * size
	return Vector3.new(origin.X + size / 2, if ChunkManager.UseY then origin.Y + size / 2 else rimY, origin.Z + size / 2)
end

-- Height of the 2D rim: the local character's feet, else the camera.
local function viewerY(): number
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position.Y - FEET_OFFSET
	end
	local camera = workspace.CurrentCamera
	return if camera then camera.CFrame.Position.Y else 0
end

local function clearAll()
	for _, outline in parts do
		outline:Destroy()
	end
	table.clear(parts)
end

local function refresh()
	if not enabled then
		return
	end

	local seen: { [Vector3]: boolean } = {}
	local rimY = viewerY()
	for _, chunk in ChunkManager.GetAllChunks() do
		if chunk.TimeScale ~= 1 then
			seen[chunk.Key] = true
			local outline = parts[chunk.Key]
			if not outline then
				outline = makeOutline(chunk.Key)
				parts[chunk.Key] = outline
			end
			local pivot = pivotFor(chunk.Key, rimY)
			if (outline:GetPivot().Position - pivot).Magnitude > 1 then
				outline:PivotTo(CFrame.new(pivot))
			end
			-- recolor only when the scale actually changed
			if outline:GetAttribute("Scale") ~= chunk.TimeScale then
				outline:SetAttribute("Scale", chunk.TimeScale)
				local color = colorForScale(chunk.TimeScale)
				for _, part in outline:GetChildren() do
					if part:IsA("BasePart") and part.Name == "Edge" then
						part.Color = color
					end
				end
				local anchor = outline.PrimaryPart
				local label = anchor and anchor:FindFirstChild("Label")
				local text = label and label:FindFirstChildWhichIsA("TextLabel")
				if text then
					text.Text = string.format("x%.2f", chunk.TimeScale)
				end
			end
		end
	end

	-- drop outlines for chunks that returned to normal or vanished
	for key, outline in parts do
		if not seen[key] then
			outline:Destroy()
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
