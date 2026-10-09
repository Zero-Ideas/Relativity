--!strict
--[[
	Spell circle editor: a full-screen whiteboard for building spells, plus a
	compact casting HUD. MainHud launches it without a Tool.
	Public API: start, Open, Close, Toggle, EditEquipped, EditSpell,
	NewLibrarySpell, SetLibraryOpener, SelectSlot, GetState, StateChanged,
	Cast, StopCast, CancelCast. Equip/Unequip preserve old Tool compatibility.

	The editor key (V by default; Settings > Controls -- UiMode binds it to
	ToggleEditor) edits the equipped spell: a library spell in place, an
	Encyclopedia one as a copy that Save adds to the library. With nothing
	equipped it starts a new spell. Unsaved work is never thrown away by the
	key: the editor reopens on it, and pressing it again within a few
	seconds switches. The same key closes the editor.

	Layout: a slim top bar (Library, name, status, undo/redo, panel toggles,
	Save, guide, close) over a row of [Toolbox | Board | Inspector]. Both
	side panels resize by dragging their inner edge and collapse from the top
	bar; the ? button opens the guide over the board. The pieces live in
	SpellEditor/: Document (graph + undo), Board (whiteboard), Panels
	(toolbox, inspector, problems).

	While the editor is open its root frame is Active, so mouse input never
	reaches the camera, and movement keys are sunk through
	ContextActionService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Signal"))
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

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
-- (live admin settings: cast cooldown and infinite mana)
local SpellSettings = require(Shared.SpellSettings)
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
local stateEvent = Signal.new()
SpellAssemblerGui.StateChanged = stateEvent
-- (fires true / false as the editor opens and closes)
local openEvent = Signal.new()
SpellAssemblerGui.OpenChanged = openEvent
local firedEvent = Signal.new()
SpellAssemblerGui.SpellFired = firedEvent
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
	if slot then cooldownDeadlines[slot] = workspace:GetServerTimeNow() + SpellSettings.GetCooldown() end
	lastCastAt = os.clock()
	castRemote:FireServer(target)
end
local started = false
local loadingCards = false
local pendingActiveSlot: number? = nil
local selectionPending = false -- separate flag: nil is a pending deselection
local selectionVersion = 0
local selectionWorker = false

local SLOT_COUNT = 5
local TOP_BAR = 48
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
local manaShortEvent = Signal.new()
SpellAssemblerGui.ManaShort = manaShortEvent
local castingPaused = false -- (the HUD's items bar is up)
local function canCast(): boolean
	if castingPaused then return false end
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
local statusChip: TextButton? = nil
local modeLabel: TextLabel? = nil
local helpFrame: Frame? = nil
local zoomLabel: TextLabel? = nil
local ghost: TextLabel? = nil
-- opens the spell library window (UiMode wires it: SpellLibrary requires us)
local libraryOpener: (() -> ())? = nil
-- E pressed over unsaved work: a second E before this switches anyway
local discardArmed: { until_: number, id: string? }? = nil
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
	if saveButton then
		local available = serverState.available == true
		saveButton.Text = if savingCard then "Saving…" elseif not available then "Unavailable" elseif dirty then "Save" else "Saved ✓"
		saveButton.BackgroundColor3 = if compiledOk and dirty and available and not savingCard then Color3.fromRGB(58, 128, 86) else Colors.panel3
		saveButton.AutoButtonColor = compiledOk and available and not savingCard
	end
	if modeLabel then
		local where = if libraryMode then (if editingSpellId then "Library spell" else "New spell · Save adds it to your library") else `Hotbar slot {selectedSlot}`
		modeLabel.Text = where .. (if dirty then "  ·  unsaved" else "")
	end
	if statusChip then
		local warnings = if analysis and analysis.warnings then #analysis.warnings else 0
		local mana = if analysis then `{analysis.manaCost} mana` else ""
		local color
		if #errors > 0 then
			statusChip.Text = `✖  {#errors} problem{if #errors == 1 then "" else "s"}`
			color = Colors.bad
		elseif warnings > 0 then
			statusChip.Text = `⚠  {mana} · {warnings} warning{if warnings == 1 then "" else "s"}`
			color = Colors.warn
		else
			statusChip.Text = `✓  {mana}`
			color = Colors.good
		end
		statusChip.TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.25)
		statusChip.BackgroundColor3 = color:Lerp(Colors.panel, 0.8)
	end
	if nameBox then
		nameBox.PlaceholderText = SpellCompiler.SuggestName(doc.graph)
	end
	local displaySlot = SpellAssemblerGui.GetSelectedSlot()
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

-- All editor/library/share calls use the same serialized dispatcher. A
-- background GetState must not make an interactive command fail as busy
-- or hit the server's 0.15-second command limit.
local COMMAND_GAP = 0.2
local commandReleased = Signal.new()
local lastCommandAt = -math.huge
local lastCommandWasSelection = false
local commandSequence = 0
local nextCommandSequence = 1
local appliedCommandSequence = 0

local function acceptServerResult(result: any)
	local sequence = result.clientSequence or 0
	if sequence < appliedCommandSequence then return end
	appliedCommandSequence = sequence
	if result.state then serverState = result.state end
	if result.selection then serverState.activeSlot = result.selection.slot end
end

local function invoke(action: string, payload: any?): any
	-- Reserve a ticket before yielding: waking all waiters must not reorder
	-- two library swaps (or let a newer command overtake an earlier one).
	commandSequence += 1
	local sequence = commandSequence
	while sequence ~= nextCommandSequence do commandReleased:Wait() end
	local isSelection = action == "SetActive" or action == "ClearActive"
	local gap = if isSelection and lastCommandWasSelection then 0.08 else COMMAND_GAP
	local remaining = gap - (os.clock() - lastCommandAt)
	if remaining > 0 then task.wait(remaining) end
	lastCommandAt = os.clock()
	lastCommandWasSelection = isSelection
	local ok, result = pcall(command.InvokeServer, command, action, payload)
	-- Network jitter can compress two arrivals despite client pacing. Retry
	-- only an explicit throttle rejection (the server performed no mutation).
	if ok and typeof(result) == "table" and typeof(result.retryAfter) == "number" then
		task.wait(math.clamp(result.retryAfter, 0, 0.2) + 0.03)
		lastCommandAt = os.clock()
		ok, result = pcall(command.InvokeServer, command, action, payload)
	end
	if not ok or typeof(result) ~= "table" then
		result = { ok = false, message = "The spell service did not respond." }
	end
	result.clientSequence = sequence
	acceptServerResult(result)
	nextCommandSequence += 1
	commandReleased:Fire()
	return result
end

local function applyServerResult(result: any)
	acceptServerResult(result)
	local message = result.message or ""
	if not result.ok and result.errors and result.errors[1] then
		message = result.errors[1].message or message
	end
	setStatus(message, result.ok)
	updateTopBar()
end

-- Highlight immediately and coalesce rapid clicks into the latest intent.
-- Older acknowledgements may update the server cache, never the pending UI.
local function requestSelection(slot: number?)
	SpellAssemblerGui.CancelCast()
	pendingActiveSlot = slot
	selectionPending = true
	selectionVersion += 1
	updateTopBar()
	if selectionWorker then return end
	selectionWorker = true
	task.spawn(function()
		while selectionPending do
			local version, target = selectionVersion, pendingActiveSlot
			local result = invoke(if target then "SetActive" else "ClearActive", if target then { slot = target } else nil)
			acceptServerResult(result)
			if version == selectionVersion then
				selectionPending = false
				pendingActiveSlot = nil
				if result.ok then
					result.message = if target then `Equipped "{(slotRecord(target) or {}).name or "spell"}".` else "Spell deselected."
				end
				applyServerResult(result)
			else
				updateTopBar()
			end
		end
		selectionWorker = false
	end)
end

local function deselectSlot()
	requestSelection(nil)
end

local function equipSlot(slot: number)
	requestSelection(slot)
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
		acceptServerResult(result)
		local wasNew = editingSpellId == nil
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
		-- nothing equipped yet: a brand-new spell goes on the first free box
		-- and is selected, so it casts straight away
		if result.ok and wasNew and editingSpellId and not serverState.activeSlot then
			local free = nil
			for slot = 1, SLOT_COUNT do
				if not slotRecord(slot) then
					free = slot
					break
				end
			end
			if free then
				local equipped = invoke("Equip", { slot = free, ref = "c:" .. editingSpellId })
				acceptServerResult(equipped)
				if equipped.ok then
					equipSlot(free)
				else
					applyServerResult(equipped)
				end
			end
		end
		return result.ok == true
	end
	local result = invoke("SaveCard", { slot = selectedSlot, name = currentName(), graph = doc.graph })
	savingCard = false
	-- Apply the authoritative state BEFORE reading the saved record. Loading
	-- its normalized graph/name avoids marking an older local copy as Saved.
	acceptServerResult(result)
	if result.ok then
		local record = slotRecord(selectedSlot)
		if record and record.graph then doc:load(record.graph) end
		if record and nameBox then nameBox.Text = record.name end
		savedSignature = signature()
	end
	applyServerResult(result)
	refresh()
	if result.ok and not serverState.activeSlot then
		equipSlot(selectedSlot)
	end
	return result.ok == true
end

-- Makes the next/previous saved slot the active spell (HUD arrows).
local function cycleActive(direction: number)
	local current = SpellAssemblerGui.GetSelectedSlot() or selectedSlot
	for step = 1, SLOT_COUNT do
		local slot = (current - 1 + direction * step) % SLOT_COUNT + 1
		if slotRecord(slot) then
			if slot ~= SpellAssemblerGui.GetSelectedSlot() then
				equipSlot(slot)
			end
			return
		end
	end
end

-- Frames the whole circle once the board has its size (just after opening).
local function frameSoon()
	if not board then
		return
	end
	task.defer(function()
		task.wait()
		if board then
			board:frameAll()
		end
	end)
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
			frameSoon()
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
		frameSoon()
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

local function iconButton(parent: Instance, text: string, order: number, callback: () -> ()): TextButton
	local button = Theme.button(parent, text, {
		Size = UDim2.fromOffset(32, 32),
		LayoutOrder = order,
		BackgroundColor3 = Colors.panel2,
		TextSize = 16,
	})
	button.Activated:Connect(callback)
	return button
end

local function textButton(parent: Instance, text: string, order: number, callback: () -> ()): TextButton
	local button = Theme.button(parent, text, {
		Size = UDim2.fromOffset(0, 32),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = order,
		BackgroundColor3 = Colors.panel2,
		TextSize = 12,
	})
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, button)
	button.Activated:Connect(callback)
	return button
end

local function setHelpVisible(on: boolean)
	if helpFrame then
		helpFrame.Visible = on
	end
end

local function buildTopBar(parent: Frame)
	local bar = Theme.make("Frame", {
		Name = "TopBar",
		Size = UDim2.new(1, 0, 0, TOP_BAR),
		BackgroundColor3 = Colors.panel,
		BorderSizePixel = 0,
	}, parent)
	Theme.glass(bar, "panel", true)
	Theme.fadeLine(bar, { Position = UDim2.new(0, 0, 1, -1) })

	-- left: back to the library, the spell's name, what's being edited
	local RIGHT_WIDTH = 500
	local leftGroup = Theme.make("Frame", { Name = "LeftGroup", BackgroundTransparency = 1, Size = UDim2.new(1, -RIGHT_WIDTH, 1, 0), ClipsDescendants = true }, bar)
	local leftList = Theme.list(leftGroup, 10, true)
	leftList.VerticalAlignment = Enum.VerticalAlignment.Center
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 12) }, leftGroup)
	local library = Theme.button(leftGroup, "≡  Library", { Size = UDim2.fromOffset(96, 32), LayoutOrder = 1, BackgroundColor3 = Colors.panel2 })
	library.Activated:Connect(function()
		SpellAssemblerGui.Close()
		if libraryOpener then libraryOpener() end
	end)
	local box = Theme.make("TextBox", {
		Size = UDim2.fromOffset(240, 32),
		BackgroundColor3 = Colors.panel2,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = Theme.FontBold,
		PlaceholderText = "Spell name",
		PlaceholderColor3 = Colors.muted,
		Text = doc.graph.name,
		TextColor3 = Colors.text,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = 2,
	}, leftGroup)
	Theme.corner(box)
	Theme.field(box)
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, box)
	box.FocusLost:Connect(function() updateTopBar() end)
	nameBox = box
	modeLabel = Theme.label(leftGroup, "", 12, {
		Size = UDim2.fromOffset(0, 32),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = Colors.muted,
		LayoutOrder = 3,
	})

	-- right: status, history, panels, save, guide, close
	local rightGroup = Theme.make("Frame", {
		Name = "RightGroup",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 0),
		Size = UDim2.new(0, RIGHT_WIDTH - 12, 1, 0),
		BackgroundTransparency = 1,
	}, bar)
	local rightList = Theme.list(rightGroup, 6, true)
	rightList.VerticalAlignment = Enum.VerticalAlignment.Center
	rightList.HorizontalAlignment = Enum.HorizontalAlignment.Right
	local chip = Theme.button(rightGroup, "", {
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
		TextSize = 12,
		Font = Theme.FontBold,
	})
	Theme.corner(chip, 15)
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, chip)
	chip.Activated:Connect(function()
		-- show (or hide) the problem list on the board
		if problems then
			problems.expanded = not problems.expanded
			problems:show(problems.errors or {}, problems.summary or "")
		end
	end)
	statusChip = chip
	Theme.make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(6, 1), LayoutOrder = 2 }, rightGroup)
	textButton(rightGroup, "Undo", 3, function() if doc:undo() then refresh() end end)
	textButton(rightGroup, "Redo", 4, function() if doc:redo() then refresh() end end)
	textButton(rightGroup, "Runes", 5, function()
		panelState.leftOpen = not panelState.leftOpen
		relayout()
	end)
	textButton(rightGroup, "Info", 6, function()
		panelState.rightOpen = not panelState.rightOpen
		relayout()
	end)
	local save = Theme.button(rightGroup, "Save", { Size = UDim2.fromOffset(92, 32), LayoutOrder = 7, Font = Theme.FontBold })
	save.Activated:Connect(saveCard)
	saveButton = save
	iconButton(rightGroup, "?", 8, function()
		setHelpVisible(not (helpFrame and helpFrame.Visible))
	end)
	iconButton(rightGroup, "×", 9, function() SpellAssemblerGui.Close() end).TextSize = 22
