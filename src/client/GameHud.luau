--!strict
--[[
	The game HUD (UiMode's "Ours" UI):
	  bottom left   -- health (green), mana (blue) and stamina (orange): thin
	                   bars fading out to the right, each with a "Name  x / max"
	                   label above it. A thin vertical line on the mana bar
	                   marks where mana would be after casting the equipped
	                   spell (red when it can't be afforded).
	  bottom centre -- a card per saved spell, numbered 1..n (never an empty
	                   one; SpellCardPreview: each card's circle redraws
	                   itself over its cooldown). Click or press its number
	                   to select it; again to deselect.
	  bottom right  -- a "Make party" button until you're in a party; then
	                   "Party" and "+" (the leader's: PartyWindow's Invite
	                   tab; everyone else's is an X to leave) over the members
	                   (viewport headshot, name, health bar; an X to kick for
	                   the leader), stacked up to 5 and scrolling past that.
	                   Leaving is in the topbar Menu.
	Party invites and notices arrive as Notifications (see PartyClient).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local SpellEditor = require(script.Parent.SpellAssemblerGui)
local SpellCardPreview = require(script.Parent.SpellCardPreview)
local SpellCardDecoration = require(script.Parent.SpellCardDecoration)
local PartyClient = require(script.Parent.PartyClient)
local PartyWindow = require(script.Parent.PartyWindow)

local player = Players.LocalPlayer

local FONT = Enum.Font.GothamBold
local TEXT = Color3.fromRGB(240, 240, 240)
local BAR_WIDTH = 320
local BAR_HEIGHT = 5
local CARD_W, CARD_H, CARD_GAP, CARD_LIFT = 84, 84, 10, 8
local PANEL_W = 260
local SLOT_COUNT = 5
local SLOT_ACTION = "GameHudSpellSlots"
local SLOT_KEYS = { [Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3, [Enum.KeyCode.Four] = 4, [Enum.KeyCode.Five] = 5 }

local GameHud = {}
local started = false
local enabled = false
local gui: ScreenGui? = nil
local renderConnection: RBXScriptConnection? = nil

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local object = Instance.new(className)
	for key, value in props do
		(object :: any)[key] = value
	end
	if parent then
		object.Parent = parent
	end
	return object
end

local function corner(parent: Instance, radius: UDim)
	make("UICorner", { CornerRadius = radius }, parent)
end

local function label(props: { [string]: any }, parent: Instance): TextLabel
	local base = {
		BackgroundTransparency = 1,
		Font = FONT,
		TextColor3 = TEXT,
		TextSize = 14,
		TextStrokeTransparency = 0.6,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for key, value in props do
		base[key] = value
	end
	return make("TextLabel", base, parent)
end

--------------------------------------------------------------------------------
-- Resource bars
--------------------------------------------------------------------------------

type Bar = { name: string, fill: Frame, label: TextLabel, value: number }
local bars: { Bar } = {}
local manaMarker: Frame? = nil
local manaShortUntil = 0

local FADE = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.5, 0.1),
	NumberSequenceKeypoint.new(1, 1),
})

-- A thin bar that fades out towards its right edge. The fill is a full-width
-- strip inside a clipping frame sized to the value, so its fade stays
-- relative to the whole bar, not to how full it is.
local function buildBar(parent: Instance, name: string, color: Color3, order: number): (Bar, Frame)
	local row = make("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 30),
		LayoutOrder = order,	
	}, parent)
	local text = label({ Name = "Label", Size = UDim2.new(1, 0, 0, 16), Text = name }, row)
	local area = make("Frame", {
		Name = "Area",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 20),
		Size = UDim2.new(1, 0, 0, BAR_HEIGHT),
	}, row)
	local track = make("Frame", {
		Name = "Track",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
	}, area)
	make("UIGradient", { Transparency = FADE }, track)
	local clip = make("Frame", {
		Name = "Fill",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
	}, area)
	local strip = make("Frame", {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.new(0, BAR_WIDTH, 1, 0),
		ZIndex = 2,
	}, clip)
	make("UIGradient", { Transparency = FADE }, strip)
	return { name = name, fill = clip, label = text, value = 1 }, area
end

local function resource(name: string): (number, number)
	if name == "Health" then
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		return if humanoid then humanoid.Health else 0, if humanoid then humanoid.MaxHealth else 0
	end
	local current, maximum = player:GetAttribute(name), player:GetAttribute("Max" .. name)
	return if typeof(current) == "number" then current else 0, if typeof(maximum) == "number" then maximum else 0
end

local function stepBars(dt: number)
	local alpha = 1 - math.exp(-14 * dt)
	for _, bar in bars do
		local current, maximum = resource(bar.name)
		local target = if maximum > 0 then math.clamp(current / maximum, 0, 1) else 0
		if bar.value ~= target then
			bar.value += (target - bar.value) * alpha
			if math.abs(target - bar.value) < 0.001 then
				bar.value = target
			end
			bar.fill.Size = UDim2.fromScale(bar.value, 1)
		end
		local text = string.format("%s  %d / %d", bar.name, math.floor(current + 0.5), math.floor(maximum + 0.5))
		if bar.label.Text ~= text then
			bar.label.Text = text
		end
	end
	-- where mana would land after casting the equipped spell (its full cost
	-- is paid the moment the charge starts, so hide it while charging)
	local marker = manaMarker
	if marker then
		local cost = SpellEditor.GetActiveManaCost()
		local mana, maxMana = resource("Mana")
		local show = cost ~= nil and cost > 0 and maxMana > 0 and not SpellEditor.IsCharging()
		marker.Visible = show
		if show then
			local short = mana < (cost :: number) or os.clock() < manaShortUntil
			marker.Position = UDim2.new(math.clamp((mana - (cost :: number)) / maxMana, 0, 1), 0, 0.5, 0)
			marker.BackgroundColor3 = if short then Color3.fromRGB(255, 70, 70) else Color3.new(1, 1, 1)
		end
	end
end

local function buildBars(screen: ScreenGui)
	local holder = make("Frame", {
		Name = "Resources",
		AnchorPoint = Vector2.new(0, 1),
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 24, 1, -20),
		Size = UDim2.fromOffset(BAR_WIDTH, 3 * 30 + 2 * 6),
	}, screen)
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }, holder)
	local health = buildBar(holder, "Health", Color3.fromRGB(60, 200, 90), 1)
	local mana, manaArea = buildBar(holder, "Mana", Color3.fromRGB(70, 110, 255), 2)
	local stamina = buildBar(holder, "Stamina", Color3.fromRGB(255, 140, 40), 3)
	bars = { health, mana, stamina }
	manaMarker = make("Frame", {
		Name = "CostMarker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.new(0, 2, 1, 8),
		Visible = false,
		ZIndex = 5,
	}, manaArea)
