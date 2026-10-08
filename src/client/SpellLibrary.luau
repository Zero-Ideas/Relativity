--!strict
--[[
	The Spells window (ReGui; the topbar's Spells button), with three tabs.
	Each starts with the hotbar: 5 boxes showing the equipped spells'
	circles with their names below.

	  Loadout      -- the hotbar, and saved loadouts (save the current hotbar
	                  under a name, load or delete one).
	  Library      -- search (Enter), New spell, New folder; your spells in
	                  folder dropdowns (Edit, Share, Copy, Delete; with a
	                  spell picked, "Move here" files it), and below them the
	                  Encyclopedia spells you own, in element dropdowns.
	  Encyclopedia -- every element and premade spell, by element, with
	                  prices (buying isn't available yet; free ones are yours).

	Equipping: click a spell (its circle or name) to pick it up, then a box
	to put it there -- a spell sits in one box at most (equipping it again
	moves it). Clicking a box with nothing picked up picks up that box; a
	second box then swaps the two (the same box again drops it).

	A spell's circle also shows bigger in a preview panel beside the window
	when picked; it closes with the window. Shared spells arrive as
	notifications (Accept adds a copy to your library).

	The window is built once, hidden on close, and updated in place.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SpellCompiler = require(Shared:WaitForChild("SpellCompiler"))
local SpellRunes = require(Shared:WaitForChild("SpellRunes"))
local Encyclopedia = require(Shared:WaitForChild("SpellEncyclopedia"))

local ReGuiLoader = require(script.Parent.ReGuiLoader)
local ReGuiLive = require(script.Parent.ReGuiLive)
local SpellEditor = require(script.Parent.SpellAssemblerGui)
local SpellCardPreview = require(script.Parent.SpellCardPreview)
local Notifications = require(script.Parent.Notifications)

local player = Players.LocalPlayer
local shareRemote = ReplicatedStorage:WaitForChild("SpellRemotes"):WaitForChild("SpellShare") :: RemoteEvent

local SLOT_COUNT = 5
local BOX_W, BOX_H, BOX_GAP = 76, 96, 8
local ICON = 40 -- a spell's circle beside its name

local SpellLibrary = {}

local open = false
local window: any = nil
local geometry: { position: UDim2, size: UDim2 }? = nil
local activeTab = "Library"

-- what you've picked up: a spell (to equip) or a hotbar box (to swap)
type Held = { kind: "spell", ref: string, name: string, id: string? } | { kind: "slot", slot: number }
local held: Held? = nil

-- per-window UI state, kept across updates
local search = ""
local message = ""
local sharing: { id: string, name: string }? = nil
local confirmDelete: string? = nil
local confirmFolder: string? = nil

--------------------------------------------------------------------------------
-- Spell info
--------------------------------------------------------------------------------

-- (mana cost and element per graph; graphs are replaced, never edited, so
-- caching by table is safe)
local infoCache: { [any]: { mana: number?, element: string } } = setmetatable({}, { __mode = "k" }) :: any

local function infoOf(graph: any): { mana: number?, element: string }
	if typeof(graph) ~= "table" then
		return { mana = nil, element = "?" }
	end
	local cached = infoCache[graph]
	if cached then
		return cached
	end
	local compiled = SpellCompiler.Compile(graph)
	local elements = {}
	for _, rune in graph.runes or {} do
		if SpellRunes.Elements[rune.rune] and not table.find(elements, rune.rune) then
			table.insert(elements, rune.rune)
		end
	end
	cached = {
		mana = if compiled then compiled.manaCost else nil,
		element = if #elements > 0 then table.concat(elements, "/") else "None",
	}
	infoCache[graph] = cached
	return cached
end

local function describe(graph: any): string
	local info = infoOf(graph)
	return `{if info.mana then math.floor(info.mana + 0.5) else "?"} mana · {info.element}`
end

local function matches(name: string): boolean
	return search == "" or string.find(name:lower(), search:lower(), 1, true) ~= nil
end

local function slotOf(state: any, ref: string): number?
	for slot = 1, SLOT_COUNT do
		local record = state.slots and state.slots[tostring(slot)]
		if record and record.ref == ref then
			return slot
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Preview panel (a bigger circle of the spell picked up)
--------------------------------------------------------------------------------

local previewGui: ScreenGui? = nil
local previewTitle: TextLabel? = nil
local previewInfo: TextLabel? = nil
local preview: any = nil

local function closePreview()
	if previewGui then
		previewGui.Enabled = false
	end
end

local function showPreview(name: string, graph: any)
	if not previewGui then
		local screen = Instance.new("ScreenGui")
		screen.Name = "SpellPreview"
		screen.ResetOnSpawn = false
		screen.DisplayOrder = 30
		local panel = Instance.new("Frame")
		panel.Name = "Panel"
		panel.AnchorPoint = Vector2.new(1, 0)
		panel.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
		panel.BackgroundTransparency = 0.1
		panel.Size = UDim2.fromOffset(280, 330)
		panel.Parent = screen
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = panel
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(90, 90, 110)
		stroke.Parent = panel
		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Position = UDim2.fromOffset(12, 8)
		title.Size = UDim2.new(1, -48, 0, 20)
		title.Font = Enum.Font.GothamBold
		title.TextSize = 15
		title.TextColor3 = Color3.new(1, 1, 1)
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.Parent = panel
		local info = title:Clone()
		info.Position = UDim2.fromOffset(12, 28)
		info.Font = Enum.Font.Gotham
		info.TextSize = 12
		info.TextColor3 = Color3.fromRGB(180, 180, 195)
		info.Parent = panel
		local close = Instance.new("TextButton")
		close.AnchorPoint = Vector2.new(1, 0)
		close.BackgroundTransparency = 1
		close.Position = UDim2.new(1, -6, 0, 6)
		close.Size = UDim2.fromOffset(24, 24)
		close.Font = Enum.Font.GothamBold
		close.Text = "X"
		close.TextSize = 14
		close.TextColor3 = Color3.fromRGB(220, 220, 230)
		close.Parent = panel
		close.Activated:Connect(closePreview)
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Position = UDim2.fromOffset(10, 50)
		holder.Size = UDim2.new(1, -20, 1, -60)
		holder.Parent = panel
		preview = SpellCardPreview.new(holder)
		preview.Frame.Size = UDim2.fromScale(1, 1)
		preview.Frame.Position = UDim2.fromScale(0.5, 0.5)
		screen.Parent = player:WaitForChild("PlayerGui")
		previewGui, previewTitle, previewInfo = screen, title, info
	end
	local panel = (previewGui :: ScreenGui):FindFirstChild("Panel") :: Frame
	-- (beside the Spells window, on its left)
	if window then
		local frame = window.WindowFrame
		panel.Position = UDim2.fromOffset(frame.AbsolutePosition.X - 8, frame.AbsolutePosition.Y)
	else
		panel.Position = UDim2.new(1, -600, 0, 70)
	end
	(previewTitle :: TextLabel).Text = name;
	(previewInfo :: TextLabel).Text = describe(graph)
	preview:SetGraph(graph);
	(previewGui :: ScreenGui).Enabled = true
end

--------------------------------------------------------------------------------
-- Commands, picking up
--------------------------------------------------------------------------------

local update: () -> ()

local function run(action: string, payload: any?)
	task.spawn(function()
		local result = SpellEditor.Command(action, payload)
		message = result.message or (if result.ok then "" else "That didn't work.")
		update()
	end)
end

local function pickSpell(ref: string, name: string, graph: any, id: string?)
	if held and held.kind == "spell" and held.ref == ref then
		held = nil
		closePreview()
	else
		held = { kind = "spell", ref = ref, name = name, id = id }
		showPreview(name, graph)
	end
	message = ""
	update()
end

local function clickBox(slot: number)
	local state = SpellEditor.GetState()
	local current = held
	if current and current.kind == "spell" then
		held = nil
		run("Equip", { slot = slot, ref = current.ref })
	elseif current and current.kind == "slot" then
		held = nil
		if current.slot ~= slot then
			run("SwapSlots", { slot = current.slot, other = slot })
		else
			update()
		end
	elseif state.slots and state.slots[tostring(slot)] then
		held = { kind = "slot", slot = slot }
		message = ""
		update()
	end
end

--------------------------------------------------------------------------------
-- Hotbar boxes (custom frames inside the window, updated in place)
--------------------------------------------------------------------------------

type Box = { frame: Frame, stroke: UIStroke, name: TextLabel, preview: any }
type Bar = { boxes: { Box } }
local bars: { Bar } = {}

-- An empty ReGui label used as a host for custom frames of a given height.
local function host(canvas: any, height: number): Instance
	local label = canvas:Label({ Text = "" })
	pcall(function()
		label.AutomaticSize = Enum.AutomaticSize.None
		label.Size = UDim2.new(1, 0, 0, height)
	end)
	return label
end

local function buildBar(canvas: any): Bar
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 1, 0)
	row.Parent = host(canvas, BOX_H + 6)
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, BOX_GAP)
	layout.Parent = row
	local bar: Bar = { boxes = {} }
	for slot = 1, SLOT_COUNT do
		local frame = Instance.new("TextButton")
		frame.Name = "Box" .. slot
		frame.AutoButtonColor = false
		frame.Text = ""
		frame.LayoutOrder = slot
		frame.BackgroundColor3 = Color3.fromRGB(14, 14, 20)
		frame.Size = UDim2.fromOffset(BOX_W, BOX_H)
		frame.Parent = row
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = frame
		local stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Thickness = 1.5
		stroke.Parent = frame
		local key = Instance.new("TextLabel")
		key.BackgroundTransparency = 1
		key.Position = UDim2.fromOffset(4, 2)
		key.Size = UDim2.fromOffset(12, 12)
		key.Font = Enum.Font.GothamBold
		key.Text = tostring(slot)
		key.TextSize = 11
		key.TextColor3 = Color3.fromRGB(170, 170, 180)
		key.ZIndex = 8
		key.Parent = frame
		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.AnchorPoint = Vector2.new(0.5, 1)
		name.Position = UDim2.new(0.5, 0, 1, -3)
		name.Size = UDim2.new(1, -6, 0, 14)
		name.Font = Enum.Font.GothamBold
		name.TextSize = 11
		name.TextColor3 = Color3.fromRGB(235, 235, 240)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.ZIndex = 8
		name.Parent = frame
		local circle = SpellCardPreview.new(frame)
		frame.Activated:Connect(function()
			clickBox(slot)
		end)
		bar.boxes[slot] = { frame = frame, stroke = stroke, name = name, preview = circle }
	end
	table.insert(bars, bar)
	return bar
end

local function updateBars(state: any)
	for _, bar in bars do
		for slot, box in bar.boxes do
			local record = state.slots and state.slots[tostring(slot)]
			box.preview:SetGraph(if record and not record.invalid then record.graph else nil)
			box.name.Text = if record then record.name else "Empty"
			box.name.TextColor3 = if record then Color3.fromRGB(235, 235, 240) else Color3.fromRGB(120, 120, 130)
			local pickedBox = held and held.kind == "slot" and held.slot == slot
			local target = held ~= nil and not pickedBox
			box.stroke.Color = if pickedBox then Color3.new(1, 1, 1)
				elseif target then Color3.fromRGB(120, 170, 255)
				elseif state.activeSlot == slot then Color3.fromRGB(200, 200, 210)
				else Color3.fromRGB(70, 70, 82)
			box.stroke.Thickness = if pickedBox then 2.5 elseif target then 2 else 1.5
		end
	end
end

-- A spell's circle (clickable) for a list row.
local rowIcons: { [Instance]: any } = setmetatable({}, { __mode = "k" }) :: any
local function rowIcon(row: any, graph: any, onClick: () -> ())
	local label = row:Label({ Text = "" })
	pcall(function()
		label.AutomaticSize = Enum.AutomaticSize.None
		label.Size = UDim2.fromOffset(ICON, ICON)
	end)
	local retained = rowIcons[label]
	if retained then
		retained.onClick = onClick
		retained.circle:SetGraph(graph)
		return
	end
	local circle = SpellCardPreview.new(label)
	circle.Frame.Size = UDim2.fromScale(1, 1)
	circle.Frame.Position = UDim2.fromScale(0.5, 0.5)
	circle:SetGraph(graph)
	local button = Instance.new("TextButton")
	button.BackgroundTransparency = 1
	button.Text = ""
	button.Size = UDim2.fromScale(1, 1)
	button.ZIndex = 9
	button.Parent = label
	retained = { circle = circle, onClick = onClick }
	rowIcons[label] = retained
	button.Activated:Connect(function() retained.onClick() end)
	label.Destroying:Connect(function() circle:Destroy(); rowIcons[label] = nil end)
end

--------------------------------------------------------------------------------
-- Sections
--------------------------------------------------------------------------------

local sections: { [string]: ReGuiLive.Section } = {}

local function heldText(): string
	if not held then
		return "Click a spell, then a box to equip it. Click a box, then another, to swap them."
	elseif held.kind == "spell" then
		return `Picked "{held.name}": click a box to equip it (or the spell again to drop it).`
	end
	return `Picked box {held.slot}: click another box to swap (or the same one to drop it).`
end

local function renderStatus(section: ReGuiLive.Section, state: any)
	section:Render(ReGuiLive.Key({ message, heldText(), state.available, state.error }), function(canvas)
		if state.available == false then
			canvas:Label({ Text = state.error or "Spells aren't available right now." })
		end
		local hint = canvas:Label({ Text = heldText() })
		pcall(function()
			hint.TextWrapped = true
			hint.AutomaticSize = Enum.AutomaticSize.Y
			hint.Size = UDim2.new(1, 0, 0, 0)
		end)
		if held and held.kind == "slot" then
			local slot = held.slot
			canvas:SmallButton({
				Text = `Take box {slot} off the hotbar`,
				Callback = function()
					held = nil
					run("DeleteCard", { slot = slot })
				end,
			})
		end
		if message ~= "" then
			canvas:Label({ Text = message })
		end
	end)
end

local function heldRef(): string?
	return if held and held.kind == "spell" then held.ref else nil
end

local function slotRefs(state: any): { string }
	local refs = {}
	for slot = 1, SLOT_COUNT do
		local record = state.slots and state.slots[tostring(slot)]
		refs[slot] = if record then record.ref else ""
	end
	return refs
end

local function renderLoadouts(section: ReGuiLive.Section, state: any)
	local names = {}
	for _, spell in state.library or {} do
		names[spell.id] = spell.name
	end
	section:Render(ReGuiLive.Key({ state.loadouts or {}, names }), function(canvas)
		local loadouts = state.loadouts or {}
		if #loadouts == 0 then
			canvas:Label({ Text = "None saved yet." })
		end
		for _, saved in loadouts do
			local list = {}
			for slot = 1, SLOT_COUNT do
				local ref = saved.slots and saved.slots[tostring(slot)]
				if ref then
					local kind, id = string.sub(ref, 1, 1), string.sub(ref, 3)
					local spell = if kind == "e" then Encyclopedia.Get(id) else nil
					table.insert(list, if spell then spell.Name else (names[id] or "?"))
				end
			end
			local row = canvas:Row({ LiveKey = "loadout:" .. saved.name })
			row:Label({ Text = `{saved.name} ({#list})` })
			row:SmallButton({ Text = "Load", Callback = function() run("LoadLoadout", { name = saved.name }) end })
			row:SmallButton({ Text = "Delete", Callback = function() run("DeleteLoadout", { name = saved.name }) end })
			if #list > 0 then
				canvas:Label({ Text = "    " .. table.concat(list, ", ") })
			end
		end
	end)
end

local function renderSharing(section: ReGuiLive.Section)
	local others = {}
	for _, other in Players:GetPlayers() do
		if other ~= player then
			table.insert(others, other.UserId)
		end
	end
	section:Render(ReGuiLive.Key({ sharing or false, others }), function(canvas)
		local share = sharing
		if not share then
			return
		end
		canvas:Separator({ Text = `Share "{share.name}" with` })
		local row = canvas:Row()
		local anyone = false
		for _, other in Players:GetPlayers() do
			if other ~= player then
				anyone = true
				row:SmallButton({
					Text = other.DisplayName,
					Callback = function()
						sharing = nil
						run("ShareSpell", { id = share.id, target = other })
					end,
				})
			end
		end
		if not anyone then
			row:Label({ Text = "No one else is here." })
		end
		row:SmallButton({ Text = "Cancel", Callback = function() sharing = nil; update() end })
	end)
end

-- One of your spells: circle, name (pick up), info, and its buttons.
local function spellRow(parent: any, state: any, spell: any)
	local canvas = parent:Group({ LiveKey = "spell:" .. spell.id })
	local ref = "c:" .. spell.id
	local picked = heldRef() == ref
	local row = canvas:Row()
	if not spell.invalid then
		rowIcon(row, spell.graph, function() pickSpell(ref, spell.name, spell.graph, spell.id) end)
	end
	row:SmallButton({
		Text = (if picked then "▶ " else "") .. spell.name,
		Callback = function()
			if not spell.invalid then
				pickSpell(ref, spell.name, spell.graph, spell.id)
			end
		end,
	})
	local slot = slotOf(state, ref)
	row:Label({ Text = (if spell.invalid then "doesn't compile" else describe(spell.graph)) .. (if slot then ` · box {slot}` else "") })
	local actions = canvas:Row()
	actions:SmallButton({ Text = "Edit", Callback = function() SpellEditor.EditSpell(spell.id) end })
	if not spell.invalid then
		actions:SmallButton({
			Text = "Share",
			Callback = function()
				sharing = { id = spell.id, name = spell.name }
				update()
			end,
		})
		actions:SmallButton({
			Text = "Copy",
			Callback = function()
				run("SaveSpell", { name = string.sub(spell.name, 1, 19) .. " copy", graph = spell.graph })
			end,
		})
	end
	actions:SmallButton({
		Text = if confirmDelete == spell.id then "Confirm delete" else "Delete",
		Callback = function()
			if confirmDelete == spell.id then
				confirmDelete = nil
				run("DeleteSpell", { id = spell.id })
			else
				confirmDelete = spell.id
				update()
			end
		end,
	})
end

local function renderMySpells(section: ReGuiLive.Section, state: any)
	local summary = {}
	for _, spell in state.library or {} do
		table.insert(summary, { spell.id, spell.name, spell.folder or "", spell.savedAt or 0, spell.invalid or false })
	end
	local key = ReGuiLive.Key({ summary, state.folders or {}, search, heldRef() or "", held and held.kind == "spell" and held.id or "",
		confirmDelete or "", confirmFolder or "", slotRefs(state) })
	section:Render(key, function(canvas)
		local library = state.library or {}
		local folders = state.folders or {}
		local pickedId = if held and held.kind == "spell" then held.id else nil
		local pickedFolder: string? = nil
		local byFolder: { [string]: { any } } = {}
		local unfiled = {}
		for _, spell in library do
			if spell.id == pickedId then
				pickedFolder = spell.folder
			end
			if not matches(spell.name) then
				continue
			end
			if spell.folder and table.find(folders, spell.folder) then
				byFolder[spell.folder] = byFolder[spell.folder] or {}
				table.insert(byFolder[spell.folder], spell)
			else
				table.insert(unfiled, spell)
			end
		end
		canvas:Separator({ Text = `My spells ({#library})` })
		if #library == 0 then
			canvas:Label({ Text = "No spells yet: + New spell, or pick one from the Encyclopedia below." })
		end
		local function moveHere(target: any, folder: string?)
			if pickedId and pickedFolder ~= folder then
				local id = pickedId
				target:SmallButton({
					Text = `Move picked spell here`,
					Callback = function()
						held = nil
						run("MoveToFolder", { id = id, folder = folder })
					end,
				})
			end
		end
		for _, folder in folders do
			local spells = byFolder[folder] or {}
			if search ~= "" and #spells == 0 then
				continue
			end
			local inner = section:Header(canvas, "folder:" .. folder, { Title = `{folder} ({#spells})`, Collapsed = search == "" })
			local tools = inner:Row()
			moveHere(tools, folder)
			tools:SmallButton({
				Text = if confirmFolder == folder then "Confirm delete folder" else "Delete folder",
				Callback = function()
					if confirmFolder == folder then
						confirmFolder = nil
						run("DeleteFolder", { name = folder })
					else
						confirmFolder = folder
						update()
					end
				end,
			})
			for _, spell in spells do
				spellRow(inner, state, spell)
			end
		end
		local unfiledCanvas = section:Header(canvas, "unfiled", { Title = `Unfiled ({#unfiled})`, Collapsed = false })
		moveHere(unfiledCanvas, nil)
		for _, spell in unfiled do
			spellRow(unfiledCanvas, state, spell)
		end
		if search ~= "" and #unfiled == 0 and next(byFolder) == nil then
			canvas:Label({ Text = "None match." })
		end
	end)
end

-- Encyclopedia spells by element (only owned ones when `ownedOnly`).
local function renderEncyclopedia(section: ReGuiLive.Section, state: any, ownedOnly: boolean, withSearch: boolean)
	local key = ReGuiLive.Key({ state.owned or {}, if withSearch then search else "", heldRef() or "", slotRefs(state) })
	section:Render(key, function(canvas)
		if ownedOnly then
			canvas:Separator({ Text = "Encyclopedia spells" })
		end
		local any = false
		for _, element in Encyclopedia.Elements do
			local spells = {}
			for _, spell in Encyclopedia.Spells do
				local owned = Encyclopedia.IsOwned(spell.Id, state.owned)
				if spell.Element == element.Id and (owned or not ownedOnly) and (not withSearch or matches(spell.Name)) then
					table.insert(spells, spell)
				end
			end
			if #spells == 0 then
				continue
			end
			any = true
			local id = (if ownedOnly then "lib:" else "enc:") .. element.Id
			local inner = section:Header(canvas, id, {
				Title = `{element.Name} ({#spells})`,
				Collapsed = not withSearch or search == "",
			})
			if not ownedOnly then
				inner:Label({ Text = `{element.Description}  ({if element.Price <= 0 then "free" else tostring(element.Price)})` })
			end
			for _, spell in spells do
				local ref = "e:" .. spell.Id
				local owned = Encyclopedia.IsOwned(spell.Id, state.owned)
				local row = inner:Row({ LiveKey = "spell:" .. spell.Id })
				rowIcon(row, spell.Graph, function()
					if owned then pickSpell(ref, spell.Name, spell.Graph) else showPreview(spell.Name, spell.Graph) end
				end)
				row:SmallButton({
					Text = (if heldRef() == ref then "▶ " else "") .. spell.Name,
					Callback = function()
						if owned then pickSpell(ref, spell.Name, spell.Graph) else showPreview(spell.Name, spell.Graph) end
					end,
				})
				local slot = slotOf(state, ref)
				row:Label({
					Text = describe(spell.Graph) .. (if slot then ` · box {slot}` else "")
						.. (if ownedOnly then "" elseif owned then " · owned" else ` · {spell.Price}`),
				})
				if not owned then
					row:SmallButton({ Text = "Purchase", Callback = function() run("Purchase", { id = spell.Id }) end })
				end
				if not ownedOnly then
					inner:Label({ Text = "    " .. spell.Description })
				end
			end
		end
		if not any then
			canvas:Label({ Text = "None match." })
		end
	end)
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local function captureState()
	if not window then
		return
	end
	local frame = window.WindowFrame
	geometry = { position = frame.Position, size = frame.Size }
	local selector = window.WindowTabSelector
	if selector then
		for _, entry in selector.Tabs do
			if entry.IsSelected then
				activeTab = entry.Name
			end
		end
	end
end

local function hideWindow()
	captureState()
	if window then
		window:SetVisible(false)
	end
end

-- Builds the window and its static parts once; update() fills the rest.
local function build(ReGui: any)
	if window then window:SetVisible(true); return end
	local created: any
	created = ReGui:TabsWindow({
		Title = "Spells",
		Size = if geometry then geometry.size else UDim2.fromOffset(600, 520),
		NoCollapse = true,
		NoWindowRegistor = true,
		CloseCallback = function()
			hideWindow()
			open = false
			held = nil
			closePreview()
			return false
		end,
	})
	window = created
	local frame = created.WindowFrame
	-- (top-left anchor, which ReGui's resize handle assumes: placed at the
	-- right edge by its width instead)
	frame.Position = if geometry then geometry.position else UDim2.new(1, -16 - frame.Size.X.Offset, 0, 70)

	-- Loadout
	local loadout = created:CreateTab({ Name = "Loadout" })
	buildBar(loadout)
	sections.loadoutStatus = ReGuiLive.Section(loadout)
	loadout:Separator({ Text = "Saved loadouts" })
	local saveRow = loadout:Row()
	local loadoutName = ""
	saveRow:InputText({
		Label = "",
		Placeholder = "Loadout name",
		Callback = function(_, text: string)
			loadoutName = text
		end,
	})
	saveRow:SmallButton({
		Text = "Save current hotbar",
		Callback = function()
			if loadoutName == "" then
				message = "Name the loadout first."
				update()
				return
			end
			run("SaveLoadout", { name = loadoutName })
		end,
	})
	sections.loadouts = ReGuiLive.Section(loadout)

	-- Library
	local library = created:CreateTab({ Name = "Library" })
	buildBar(library)
	sections.libraryStatus = ReGuiLive.Section(library)
	local top = library:Row()
	local searchDraft = search
	local searchBox = top:InputText({
		Label = "",
		Placeholder = "Search (Enter)",
		Callback = function(_, text: string)
			searchDraft = text
		end,
	})
	pcall(function()
		searchBox:SetValue(search)
		searchBox.Frame.Input.FocusLost:Connect(function()
			if search ~= searchDraft then
				search = searchDraft
				update()
			end
		end)
	end)
	top:SmallButton({ Text = "Search", Callback = function() search = searchDraft; update() end })
	top:SmallButton({ Text = "+ New spell", Callback = function() SpellEditor.NewLibrarySpell() end })
	local folderRow = library:Row()
	local folderName = ""
	folderRow:InputText({
		Label = "",
		Placeholder = "Folder name",
		Callback = function(_, text: string)
			folderName = text
		end,
	})
	folderRow:SmallButton({
		Text = "+ New folder",
		Callback = function()
			if folderName == "" then
				message = "Name the folder first."
				update()
				return
			end
			run("CreateFolder", { name = folderName })
		end,
	})
	sections.sharing = ReGuiLive.Section(library)
	sections.mySpells = ReGuiLive.Section(library)
	sections.librarySpells = ReGuiLive.Section(library)

	-- Encyclopedia
	local encyclopedia = created:CreateTab({ Name = "Encyclopedia" })
	buildBar(encyclopedia)
	sections.encyclopediaStatus = ReGuiLive.Section(encyclopedia)
	local note = encyclopedia:Label({ Text = "Elements and premade spells. Buying isn't available yet; free ones are already yours." })
	pcall(function()
		note.TextWrapped = true
		note.AutomaticSize = Enum.AutomaticSize.Y
		note.Size = UDim2.new(1, 0, 0, 0)
	end)
	sections.encyclopedia = ReGuiLive.Section(encyclopedia)

	pcall(function()
		created.WindowTabSelector:SetActiveTab(activeTab)
	end)
end

-- Reconciles changed sections; unchanged controls and their state survive.
function update()
	if not open or not window then
		return
	end
	local state = SpellEditor.GetState()
	updateBars(state)
	for _, name in { "loadoutStatus", "libraryStatus", "encyclopediaStatus" } do
		renderStatus(sections[name], state)
	end
	renderLoadouts(sections.loadouts, state)
	renderSharing(sections.sharing)
	renderMySpells(sections.mySpells, state)
	renderEncyclopedia(sections.librarySpells, state, true, true)
	renderEncyclopedia(sections.encyclopedia, state, false, false)
end

function SpellLibrary.Open()
	if open then
		return
	end
	open = true
	message = ""
	held, sharing, confirmDelete, confirmFolder = nil, nil, nil, nil
	task.spawn(function()
		local ReGui = ReGuiLoader.Get()
		if not ReGui or not open then
			return
		end
		build(ReGui)
		update()
		-- (fresh state from the server)
		SpellEditor.Command("GetState")
		update()
	end)
end

function SpellLibrary.Close()
	open = false
	held = nil
	hideWindow()
	closePreview()
end

function SpellLibrary.Toggle()
	if open then
		SpellLibrary.Close()
	else
		SpellLibrary.Open()
	end
end

-- Live: the state changes on every command (and the editor fires this for
-- its own redraws too -- update() is cheap when nothing changed).
SpellEditor.StateChanged:Connect(function()
	if open then
		update()
	end
end)

-- Spells shared with you, and answers to the ones you shared.
shareRemote.OnClientEvent:Connect(function(kind: any, a: any, b: any, c: any, d: any)
	if kind == "Offer" and typeof(a) == "string" and typeof(b) == "Instance" and b:IsA("Player") then
		local shareId, from, name = a, b :: Player, tostring(c)
		local seconds = if typeof(d) == "number" then math.max(d - workspace:GetServerTimeNow(), 1) else 60
		Notifications.Push({
			Title = "Shared spell",
			Text = `{from.DisplayName} wants to share "{name}" with you.`,
			ExpiresIn = seconds,
			Buttons = {
				{ Text = "Accept", Callback = function() run("AcceptShare", { shareId = shareId }) end },
				{ Text = "Decline", Callback = function() run("DeclineShare", { shareId = shareId }) end },
			},
		})
	elseif kind == "Answer" and typeof(a) == "Instance" and a:IsA("Player") then
		Notifications.Push({
			Title = "Shared spell",
			Text = `{a.DisplayName} {if b == true then "accepted" else "declined"} "{tostring(c)}".`,
		})
	end
end)

return SpellLibrary