end

-- The guide (? in the top bar): how spells work, the building blocks, how
-- they compose, and the controls. Each section: heading, then paragraphs.
local GUIDE: { { string } } = {
	{ "The idea",
		"Mana is energy. A Mana Well pushes it along the gold wires; every rune it passes shapes it, and a Vessel at the end turns it into magic. A cast costs the sum of your wells.",
		"Damage vessels (Orb, Bullet, Beam, Explosion, Smite) deal their energy as damage and need a Transform — Fire, Arcane or Shock — on the way.",
		"Every other vessel does exactly what its settings say — a 14 × 8 wall with 150 HP, a 110 studs/s shove, +60 HP — and the energy that reaches it pays for it. The estimate on the card shows what it costs; fed less, it does proportionally less (⚠ on the card).",
		"Every rune sits inside a zone of its colour. Pick a pen under Zones and drag on the board to draw one." },
	{ "Every setting is an input",
		"Each number or on/off setting is also a port, with its value shown beside it. Leave it unwired and it uses that value; wire anything into it and the wire decides — Barrier width from a Scan's count, Force speed from your distance to the target, a Repeat's count from your health. Wired values are kept within the setting's range.",
		"Coloured wires carry values: numbers (blue), true/false (pink), entities (orange), points and directions (green), lists of entities (tan). An entity works as a point (its position) or as a list of one." },
	{ "Where things go",
		"Placed vessels take a point: At for barriers, fields and blasts, To for Blink, From and Aim for projectiles (launch from anywhere, toward anything), Centre for Force. Unwired, they use your mouse, the current target or Here.",
		"Locate builds points around a body: 10 studs ahead along your level aim, 4 up, onto the ground. Offset, Point Math, Direction and Raycast do the rest.",
		"Barriers: Box, Dome, Sphere or Ring of any size, turned toward Face toward, tilted, anchored by base, centre or top, optionally following an entity. Lets through and Stops spells decide who walks and whose magic passes." },
	{ "Flow — when and where",
		"If sends all the energy one way; Divide splits it (A runs first, then B).",
		"Delay waits. Repeat runs what follows several times. For Each runs it once per entity of a list. Wait Until holds the energy until a condition is true — traps and mines.",
		"Conjure Circle opens a new circle somewhere else — above an impact, over your cursor, on the ground — and everything after it fires from there.",
		"Store and Recall are memory: a point, number, entity and list per slot — yours for the session, or private to one cast.",
		"Invoke casts the spell on one of your hotbar slots from here, handing it a point, entity and number (Given reads them): spells are functions you can call from other spells." },
	{ "Values and lists",
		"Sensors read the world at the moment their part of the circle runs; Logic and Vector runes compute with them.",
		"Filter keeps the entities of a list for which its condition holds, and Pick finds the one with the lowest or highest score. Both judge one entity at a time: wire their Item output into the runes that decide, and back into Keep / Score.",
		"Triggers and flow runes output what they saw: On Impact's Point, Surface and Struck, Repeat's Index, For Each's Entity, a conjured Circle's position. Wire them into anything that comes after them." },
	{ "Triggers",
		"Wire a vessel's Triggers port into On Impact, On Expire, On Timer or On Proximity. Each releases a share of the vessel's energy mid-flight or where it lands, and runs more of the circle from there. Barriers and Time Fields carry triggers too (On Expire fires when they break or fade)." },
	{ "Examples",
		"Dash: Caster → Force's Target, Locate's Forward → its Direction, Speed 110. Execute: Scan → Pick (Item → Health → Score) → Smite. Gravity Well: a Force pulling Toward the cursor for 2 s, then a blast there.",
		"Hunter's Sigil: Bullet → On Impact → Scan Area → If Count > 0 → Conjure Circle above the impact → For Each → Bullet.",
		"They're all in the Encyclopedia: equip one, press V outside the editor, and it opens here to take apart." },
	{ "Controls",
		"Right-drag: pan · Wheel: zoom · F: frame everything",
		"Drag a rune from the left onto a zone, or click it to drop it mid-board. Drag from a port to wire; drag a connected input to pick its wire up.",
		"Del: delete · Ctrl+D: duplicate · L: lock · Ctrl+Z / Ctrl+Y: undo / redo · Ctrl+S: save",
		"Double-click a zone's tab to move it with its runes; drag an edge or corner to resize.",
		"V (or the key set in Settings > Controls) edits your equipped spell and closes the editor again; so does ×." },
}