end

--------------------------------------------------------------------------------
-- Spell cards
--------------------------------------------------------------------------------

-- One card per saved spell, in slot order, numbered 1..n: never an empty
-- card. Key k (or clicking card k) selects the k-th saved spell; selecting
-- the selected one again deselects it. With no spells, a hint shows instead.
type Card = { holder: Frame, card: Frame, stroke: UIStroke, key: TextLabel, preview: any }
local cards: { Card } = {}
local cardSlots: { number } = {} -- card index -> spell slot
local cardRow: Frame? = nil
local noSpellsHint: TextLabel? = nil
local equippedHeading: Frame? = nil
local equippedName: TextLabel? = nil
local equippedUnderline: Frame? = nil

local function selectCard(index: number)
	local slot = cardSlots[index]
	if slot then
		task.spawn(SpellEditor.SelectSlot, slot)
	end
end

local function createCard(index: number, row: Frame): Card
	local holder = make("Frame", {
		Name = "Card" .. index,
		BackgroundTransparency = 1,
		LayoutOrder = index,
		Size = UDim2.fromOffset(CARD_W, CARD_H + CARD_LIFT),
	}, row)
	local card = make("Frame", {
		Name = "Card",
		BackgroundColor3 = Color3.fromRGB(12, 12, 16),
		BackgroundTransparency = 0.15,
		Position = UDim2.fromOffset(0, CARD_LIFT),
		Size = UDim2.fromOffset(CARD_W, CARD_H),
	}, holder)
	local stroke = make("UIStroke", { Color = Color3.fromRGB(90, 90, 95), Thickness = 1.5 }, card)
	local key = label({
		Name = "Key",
		Position = UDim2.fromOffset(5, 3),
		Size = UDim2.fromOffset(14, 14),
		Text = tostring(index),
		TextSize = 12,
		TextColor3 = Color3.fromRGB(180, 180, 180),
		ZIndex = 8,
	}, card)
	local button = make("TextButton", {
		Name = "Select",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		ZIndex = 10,
	}, card)
	button.Activated:Connect(function()
		selectCard(index)
	end)
	local preview = SpellCardPreview.new(card, true)
	preview.Frame.Size = UDim2.fromScale(0.82, 0.82)
	preview.Frame.Position = UDim2.fromScale(0.5, 0.5)
	return { holder = holder, card = card, stroke = stroke, key = key, preview = preview }
