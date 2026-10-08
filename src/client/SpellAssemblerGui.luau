--!strict
--[[
	Spell circle editor: a full-screen whiteboard for building spell cards,
	plus a compact casting HUD. MainHud launches it without a Tool.
	Public API: start, Open, Close, Toggle, SelectSlot, GetState, StateChanged,
	Cast, StopCast, CancelCast. Equip/Unequip preserve old Tool compatibility.

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
local SpellCircleLayout = require(Shared:WaitForChild("SpellCircleLayout"))
local SpellCircleVFX = require(script.Parent:WaitForChild("SpellCircleVFX"))
local remotes = ReplicatedStorage:WaitForChild("SpellRemotes")
local command = remotes:WaitForChild("SpellCommand") :: RemoteFunction
local castRemote = remotes:WaitForChild("SpellCast") :: RemoteEvent
local feedbackRemote = remotes:WaitForChild("SpellFeedback") :: RemoteEvent
local CAST_COOLDOWN = require(Shared.SpellSettings).CastCooldown
local aimRemote = remotes:WaitForChild("SpellAim") :: UnreliableRemoteEvent
local channelRemote = remotes:WaitForChild("SpellChannel") :: RemoteEvent
local holdingCast = false

local EditorFolder = script.Parent:WaitForChild("SpellEditor")
local Theme = require(EditorFolder:WaitForChild("Theme"))
local Document = require(EditorFolder:WaitForChild("Document"))
local Board = require(EditorFolder:WaitForChild("Board"))
local Panels = require(EditorFolder:WaitForChild("Panels"))

local Colors = Theme.Colors
local SpellAssemblerGui = {}
local stateEvent = Instance.new("BindableEvent")
SpellAssemblerGui.StateChanged = stateEvent.Event
local firedEvent = Instance.new("BindableEvent")
SpellAssemblerGui.SpellFired = firedEvent.Event
local cooldownDeadlines: { [number]: number } = {}
function SpellAssemblerGui.GetCooldownRemaining(slot: number?): number
	local key = slot or SpellAssemblerGui.GetSelectedSlot()
	if not key then return 0 end
	return math.max(0, math.max(cooldownDeadlines[key] or 0, player:GetAttribute("SpellCooldownEndsAt" .. key) or 0) - workspace:GetServerTimeNow())
end
feedbackRemote.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" or typeof(data.EndsAt) ~= "number" or typeof(data.Slot) ~= "number" then return end
	cooldownDeadlines[data.Slot] = data.EndsAt
	if data.Accepted then firedEvent:Fire(data) end
end)
local lastCastAt = -math.huge -- (keeps the live cursor streaming after a cast)
local function sendCast(target: Vector3)
	local slot = SpellAssemblerGui.GetSelectedSlot()
	if slot then cooldownDeadlines[slot] = workspace:GetServerTimeNow() + CAST_COOLDOWN end
	lastCastAt = os.clock()
	castRemote:FireServer(target)
end
local started = false
local loadingCards = false
local selectingCard = false
local pendingActiveSlot: number? = nil

local SLOT_COUNT = 5
local TOP_BAR = 52
local HANDLE = 6
local LEFT_RANGE = Vector2.new(200, 480)
local RIGHT_RANGE = Vector2.new(240, 520)
local SINK_ACTION = "SpellEditorSinkMovement"
local AIM_SEND_INTERVAL = 0.05 -- live cursor for Stream/Sustain re-aiming
local AIM_AFTER_CAST = 6 -- seconds the cursor keeps streaming after a cast
local SINK_KEYS = {
	Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Space,
	Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right,
}

local equippedTool: Tool? = nil
-- Classic UI (see UiMode): casting and the E editor need the SpellAssembler
-- Tool held, as before MainHud; the hotbar UI casts without a Tool.
local toolRequired = false
local compactEnabled = true
-- fired with the cost when a cast is refused for lack of mana (GameHud)
local manaShortEvent = Instance.new("BindableEvent")
SpellAssemblerGui.ManaShort = manaShortEvent.Event
local function canCast(): boolean
	if toolRequired and not equippedTool then return false end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then return false end
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child.Name ~= "SpellAssembler" then return false end
	end
	return true
end
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
-- Editing a library spell (SpellLibrary's Edit / New spell) instead of a
-- hotbar slot: Save writes to that library spell, or adds a new one when
-- `libraryMode` is on without an id. Picking a slot leaves this mode.
local libraryMode = false
local editingSpellId: string? = nil
local savedSignature: string? = nil
local savingCard = false
local hasLoadedCards = false
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
	local typed = if nameBox then string.gsub(nameBox.Text, "^%s*(.-)%s*$", "%1") else ""
	if typed ~= "" then
		return typed
	end
	-- unnamed card: describe it instead of saving a generic placeholder
	return if doc.graph.name ~= "" then doc.graph.name else SpellCompiler.SuggestName(doc.graph)
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
		local active = (pendingActiveSlot or serverState.activeSlot) == slot
		button.Text = `{slot}  {if record then record.name else "Empty"}{if active then "  ◆" else ""}`
		button.BackgroundColor3 = if selectedSlot == slot and not libraryMode then Colors.accent:Lerp(Colors.panel, 0.45) else Colors.panel2
		button.TextColor3 = if record then Colors.text else Colors.muted
	end
	if saveButton then
		local available = serverState.available == true
		local target = if libraryMode then "library" else tostring(selectedSlot)
		saveButton.Text = if savingCard then "Saving…" elseif not available then "Save unavailable" elseif dirty then `Save to {target} •` else "Saved"
		saveButton.BackgroundColor3 = if compiledOk and dirty and available and not savingCard then Color3.fromRGB(58, 128, 86) else Colors.panel3
		saveButton.AutoButtonColor = compiledOk and available and not savingCard
	end
	local displaySlot = pendingActiveSlot or serverState.activeSlot
	local active = displaySlot and slotRecord(displaySlot)
	if activeLabel then
		activeLabel.Text = `Active spell: {if active then active.name else "None"}`
	end
	stateEvent:Fire(serverState)
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
	local warnings = if analysis and analysis.warnings then analysis.warnings else {}
	if #warnings > 0 then
		summary ..= `  ·  ⚠ {warnings[1].message}` .. (if #warnings > 1 then ` (+{#warnings - 1} more)` else "")
	end
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

-- Unequips the active spell (nothing casts until another is selected).
local function deselectSlot()
	if pendingActiveSlot then return end
	SpellAssemblerGui.CancelCast()
	local result = invoke("ClearActive")
	if result.ok then result.message = "Spell deselected." end
	applyServerResult(result)
end

local function equipSlot(slot: number)
	if pendingActiveSlot then return end
	SpellAssemblerGui.CancelCast()
	pendingActiveSlot = slot
	updateTopBar()
	setStatus("Equipping…", nil, true)
	local result = invoke("SetActive", { slot = slot })
	pendingActiveSlot = nil
	if result.ok then
		result.message = `Equipped "{(slotRecord(slot) or {}).name or "spell"}". Close the editor [E] and click to cast.`
	end
	applyServerResult(result)
end

-- Saves the circle to the selected slot. The first saved spell is equipped
-- automatically, so a fresh card is castable right after saving.
local function saveCard(): boolean
	if savingCard then return false end
	if serverState.available ~= true then
		setStatus(serverState.error or "Spell storage is unavailable.", false, true)
		return false
	end
	if not compiledOk then
		local first = errors[1]
		setStatus(if first then `Can't save yet: {first.message}` else "Fix the problems on the board before saving.", false)
		return false
	end
	setStatus("Saving…", nil, true)
	savingCard = true
	updateTopBar()
	if libraryMode then
		-- a library spell (not a hotbar slot): saved back to it, or added
		local result = invoke("SaveSpell", { id = editingSpellId, name = currentName(), graph = doc.graph })
		savingCard = false
		if result.state then serverState = result.state end
		if result.ok then
			editingSpellId = result.id or editingSpellId
			for _, spell in serverState.library or {} do
				if spell.id == editingSpellId then
					doc:load(spell.graph)
					if nameBox then nameBox.Text = spell.name end
				end
			end
			savedSignature = signature()
		end
		applyServerResult(result)
		refresh()
		return result.ok == true
	end
	local result = invoke("SaveCard", { slot = selectedSlot, name = currentName(), graph = doc.graph })
	savingCard = false
	-- Apply the authoritative state BEFORE reading the saved record. Loading
	-- its normalized graph/name avoids marking an older local copy as Saved.
	if result.state then serverState = result.state end
	if result.ok then
		local record = slotRecord(selectedSlot)
		if record and record.graph then doc:load(record.graph) end
		if record and nameBox then nameBox.Text = record.name end
		savedSignature = signature()
	end
	applyServerResult(result)
	refresh()
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
	libraryMode, editingSpellId = false, nil
	local record = slotRecord(slot)
	if record and record.invalid then
		savedSignature = nil
		setStatus(record.error or "This older card cannot be compiled; its saved data has been preserved.", false, true)
		updateTopBar()
		return
	end
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
		savedSignature = nil
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
			if ghost then ghost.Text = "＋ " .. SpellRunes.DisplayName(SpellRunes.Runes[runeId]) end
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

	-- Compact casting controls while the editor is closed (also supports touch).
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
	castButton.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then SpellAssemblerGui.Cast() end
	end)
	castButton.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then SpellAssemblerGui.StopCast() end
	end)

	--------------------------------------------------------------------------
	-- Input routing. Mouse input goes to the board whenever it's over the
	-- viewport, regardless of gameProcessed (the Active root marks it
	-- processed on purpose); keys respect gameProcessed so typing in a
	-- TextBox never triggers shortcuts.
	--------------------------------------------------------------------------
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.E and not processed and (visible or canCast()) then
			SpellAssemblerGui.Toggle()
			return
		end
		if not processed and not visible and canCast() then
			if input.KeyCode == Enum.KeyCode.R then
				SpellAssemblerGui.Freeze()
				return
			elseif input.KeyCode == Enum.KeyCode.T then
				SpellAssemblerGui.FireFrozen()
				return
			end
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
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then SpellAssemblerGui.StopCast() end
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
	SpellAssemblerGui.CancelCast()
	buildGui()
	if not hasLoadedCards or serverState.available ~= true then task.spawn(SpellAssemblerGui.LoadCards) end
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
	(hud :: Frame).Visible = compactEnabled and canCast()
	updateTopBar()
end

function SpellAssemblerGui.Toggle()
	if visible then SpellAssemblerGui.Close() else SpellAssemblerGui.Open() end
end

--------------------------------------------------------------------------------
-- Hold-to-charge (spells without Sustain): press starts charging, release
-- casts. The server times the hold itself; this only mirrors it for the bar.
--------------------------------------------------------------------------------

local charging = false
local chargeStarted = 0
local chargeGui: ScreenGui? = nil
local chargeFill: Frame? = nil
local chargeText: TextLabel? = nil
local chargeConnection: RBXScriptConnection? = nil
-- The active card compiled once, with its circle spec: the same
-- SpellCircleLayout.Build the server broadcasts, so the caster's own circle
-- draws instantly and matches what everyone else sees.
local activeCache: { record: any, compiled: any, spec: any, sustain: boolean } = { record = nil, compiled = nil, spec = nil, sustain = false }

local function refreshActive()
	local record = serverState.activeSlot and slotRecord(serverState.activeSlot)
	if not record or not record.graph then
		activeCache.record, activeCache.compiled, activeCache.spec, activeCache.sustain = nil, nil, nil, false
		return
	end
	if activeCache.record ~= record then
		local compiled = SpellCompiler.Compile(record.graph)
		activeCache.record = record
		activeCache.compiled = compiled
		activeCache.spec = if compiled then SpellCircleLayout.Build(compiled) else nil
		activeCache.sustain = compiled ~= nil and SpellRunes.HasSustain(compiled)
	end
end

local function activeHasSustain(): boolean
	refreshActive()
	return activeCache.sustain
end

local function buildChargeBar()
	if chargeGui then
		return
	end
	local screen = Instance.new("ScreenGui")
	screen.Name = "SpellCharge"
	screen.ResetOnSpawn = false
	screen.Enabled = false
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.new(0.5, 0, 1, -170)
	frame.Size = UDim2.fromOffset(240, 10)
	frame.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	frame.BackgroundTransparency = 0.2
	frame.BorderSizePixel = 0
	frame.Parent = screen
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BorderSizePixel = 0
	fill.Parent = frame
	-- tick at charge 1: everything right of it is overcharge
	local tick = Instance.new("Frame")
	tick.AnchorPoint = Vector2.new(0.5, 0)
	tick.Position = UDim2.fromScale(1 / SpellRunes.Charge.Max, 0)
	tick.Size = UDim2.new(0, 2, 1, 0)
	tick.BackgroundColor3 = Color3.new(1, 1, 1)
	tick.BorderSizePixel = 0
	tick.ZIndex = 2
	tick.Parent = frame
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.AnchorPoint = Vector2.new(0.5, 1)
	text.Position = UDim2.new(0.5, 0, 0, -2)
	text.Size = UDim2.fromOffset(240, 16)
	text.Font = Enum.Font.GothamBold
	text.TextSize = 13
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextStrokeTransparency = 0.5
	text.Parent = frame
	screen.Parent = player:WaitForChild("PlayerGui")
	chargeGui, chargeFill, chargeText = screen, fill, text
end

local function stopChargeBar()
	charging = false
	if chargeConnection then
		chargeConnection:Disconnect()
		chargeConnection = nil
	end
	if chargeGui then
		chargeGui.Enabled = false
	end
end

local function startChargeBar()
	buildChargeBar()
	local screen = chargeGui :: ScreenGui
	screen.Enabled = true
	if chargeConnection then
		chargeConnection:Disconnect()
	end
	chargeConnection = game:GetService("RunService").RenderStepped:Connect(function()
		local level = SpellRunes.ChargeFromHold(os.clock() - chargeStarted)
		local fill = chargeFill :: Frame
		local text = chargeText :: TextLabel
		fill.Size = UDim2.fromScale(level / SpellRunes.Charge.Max, 1)
		fill.BackgroundColor3 = if level < 1 then Color3.fromRGB(110, 170, 255) else Color3.fromRGB(255, 170, 60)
		if level < 1 then
			text.Text = string.format("%d%% power", math.floor(level * 100))
		else
			text.Text = string.format("OVERCHARGE  %.2fx copies", SpellRunes.ChargeCopyMultiplier(level))
		end
	end)
end

function SpellAssemblerGui.Cast()
	if pendingActiveSlot or SpellAssemblerGui.GetCooldownRemaining() > 0 or not canCast() or visible or holdingCast or charging then return end
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
	if not activeHasSustain() then
		-- charge while held; released in StopCast. The full cost is paid as
		-- the charge starts (SpellService), so it must be affordable now.
		local mana = player:GetAttribute("Mana")
		local compiled = activeCache.compiled
		if not compiled or typeof(mana) ~= "number" or mana < compiled.manaCost then
			manaShortEvent:Fire(if compiled then compiled.manaCost else 0)
			return
		end
		charging = true
		chargeStarted = os.clock()
		channelRemote:FireServer("ChargeBegin")
		startChargeBar()
		local character = player.Character
		if character and activeCache.spec then
			SpellCircleVFX.Begin(character, activeCache.spec, player:GetMouse().Hit.Position, true, compiled.manaCost)
		end
		return
	end
	local mouse = player:GetMouse()
	holdingCast = true
	sendCast(mouse.Hit.Position)
	local character = player.Character
	if character and activeCache.spec then
		local compiled = activeCache.compiled
		if compiled then require(script.Parent.SpellCastGlint).Play(character, compiled.manaCost, mouse.Hit.Position) end
		SpellCircleVFX.Cast(character, activeCache.spec, 1, mouse.Hit.Position, true, true)
	end
end

-- R while charging: the charge is paid for now and the spell hangs where its
-- circle is. Freezing one past SpellRunes.Freeze.MaxQueued fires the oldest
-- first (the server mirrors both).
function SpellAssemblerGui.Freeze()
	local character = player.Character
	local compiled = activeCache.compiled
	if not charging or not character or not compiled then return end
	if SpellCircleVFX.FrozenCount(character) >= SpellRunes.Freeze.MaxQueued and SpellAssemblerGui.GetCooldownRemaining(player:GetAttribute("SpellFrozenSlot")) > 0 then return end
	-- (already paid for when the charge began; unaffordable overcharge falls
	-- back to charge 1 on the server)
	stopChargeBar()
	if SpellCircleVFX.FrozenCount(character) >= SpellRunes.Freeze.MaxQueued then
		SpellCircleVFX.FireFrozen(character, player:GetMouse().Hit.Position)
	end
	local position = SpellCircleVFX.Freeze(character)
	channelRemote:FireServer("Freeze", position)
end

-- T: the oldest frozen spell fires toward the cursor.
function SpellAssemblerGui.FireFrozen()
	local character = player.Character
	local frozenSlot = player:GetAttribute("SpellFrozenSlot")
	if not character or not frozenSlot or SpellAssemblerGui.GetCooldownRemaining(frozenSlot) > 0 or not canCast() then return end
	local target = player:GetMouse().Hit.Position
	cooldownDeadlines[frozenSlot] = workspace:GetServerTimeNow() + CAST_COOLDOWN
	lastCastAt = os.clock()
	channelRemote:FireServer("FireFrozen", target)
	SpellCircleVFX.FireFrozen(character, target)
end

function SpellAssemblerGui.StopCast()
	if charging then
		stopChargeBar()
		if SpellAssemblerGui.GetCooldownRemaining() > 0 then
			channelRemote:FireServer("ChargeCancel")
			if player.Character then SpellCircleVFX.Cancel(player.Character) end
			return
		end
		local target = player:GetMouse().Hit.Position
		sendCast(target)
		local character = player.Character
		if character then
			-- the charge was paid for when it began; overcharge the server
			-- can't take the extra mana for fires at charge 1 instead
			local charge = SpellRunes.ChargeFromHold(os.clock() - chargeStarted)
			local compiled = activeCache.compiled
			local mana = player:GetAttribute("Mana")
			if compiled and charge > 1 and typeof(mana) == "number"
				and mana < compiled.manaCost * (SpellRunes.ChargeEnergyMultiplier(charge) - 1) then
				charge = 1
			end
			SpellCircleVFX.Cast(character, activeCache.spec, charge, target, false, true)
		end
		return
	end
	if not holdingCast then return end
	holdingCast = false
	channelRemote:FireServer("Stop")
	if player.Character then
		SpellCircleVFX.End(player.Character)
	end
end

local aimConnection: RBXScriptConnection? = nil

local function startAimStream()
	if aimConnection then return end
	local mouse = player:GetMouse()
	local elapsed, last, sinceSend = 0, nil, 0
	aimConnection = game:GetService("RunService").Heartbeat:Connect(function(dt)
		-- while charging / channelling, and for a while after each cast: a
		-- Stream's later copies and a released beam re-aim at the live cursor
		local recent = os.clock() - lastCastAt < AIM_AFTER_CAST
		if not canCast() or (not holdingCast and not charging and not recent) then return end
		elapsed += dt
		sinceSend += dt
		if elapsed < AIM_SEND_INTERVAL or visible then return end
		elapsed = 0
		local position = mouse.Hit.Position
		if not last or (position - last).Magnitude > 0.1 or sinceSend >= 0.2 then
			last = position
			sinceSend = 0
			aimRemote:FireServer(position)
			if holdingCast then channelRemote:FireServer("KeepAlive") end
		end
	end)
end

local function stopAimStream()
	if aimConnection then
		aimConnection:Disconnect()
		aimConnection = nil
	end
end

function SpellAssemblerGui.LoadCards()
	if loadingCards then return end
	loadingCards = true
	buildGui()
	setStatus("Loading spell cards…", nil, true)
	local result = invoke("GetState")
	if result.state then serverState = result.state end
	if result.ok and serverState.available and not hasLoadedCards then
		hasLoadedCards = true
		local initialSlot = serverState.activeSlot
		if not initialSlot then
			for slot = 1, SLOT_COUNT do if slotRecord(slot) then initialSlot = slot; break end end
		end
		if initialSlot then loadSlot(initialSlot) end
	end
	if result.state and result.state.error then
		setStatus(result.state.error, result.state.sessionOnly)
	else
		setStatus(result.message or "Cards loaded.", result.ok)
	end
	updateTopBar()
	loadingCards = false
end

function SpellAssemblerGui.Equip(tool: Tool)
	equippedTool = tool
	startAimStream()
	SpellAssemblerGui.LoadCards()
	SpellAssemblerGui.Open()
end

function SpellAssemblerGui.CancelCast()
	if charging then
		stopChargeBar()
		channelRemote:FireServer("ChargeCancel")
		if player.Character then SpellCircleVFX.Cancel(player.Character) end
	end
	SpellAssemblerGui.StopCast()
end

function SpellAssemblerGui.GetState(): any
	return serverState
end

-- Runs a spell command (SpellService) and applies the state it returns
-- (StateChanged fires). Yields; returns the server's response.
function SpellAssemblerGui.Command(action: string, payload: any?): any
	local result = invoke(action, payload)
	if result.state then serverState = result.state end
	updateTopBar()
	return result
end

-- Opens the editor on a library spell; Save writes back to it.
function SpellAssemblerGui.EditSpell(id: string)
	local spell = nil
	for _, candidate in serverState.library or {} do
		if candidate.id == id then
			spell = candidate
		end
	end
	if not spell then return end
	SpellAssemblerGui.Open()
	libraryMode, editingSpellId = true, id
	if spell.invalid then
		savedSignature = nil
		setStatus(spell.error or "This spell no longer compiles; its saved data has been preserved.", false, true)
		updateTopBar()
		return
	end
	doc:load(spell.graph)
	if nameBox then nameBox.Text = spell.name end
	if board then
		board.selection = nil
		board:frameAll()
	end
	savedSignature = signature()
	setStatus(`Editing "{spell.name}" from your library.`)
	refresh()
end

-- Opens the editor on a fresh circle; Save adds it to the library.
function SpellAssemblerGui.NewLibrarySpell()
	SpellAssemblerGui.Open()
	libraryMode, editingSpellId = true, nil
	newSpell()
	setStatus("New spell: Save adds it to your library.")
end

function SpellAssemblerGui.GetSelectedSlot(): number?
	return pendingActiveSlot or serverState.activeSlot
end

function SpellAssemblerGui.IsOpen(): boolean
	return visible
end

-- Mana cost (at charge 1) of the equipped spell, or nil with none equipped.
function SpellAssemblerGui.GetActiveManaCost(): number?
	refreshActive()
	return if activeCache.compiled then activeCache.compiled.manaCost else nil
end

function SpellAssemblerGui.IsCharging(): boolean
	return charging
end

-- The compact casting panel (bottom right); GameHud has its own controls.
function SpellAssemblerGui.SetCompactHudEnabled(enabled: boolean)
	compactEnabled = enabled
	if gui and not visible then SpellAssemblerGui.Close() end
end

function SpellAssemblerGui.SetToolRequired(required: boolean)
	if toolRequired == required then return end
	toolRequired = required
	if not canCast() then SpellAssemblerGui.CancelCast() end
	-- (Close refreshes the compact HUD's visibility from canCast)
	if gui and (not visible or not canCast()) then SpellAssemblerGui.Close() end
end

function SpellAssemblerGui.SelectSlot(slot: number)
	if selectingCard or loadingCards then return end
	if not slotRecord(slot) then
		loadSlot(slot)
		SpellAssemblerGui.Open()
		return
	end
	selectingCard = true
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then humanoid:UnequipTools() end
	if serverState.activeSlot == slot then
		-- selecting the selected spell again deselects it
		deselectSlot()
		selectingCard = false
		return
	end
	equipSlot(slot)
	selectingCard = false
	if serverState.activeSlot == slot then SpellAssemblerGui.Close() end
end

function SpellAssemblerGui.start()
	if started then return end
	started = true
	buildGui()
	SpellAssemblerGui.Close()
	startAimStream()
	task.spawn(SpellAssemblerGui.LoadCards)
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and not equippedTool and input.UserInputType == Enum.UserInputType.MouseButton1 then
			SpellAssemblerGui.Cast()
		end
	end)
	local function watchCharacter(character: Model)
		SpellAssemblerGui.CancelCast()
		character.ChildAdded:Connect(function(child)
			if child:IsA("Tool") and child.Name ~= "SpellAssembler" then SpellAssemblerGui.CancelCast() end
		end)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			if not visible then SpellAssemblerGui.Close() end
			humanoid.Died:Connect(function() SpellAssemblerGui.CancelCast(); SpellAssemblerGui.Close() end)
		end
	end
	player.CharacterAdded:Connect(watchCharacter)
	player.CharacterRemoving:Connect(function() SpellAssemblerGui.CancelCast(); SpellAssemblerGui.Close() end)
	if player.Character then task.spawn(watchCharacter, player.Character) end
end

function SpellAssemblerGui.Unequip(tool: Tool)
	if equippedTool ~= tool then return end
	if charging then
		-- switching away abandons the charge instead of releasing it
		stopChargeBar()
		channelRemote:FireServer("ChargeCancel")
		if player.Character then
			SpellCircleVFX.Cancel(player.Character)
		end
	end
	SpellAssemblerGui.StopCast()
	equippedTool = nil
	if started then startAimStream() else stopAimStream() end
	if visible then SpellAssemblerGui.Close() end
	if gui then gui.Enabled = started end
end

return SpellAssemblerGui