local function buildHelp(view: Frame)
	local frame = Theme.make("Frame", {
		Name = "Guide",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.72, 0.84),
		BackgroundColor3 = Colors.panel,
		BorderSizePixel = 0,
		Visible = false,
		Active = true,
		ZIndex = 30,
	}, view)
	Theme.corner(frame, 6)
	Theme.panel(frame)
	Theme.make("UISizeConstraint", { MaxSize = Vector2.new(660, 820), MinSize = Vector2.new(320, 240) }, frame)
	Theme.label(frame, "Spell circles · guide", 17, {
		Font = Theme.FontBold,
		Position = UDim2.fromOffset(18, 12),
		Size = UDim2.new(1, -70, 0, 26),
		ZIndex = 31,
	})
	local close = Theme.button(frame, "×", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 10),
		Size = UDim2.fromOffset(30, 30),
		TextSize = 22,
		ZIndex = 31,
	})
	close.Activated:Connect(function() setHelpVisible(false) end)
	local scroll = Theme.make("ScrollingFrame", {
		Position = UDim2.fromOffset(18, 48),
		Size = UDim2.new(1, -26, 1, -60),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Colors.line,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ZIndex = 31,
	}, frame)
	Theme.list(scroll, 6)
	Theme.make("UIPadding", { PaddingRight = UDim.new(0, 10), PaddingBottom = UDim.new(0, 12) }, scroll)
	local order = 0
	for sectionIndex, section in GUIDE do
		for index, text in section do
			order += 1
			local heading = index == 1
			local label = Theme.label(scroll, if heading then string.upper(text) else text, if heading then 12 else 13, {
				Font = if heading then Theme.FontBold else Theme.Font,
				TextColor3 = if heading then Colors.accent else Colors.text,
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.None,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				LayoutOrder = order,
				ZIndex = 32,
			})
			if heading and sectionIndex > 1 then
				Theme.make("UIPadding", { PaddingTop = UDim.new(0, 10) }, label)
			end
		end
	end
	helpFrame = frame
	board:addOverlay(frame)