end

local function refreshCards()
	local row = cardRow
	if not row then
		return
	end
	local state = SpellEditor.GetState()
	table.clear(cardSlots)
	for slot = 1, SLOT_COUNT do
		if state.slots and (state.slots[slot] or state.slots[tostring(slot)]) then
			table.insert(cardSlots, slot)
		end
	end
	local count = #cardSlots
	for index = 1, count do
		cards[index] = cards[index] or createCard(index, row)
	end
	for index = #cards, count + 1, -1 do
		cards[index].preview:Destroy()
		cards[index].holder:Destroy()
		cards[index] = nil
	end
	row.Size = UDim2.fromOffset(math.max(count * CARD_W + (count - 1) * CARD_GAP, 0), CARD_H + CARD_LIFT)
	if noSpellsHint then
		noSpellsHint.Visible = count == 0
	end

	local selectedSlot = SpellEditor.GetSelectedSlot()
	if equippedHeading then
		equippedHeading.Visible = false
		equippedHeading.Size = UDim2.fromOffset(math.clamp(row.Size.X.Offset, 180, 420), 32)
	end
	local now = workspace:GetServerTimeNow()
	for index, card in cards do
		local slot = cardSlots[index]
		local record = state.slots[slot] or state.slots[tostring(slot)]
		local selected = selectedSlot == slot
		card.card.Position = UDim2.fromOffset(0, if selected then 0 else CARD_LIFT)
		card.stroke.Enabled = false
		card.preview:SetSpell(record)
		card.preview:SetSelected(selected)
		if selected and equippedHeading and equippedName and equippedUnderline then
			equippedHeading.Visible = true
			equippedName.Text = record.name
			equippedUnderline.BackgroundColor3 = SpellCardDecoration.GetColor(card.preview.ManaCost or 0)
		end
		-- (cooldowns belong to slots: a card now showing another slot follows
		-- that slot's cooldown)
		local deadline = player:GetAttribute("SpellCooldownEndsAt" .. slot) or 0
		if card.preview.Deadline ~= deadline and (deadline > now or card.preview.Deadline > now) then
			card.preview:Cooldown(deadline, false)
		end
	end
end

local function buildCards(screen: ScreenGui)
	local row = make("Frame", {
		Name = "SpellCards",
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundTransparency = 1,
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(0, CARD_H + CARD_LIFT),
	}, screen)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, CARD_GAP),
	}, row)
	cardRow = row
	local heading = make("Frame", {
		Name = "EquippedSpellHeading",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -(CARD_H + CARD_LIFT + 24)),
		Size = UDim2.fromOffset(320, 32),
		BackgroundTransparency = 1,
		Visible = false,
	}, screen)
	equippedHeading = heading
	equippedName = label({
		Name = "SpellName",
		Size = UDim2.new(1, -12, 0, 22),
		Position = UDim2.fromOffset(6, 0),
		Text = "",
		TextSize = 16,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Center,
	}, heading)
	local underline = make("Frame", {
		Name = "TierUnderline",
		Position = UDim2.fromOffset(0, 27),
		Size = UDim2.new(1, 0, 0, 1),
		BorderSizePixel = 0,
	}, heading)
	equippedUnderline = underline
	make("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.35, 0),
			NumberSequenceKeypoint.new(0.65, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, underline)
	noSpellsHint = label({
		Name = "NoSpells",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -24),
		Size = UDim2.fromOffset(320, 18),
		Text = "No spells yet: open Spells to make one",
		TextColor3 = Color3.fromRGB(190, 190, 195),
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
	}, screen)
