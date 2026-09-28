--!strict
-- Structured magic-circle editor and card interface. The Tool controller is
-- deliberately only one launcher; any future menu can call Open/Close/Cast.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local SpellCompiler = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SpellCompiler"))
local remotes = ReplicatedStorage:WaitForChild("SpellRemotes")
local command = remotes:WaitForChild("SpellCommand") :: RemoteFunction
local castRemote = remotes:WaitForChild("SpellCast") :: RemoteEvent

local SpellAssemblerGui = {}

local COLORS = {
	background = Color3.fromRGB(12, 10, 22),
	panel = Color3.fromRGB(24, 20, 39),
	panel2 = Color3.fromRGB(35, 29, 54),
	line = Color3.fromRGB(174, 113, 255),
	text = Color3.fromRGB(238, 230, 255),
	muted = Color3.fromRGB(162, 151, 184),
	good = Color3.fromRGB(92, 220, 147),
	bad = Color3.fromRGB(255, 92, 112),
	selected = Color3.fromRGB(111, 72, 165),
}

local equippedTool: Tool? = nil
local gui: ScreenGui? = nil
local main: Frame? = nil
local mini: Frame? = nil
local canvas: Frame? = nil
local regionLayer: Frame? = nil
local nodeLayer: Frame? = nil
local edgeLayer: Frame? = nil
local palette: ScrollingFrame? = nil
local inspector: Frame? = nil
local errorLabel: TextLabel? = nil
local statusLabel: TextLabel? = nil
local nameBox: TextBox? = nil
local saveButton: TextButton? = nil
local activeLabel: TextLabel? = nil
local tierHolder: Frame? = nil
local cardButtons: { TextButton } = {}

local graph = SpellCompiler.CreateDefaultGraph()
local serverState: any = { slots = {}, activeSlot = nil }
local selectedSlot = 1
local selectedNodeId: string? = nil
local pendingFrom: any = nil -- { id: string, branch: "true"|"false"? }
local compiled: any = nil
local validationErrors: { string } = {}
local draggingNode: string? = nil
local draggingRegion: any = nil
local editingRegions = false
local paletteDragRune: string? = nil
local visible = false

local function deepCopy(value: any): any
	if typeof(value) ~= "table" then return value end
	local result = {}
	for key, child in value do result[deepCopy(key)] = deepCopy(child) end
	return result
end

local function corner(parent: Instance, radius: number?)
	local item = Instance.new("UICorner")
	item.CornerRadius = UDim.new(0, radius or 8)
	item.Parent = parent
end

local function stroke(parent: Instance, color: Color3?, thickness: number?)
	local item = Instance.new("UIStroke")
	item.Color = color or COLORS.line
	item.Thickness = thickness or 1
	item.Transparency = 0.25
	item.Parent = parent
	return item
end

local function textButton(parent: Instance, text: string): TextButton
	local button = Instance.new("TextButton")
	button.AutoButtonColor = true
	button.BackgroundColor3 = COLORS.panel2
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamMedium
	button.Text = text
	button.TextColor3 = COLORS.text
	button.TextSize = 13
	button.Parent = parent
	corner(button, 7)
	stroke(button, Color3.fromRGB(118, 83, 168), 1)
	return button
end

local function label(parent: Instance, text: string, size: number?): TextLabel
	local item = Instance.new("TextLabel")
	item.BackgroundTransparency = 1
	item.Font = Enum.Font.Gotham
	item.Text = text
	item.TextColor3 = COLORS.text
	item.TextSize = size or 13
	item.TextWrapped = true
	item.Parent = parent
	return item
end

local function connect(signal: RBXScriptSignal, fn: (...any) -> ())
	-- Destroying a rebuilt node/edge disconnects its Instance signals. The
	-- persistent GUI/input signals intentionally live for the client session.
	signal:Connect(fn)
end

local function nodeById(id: string): any?
	for _, node in graph.nodes do if node.id == id then return node end end
	return nil
end

local function nodeByRune(runeId: string): any?
	for _, node in graph.nodes do if node.runeId == runeId then return node end end
	return nil
end