end

local function buildBoardOverlays(view: Frame)
	local label = Theme.label(view, "", 13, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Colors.panel,
		Font = Theme.FontMedium,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		ZIndex = 20,
	})
	Theme.corner(label)
	Theme.panel(label)
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
	Theme.corner(zoom)
	Theme.panel(zoom)
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
	buildHelp(view)
end

-- Holographic boot-up: the editor projects open. It sits in a clipping
-- "aperture" that first draws as a thin cyan line across the middle of the
-- screen, then opens up and down to full height between two glowing edges,
-- revealing the editor (held still at full size, so nothing squashes) while
-- its glass fades in. Closing mid-way just snaps it to the end.
local BOOT_DRAW, BOOT_OPEN, BOOT_EDGE_FADE = 0.12, 0.34, 0.25
local aperture: Frame? = nil
local apertureEdges: { Frame } = {}
local bootTweens: { Tween } = {}
local blurEffect: BlurEffect? = nil
local blurSize = 8

local function finishBoot()
	for _, tween in bootTweens do
		tween:Cancel()
	end
	table.clear(bootTweens)
	if aperture then
		aperture.Size = UDim2.fromScale(1, 1)
	end
	if root then
		root.Size = UDim2.fromScale(1, 1)
	end
	for _, edge in apertureEdges do
		edge.Visible = false
	end