end

--------------------------------------------------------------------------------
-- Party panel
--------------------------------------------------------------------------------

-- Out of a party only a "Make party" button shows. In one, "Party" and "+"
-- sit over the members, stacked with no background up to STACK_LIMIT rows;
-- past that the list keeps that height, scrolls and gets a background.
local ROW_H, ROW_GAP, HEADER_H, STACK_LIMIT = 44, 6, 30, 5
local LIST_X = 14 -- members sit right of the panel's left line
local MEMBER_BAR_W = PANEL_W - LIST_X - 6 - 48 - 4
-- the panel's two lines: nearly white, translucent, fading out at their ends
local LINE_COLOR, LINE_TRANSPARENCY, LINE_W = Color3.fromRGB(235, 235, 240), 0.35, 2

type Row = {
	frame: Frame,
	viewport: ViewportFrame,
	thumbnail: ImageLabel,
	name: TextLabel,
	fill: Frame,
	kick: TextButton,
	connections: { RBXScriptConnection },
	healthConnections: { RBXScriptConnection },
	headWait: RBXScriptConnection?,
}
local rows: { [Instance]: Row } = {}
local partyPanel: Frame? = nil
local partyList: ScrollingFrame? = nil
local makePartyButton: GuiObject? = nil -- (the Make / Find party buttons)
local panelVisible = true -- (topbar Menu: hide / show the party panel)
local headerButton: TextButton? = nil -- "+" (leader: invite) or "X" (leave)
local panelHeight = 0

local function disconnectAll(list: { RBXScriptConnection })
	for _, connection in list do
		connection:Disconnect()
	end
	table.clear(list)
end

local SKIP_CLASSES = { "LuaSourceContainer", "Sound", "ParticleEmitter", "Trail", "Beam", "Fire", "Smoke", "Sparkles", "Light", "ForceField", "BillboardGui", "Highlight" }

-- A headshot: a copy of the member's character (or dummy), anchored in the
-- viewport, with the camera in front of its face. A player falls back to
-- their avatar thumbnail while no character is around.
local function buildHeadshot(row: Row, member: Instance)
	for _, child in row.viewport:GetChildren() do
		if child:IsA("Model") or child:IsA("Camera") then
			child:Destroy()
		end
	end
	local character = PartyClient.CharacterOf(member)
	local head = character and character:FindFirstChild("Head")
	row.thumbnail.Visible = member:IsA("Player")
	if row.headWait then
		row.headWait:Disconnect()
		row.headWait = nil
	end
	if not character or not head or not head:IsA("BasePart") then
		if character then
			-- (streaming: the model can arrive before its head does)
			row.headWait = character.ChildAdded:Connect(function(child)
				if child.Name == "Head" then
					task.defer(buildHeadshot, row, member)
				end
			end)
		end
		return
	end
	local archivable = character.Archivable
	character.Archivable = true
	local ok, clone = pcall(character.Clone, character)
	character.Archivable = archivable
	if not ok or not clone then
		return
	end
	for _, object in clone:GetDescendants() do
		local skip = false
		for _, className in SKIP_CLASSES do
			if object:IsA(className) then
				skip = true
				break
			end
		end
		if skip then
			object:Destroy()
		elseif object:IsA("BasePart") then
			object.Anchored = true
		elseif object:IsA("Humanoid") then
			object.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end
	local cloneHead = clone:FindFirstChild("Head") :: BasePart?
	if not cloneHead then
		clone:Destroy()
		return
	end
	clone.Parent = row.viewport
	local camera = Instance.new("Camera")
	camera.FieldOfView = 30
	local face = cloneHead.Position + Vector3.new(0, 0.25, 0)
	camera.CFrame = CFrame.lookAt(face + cloneHead.CFrame.LookVector * 4.2, face)
	camera.Parent = row.viewport
	row.viewport.CurrentCamera = camera
	row.thumbnail.Visible = false
end