local function removeNode(id: string)
	for index = #graph.nodes, 1, -1 do
		if graph.nodes[index].id == id then table.remove(graph.nodes, index) end
	end
	for index = #graph.edges, 1, -1 do
		local edge = graph.edges[index]
		if edge.from == id or edge.to == id then table.remove(graph.edges, index) end
	end
	if selectedNodeId == id then selectedNodeId = nil end
	if pendingFrom and pendingFrom.id == id then pendingFrom = nil end
end

local function clampToRegion(runeId: string, screenPosition: Vector2): { x: number, y: number }
	local targetCanvas = canvas :: Frame
	local absolute = targetCanvas.AbsolutePosition
	local size = targetCanvas.AbsoluteSize
	local x = math.clamp((screenPosition.X - absolute.X) / math.max(size.X, 1), 0, 1)
	local y = math.clamp((screenPosition.Y - absolute.Y) / math.max(size.Y, 1), 0, 1)
	local rune = SpellCompiler.Runes[runeId]
	local best, bestDistance
	for _, region in graph.regions or {} do
		if region.kind == rune.Region then
			local nearestX = math.clamp(x, region.x, region.x + region.w)
			local nearestY = math.clamp(y, region.y, region.y + region.h)
			local distance = (Vector2.new(nearestX, nearestY) - Vector2.new(x, y)).Magnitude
			if not bestDistance or distance < bestDistance then best, bestDistance = region, distance end
		end
	end
	if not best then return { x = x, y = y } end
	local paddingX = math.min(0.025, best.w * 0.2)
	local paddingY = math.min(0.025, best.h * 0.2)
	return { x = math.clamp(x, best.x + paddingX, best.x + best.w - paddingX), y = math.clamp(y, best.y + paddingY, best.y + best.h - paddingY) }
end

local refresh: () -> ()

local function addEdge(fromId: string, toId: string, branch: string?)
	if branch then
		-- A branch label has one destination. Reconnecting it replaces its old
		-- edge instead of leaving an ambiguous fork behind.
		for index = #graph.edges, 1, -1 do
			local edge = graph.edges[index]
			if edge.from == fromId and edge.branch == branch then table.remove(graph.edges, index) end
		end
	end
	for _, edge in graph.edges do
		if edge.from == fromId and edge.to == toId and edge.branch == branch then return end
	end
	if #graph.edges < SpellCompiler.MaxEdges then
		table.insert(graph.edges, { from = fromId, to = toId, branch = branch })
	end
end