end

local function bootTween(object: Instance, seconds: number, goal: { [string]: any }, style: Enum.EasingStyle?): Tween
	local tween = TweenService:Create(object, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
	table.insert(bootTweens, tween)
	tween:Play()
	return tween
end

local function bootUp()
	local frame, editor, screen = aperture, root, gui
	if not frame or not editor or not screen then
		return
	end
	finishBoot()
	local size = screen.AbsoluteSize
	editor.Size = UDim2.fromOffset(size.X, size.Y)
	frame.Size = UDim2.new(0, 0, 0, 2)
	for _, edge in apertureEdges do
		edge.Visible = true
		edge.BackgroundTransparency = 0
	end
	Theme.FadeInGlass(BOOT_DRAW + BOOT_OPEN)
	bootTween(frame, BOOT_DRAW, { Size = UDim2.new(1, 0, 0, 2) }).Completed:Once(function(drawn)
		if drawn ~= Enum.PlaybackState.Completed then
			return
		end
		bootTween(frame, BOOT_OPEN, { Size = UDim2.fromScale(1, 1) }, Enum.EasingStyle.Quart).Completed:Once(function(opened)
			if opened ~= Enum.PlaybackState.Completed then
				return
			end
			editor.Size = UDim2.fromScale(1, 1) -- (follows the screen again)
			for _, edge in apertureEdges do
				bootTween(edge, BOOT_EDGE_FADE, { BackgroundTransparency = 1 }).Completed:Once(function(faded)
					if faded == Enum.PlaybackState.Completed then
						edge.Visible = false
					end
				end)
			end
		end)
	end)
end

-- The world behind the glass blurs while the editor is open (Lighting
-- blurs the 3D world only, never the GUI).
local BLUR_IN, BLUR_OUT = 0.3, 0.15

local function setBlur(on: boolean)
	local effect = blurEffect
	if not effect or not effect.Parent then
		local created = Instance.new("BlurEffect")
		created.Name = "SpellEditorBlur"
		created.Size = 0
		created.Enabled = false
		created.Parent = Lighting
		blurEffect = created
		effect = created
	end
	local target = if on then blurSize else 0
	local blur = effect :: BlurEffect
	if on and target > 0 then
		blur.Enabled = true
	end
	local tween = TweenService:Create(blur, TweenInfo.new(if on then BLUR_IN else BLUR_OUT), { Size = target })
	tween:Play()
	if target <= 0 then
		tween.Completed:Once(function()
			if blur.Size <= 0 then
				blur.Enabled = false
			end
		end)
	end
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

	-- (see bootUp)
	local opening = Theme.make("Frame", {
		Name = "Aperture",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
	}, screen)
	aperture = opening
	for _, bottom in { false, true } do
		table.insert(apertureEdges, Theme.fadeLine(opening, {
			Name = if bottom then "BottomEdge" else "TopEdge",
			AnchorPoint = Vector2.new(0, if bottom then 1 else 0),
			Position = UDim2.fromScale(0, if bottom then 1 else 0),
			Size = UDim2.new(1, 0, 0, 2),
			BackgroundTransparency = 0,
			Visible = false,
			ZIndex = 200,
		}))
	end
	local editor = Theme.make("Frame", {
		Name = "Editor",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Colors.background,
		BorderSizePixel = 0,
		Active = true, -- keeps clicks/wheel away from the camera
		Visible = false,
	}, opening)
	Theme.glass(editor, "backdrop")
	-- keep clear of Roblox's own top bar (it swallows clicks there); its
	-- height is only known once the CoreGui has laid it out
	local inset = Theme.make("UIPadding", {}, editor)
	local function fitInset()
		inset.PaddingTop = UDim.new(0, math.max(GuiService:GetGuiInset().Y, GuiService.TopbarInset.Height))
	end
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(fitInset)
	fitInset()
	root = editor
	buildTopBar(editor)

	local row = Theme.make("Frame", { Name = "Body", Position = UDim2.fromOffset(0, TOP_BAR), Size = UDim2.new(1, 0, 1, -TOP_BAR), BackgroundTransparency = 1 }, editor)
	toolboxFrame = Theme.make("Frame", { Name = "Toolbox", BackgroundColor3 = Colors.panel, BorderSizePixel = 0 }, row)
	inspectorFrame = Theme.make("Frame", { Name = "Inspector", BackgroundColor3 = Colors.panel, BorderSizePixel = 0 }, row)
	Theme.panel(toolboxFrame :: Frame)
	Theme.panel(inspectorFrame :: Frame)
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
	local edit = Theme.button(compact, "Edit [V]", { Position = UDim2.new(1, -134, 0, 9), Size = UDim2.fromOffset(70, 36) })
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
			if helpFrame and helpFrame.Visible then
				setHelpVisible(false)
				return
			end
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
	bootUp()
	setBlur(true)
	openEvent:Fire(true)
end

function SpellAssemblerGui.Close()
	if not gui then return end
	if visible then
		finishBoot()
		setBlur(false)
		openEvent:Fire(false)
	end
	visible = false
	placing, resizing = nil, nil
	if ghost then ghost.Visible = false end
	if board then board:setCursor("") end
	ContextActionService:UnbindAction(SINK_ACTION);
	(root :: Frame).Visible = false;
	(hud :: Frame).Visible = compactEnabled and canCast()
	updateTopBar()
end

-- The look the player chose (Settings: "Spell editor opacity" %, "Spell
-- editor background blur"). Applies live, even while the editor is open.
function SpellAssemblerGui.SetAppearance(opacityPercent: number, blur: number)
	Theme.SetOpacity(opacityPercent / 100)
	blurSize = math.clamp(blur, 0, 56)
	if visible then
		setBlur(true)
	end
end

-- The editor key: closes the editor, or edits the equipped spell.
function SpellAssemblerGui.ToggleEditor()
	if visible then
		SpellAssemblerGui.Close()
	else
		SpellAssemblerGui.EditEquipped()
	end
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

-- The LocalPlayer's "Casting" attribute mirrors charging / channelling, for
-- place scripts (MainGui.Animation faces the mouse only while it's set).
local function syncCasting()
	local casting = charging or holdingCast
	if player:GetAttribute("Casting") ~= casting then
		player:SetAttribute("Casting", casting)
	end
end
-- The active card compiled once, with its circle spec: the same
-- SpellCircleLayout.Build the server broadcasts, so the caster's own circle
-- draws instantly and matches what everyone else sees.
local activeCache: { record: any, compiled: any, spec: any, sustain: boolean } = { record = nil, compiled = nil, spec = nil, sustain = false }

local function refreshActive()
	local slot = SpellAssemblerGui.GetSelectedSlot()
	local record = slot and slotRecord(slot)
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
	local function placeChargeBar()
		frame.Position = UDim2.new(0.5, 0, 1, if player:GetAttribute("UiMode") == "Mode3" then -206 else -170)
	end
	player:GetAttributeChangedSignal("UiMode"):Connect(placeChargeBar)
	placeChargeBar()
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
	syncCasting()
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
	if selectionPending or SpellAssemblerGui.GetCooldownRemaining() > 0 or not canCast() or visible or holdingCast or charging then return end
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
		if not compiled or (not SpellSettings.InfiniteMana() and (typeof(mana) ~= "number" or mana < compiled.manaCost)) then
			manaShortEvent:Fire(if compiled then compiled.manaCost else 0)
			return
		end
		charging = true
		syncCasting()
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
	syncCasting()
	sendCast(mouse.Hit.Position)
	local character = player.Character
	if character and activeCache.spec then
		local compiled = activeCache.compiled
		SpellCircleVFX.Cast(character, activeCache.spec, 1, mouse.Hit.Position, true, true)
		-- (after Cast, so the glint follows the sustained circle)
		if compiled then SpellCircleVFX.PlayGlint(character, compiled.manaCost, mouse.Hit.Position) end
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
	cooldownDeadlines[frozenSlot] = workspace:GetServerTimeNow() + SpellSettings.GetCooldown()
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
			if compiled and charge > 1 and not SpellSettings.InfiniteMana() and typeof(mana) == "number"
				and mana < compiled.manaCost * (SpellRunes.ChargeEnergyMultiplier(charge) - 1) then
				charge = 1
			end
			SpellCircleVFX.Cast(character, activeCache.spec, charge, target, false, true)
		end
		return
	end
	if not holdingCast then return end
	holdingCast = false
	syncCasting()
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
	acceptServerResult(result)
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
	acceptServerResult(result)
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
		frameSoon()
	end
	savedSignature = signature()
	setStatus(`Editing "{spell.name}" from your library.`)
	refresh()
end

-- Opens the editor on a fresh circle (or a copy of `graph`); Save adds it to
-- the library.
function SpellAssemblerGui.NewLibrarySpell(graph: any?, name: string?)
	SpellAssemblerGui.Open()
	libraryMode, editingSpellId = true, nil
	newSpell()
	if graph then
		doc:load(graph)
		if nameBox then nameBox.Text = name or "" end
		if board then
			board.selection = nil
			frameSoon()
		end
		refresh()
		setStatus(`Editing a copy of "{name or "spell"}": Save adds it to your library.`)
	else
		setStatus("New spell: Save adds it to your library.")
	end
end

-- What E opens: the equipped spell (a library spell in place, an
-- Encyclopedia one as a copy), else a new spell. Unsaved edits to something
-- else reopen instead; pressing E again within a few seconds switches anyway.
function SpellAssemblerGui.EditEquipped()
	local slot = serverState.activeSlot
	local record = slot and slotRecord(slot)
	local ref = record and record.ref
	local id = if typeof(ref) == "string" and string.sub(ref, 1, 2) == "c:" then string.sub(ref, 3) else nil
	local target = if typeof(ref) == "string" then ref else "new"
	local editingSame = libraryMode and id ~= nil and editingSpellId == id
	-- (edited since it was loaded, and not saved since)
	local dirty = #doc.undoStack > 0 and savedSignature ~= signature()
	local armed = discardArmed ~= nil and discardArmed.id == target and os.clock() < discardArmed.until_
	if editingSame or (dirty and not armed) then
		SpellAssemblerGui.Open()
		if dirty and not editingSame then
			discardArmed = { until_ = os.clock() + 6, id = target }
			local what = if record then `edit "{record.name}"` else "start a new spell"
			setStatus(`Unsaved changes here. Save them (Ctrl+S), or close and press E again to {what} anyway.`, false, true)
		end
		return
	end
	discardArmed = nil
	if id then
		SpellAssemblerGui.EditSpell(id)
	elseif record and record.graph then
		SpellAssemblerGui.NewLibrarySpell(record.graph, record.name)
	elseif libraryMode and not editingSpellId and #doc.graph.runes > 0 then
		SpellAssemblerGui.Open() -- (already on a new spell)
	else
		SpellAssemblerGui.NewLibrarySpell()
	end
end

-- The Library button opens the spell library (SpellLibrary requires this
-- module, so it's handed in: UiMode).
function SpellAssemblerGui.SetLibraryOpener(open: () -> ())
	libraryOpener = open
end

function SpellAssemblerGui.GetSelectedSlot(): number?
	if selectionPending then return pendingActiveSlot end
	return serverState.activeSlot
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

-- Spells don't cast while paused (GameHud's items hotbar is showing).
function SpellAssemblerGui.SetCastingPaused(paused: boolean)
	if castingPaused == paused then return end
	castingPaused = paused
	if paused then SpellAssemblerGui.CancelCast() end
end

function SpellAssemblerGui.SetToolRequired(required: boolean)
	if toolRequired == required then return end
	toolRequired = required
	if not canCast() then SpellAssemblerGui.CancelCast() end
	-- (Close refreshes the compact HUD's visibility from canCast)
	if gui and (not visible or not canCast()) then SpellAssemblerGui.Close() end
end

function SpellAssemblerGui.SelectSlot(slot: number)
	if loadingCards then return end
	if not slotRecord(slot) then
		loadSlot(slot)
		SpellAssemblerGui.Open()
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then humanoid:UnequipTools() end
	if SpellAssemblerGui.GetSelectedSlot() == slot then
		-- selecting the selected spell again deselects it
		deselectSlot()
		return
	end
	equipSlot(slot)
	SpellAssemblerGui.Close()
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