local function bindHealth(row: Row, member: Instance)
	disconnectAll(row.healthConnections)
	local character = PartyClient.CharacterOf(member)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local function update()
		local fraction = if humanoid and humanoid.MaxHealth > 0 then math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1) else 0
		row.fill.Size = UDim2.fromOffset(MEMBER_BAR_W * fraction, 4)
	end
	if humanoid then
		table.insert(row.healthConnections, humanoid.HealthChanged:Connect(update))
		table.insert(row.healthConnections, humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(update))
	end
	update()
end

local function refreshRowText(row: Row, member: Instance)
	local leader = PartyClient.IsLeader(member)
	row.name.Text = (if leader then "★ " else "") .. PartyClient.NameOf(member) .. (if member == player then " (you)" else "")
	row.name.TextColor3 = if leader then Color3.fromRGB(255, 215, 90) else TEXT
	row.kick.Visible = PartyClient.CanKick(member)
end

local function createRow(member: Instance, list: ScrollingFrame): Row
	local frame = make("Frame", {
		Name = member.Name,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -6, 0, ROW_H),
	}, list)
	local portrait = make("Frame", {
		Name = "Portrait",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(40, 40),
		Position = UDim2.fromOffset(0, 2),
	}, frame)
	local thumbnail = make("ImageLabel", {
		Name = "Thumbnail",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Image = if member:IsA("Player") then `rbxthumb://type=AvatarHeadShot&id={member.UserId}&w=150&h=150` else "",
	}, portrait)
	local viewport = make("ViewportFrame", {
		Name = "Headshot",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Ambient = Color3.fromRGB(170, 170, 170),
		LightColor = Color3.fromRGB(255, 255, 255),
		LightDirection = Vector3.new(-0.5, -1, -1),
		ZIndex = 2,
	}, portrait)
	local name = label({
		Name = "Username",
		Position = UDim2.fromOffset(48, 6),
		Size = UDim2.new(1, -48 - 26, 0, 16),
		TextSize = 13,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, frame)
	-- health: the same fading bar as the main HUD's (see buildBar)
	local track = make("Frame", {
		Name = "Health",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(48, 27),
		Size = UDim2.fromOffset(MEMBER_BAR_W, 4),
	}, frame)
	make("UIGradient", { Transparency = FADE }, track)
	local fill = make("Frame", {
		Name = "Fill",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Position = UDim2.fromOffset(48, 27),
		Size = UDim2.fromOffset(MEMBER_BAR_W, 4),
		ZIndex = 2,
	}, frame)
	local strip = make("Frame", {
		BackgroundColor3 = Color3.fromRGB(60, 200, 90),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(MEMBER_BAR_W, 4),
		ZIndex = 2,
	}, fill)
	make("UIGradient", { Transparency = FADE }, strip)
	local kick = make("TextButton", {
		Name = "Kick",
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -2, 0, 4),
		Size = UDim2.fromOffset(20, 20),
		Font = FONT,
		Text = "X",
		TextColor3 = Color3.fromRGB(255, 95, 95),
		TextSize = 14,
		Visible = false,
	}, frame)
	kick.Activated:Connect(function()
		PartyClient.Kick(member)
	end)

	local row: Row = {
		frame = frame,
		viewport = viewport,
		thumbnail = thumbnail,
		name = name,
		fill = fill,
		kick = kick,
		connections = {},
		healthConnections = {},
	}
	local function onCharacter()
		bindHealth(row, member)
		buildHeadshot(row, member)
	end
	if member:IsA("Player") then
		table.insert(row.connections, member.CharacterAppearanceLoaded:Connect(onCharacter))
		table.insert(row.connections, member.CharacterAdded:Connect(function(character)
			-- the head may arrive a moment after the model
			character:WaitForChild("Head", 5)
			if member.Character == character then
				onCharacter()
			end
		end))
		table.insert(row.connections, member.CharacterRemoving:Connect(function()
			disconnectAll(row.healthConnections)
			row.fill.Size = UDim2.fromOffset(0, 4)
		end))
	end
	onCharacter()
	return row
end

local function removeRow(member: Instance)
	local row = rows[member]
	if not row then
		return
	end
	rows[member] = nil
	if row.headWait then
		row.headWait:Disconnect()
	end
	disconnectAll(row.connections)
	disconnectAll(row.healthConnections)
	row.frame:Destroy()
