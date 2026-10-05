--!optimize 2
--[[
	Chunks tab: minimap of chunks / time zones / players. Left-drag paints a
	selection (Shift adds), right-drag pans; per-chunk, radius and global
	time scale and chunk load state.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)
local Util = require(script.Parent.Parent.Util)
local Heartbeat = require(Shared.Heartbeat)
local ChunkManager = require(Shared.ChunkManager)
local ChunkVisualizer = require(script.Parent.Parent.Parent.ChunkVisualizer)
local statLine = Util.statLine

local localPlayer = Players.LocalPlayer

-- Chunks tab: a minimap of every chunk the server tracks (non-default time
-- scale, unloaded, or occupied) plus time zones and players. Left-drag paints
-- a selection (Shift adds to it), right-drag pans; actions apply to every
-- selected chunk. The map redraws at MAP_REFRESH while showing.
local MAP_REFRESH = 0.1
local MAP_HEIGHT = 260
local MIN_ZOOM, MAX_ZOOM = 128, 8192 -- studs across the map's width
local PAN_ACTION = "DebugMinimapPan"
local PAN_PRIORITY = Enum.ContextActionPriority.High.Value + 100 -- above the camera's bindings

local colorForScale = ChunkVisualizer.ColorForScale

local pool = Util.pool

return function(window, ReGui)
	local tab = window:CreateTab({ Name = "Chunks" })

	local data: any = nil -- latest DebugChunks snapshot
	local byKey: { [Vector3]: any } = {}
	local selected: { [Vector3]: true } = {}
	local selectedCount = 0
	local anchorKey: Vector3? = nil -- first chunk of the current selection; radius center
	local follow = true
	local viewCenter = Vector2.zero -- world XZ at the map's center
	local zoom = 768
	local chunkScaleValue, globalScaleValue = 1, 1
	local connection: RBXScriptConnection? = nil
	local sinceRedraw = 0

	local function act(action: string, extra: { [string]: any }?)
		local payload = extra or {}
		payload.Action = action
		VisualOffload.Fire("DebugChunkAction", payload)
	end

	local controls = tab:Row()
	controls:Button({
		Text = "Recenter",
		Callback = function()
		follow = true
		end,
	})
	controls:Button({
		Text = "Zoom in",
		Callback = function()
		zoom = math.max(zoom / 1.5, MIN_ZOOM)
		end,
	})
	controls:Button({
		Text = "Zoom out",
		Callback = function()
		zoom = math.min(zoom * 1.5, MAX_ZOOM)
		end,
	})

	local map = tab:Image({ Image = "", Size = UDim2.new(1, 0, 0, MAP_HEIGHT) })
	-- The Image prefab is AutomaticSize XY with padding: grid lines drawn past
	-- its edge grew it, which raised pixels-per-stud, which drew further out --
	-- a runaway zoom. The map must keep a fixed size.
	map.AutomaticSize = Enum.AutomaticSize.None
	map.Size = UDim2.new(1, 0, 0, MAP_HEIGHT)
	local padding = map:FindFirstChildOfClass("UIPadding")
	if padding then
		padding:Destroy()
	end
	map.ImageTransparency = 1
	map.AutoButtonColor = false
	map.BackgroundTransparency = 0
	map.BackgroundColor3 = Color3.fromRGB(14, 16, 22)
	map.ClipsDescendants = true

	local function frame(color: Color3?, transparency: number?, round: boolean?): Frame
		local item = Instance.new("Frame")
		item.BorderSizePixel = 0
		item.BackgroundColor3 = color or Color3.new(1, 1, 1)
		item.BackgroundTransparency = transparency or 0
		if round then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = item
		end
		return item
	end

	local gridPool = pool(map, function()
		return frame(Color3.fromRGB(60, 66, 84), 0.5)
	end)
	local cellPool = pool(map, function()
		local cell = frame(nil, 0.35)
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(255, 80, 80)
		stroke.Thickness = 1
		stroke.Parent = cell
		local count = Instance.new("TextLabel")
		count.Name = "Count"
		count.BackgroundTransparency = 1
		count.Size = UDim2.fromScale(1, 1)
		count.Font = Enum.Font.GothamBold
		count.TextScaled = true
		count.TextColor3 = Color3.new(1, 1, 1)
		count.TextStrokeTransparency = 0.5
		count.Parent = cell
		local cap = Instance.new("UITextSizeConstraint")
		cap.MaxTextSize = 16
		cap.Parent = count
		return cell
	end)
	local zonePool = pool(map, function()
		local zone = frame(nil, 0.8, true)
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1.5
		stroke.Parent = zone
		return zone
	end)
	local playerPool = pool(map, function()
		local dot = frame(Color3.fromRGB(230, 230, 240), 0, true)
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Size = UDim2.fromOffset(6, 6)
		dot.ZIndex = 4
		return dot
	end)
	local selectionPool = pool(map, function()
		local outline = frame(Color3.new(1, 1, 1), 0.85)
		outline.ZIndex = 3
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(1, 1, 1)
		stroke.Thickness = 1.5
		stroke.Parent = outline
		return outline
	end)
	local me = frame(Color3.fromRGB(255, 230, 90), 0, true)
	me.AnchorPoint = Vector2.new(0.5, 0.5)
	me.Size = UDim2.fromOffset(9, 9)
	me.ZIndex = 6
	me.Parent = map
	-- View cone: a fan of rays across the camera's horizontal FOV. GuiObjects
	-- rotate about their center, so each ray is twice VIEW_LENGTH long,
	-- centered on you, with its back half faded out by a gradient.
	local VIEW_RAYS, VIEW_LENGTH = 9, 34
	local viewCone = Instance.new("Frame")
	viewCone.BackgroundTransparency = 1
	viewCone.Size = UDim2.fromOffset(0, 0)
	viewCone.ZIndex = 5
	viewCone.Parent = map
	local viewRays: { Frame } = {}
	for index = 1, VIEW_RAYS do
		local edge = index == 1 or index == VIEW_RAYS
		local ray = frame(Color3.fromRGB(255, 230, 90), 0)
		ray.AnchorPoint = Vector2.new(0.5, 0.5)
		ray.Size = UDim2.fromOffset(VIEW_LENGTH * 2, if edge then 2 else 1)
		ray.ZIndex = 5
		local fade = Instance.new("UIGradient")
		fade.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 1),
			NumberSequenceKeypoint.new(0.501, if edge then 0.15 else 0.55),
			NumberSequenceKeypoint.new(1, 1),
		})
		fade.Parent = ray
		ray.Parent = viewCone
		viewRays[index] = ray
	end

	local legend = statLine(tab, "Map")
	tab:Separator({ Text = "Selection  (left-drag paint, Shift adds, right-drag pans)" })
	local keyLine = statLine(tab, "Chunk")
	local scaleLine = statLine(tab, "Time scale")
	local flagsLine = statLine(tab, "State")

	tab:SliderFloat({
		Label = "Chunk time",
		Minimum = 0,
		Maximum = 3,
		Value = 1,
		Format = "x%.2f",
		Callback = function(_, value: number)
		chunkScaleValue = value
		end,
	})
	local function selectedKeys(): { Vector3 }
		local keys = {}
		for key in selected do
		table.insert(keys, key)
		end
		return keys
	end

	local updateSelectionInfo -- defined below; the buttons only run later
	local function clearSelection()
		table.clear(selected)
		selectedCount, anchorKey = 0, nil
	end

	local chunkRow = tab:Row()
	chunkRow:Button({
		Text = "Apply",
		Callback = function()
		if selectedCount > 0 then
			act("SetScale", { Keys = selectedKeys(), Scale = chunkScaleValue })
		end
		end,
	})
	chunkRow:Button({
		Text = "Reset",
		Callback = function()
		if selectedCount > 0 then
			act("SetScale", { Keys = selectedKeys(), Scale = 1 })
		end
		end,
	})
	chunkRow:Button({
		Text = "Toggle loaded",
		Callback = function()
		if selectedCount == 0 then
			return
		end
		-- any loaded chunk in the selection -> unload all, else load all
		local anyLoaded = false
		for key in selected do
			local chunk = byKey[key]
			if chunk == nil or chunk.Loaded then
				anyLoaded = true
				break
			end
		end
		act("SetLoaded", { Keys = selectedKeys(), Loaded = not anyLoaded })
		end,
	})
	chunkRow:Button({
		Text = "Deselect",
		Callback = function()
		clearSelection()
		updateSelectionInfo()
		end,
	})
	local radiusInput = tab:InputInt({ Label = "Radius (studs)", Value = 128, Increment = 32 })
	tab:Button({
		Text = "Apply chunk time in radius of first selected",
		Callback = function()
		if anchorKey then
			act("SetScaleRadius", { Key = anchorKey, Scale = chunkScaleValue, Radius = radiusInput.Value })
		end
		end,
	})

	tab:Separator({ Text = "World" })
	local worldLine = statLine(tab, "World")
	tab:SliderFloat({
		Label = "Global time",
		Minimum = 0,
		Maximum = 3,
		Value = Heartbeat.GetGlobalTimeScale(),
		Format = "x%.2f",
		Callback = function(_, value: number)
		globalScaleValue = value
		end,
	})
	local worldRow = tab:Row()
	worldRow:Button({
		Text = "Apply global",
		Callback = function()
		act("SetGlobalScale", { Scale = globalScaleValue })
		end,
	})
	worldRow:Button({
		Text = "Reset all chunks",
		Callback = function()
		act("ResetAll")
		end,
	})
	worldRow:Button({
		Text = "Clear zones",
		Callback = function()
		act("ClearZones")
		end,
	})

	local function chunkSize(): number
		return if data then data.ChunkSize else ChunkManager.ChunkSize
	end

	local function localRoot(): BasePart?
		local character = localPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		return if root and root:IsA("BasePart") then root else nil
	end

	local function center(): Vector2
		local root = localRoot()
		if follow and root then
		viewCenter = Vector2.new(root.Position.X, root.Position.Z)
		end
		return viewCenter
	end

	function updateSelectionInfo()
		if selectedCount == 0 then
		keyLine("left-drag on the map")
		scaleLine("-")
		flagsLine("-")
		return
		end
		if selectedCount == 1 then
		local key = next(selected) :: Vector3
		local chunk = byKey[key]
		local size = chunkSize()
		keyLine(string.format("(%d, %d)  origin %d, %d", key.X, key.Z, key.X * size, key.Z * size))
		scaleLine(string.format("x%.2f", if chunk then chunk.TimeScale else 1))
		flagsLine(if chunk
			then `{if chunk.Loaded then "loaded" else "UNLOADED"}  ·  {chunk.Entities} entities{if chunk.Persistent then "  ·  persistent" else ""}`
			else "untracked (default)")
		return
		end
		local low, high, unloaded, entities = math.huge, -math.huge, 0, 0
		for key in selected do
		local chunk = byKey[key]
		local scale = if chunk then chunk.TimeScale else 1
		low, high = math.min(low, scale), math.max(high, scale)
		if chunk then
			entities += chunk.Entities
			if not chunk.Loaded then
				unloaded += 1
			end
		end
		end
		keyLine(`{selectedCount} chunks selected`)
		scaleLine(if low == high then string.format("x%.2f", low) else string.format("x%.2f - x%.2f", low, high))
		flagsLine(`{selectedCount - unloaded} loaded, {unloaded} unloaded  ·  {entities} entities`)
	end

	local function redraw()
		local size = map.AbsoluteSize
		if size.X <= 0 or not data then
		return
		end
		local mid = center()
		local pixelsPerStud = size.X / zoom
		local half = size / 2
		local function toMap(x: number, z: number): Vector2
		return Vector2.new((x - mid.X) * pixelsPerStud + half.X, (z - mid.Y) * pixelsPerStud + half.Y)
		end
		local studs = chunkSize()
		local cellPixels = studs * pixelsPerStud

		gridPool.reset()
		if cellPixels >= 6 then
		local left, top = mid.X - half.X / pixelsPerStud, mid.Y - half.Y / pixelsPerStud
		for x = math.floor(left / studs) * studs, left + size.X / pixelsPerStud, studs do
			local line = gridPool.take()
			line.Position = UDim2.fromOffset(toMap(x, 0).X, 0)
			line.Size = UDim2.new(0, 1, 1, 0)
		end
		for z = math.floor(top / studs) * studs, top + size.Y / pixelsPerStud, studs do
			local line = gridPool.take()
			line.Position = UDim2.fromOffset(0, toMap(0, z).Y)
			line.Size = UDim2.new(1, 0, 0, 1)
		end
		end
		gridPool.hide()

		cellPool.reset()
		for _, chunk in data.Chunks do
		local corner = toMap(chunk.Key.X * studs, chunk.Key.Z * studs)
		if corner.X > size.X or corner.Y > size.Y or corner.X + cellPixels < 0 or corner.Y + cellPixels < 0 then
			continue
		end
		local cell = cellPool.take()
		cell.Position = UDim2.fromOffset(corner.X, corner.Y)
		cell.Size = UDim2.fromOffset(math.max(cellPixels, 2), math.max(cellPixels, 2))
		cell.BackgroundColor3 = if chunk.TimeScale == 1 then Color3.fromRGB(70, 80, 100) else colorForScale(chunk.TimeScale)
		cell.BackgroundTransparency = if chunk.TimeScale == 1 then 0.6 else 0.3
		local stroke = cell:FindFirstChildOfClass("UIStroke") :: UIStroke
		stroke.Enabled = not chunk.Loaded
		local count = cell:FindFirstChild("Count") :: TextLabel
		count.Visible = cellPixels >= 18 and chunk.Entities > 0
		count.Text = tostring(chunk.Entities)
		end
		cellPool.hide()

		zonePool.reset()
		for _, zone in data.Zones do
		local at = toMap(zone.Position.X, zone.Position.Z)
		local diameter = zone.Radius * 2 * pixelsPerStud
		local item = zonePool.take()
		item.Position = UDim2.fromOffset(at.X - diameter / 2, at.Y - diameter / 2)
		item.Size = UDim2.fromOffset(diameter, diameter)
		item.BackgroundColor3 = colorForScale(zone.Scale)
		local stroke = item:FindFirstChildOfClass("UIStroke") :: UIStroke
		stroke.Color = colorForScale(zone.Scale)
		end
		zonePool.hide()

		playerPool.reset()
		for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if player ~= localPlayer and root and root:IsA("BasePart") then
			local at = toMap(root.Position.X, root.Position.Z)
			playerPool.take().Position = UDim2.fromOffset(at.X, at.Y)
		end
		end
		playerPool.hide()

		local root = localRoot()
		local camera = workspace.CurrentCamera
		me.Visible, viewCone.Visible = root ~= nil, root ~= nil and camera ~= nil
		if root then
			local at = toMap(root.Position.X, root.Position.Z)
			me.Position = UDim2.fromOffset(at.X, at.Y)
			viewCone.Position = me.Position
		end
		if root and camera then
			-- Map X is world X, map Y is world Z, so atan2(Z, X) is the on-map
			-- heading; spread the rays across the horizontal field of view.
			local look = camera.CFrame.LookVector
			local heading = math.deg(math.atan2(look.Z, look.X))
			local viewport = camera.ViewportSize
			local aspect = if viewport.Y > 0 then viewport.X / viewport.Y else 16 / 9
			local horizontalFov = 2 * math.deg(math.atan(math.tan(math.rad(camera.FieldOfView) / 2) * aspect))
			for index, ray in viewRays do
				ray.Rotation = heading + horizontalFov * ((index - 1) / (VIEW_RAYS - 1) - 0.5)
			end
		end

		selectionPool.reset()
		for key in selected do
		local corner = toMap(key.X * studs, key.Z * studs)
		if corner.X > size.X or corner.Y > size.Y or corner.X + cellPixels < 0 or corner.Y + cellPixels < 0 then
			continue
		end
		local outline = selectionPool.take()
		outline.Position = UDim2.fromOffset(corner.X, corner.Y)
		outline.Size = UDim2.fromOffset(math.max(cellPixels, 3), math.max(cellPixels, 3))
		end
		selectionPool.hide()

		legend(string.format("%d studs across  ·  %s", zoom, if follow then "following you" else "panned (Recenter)"))
	end

	-- Left button paints a selection. ReGui:ConnectDrag (as its sliders use)
	-- also blocks the window from dragging while the map is being painted.
	local function keyAt(position: Vector2): Vector3
		local size = map.AbsoluteSize
		local offset = position - map.AbsolutePosition - size / 2
		local world = center() + offset / (size.X / zoom)
		local studs = chunkSize()
		return Vector3.new(math.floor(world.X / studs), 0, math.floor(world.Y / studs))
	end

	local function paintAt(position: Vector2)
		local low, high = map.AbsolutePosition, map.AbsolutePosition + map.AbsoluteSize
		if position.X < low.X or position.Y < low.Y or position.X > high.X or position.Y > high.Y then
		return -- dragged off the map
		end
		local key = keyAt(position)
		if not selected[key] then
		selected[key] = true
		selectedCount += 1
		anchorKey = anchorKey or key
		end
	end

	local lastPaint: Vector2? = nil
	ReGui:ConnectDrag(map, {
		DragStart = function(position: Vector2)
		local adding = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		if not adding then
			clearSelection()
		end
		paintAt(position)
		lastPaint = position
		updateSelectionInfo()
		redraw()
		end,
		DragMovement = function(position: Vector2)
		if not lastPaint then
			return
		end
		-- sample the path at half-cell spacing so fast drags skip nothing
		local step = math.max(chunkSize() * map.AbsoluteSize.X / zoom * 0.5, 1)
		local delta = position - lastPaint
		local samples = math.max(math.ceil(delta.Magnitude / step), 1)
		for index = 1, samples do
			paintAt(lastPaint + delta * (index / samples))
		end
		lastPaint = position
		updateSelectionInfo()
		redraw()
		end,
		DragEnd = function()
		lastPaint = nil
		end,
	})

	-- Right button pans. GUI buttons don't stop the default camera from
	-- treating right-drag as "rotate", so while the cursor is over the map a
	-- high-priority action claims (sinks) MouseButton2 before the camera.
	local panStart: Vector2? = nil
	local panCenter = Vector2.zero
	local hovering = false
	local function panAction(_, state: Enum.UserInputState, input: InputObject)
		if state == Enum.UserInputState.Begin then
		panStart = Vector2.new(input.Position.X, input.Position.Y)
		panCenter = center()
		else
		panStart = nil
		if not hovering then
			ContextActionService:UnbindAction(PAN_ACTION)
		end
		end
		return Enum.ContextActionResult.Sink
	end
	map.MouseEnter:Connect(function()
		hovering = true
		ContextActionService:BindActionAtPriority(PAN_ACTION, panAction, false, PAN_PRIORITY, Enum.UserInputType.MouseButton2)
	end)
	map.MouseLeave:Connect(function()
		hovering = false
		if not panStart then
		ContextActionService:UnbindAction(PAN_ACTION)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if panStart and input.UserInputType == Enum.UserInputType.MouseMovement then
		local delta = Vector2.new(input.Position.X, input.Position.Y) - panStart
		if follow and delta.Magnitude < 3 then
			return
		end
		follow = false
		viewCenter = panCenter - delta / (map.AbsoluteSize.X / zoom)
		redraw()
		end
	end)

	VisualOffload.On("DebugChunks", function(snapshot)
		if typeof(snapshot) ~= "table" then
		return
		end
		data = snapshot
		table.clear(byKey)
		local dilated = 0
		for _, chunk in snapshot.Chunks do
		byKey[chunk.Key] = chunk
		if chunk.TimeScale ~= 1 then
			dilated += 1
		end
		end
		worldLine(string.format("global x%.2f  ·  %d chunks tracked, %d dilated  ·  %d zones",
		snapshot.GlobalScale, #snapshot.Chunks, dilated, #snapshot.Zones))
		updateSelectionInfo()
		redraw()
	end)

	local function setActive(active: boolean)
		VisualOffload.Fire("DebugChunkWatch", active)
		if active and not connection then
		VisualOffload.Fire("DebugRequestChunks")
		connection = RunService.RenderStepped:Connect(function(dt)
			sinceRedraw += dt
			if sinceRedraw >= MAP_REFRESH then
				sinceRedraw = 0
				redraw()
			end
		end)
		elseif not active and connection then
		connection:Disconnect()
		connection = nil
		end
	end

	updateSelectionInfo()
	return { Active = setActive }
end