local function addRune(runeId: string, screenPosition: Vector2?)
	local existing = nodeByRune(runeId)
	if existing and (runeId == "Mana" or runeId == "Fire" or runeId == "Condition") then selectedNodeId = existing.id; refresh(); return end
	if #graph.nodes >= SpellCompiler.MaxNodes then return end
	local rune = SpellCompiler.Runes[runeId]
	local region
	for _, candidate in graph.regions or {} do if candidate.kind == rune.Region then region = candidate; break end end
	local position = if screenPosition then clampToRegion(runeId, screenPosition) elseif region then {
		x = region.x + region.w * (0.35 + (#graph.nodes % 3) * 0.15), y = region.y + region.h * (0.35 + (#graph.nodes % 2) * 0.25),
	} else { x = 0.5, y = 0.5 }
	local baseId = string.lower(runeId)
	local id, suffix = baseId, 2
	while nodeById(id) do id = baseId .. tostring(suffix); suffix += 1 end
	table.insert(graph.nodes, { id = id, runeId = runeId, tier = rune.Tiered and 1 or nil, position = position })
	selectedNodeId = id
	refresh()
end

local function invoke(action: string, payload: any?): any
	local ok, result = pcall(command.InvokeServer, command, action, payload)
	if not ok then
		return { ok = false, message = "The spell service did not respond." }
	end
	return result
end

local function updateCards()
	for slot, button in cardButtons do
		local record = serverState.slots and (serverState.slots[tostring(slot)] or serverState.slots[slot])
		local active = serverState.activeSlot == slot
		button.Text = `{slot}. {record and record.name or "Empty"}{active and "  ◆" or ""}`
		button.BackgroundColor3 = if selectedSlot == slot then COLORS.selected else COLORS.panel2
	end
	local active = serverState.activeSlot and serverState.slots and (serverState.slots[tostring(serverState.activeSlot)] or serverState.slots[serverState.activeSlot])
	if activeLabel then activeLabel.Text = `Active: {active and active.name or "None"}` end
end

local REGION_COLORS = {
	Input = Color3.fromRGB(70, 157, 215),
	Transform = Color3.fromRGB(218, 96, 73),
	Vessel = Color3.fromRGB(151, 83, 210),
	Output = Color3.fromRGB(210, 70, 91),
	Modifier = Color3.fromRGB(105, 82, 153),
}

local function drawRegions()
	local layer = regionLayer :: Frame
	for _, child in layer:GetChildren() do child:Destroy() end
	for _, region in graph.regions or {} do
		local color = REGION_COLORS[region.kind] or COLORS.line
		local area = Instance.new("Frame")
		area.Name = region.id
		area.Position = UDim2.fromScale(region.x, region.y)
		area.Size = UDim2.fromScale(region.w, region.h)
		area.BackgroundColor3 = color
		area.BackgroundTransparency = if editingRegions then 0.78 else 0.9
		area.BorderSizePixel = 0
		area.ZIndex = 1
		area.Parent = layer
		corner(area, 10)
		stroke(area, color, if editingRegions then 2 else 1)
		local title = textButton(area, string.upper(region.kind) .. " AREA")
		title.BackgroundTransparency = 1
		title.Size = UDim2.new(1, -8, 0, 25)
		title.Position = UDim2.fromOffset(4, 2)
		title.TextSize = 10
		title.ZIndex = 2
		title.AutoButtonColor = editingRegions
		if editingRegions then
			connect(title.InputBegan, function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					draggingRegion = { id = region.id, mode = "move", start = input.Position, x = region.x, y = region.y, w = region.w, h = region.h }
				end
			end)
			local handle = textButton(area, "↘")
			handle.AnchorPoint = Vector2.new(1, 1)
			handle.Position = UDim2.fromScale(1, 1)
			handle.Size = UDim2.fromOffset(25, 25)
			handle.ZIndex = 3
			connect(handle.InputBegan, function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					draggingRegion = { id = region.id, mode = "resize", start = input.Position, x = region.x, y = region.y, w = region.w, h = region.h }
				end
			end)
		end
	end
end

local function drawEdges()
	local layer = edgeLayer :: Frame
	for _, child in layer:GetChildren() do child:Destroy() end
	local targetCanvas = canvas :: Frame
	for index, edge in graph.edges do
		local fromNode = nodeById(edge.from)
		local toNode = nodeById(edge.to)
		if fromNode and toNode then
			local a = Vector2.new(fromNode.position.x * targetCanvas.AbsoluteSize.X, fromNode.position.y * targetCanvas.AbsoluteSize.Y)
			local b = Vector2.new(toNode.position.x * targetCanvas.AbsoluteSize.X, toNode.position.y * targetCanvas.AbsoluteSize.Y)
			local delta = b - a
			local line = Instance.new("TextButton")
			line.Name = `Edge{index}`
			line.Text = ""
			line.AutoButtonColor = false
			line.AnchorPoint = Vector2.new(0.5, 0.5)
			line.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
			line.Size = UDim2.fromOffset(delta.Magnitude, 5)
			line.Rotation = math.deg(math.atan2(delta.Y, delta.X))
			line.BackgroundColor3 = if edge.branch == "true" then COLORS.good elseif edge.branch == "false" then COLORS.bad else COLORS.line
			line.BackgroundTransparency = 0.2
			line.BorderSizePixel = 0
			line.ZIndex = 2
			line.Parent = layer
			if edge.branch then
				line.Text = if edge.branch == "true" then "T" else "F"
				line.TextColor3 = COLORS.text
				line.TextSize = 11
			end
			connect(line.Activated, function()
				if graph.edges[index] == edge then table.remove(graph.edges, index) else
					local found = table.find(graph.edges, edge)
					if found then table.remove(graph.edges, found) end
				end
				refresh()
			end)
		end
	end
end

local function showInspector()
	local holder = tierHolder :: Frame
	for _, child in holder:GetChildren() do if not child:IsA("UIListLayout") then child:Destroy() end end
	local node = selectedNodeId and nodeById(selectedNodeId)
	if not node then
		local hint = label(holder, "Select a rune to change its tier.", 12)
		hint.Size = UDim2.new(1, 0, 0, 38)
		hint.TextColor3 = COLORS.muted
		return
	end
	local rune = SpellCompiler.Runes[node.runeId]
	local heading = label(holder, rune.DisplayName, 15)
	heading.Size = UDim2.new(1, 0, 0, 26)
	if node.runeId == "Condition" then
		heading.Text = `Condition: {SpellCompiler.ConditionNames[node.tier] or "Unknown"}`
		heading.TextSize = 12
	end
	if rune.Tiered then
		for tier = 1, 5 do
			local button = textButton(holder, ({ "I", "II", "III", "IV", "V" })[tier])
			button.Size = UDim2.new(0.18, -2, 0, 30)
			button.BackgroundColor3 = if node.tier == tier then rune.Color else COLORS.panel2
			connect(button.Activated, function() node.tier = tier; refresh() end)
		end
	end
	local remove = textButton(holder, "Remove rune")
	remove.Size = UDim2.new(1, 0, 0, 30)
	remove.BackgroundColor3 = Color3.fromRGB(99, 38, 54)
	connect(remove.Activated, function() removeNode(node.id); refresh() end)
end

local function drawNodes()
	local layer = nodeLayer :: Frame
	for _, child in layer:GetChildren() do child:Destroy() end
	local invalid = compiled == nil
	for _, node in graph.nodes do
		local rune = SpellCompiler.Runes[node.runeId]
		local frame = Instance.new("Frame")
		frame.Name = node.id
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(node.position.x, node.position.y)
		frame.Size = UDim2.fromOffset(92, 42)
		frame.BackgroundColor3 = if selectedNodeId == node.id then rune.Color:Lerp(Color3.new(1, 1, 1), 0.18) else rune.Color:Lerp(COLORS.background, 0.5)
		frame.BorderSizePixel = 0
		frame.ZIndex = 4
		frame.Parent = layer
		corner(frame, 10)
		stroke(frame, if invalid then COLORS.bad else rune.Color, if selectedNodeId == node.id then 2 else 1)

		local title = Instance.new("TextButton")
		title.BackgroundTransparency = 1
		title.Size = UDim2.new(1, -18, 1, 0)
		title.Position = UDim2.fromOffset(9, 0)
		title.Font = Enum.Font.GothamBold
		title.Text = rune.DisplayName .. (rune.Tiered and ` {({ "I", "II", "III", "IV", "V" })[node.tier]}` or "")
		title.TextColor3 = COLORS.text
		title.TextSize = 11
		title.ZIndex = 5
		title.Parent = frame
		connect(title.Activated, function() selectedNodeId = node.id; refresh() end)
		connect(title.InputBegan, function(input)
			if not editingRegions and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
				draggingNode = node.id
				selectedNodeId = node.id
			end
		end)

		if rune.Kind ~= "Input" and rune.Kind ~= "Modifier" then
			local inputPort = textButton(frame, "◀")
			inputPort.Size = UDim2.fromOffset(22, 22)
			inputPort.AnchorPoint = Vector2.new(0.5, 0.5)
			inputPort.Position = UDim2.fromScale(0, 0.5)
			inputPort.ZIndex = 6
			connect(inputPort.Activated, function()
				if pendingFrom and pendingFrom.id ~= node.id then addEdge(pendingFrom.id, node.id, pendingFrom.branch) end
				pendingFrom = nil
				refresh()
			end)
		end
		if rune.Kind ~= "Output" then
			if node.runeId == "Condition" then
				for index, branch in { "true", "false" } do
					local active = pendingFrom and pendingFrom.id == node.id and pendingFrom.branch == branch
					local outputPort = textButton(frame, if active then "●" else (branch == "true" and "T" or "F"))
					outputPort.Size = UDim2.fromOffset(22, 20)
					outputPort.AnchorPoint = Vector2.new(0.5, 0.5)
					outputPort.Position = UDim2.fromScale(1, if index == 1 then 0.25 else 0.75)
					outputPort.BackgroundColor3 = if branch == "true" then Color3.fromRGB(45, 120, 75) else Color3.fromRGB(130, 45, 60)
					outputPort.ZIndex = 6
					connect(outputPort.Activated, function()
						pendingFrom = if active then nil else { id = node.id, branch = branch }
						refresh()
					end)
				end
			else
				local active = pendingFrom and pendingFrom.id == node.id
				local outputPort = textButton(frame, if active then "●" else "▶")
				outputPort.Size = UDim2.fromOffset(22, 22)
				outputPort.AnchorPoint = Vector2.new(0.5, 0.5)
				outputPort.Position = UDim2.fromScale(1, 0.5)
				outputPort.ZIndex = 6
				connect(outputPort.Activated, function()
					pendingFrom = if active then nil else { id = node.id }
					refresh()
				end)
			end
		end
	end
end

refresh = function()
	compiled, validationErrors = SpellCompiler.Compile(graph)
	if errorLabel then
		if compiled then
			errorLabel.Text = `Valid spell  •  Mana {compiled.manaCost}  •  up to {compiled.maxProjectiles} projectile{compiled.maxProjectiles == 1 and "" or "s"}`
			errorLabel.TextColor3 = COLORS.good
		else
			errorLabel.Text = table.concat(validationErrors, "\n", 1, math.min(#validationErrors, 4))
			errorLabel.TextColor3 = COLORS.bad
		end
	end
	if saveButton then
		saveButton.Active = compiled ~= nil
		saveButton.AutoButtonColor = compiled ~= nil
		saveButton.BackgroundColor3 = if compiled then Color3.fromRGB(79, 121, 88) else Color3.fromRGB(67, 55, 72)
	end
	drawRegions()
	drawEdges()
	drawNodes()
	showInspector()
	updateCards()
end

local function setStatus(message: string, good: boolean?)
	if statusLabel then
		statusLabel.Text = message
		statusLabel.TextColor3 = if good == true then COLORS.good elseif good == false then COLORS.bad else COLORS.muted
	end
end

local function saveCard()
	if not compiled then return end
	setStatus("Saving card…")
	local result = invoke("SaveCard", { slot = selectedSlot, name = nameBox and nameBox.Text, graph = graph })
	if result.state then serverState = result.state end
	setStatus(result.message or (result.ok and "Card saved." or "Save failed."), result.ok)
	updateCards()
end

local function loadSlot(slot: number)
	selectedSlot = slot
	local record = serverState.slots and (serverState.slots[tostring(slot)] or serverState.slots[slot])
	if record and record.graph then
		graph = deepCopy(record.graph)
		if nameBox then nameBox.Text = record.name end
		selectedNodeId = nil
		pendingFrom = nil
	end
	refresh()
end

local function buildGui()
	if gui then return end
	local screen = Instance.new("ScreenGui")
	screen.Name = "SpellAssemblerGui"
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 80
	screen.Enabled = false
	screen.Parent = player:WaitForChild("PlayerGui")
	gui = screen

	local root = Instance.new("Frame")
	root.Name = "Editor"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromScale(0.94, 0.9)
	root.BackgroundColor3 = COLORS.background
	root.BackgroundTransparency = 0.04
	root.BorderSizePixel = 0
	root.Parent = screen
	corner(root, 16)
	stroke(root, COLORS.line, 2)
	main = root

	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = Vector2.new(760, 520)
	sizeConstraint.MaxSize = Vector2.new(1450, 900)
	sizeConstraint.Parent = root

	local header = label(root, "MAGIC CIRCLE ASSEMBLER", 20)
	header.Font = Enum.Font.GothamBold
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Position = UDim2.fromOffset(20, 10)
	header.Size = UDim2.new(1, -180, 0, 36)

	local close = textButton(root, "Minimize")
	close.Position = UDim2.new(1, -116, 0, 10)
	close.Size = UDim2.fromOffset(96, 32)
	connect(close.Activated, SpellAssemblerGui.Close)
	local layout = textButton(root, "Edit areas")
	layout.Position = UDim2.new(1, -222, 0, 10)
	layout.Size = UDim2.fromOffset(96, 32)
	connect(layout.Activated, function()
		editingRegions = not editingRegions
		layout.Text = if editingRegions then "Finish areas" else "Edit areas"
		draggingNode = nil
		refresh()
	end)

	local left = Instance.new("Frame")
	left.Position = UDim2.fromOffset(16, 54)
	left.Size = UDim2.new(0, 172, 1, -142)
	left.BackgroundColor3 = COLORS.panel
	left.BorderSizePixel = 0
	left.Parent = root
	corner(left, 10)
	local paletteTitle = label(left, "RUNES  •  drag into an area", 12)
	paletteTitle.Size = UDim2.new(1, -12, 0, 32)
	paletteTitle.Position = UDim2.fromOffset(6, 3)
	paletteTitle.TextColor3 = COLORS.muted

	local scroll = Instance.new("ScrollingFrame")
	scroll.Position = UDim2.fromOffset(8, 38)
	scroll.Size = UDim2.new(1, -16, 1, -46)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = left
	palette = scroll
	local paletteLayout = Instance.new("UIListLayout")
	paletteLayout.Padding = UDim.new(0, 6)
	paletteLayout.Parent = scroll

	local right = Instance.new("Frame")
	right.AnchorPoint = Vector2.new(1, 0)
	right.Position = UDim2.new(1, -16, 0, 54)
	right.Size = UDim2.new(0, 235, 1, -142)
	right.BackgroundColor3 = COLORS.panel
	right.BorderSizePixel = 0
	right.Parent = root
	corner(right, 10)
	inspector = right

	local center = Instance.new("Frame")
	center.Position = UDim2.fromOffset(198, 54)
	center.Size = UDim2.new(1, -459, 1, -142)
	center.BackgroundTransparency = 1
	center.Parent = root
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.DominantAxis = Enum.DominantAxis.Height
	ratio.Parent = center
	canvas = center

	local regions = Instance.new("Frame")
	regions.Name = "Areas"
	regions.Size = UDim2.fromScale(1, 1)
	regions.BackgroundTransparency = 1
	regions.ZIndex = 1
	regions.Parent = center
	regionLayer = regions
	local edges = Instance.new("Frame")
	edges.Name = "Edges"
	edges.Size = UDim2.fromScale(1, 1)
	edges.BackgroundTransparency = 1
	edges.ZIndex = 2
	edges.Parent = center
	edgeLayer = edges
	local nodes = Instance.new("Frame")
	nodes.Name = "Nodes"
	nodes.Size = UDim2.fromScale(1, 1)
	nodes.BackgroundTransparency = 1
	nodes.ZIndex = 3
	nodes.Parent = center
	nodeLayer = nodes

	local nameTitle = label(right, "CARD NAME", 11)
	nameTitle.Position = UDim2.fromOffset(10, 8)
	nameTitle.Size = UDim2.new(1, -20, 0, 22)
	nameTitle.TextColor3 = COLORS.muted
	local box = Instance.new("TextBox")
	box.Position = UDim2.fromOffset(10, 31)
	box.Size = UDim2.new(1, -20, 0, 34)
	box.BackgroundColor3 = COLORS.panel2
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Font = Enum.Font.Gotham
	box.PlaceholderText = "Fire Projectile"
	box.Text = graph.name
	box.TextColor3 = COLORS.text
	box.TextSize = 13
	box.Parent = right
	corner(box, 7)
	nameBox = box

	local tierTitle = label(right, "SELECTED RUNE", 11)
	tierTitle.Position = UDim2.fromOffset(10, 76)
	tierTitle.Size = UDim2.new(1, -20, 0, 22)
	tierTitle.TextColor3 = COLORS.muted
	local tiers = Instance.new("Frame")
	tiers.Position = UDim2.fromOffset(10, 100)
	tiers.Size = UDim2.new(1, -20, 0, 126)
	tiers.BackgroundTransparency = 1
	tiers.Parent = right
	tierHolder = tiers
	local tierLayout = Instance.new("UIListLayout")
	tierLayout.FillDirection = Enum.FillDirection.Horizontal
	tierLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	tierLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	tierLayout.Wraps = true
	tierLayout.Padding = UDim.new(0, 5)
	tierLayout.Parent = tiers

	local errors = label(right, "", 11)
	errors.Position = UDim2.fromOffset(10, 232)
	errors.Size = UDim2.new(1, -20, 1, -282)
	errors.TextXAlignment = Enum.TextXAlignment.Left
	errors.TextYAlignment = Enum.TextYAlignment.Top
	errorLabel = errors
	local status = label(right, "", 11)
	status.AnchorPoint = Vector2.new(0, 1)
	status.Position = UDim2.new(0, 10, 1, -42)
	status.Size = UDim2.new(1, -20, 0, 36)
	statusLabel = status

	local save = textButton(right, "Save to selected card")
	save.AnchorPoint = Vector2.new(0, 1)
	save.Position = UDim2.new(0, 10, 1, -6)
	save.Size = UDim2.new(1, -20, 0, 34)
	saveButton = save
	connect(save.Activated, saveCard)

	local footer = Instance.new("Frame")
	footer.Position = UDim2.new(0, 16, 1, -78)
	footer.Size = UDim2.new(1, -32, 0, 64)
	footer.BackgroundColor3 = COLORS.panel
	footer.BorderSizePixel = 0
	footer.Parent = root
	corner(footer, 10)
	local cardLayout = Instance.new("UIListLayout")
	cardLayout.FillDirection = Enum.FillDirection.Horizontal
	cardLayout.Padding = UDim.new(0, 7)
	cardLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	cardLayout.Parent = footer
	local newButton = textButton(footer, "New")
	newButton.Size = UDim2.fromOffset(62, 42)
	connect(newButton.Activated, function()
		graph = SpellCompiler.CreateDefaultGraph()
		selectedNodeId, pendingFrom = nil, nil
		if nameBox then nameBox.Text = graph.name end
		refresh()
	end)
	for slot = 1, 5 do
		local button = textButton(footer, tostring(slot))
		button.Size = UDim2.new(0.135, 0, 0, 42)
		cardButtons[slot] = button
		connect(button.Activated, function() loadSlot(slot) end)
	end
	local use = textButton(footer, "Use")
	use.Size = UDim2.fromOffset(64, 42)
	use.BackgroundColor3 = Color3.fromRGB(65, 108, 89)
	connect(use.Activated, function()
		setStatus("Equipping card…")
		local result = invoke("SetActive", { slot = selectedSlot })
		if result.state then serverState = result.state end
		setStatus(result.message or "", result.ok)
		updateCards()
		if result.ok then SpellAssemblerGui.Close() end
	end)
	local delete = textButton(footer, "Delete")
	delete.Size = UDim2.fromOffset(68, 42)
	delete.BackgroundColor3 = Color3.fromRGB(95, 42, 55)
	connect(delete.Activated, function()
		local result = invoke("DeleteCard", { slot = selectedSlot })
		if result.state then serverState = result.state end
		setStatus(result.message or "", result.ok)
		updateCards()
	end)

	local compact = Instance.new("Frame")
	compact.Name = "Compact"
	compact.AnchorPoint = Vector2.new(1, 1)
	compact.Position = UDim2.new(1, -18, 1, -18)
	compact.Size = UDim2.fromOffset(300, 52)
	compact.BackgroundColor3 = COLORS.panel
	compact.BorderSizePixel = 0
	compact.Visible = false
	compact.Parent = screen
	corner(compact, 10)
	stroke(compact)
	mini = compact
	local active = label(compact, "Active: None", 12)
	active.Position = UDim2.fromOffset(10, 5)
	active.Size = UDim2.new(1, -132, 1, -10)
	active.TextXAlignment = Enum.TextXAlignment.Left
	activeLabel = active
	local edit = textButton(compact, "Edit [E]")
	edit.Position = UDim2.new(1, -120, 0, 8)
	edit.Size = UDim2.fromOffset(62, 36)
	connect(edit.Activated, SpellAssemblerGui.Open)
	local castButton = textButton(compact, "Cast")
	castButton.Position = UDim2.new(1, -54, 0, 8)
	castButton.Size = UDim2.fromOffset(46, 36)
	castButton.BackgroundColor3 = Color3.fromRGB(120, 55, 42)
	connect(castButton.Activated, SpellAssemblerGui.Cast)

	for _, runeId in SpellCompiler.RuneOrder do
		local rune = SpellCompiler.Runes[runeId]
		local button = textButton(scroll, rune.DisplayName .. (rune.Tiered and "  I–V" or ""))
		button.Size = UDim2.new(1, -4, 0, 36)
		button.BackgroundColor3 = rune.Color:Lerp(COLORS.background, 0.55)
		connect(button.Activated, function() addRune(runeId) end)
		connect(button.InputBegan, function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				paletteDragRune = runeId
			end
		end)
	end

	connect(UserInputService.InputChanged, function(input)
		if draggingRegion and canvas and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local region
			for _, candidate in graph.regions or {} do if candidate.id == draggingRegion.id then region = candidate; break end end
			if region then
				local canvasSize = canvas.AbsoluteSize
				local delta = input.Position - draggingRegion.start
				local dx, dy = delta.X / math.max(canvasSize.X, 1), delta.Y / math.max(canvasSize.Y, 1)
				if draggingRegion.mode == "move" then
					region.x = math.clamp(draggingRegion.x + dx, 0, 1 - region.w)
					region.y = math.clamp(draggingRegion.y + dy, 0, 1 - region.h)
				else
					region.w = math.clamp(draggingRegion.w + dx, 0.06, 1 - region.x)
					region.h = math.clamp(draggingRegion.h + dy, 0.06, 1 - region.y)
				end
				refresh()
			end
		elseif draggingNode and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local node = nodeById(draggingNode)
			if node then node.position = clampToRegion(node.runeId, input.Position); refresh() end
		end
	end)
	connect(UserInputService.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if paletteDragRune and canvas then
				local p, s = canvas.AbsolutePosition, canvas.AbsoluteSize
				if input.Position.X >= p.X and input.Position.X <= p.X + s.X and input.Position.Y >= p.Y and input.Position.Y <= p.Y + s.Y then
					addRune(paletteDragRune, input.Position)
				end
			end
			draggingNode = nil
			draggingRegion = nil
			paletteDragRune = nil
		end
	end)
	connect(UserInputService.InputBegan, function(input, processed)
		if processed or not equippedTool then return end
		if input.KeyCode == Enum.KeyCode.E then
			SpellAssemblerGui.Toggle()
		elseif input.KeyCode == Enum.KeyCode.Delete and visible and selectedNodeId then
			removeNode(selectedNodeId)
			refresh()
		end
	end)
	connect(center:GetPropertyChangedSignal("AbsoluteSize"), function() if gui and gui.Enabled then drawEdges() end end)
	refresh()
end

function SpellAssemblerGui.Open()
	buildGui()
	visible = true
	(gui :: ScreenGui).Enabled = true
	(main :: Frame).Visible = true
	(mini :: Frame).Visible = false
	refresh()
end

function SpellAssemblerGui.Close()
	if not gui then return end
	visible = false
	(main :: Frame).Visible = false
	(mini :: Frame).Visible = equippedTool ~= nil
	updateCards()
end

function SpellAssemblerGui.Toggle()
	if visible then SpellAssemblerGui.Close() else SpellAssemblerGui.Open() end
end

function SpellAssemblerGui.Cast()
	if not equippedTool or visible or not serverState.activeSlot then return end
	local mouse = player:GetMouse()
	castRemote:FireServer(mouse.Hit.Position)
end

function SpellAssemblerGui.Equip(tool: Tool)
	equippedTool = tool
	buildGui()
	setStatus("Loading spell cards…")
	local result = invoke("GetState")
	if result.state then serverState = result.state end
	if result.state and result.state.error then setStatus(result.state.error, result.state.sessionOnly) else setStatus(result.message or "Cards loaded.", result.ok) end
	updateCards()
	SpellAssemblerGui.Open()
end

function SpellAssemblerGui.Unequip(tool: Tool)
	if equippedTool ~= tool then return end
	equippedTool = nil
	visible = false
	if gui then gui.Enabled = false end
end

return SpellAssemblerGui