end

-- (the invite / find-a-party window is PartyWindow's)
local function closeInviteMenu()
	PartyWindow.Close()
end

-- Sizes the panel to its members: stacked rows up to STACK_LIMIT, then a
-- fixed-height scrolling list with a background. It grows upwards from the
-- bottom-right corner.
local function layoutParty(count: number)
	local panel, list = partyPanel, partyList
	if not panel or not list then
		return
	end
	local shown = math.min(count, STACK_LIMIT)
	local listHeight = math.max(shown * (ROW_H + ROW_GAP) - ROW_GAP, 0)
	local scrolling = count > STACK_LIMIT
	list.Size = UDim2.new(1, -LIST_X, 0, listHeight + (if scrolling then 8 else 0))
	list.ScrollingEnabled = scrolling
	list.ScrollBarThickness = if scrolling then 4 else 0
	list.BackgroundTransparency = if scrolling then 0.55 else 1
	if not scrolling then
		list.CanvasPosition = Vector2.zero
	end
	panelHeight = HEADER_H + 6 + list.Size.Y.Offset + 6
	panel.Size = UDim2.fromOffset(PANEL_W, panelHeight)
end

local function refreshParty()
	local list = partyList
	if not list then
		return
	end
	local inParty = PartyClient.GetPartyId() ~= nil
	if partyPanel then
		partyPanel.Visible = inParty and panelVisible
	end
	if makePartyButton then
		makePartyButton.Visible = not inParty and panelVisible
	end
	if headerButton then
		local leader = PartyClient.IsLeader()
		headerButton.Text = if leader then "+" else "X"
		headerButton.TextSize = if leader then 26 else 18
		headerButton.TextColor3 = if leader then TEXT else Color3.fromRGB(255, 95, 95)
	end
	local members = PartyClient.GetMembers()
	local keep: { [Instance]: boolean } = {}
	for order, member in members do
		keep[member] = true
		local row = rows[member] or createRow(member, list)
		rows[member] = row
		row.frame.LayoutOrder = order
		refreshRowText(row, member)
	end
	for member in rows do
		if not keep[member] then
			removeRow(member)
		end
	end
	layoutParty(#members)
end

local function openInviteMenu()
	PartyWindow.Open(if PartyClient.GetPartyId() then "Invite" else "Parties")
end

-- A line that fades out along its length (`rotation` 0: to the right,
-- 90: downwards).
local function fadingLine(parent: Instance, name: string, size: UDim2, rotation: number)
	local line = make("Frame", {
		Name = name,
		BackgroundColor3 = LINE_COLOR,
		BackgroundTransparency = LINE_TRANSPARENCY,
		BorderSizePixel = 0,
		Size = size,
	}, parent)
	make("UIGradient", { Transparency = FADE, Rotation = rotation }, line)
	return line
end

local function buildParty(screen: ScreenGui)
	-- outside a party: Make party, and Find party (public parties / dummies)
	local start = make("Frame", {
		Name = "PartyStart",
		AnchorPoint = Vector2.new(1, 1),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -16, 1, -16),
		Size = UDim2.fromOffset(248, 30),
	}, screen)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 8),
	}, start)
	for order, info in { { "+  Make party", PartyClient.Create }, { "Find party", openInviteMenu } } do
		local button = make("TextButton", {
			BackgroundColor3 = Color3.fromRGB(20, 20, 24),
			BackgroundTransparency = 0.35,
			LayoutOrder = order,
			Size = UDim2.fromOffset(120, 30),
			Font = FONT,
			Text = info[1],
			TextColor3 = TEXT,
			TextSize = 14,
		}, start)
		corner(button, UDim.new(0, 6))
		make("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = LINE_COLOR,
			Transparency = 0.6,
		}, button)
		button.Activated:Connect(function()
			if order == 2 and PartyWindow.IsOpen() then
				closeInviteMenu()
			else
				info[2]()
			end
		end)
	end
	makePartyButton = start :: any

	-- in a party: a left line (solid at the top, fading down) and a line
	-- under the header (fading right), with "Party" and "+" above it
	local panel = make("Frame", {
		Name = "Party",
		AnchorPoint = Vector2.new(1, 1),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -16, 1, -16),
		Size = UDim2.fromOffset(PANEL_W, HEADER_H),
		Visible = false,
	}, screen)
	fadingLine(panel, "LeftLine", UDim2.new(0, LINE_W, 1, 0), 90)
	local underline = fadingLine(panel, "HeaderLine", UDim2.new(1, 0, 0, LINE_W), 0)
	underline.Position = UDim2.fromOffset(0, HEADER_H)
	label({
		Name = "Title",
		Text = "Party",
		Position = UDim2.fromOffset(LIST_X, 4),
		Size = UDim2.new(0, 80, 0, 22),
		TextSize = 16,
	}, panel)
	local plus = make("TextButton", {
		Name = "Invite",
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -8, 0, 2),
		Size = UDim2.fromOffset(24, 24),
		Font = FONT,
		Text = "+",
		TextColor3 = TEXT,
		TextSize = 26,
	}, panel)
	-- the leader's "+" invites; everyone else's is an "X" that leaves
	plus.Activated:Connect(function()
		if not PartyClient.IsLeader() then
			closeInviteMenu()
			PartyClient.Leave()
		elseif PartyWindow.IsOpen() then
			closeInviteMenu()
		else
			openInviteMenu()
		end
	end)
	headerButton = plus
	local list = make("ScrollingFrame", {
		Name = "Members",
		BackgroundColor3 = Color3.fromRGB(30, 30, 34),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(LIST_X, HEADER_H + 6),
		Size = UDim2.new(1, -LIST_X, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 0,
		ScrollingEnabled = false,
		ScrollBarImageColor3 = LINE_COLOR,
	}, panel)
	corner(list, UDim.new(0, 6))
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, ROW_GAP) }, list)
	partyPanel = panel
	partyList = list
