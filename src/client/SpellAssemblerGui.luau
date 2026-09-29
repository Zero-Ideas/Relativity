--!strict
--[[
	Spell circle editor: a full-screen whiteboard for building spell cards,
	plus the compact HUD shown while the SpellAssembler tool is held.
	Public API (used by ToolControllers/SpellAssembler): Open, Close, Toggle,
	Cast, Equip, Unequip.

	Layout: top bar (name, card slots, save/equip) over a row of
	[Toolbox | Board | Inspector]. Both side panels resize by dragging their
	inner edge and collapse from the top bar. The pieces live in SpellEditor/:
	Document (graph + undo), Board (whiteboard), Panels (toolbox, inspector,
	problems).

	While the editor is open its root frame is Active, so mouse input never
	reaches the camera, and movement keys are sunk through
	ContextActionService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local SpellCompiler = require(Shared:WaitForChild("SpellCompiler"))
local SpellRunes = require(Shared:WaitForChild("SpellRunes"))
local remotes = ReplicatedStorage:WaitForChild("SpellRemotes")
local command = remotes:WaitForChild("SpellCommand") :: RemoteFunction
local castRemote = remotes:WaitForChild("SpellCast") :: RemoteEvent
local aimRemote = remotes:WaitForChild("SpellAim") :: UnreliableRemoteEvent

local EditorFolder = script.Parent:WaitForChild("SpellEditor")
local Theme = require(EditorFolder:WaitForChild("Theme"))
local Document = require(EditorFolder:WaitForChild("Document"))
local Board = require(EditorFolder:WaitForChild("Board"))
local Panels = require(EditorFolder:WaitForChild("Panels"))

local Colors = Theme.Colors
local SpellAssemblerGui = {}

local SLOT_COUNT = 5
local TOP_BAR = 52
local HANDLE = 6
local LEFT_RANGE = Vector2.new(200, 480)
local RIGHT_RANGE = Vector2.new(240, 520)
local SINK_ACTION = "SpellEditorSinkMovement"
local AIM_SEND_INTERVAL = 0.05 -- live cursor for Stream re-aiming (see SpellService)
local SINK_KEYS = {
	Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Space,
	Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right,
}

local equippedTool: Tool? = nil
local gui: ScreenGui? = nil
local root: Frame? = nil
local hud: Frame? = nil
local activeLabel: TextLabel? = nil
local toast: TextLabel? = nil
local nameBox: TextBox? = nil
local saveButton: TextButton? = nil
local zoomLabel: TextLabel? = nil
local ghost: TextLabel? = nil
local slotButtons: { TextButton } = {}
local toolboxFrame: Frame? = nil
local inspectorFrame: Frame? = nil
local viewport: Frame? = nil
local leftHandle: TextButton? = nil
local rightHandle: TextButton? = nil

local doc = Document.new(SpellCompiler.CreateDefaultGraph())
local board: any = nil
local toolbox: any = nil
local inspector: any = nil
local problems: any = nil

local serverState: any = { slots = {}, activeSlot = nil }
local selectedSlot = 1
local savedSignature: string? = nil
local errors: { any } = {}
local analysis: any = nil
local compiledOk = false
local visible = false
local needsFrame = true
local placing: any = nil
local resizing: any = nil
local armedZone: string? = nil
local toastToken = 0
local panelState = { left = 280, right = 330, leftOpen = true, rightOpen = true }

--------------------------------------------------------------------------------
-- State helpers
--------------------------------------------------------------------------------

local function slotRecord(slot: number): any?
	local slots = serverState.slots
	return slots and (slots[tostring(slot)] or slots[slot])
end

local function currentName(): string
	return if nameBox and nameBox.Text ~= "" then nameBox.Text else doc.graph.name
end

local function signature(): string
	doc.graph.name = currentName()
	return HttpService:JSONEncode(doc.graph)
end

local function setStatus(message: string, good: boolean?, sticky: boolean?)
	if not toast then return end
	toastToken += 1
	local token = toastToken
	toast.Text = message
	toast.TextColor3 = if good == true then Colors.good elseif good == false then Colors.bad else Colors.text
	toast.Visible = message ~= ""
	if not sticky then
		task.delay(4, function()
			if toastToken == token and toast then
				toast.Visible = false
				if armedZone then
					setStatus(`Drawing a {armedZone} zone: drag on the board (Shift keeps the pen, Esc cancels)`, nil, true)
				end
			end
		end)
	end
end

local function context()
	return {
		selection = board and board.selection,
		errors = errors,
		estimates = analysis and analysis.estimates,
		analysis = analysis,
	}
end

local function updateTopBar()
	local dirty = savedSignature ~= signature()
	for slot, button in slotButtons do
		local record = slotRecord(slot)
		local active = serverState.activeSlot == slot
		button.Text = `{slot}  {if record then record.name else "Empty"}{if active then "  ◆" else ""}`
		button.BackgroundColor3 = if selectedSlot == slot then Colors.accent:Lerp(Colors.panel, 0.45) else Colors.panel2
		button.TextColor3 = if record then Colors.text else Colors.muted
	end
	if saveButton then
		saveButton.Text = if dirty then `Save to {selectedSlot} •` else `Saved`
		saveButton.BackgroundColor3 = if compiledOk and dirty then Color3.fromRGB(58, 128, 86) else Colors.panel3
		saveButton.AutoButtonColor = compiledOk
	end
	local active = serverState.activeSlot and slotRecord(serverState.activeSlot)
	if activeLabel then
		activeLabel.Text = `Active spell: {if active then active.name else "None"}`
	end
end

local function refresh()
	if not board then return end
	doc.graph.name = currentName()
	local compiled, compileErrors, _, compileAnalysis = SpellCompiler.Compile(doc.graph)
	compiledOk = compiled ~= nil
	errors = compileErrors
	analysis = compileAnalysis
	local byRune = {}
	for _, problem in errors do
		if problem.rune then byRune[problem.rune] = true end
	end
	board:setAnnotations(byRune, if analysis then analysis.estimates else {})
	board:render()
	inspector:show(context())
	local summary = if analysis then `Valid · {analysis.manaCost} mana per cast` else "Valid"
	problems:show(errors, summary)
	updateTopBar()
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function invoke(action: string, payload: any?): any
	local ok, result = pcall(command.InvokeServer, command, action, payload)
	if not ok or typeof(result) ~= "table" then
		return { ok = false, message = "The spell service did not respond." }
	end
	return result
end

local function applyServerResult(result: any)
	if result.state then serverState = result.state end
	local message = result.message or ""
	if not result.ok and result.errors and result.errors[1] then
		message = result.errors[1].message or message
	end
	setStatus(message, result.ok)
	updateTopBar()
end

-- The server rate-limits spell commands (COMMAND_INTERVAL = 0.15s), so
-- chained commands wait this long between calls.
local COMMAND_GAP = 0.2

local function equipSlot(slot: number)
	setStatus("Equipping…", nil, true)
	local result = invoke("SetActive", { slot = slot })
	if result.ok then
		result.message = `Equipped "{(slotRecord(slot) or {}).name or "spell"}". Close the editor [E] and click to cast.`
	end
	applyServerResult(result)
end

-- Saves the circle to the selected slot. The first saved spell is equipped
-- automatically, so a fresh card is castable right after saving.
local function saveCard(): boolean
	if not compiledOk then
		local first = errors[1]
		setStatus(if first then `Can't save yet: {first.message}` else "Fix the problems on the board before saving.", false)
		return false
	end
	setStatus("Saving…", nil, true)
	local result = invoke("SaveCard", { slot = selectedSlot, name = currentName(), graph = doc.graph })
	if result.ok then
		local record = slotRecord(selectedSlot)
		if record and nameBox then nameBox.Text = record.name end
		savedSignature = signature()
	end
	applyServerResult(result)
	if result.ok and not serverState.activeSlot then
		task.wait(COMMAND_GAP)
		equipSlot(selectedSlot)
	end
	return result.ok == true
end

-- Makes the next/previous saved slot the active spell (HUD arrows).
local function cycleActive(direction: number)
	local current = serverState.activeSlot or selectedSlot
	for step = 1, SLOT_COUNT do
		local slot = (current - 1 + direction * step) % SLOT_COUNT + 1
		if slotRecord(slot) then
			if slot ~= serverState.activeSlot then
				equipSlot(slot)
			end
			return
		end
	end
end

local function loadSlot(slot: number)
	selectedSlot = slot
	local record = slotRecord(slot)
	if record and record.graph then
		doc:load(record.graph)
		if nameBox then nameBox.Text = record.name end
		if board then
			board.selection = nil
			board:frameAll()
		end
		savedSignature = signature()
		setStatus(`Loaded "{record.name}".`)
	else
		setStatus(`Slot {slot} is empty: saving will put this circle there.`)
	end
	refresh()
end

local function newSpell()
	doc:load(SpellCompiler.CreateDefaultGraph())
	if nameBox then nameBox.Text = doc.graph.name end
	savedSignature = nil
	if board then
		board.selection = nil
		board:frameAll()
	end
	refresh()
end

local function deleteSelection()
	local selection = board and board.selection
	if not selection then return end
	doc:record()
	if selection.kind == "rune" then
		doc:removeRune(selection.id)
	elseif selection.kind == "zone" then
		doc:removeZone(selection.id)
	else
		doc:removeWire(selection.wire)
	end
	board.selection = nil
	refresh()
end

local function duplicateSelection()
	local selection = board and board.selection
	if not selection or selection.kind ~= "rune" then return end
	local source = doc:rune(selection.id)
	if not source then return end
	doc:record()
	local ax, ay = SpellCompiler.RuneAnchor(source)
	local copy = doc:addRune(source.rune, ax + 30, ay + 30)
	if copy then
		copy.params = Document.deepCopy(source.params)
		board.selection = { kind = "rune", id = copy.id }
	end
	refresh()
end

local function toggleLock()
	local selection = board and board.selection
	local target = selection and (if selection.kind == "rune" then doc:rune(selection.id)
		elseif selection.kind == "zone" then doc:zone(selection.id) else nil)
	if not target then return end
	doc:record()
	target.locked = if target.locked then nil else true
	setStatus(if target.locked then "Locked in place." else "Unlocked.")
	refresh()
end

local function armZone(kind: string?)
	armedZone = kind
	if board then board.armedZone = kind end
	if toolbox then toolbox:setArmed(kind) end
	if kind then
		setStatus(`Drawing a {kind} zone: drag on the board (Shift keeps the pen, Esc cancels)`, nil, true)
	else
		setStatus("")
	end
end

local function focusProblem(problem: any)
	if not problem.rune then return end
	local rune = doc:rune(problem.rune)
	if not rune then return end
	board.selection = { kind = "rune", id = rune.id }
	local ax, ay = SpellCompiler.RuneAnchor(rune)
	board:centerOn(Vector2.new(ax, ay + 40))
	refresh()
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local function relayout()
	if not toolboxFrame or not inspectorFrame or not viewport or not leftHandle or not rightHandle then return end
	local left = if panelState.leftOpen then panelState.left else 0
	local right = if panelState.rightOpen then panelState.right else 0
	local leftSpace = if panelState.leftOpen then left + HANDLE else 0
	local rightSpace = if panelState.rightOpen then right + HANDLE else 0
	toolboxFrame.Visible = panelState.leftOpen
	toolboxFrame.Size = UDim2.new(0, left, 1, 0)
	leftHandle.Visible = panelState.leftOpen
	leftHandle.Position = UDim2.new(0, left, 0, 0)
	inspectorFrame.Visible = panelState.rightOpen
	inspectorFrame.Position = UDim2.new(1, -right, 0, 0)
	inspectorFrame.Size = UDim2.new(0, right, 1, 0)
	rightHandle.Visible = panelState.rightOpen
	rightHandle.Position = UDim2.new(1, -rightSpace, 0, 0)
	viewport.Position = UDim2.new(0, leftSpace, 0, 0)
	viewport.Size = UDim2.new(1, -(leftSpace + rightSpace), 1, 0)
end

local function makeHandle(parent: Frame, side: string): TextButton
	local handle = Theme.make("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.new(0, HANDLE, 1, 0),
		BackgroundColor3 = Colors.line,
		BackgroundTransparency = 0.7,
		BorderSizePixel = 0,
		ZIndex = 5,
	}, parent)
	handle.MouseEnter:Connect(function() handle.BackgroundTransparency = 0.2 end)
	handle.MouseLeave:Connect(function() if not resizing then handle.BackgroundTransparency = 0.7 end end)
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			resizing = { side = side, start = Board.pointer(input).X, width = panelState[side], handle = handle }
		end
	end)
	return handle
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function buildTopBar(parent: Frame)
	local bar = Theme.make("Frame", {
		Name = "TopBar",
		Size = UDim2.new(1, 0, 0, TOP_BAR),
		BackgroundColor3 = Colors.panel,
		BorderSizePixel = 0,
	}, parent)
	Theme.make("Frame", { Position = UDim2.new(0, 0, 1, -1), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Colors.line, BackgroundTransparency = 0.5, BorderSizePixel = 0 }, bar)

	-- Everything left of the panel toggles. The slot tabs share whatever width
	-- the fixed controls leave (see fitTopBar), so Equip/Delete can never be
	-- pushed off the edge on narrower screens.
	local leftGroup = Theme.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -260, 1, 0), ClipsDescendants = true }, bar)
	local leftList = Theme.list(leftGroup, 8, true)
	leftList.VerticalAlignment = Enum.VerticalAlignment.Center
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 14) }, leftGroup)

	Theme.label(leftGroup, "SPELL CIRCLE", 15, { Font = Theme.FontBold, Size = UDim2.fromOffset(118, 32), TextColor3 = Colors.accent, LayoutOrder = 1 })
	local box = Theme.make("TextBox", {
		Size = UDim2.fromOffset(170, 34),
		BackgroundColor3 = Colors.panel2,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = Theme.FontMedium,
		PlaceholderText = "Spell name",
		PlaceholderColor3 = Colors.muted,
		Text = doc.graph.name,
		TextColor3 = Colors.text,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
	}, leftGroup)
	Theme.corner(box, 6)
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 10) }, box)
	box.FocusLost:Connect(function() updateTopBar() end)
	nameBox = box

	for slot = 1, SLOT_COUNT do
		local button = Theme.button(leftGroup, tostring(slot), {
			Size = UDim2.fromOffset(122, 34),
			TextSize = 12,
			TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = 10 + slot,
		})
		button.Activated:Connect(function() loadSlot(slot) end)
		slotButtons[slot] = button
	end
	local newButton = Theme.button(leftGroup, "New", { Size = UDim2.fromOffset(56, 34), LayoutOrder = 3 })
	newButton.Activated:Connect(newSpell)
	local save = Theme.button(leftGroup, "Save", { Size = UDim2.fromOffset(104, 34), LayoutOrder = 4 })
	save.Activated:Connect(saveCard)
	saveButton = save
	local equip = Theme.button(leftGroup, "Equip", { Size = UDim2.fromOffset(64, 34), LayoutOrder = 5, BackgroundColor3 = Color3.fromRGB(60, 96, 130) })
	equip.Activated:Connect(function()
		-- Equipping unsaved edits would cast the old version: save first.
		if savedSignature ~= signature() then
			if not saveCard() then return end
			task.wait(COMMAND_GAP)
		end
		equipSlot(selectedSlot)
	end)
	local delete = Theme.button(leftGroup, "Delete", { Size = UDim2.fromOffset(64, 34), LayoutOrder = 6, BackgroundColor3 = Color3.fromRGB(100, 40, 56) })
	delete.Activated:Connect(function()
		applyServerResult(invoke("DeleteCard", { slot = selectedSlot }))
	end)

	-- Fixed-width controls above: title 118 + name 170 + New 56 + Save 104 +
	-- Equip 64 + Delete 64, plus 10 gaps of 8 and 14 left padding.
	local FIXED_WIDTH = 118 + 170 + 56 + 104 + 64 + 64 + 10 * 8 + 14
	local function fitTopBar()
		local slotWidth = math.clamp(math.floor((leftGroup.AbsoluteSize.X - FIXED_WIDTH) / SLOT_COUNT), 44, 130)
		for _, button in slotButtons do
			button.Size = UDim2.fromOffset(slotWidth, 34)
		end
	end
	leftGroup:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitTopBar)
	fitTopBar()

	local rightGroup = Theme.make("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0), Size = UDim2.new(0, 250, 1, 0), BackgroundTransparency = 1 }, bar)
	local rightList = Theme.list(rightGroup, 8, true)
	rightList.VerticalAlignment = Enum.VerticalAlignment.Center
	rightList.HorizontalAlignment = Enum.HorizontalAlignment.Right
	local toolsToggle = Theme.button(rightGroup, "Toolbox", { Size = UDim2.fromOffset(74, 34), LayoutOrder = 1 })
	toolsToggle.Activated:Connect(function()
		panelState.leftOpen = not panelState.leftOpen
		relayout()
	end)
	local inspectToggle = Theme.button(rightGroup, "Inspector", { Size = UDim2.fromOffset(80, 34), LayoutOrder = 2 })
	inspectToggle.Activated:Connect(function()
		panelState.rightOpen = not panelState.rightOpen
		relayout()
	end)
	local close = Theme.button(rightGroup, "Close [E]", { Size = UDim2.fromOffset(76, 34), LayoutOrder = 3 })
	close.Activated:Connect(function() SpellAssemblerGui.Close() end)
end

local function buildBoardOverlays(view: Frame)
	local label = Theme.label(view, "", 13, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Colors.panel,
		BackgroundTransparency = 0.1,
		Font = Theme.FontMedium,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		ZIndex = 20,
	})
	Theme.corner(label, 8)
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, label)
	toast = label

	local zoom = Theme.make("Frame", {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -12, 1, -12),
		Size = UDim2.fromOffset(212, 36),
		BackgroundColor3 = Colors.panel,
		BorderSizePixel = 0,
		Active = true,
		ZIndex = 10,
	}, view)
	Theme.corner(zoom, 8)
	Theme.padding(zoom, 4)
	Theme.list(zoom, 4, true)
	local function zoomButton(text: string, width: number, order: number, callback: () -> ())
		local button = Theme.button(zoom, text, { Size = UDim2.fromOffset(width, 28), LayoutOrder = order, ZIndex = 11 })
		button.Activated:Connect(callback)
	end
	zoomButton("−", 32, 1, function() board:zoomBy(1 / 1.25) end)
	zoomLabel = Theme.label(zoom, "100%", 12, { Size = UDim2.fromOffset(52, 28), TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 2, ZIndex = 11 })
	zoomButton("+", 32, 3, function() board:zoomBy(1.25) end)
	zoomButton("Fit [F]", 72, 4, function() board:frameAll() end)
	board:addOverlay(zoom)

	problems = Panels.Problems.new(view, { onFocus = focusProblem })
	board:addOverlay(problems.frame)
end

local function buildGui()
	if gui then return end
	local screen = Theme.make("ScreenGui", {
		Name = "SpellCircleEditor",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		DisplayOrder = 80,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
	}, player:WaitForChild("PlayerGui"))
	gui = screen

	local editor = Theme.make("Frame", {
		Name = "Editor",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Colors.background,
		BorderSizePixel = 0,
		Active = true, -- keeps clicks/wheel away from the camera
		Visible = false,
	}, screen)
	Theme.make("UIPadding", { PaddingTop = UDim.new(0, GuiService:GetGuiInset().Y) }, editor)
	root = editor
	buildTopBar(editor)

	local row = Theme.make("Frame", { Name = "Body", Position = UDim2.fromOffset(0, TOP_BAR), Size = UDim2.new(1, 0, 1, -TOP_BAR), BackgroundTransparency = 1 }, editor)
	toolboxFrame = Theme.make("Frame", { Name = "Toolbox", BackgroundColor3 = Colors.panel, BorderSizePixel = 0 }, row)
	inspectorFrame = Theme.make("Frame", { Name = "Inspector", BackgroundColor3 = Colors.panel, BorderSizePixel = 0 }, row)
	viewport = Theme.make("Frame", { Name = "Board", BorderSizePixel = 0 }, row)
	leftHandle = makeHandle(row, "left")
	rightHandle = makeHandle(row, "right")

	board = Board.new(viewport :: Frame, doc, {
		onChanged = refresh,
		onSelect = function() if inspector then inspector:show(context()) end end,
		onArm = function(kind: string?) armZone(kind) end,
		onView = function(zoom: number) if zoomLabel then zoomLabel.Text = `{math.floor(zoom * 100 + 0.5)}%` end end,
		onMessage = function(text: string) setStatus(text, false) end,
	})
	toolbox = Panels.Toolbox.new(toolboxFrame :: Frame, {
		onArmZone = armZone,
		onRunePress = function(runeId: string)
			placing = { runeId = runeId, start = Board.pointer(), moved = false }
			if ghost then ghost.Text = "＋ " .. SpellRunes.Runes[runeId].Name end
		end,
	})
	inspector = Panels.Inspector.new(inspectorFrame :: Frame, {
		edit = function(fn)
			doc:record()
			fn()
			refresh()
		end,
		liveEdit = function(fn)
			fn()
			refresh()
		end,
		beginLive = function() doc:record() end,
		delete = deleteSelection,
		doc = function() return doc end,
	})
	buildBoardOverlays(viewport :: Frame)
	relayout()

	ghost = Theme.label(screen, "", 13, {
		Font = Theme.FontBold,
		Size = UDim2.fromOffset(0, 28),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Colors.accent,
		BackgroundTransparency = 0.15,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		ZIndex = 50,
	})
	Theme.corner(ghost :: TextLabel, 6)
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, ghost)

	-- Compact HUD while the tool is held and the editor is closed.
	local compact = Theme.make("Frame", {
		Name = "Compact",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -18, 1, -18),
		Size = UDim2.fromOffset(400, 54),
		BackgroundColor3 = Colors.panel,
		BorderSizePixel = 0,
		Visible = false,
	}, screen)
	Theme.corner(compact, 10)
	Theme.stroke(compact)
	hud = compact
	local previous = Theme.button(compact, "◀", { Position = UDim2.fromOffset(8, 9), Size = UDim2.fromOffset(30, 36) })
	previous.Activated:Connect(function() cycleActive(-1) end)
	activeLabel = Theme.label(compact, "Active spell: None", 13, {
		Position = UDim2.fromOffset(44, 0),
		Size = UDim2.new(1, -224, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	local nextButton = Theme.button(compact, "▶", { Position = UDim2.new(1, -172, 0, 9), Size = UDim2.fromOffset(30, 36) })
	nextButton.Activated:Connect(function() cycleActive(1) end)
	local edit = Theme.button(compact, "Edit [E]", { Position = UDim2.new(1, -134, 0, 9), Size = UDim2.fromOffset(70, 36) })
	edit.Activated:Connect(function() SpellAssemblerGui.Open() end)
	local castButton = Theme.button(compact, "Cast", { Position = UDim2.new(1, -58, 0, 9), Size = UDim2.fromOffset(48, 36), BackgroundColor3 = Color3.fromRGB(128, 58, 44) })
	castButton.Activated:Connect(function() SpellAssemblerGui.Cast() end)

	--------------------------------------------------------------------------
	-- Input routing. Mouse input goes to the board whenever it's over the
	-- viewport, regardless of gameProcessed (the Active root marks it
	-- processed on purpose); keys respect gameProcessed so typing in a
	-- TextBox never triggers shortcuts.
	--------------------------------------------------------------------------
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.E and not processed and equippedTool then
			SpellAssemblerGui.Toggle()
			return
		end
		if not visible then return end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			if not placing and not resizing then board:inputBegan(input) end
			return
		end
		if processed then return end
		local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
		local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		local key = input.KeyCode
		if key == Enum.KeyCode.Delete or key == Enum.KeyCode.Backspace then
			deleteSelection()
		elseif ctrl and (key == Enum.KeyCode.Y or (key == Enum.KeyCode.Z and shift)) then
			if doc:redo() then refresh() end
		elseif ctrl and key == Enum.KeyCode.Z then
			if doc:undo() then refresh() end
		elseif ctrl and key == Enum.KeyCode.D then
			duplicateSelection()
		elseif ctrl and key == Enum.KeyCode.S then
			saveCard()
		elseif key == Enum.KeyCode.L then
			toggleLock()
		elseif key == Enum.KeyCode.F then
			board:frameAll()
		elseif key == Enum.KeyCode.Escape then
			if board:cancel() then return end
			if armedZone then armZone(nil) else board:select(nil) end
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not visible then return end
		local movement = input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
		if resizing and movement then
			local dx = Board.pointer(input).X - resizing.start
			if resizing.side == "left" then
				panelState.left = math.clamp(resizing.width + dx, LEFT_RANGE.X, LEFT_RANGE.Y)
			else
				panelState.right = math.clamp(resizing.width - dx, RIGHT_RANGE.X, RIGHT_RANGE.Y)
			end
			relayout()
		elseif placing and movement then
			local p = Board.pointer(input)
			if (p - placing.start).Magnitude > 4 then placing.moved = true end
			if placing.moved and ghost then
				ghost.Visible = true
				ghost.Position = UDim2.fromOffset(p.X + 14, p.Y + 10 + GuiService:GetGuiInset().Y)
			end
		else
			board:inputChanged(input)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if not visible then return end
		local release = input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
		if resizing and release then
			resizing.handle.BackgroundTransparency = 0.7
			resizing = nil
		elseif placing and release then
			local p = Board.pointer(input)
			local job = placing
			placing = nil
			if ghost then ghost.Visible = false end
			if job.moved then
				if board:accepts(p) then board:placeRune(job.runeId, p) end
			else
				board:placeRune(job.runeId, nil)
			end
		else
			board:inputEnded(input)
		end
	end)

	refresh()
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local function sinkMovement(): Enum.ContextActionResult
	return Enum.ContextActionResult.Sink
end

function SpellAssemblerGui.Open()
	buildGui()
	visible = true;
	(gui :: ScreenGui).Enabled = true;
	(root :: Frame).Visible = true;
	(hud :: Frame).Visible = false
	ContextActionService:BindActionAtPriority(SINK_ACTION, sinkMovement, false, Enum.ContextActionPriority.High.Value + 100, table.unpack(SINK_KEYS))
	refresh()
	if needsFrame then
		needsFrame = false
		task.defer(function() board:frameAll() end)
	end
end

function SpellAssemblerGui.Close()
	if not gui then return end
	visible = false
	placing, resizing = nil, nil
	if ghost then ghost.Visible = false end
	if board then board:setCursor("") end
	ContextActionService:UnbindAction(SINK_ACTION);
	(root :: Frame).Visible = false;
	(hud :: Frame).Visible = equippedTool ~= nil
	updateTopBar()
end

function SpellAssemblerGui.Toggle()
	if visible then SpellAssemblerGui.Close() else SpellAssemblerGui.Open() end
end

function SpellAssemblerGui.Cast()
	if not equippedTool or visible then return end
	if not serverState.activeSlot then
		if activeLabel then
			activeLabel.Text = "No spell equipped: press E, then Save"
			activeLabel.TextColor3 = Colors.bad
			task.delay(2.5, function()
				if activeLabel then activeLabel.TextColor3 = Colors.text end
				updateTopBar()
			end)
		end
		return
	end
	local mouse = player:GetMouse()
	castRemote:FireServer(mouse.Hit.Position)
end

local aimConnection: RBXScriptConnection? = nil

local function startAimStream()
	if aimConnection then return end
	local mouse = player:GetMouse()
	local elapsed, last = 0, nil
	aimConnection = game:GetService("RunService").Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < AIM_SEND_INTERVAL or visible then return end
		elapsed = 0
		local position = mouse.Hit.Position
		if not last or (position - last).Magnitude > 0.1 then
			last = position
			aimRemote:FireServer(position)
		end
	end)
end

local function stopAimStream()
	if aimConnection then
		aimConnection:Disconnect()
		aimConnection = nil
	end
end

function SpellAssemblerGui.Equip(tool: Tool)
	equippedTool = tool
	startAimStream()
	buildGui()
	setStatus("Loading spell cards…", nil, true)
	local result = invoke("GetState")
	if result.state then serverState = result.state end
	if result.state and result.state.error then
		setStatus(result.state.error, result.state.sessionOnly)
	else
		setStatus(result.message or "Cards loaded.", result.ok)
	end
	updateTopBar()
	SpellAssemblerGui.Open()
end

function SpellAssemblerGui.Unequip(tool: Tool)
	if equippedTool ~= tool then return end
	equippedTool = nil
	stopAimStream()
	if visible then SpellAssemblerGui.Close() end
	if gui then gui.Enabled = false end
end

return SpellAssemblerGui