end

--------------------------------------------------------------------------------
-- Enable / start
--------------------------------------------------------------------------------

local function bindSlotKeys()
	ContextActionService:BindActionAtPriority(SLOT_ACTION, function(_, state, input)
		if UserInputService:GetFocusedTextBox() or SpellEditor.IsOpen() then
			return Enum.ContextActionResult.Pass
		end
		if state == Enum.UserInputState.Begin then
			selectCard(SLOT_KEYS[input.KeyCode])
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 50, Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five)
end

function GameHud.SetEnabled(on: boolean)
	if enabled == on then
		return
	end
	enabled = on
	if gui then
		gui.Enabled = on
	end
	if not started then
		return
	end
	if on then
		bindSlotKeys()
		refreshCards()
		refreshParty()
		if not renderConnection then
			renderConnection = RunService.RenderStepped:Connect(stepBars)
		end
	else
		ContextActionService:UnbindAction(SLOT_ACTION)
		if renderConnection then
			renderConnection:Disconnect()
			renderConnection = nil
		end
	end
end

function GameHud.SetPartyPanelVisible(visible: boolean)
	panelVisible = visible
	refreshParty()
end

function GameHud.start()
	if started then
		return
	end
	started = true
	SpellEditor.start()
	PartyClient.start()

	local screen = Instance.new("ScreenGui")
	screen.Name = "GameHud"
	screen.ResetOnSpawn = false
	screen.Enabled = enabled
	screen.DisplayOrder = 5
	buildBars(screen)
	buildCards(screen)
	buildParty(screen)
	screen.Parent = player:WaitForChild("PlayerGui")
	gui = screen

	SpellEditor.StateChanged:Connect(refreshCards)
	SpellEditor.SpellFired:Connect(function(data)
		local index = table.find(cardSlots, data.Slot)
		local card = index and cards[index]
		if card then
			card.preview:Cooldown(data.EndsAt, true, data.ManaSpent)
		end
	end)
	SpellEditor.ManaShort:Connect(function()
		manaShortUntil = os.clock() + 0.5
	end)
	PartyClient.Changed:Connect(refreshParty)

	refreshCards()
	refreshParty()
	if enabled then
		bindSlotKeys()
		renderConnection = RunService.RenderStepped:Connect(stepBars)
	end
end

return GameHud
