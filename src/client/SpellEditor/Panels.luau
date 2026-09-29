--!strict
--[[
	Side panels for the spell editor:
	 Toolbox   -- zone pens and the searchable rune palette (left)
	 Inspector -- whatever is selected: rune params, zone kind/label, wire,
	              or the spell overview when nothing is (right)
	 Problems  -- collapsible compile-error list floating over the board
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SpellRunes = require(Shared:WaitForChild("SpellRunes"))
local Theme = require(script.Parent.Theme)
local Board = require(script.Parent.Board)

local Colors = Theme.Colors
local Panels = {}

local function scroller(parent: Instance, props: { [string]: any }?): ScrollingFrame
	local scroll = Theme.make("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Colors.line,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, parent)
	if props then
		for key, value in props do (scroll :: any)[key] = value end
	end
	return scroll
end

local function sectionTitle(parent: Instance, text: string, order: number, color: Color3?): TextLabel
	return Theme.label(parent, string.upper(text), 11, {
		Font = Theme.FontBold,
		TextColor3 = color or Colors.muted,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = order,
	})
end

--------------------------------------------------------------------------------
-- Toolbox
--------------------------------------------------------------------------------

local Toolbox = {}
Toolbox.__index = Toolbox
Panels.Toolbox = Toolbox

-- hooks: onArmZone(kind?), onRunePress(runeId)
function Toolbox.new(parent: Frame, hooks: any)
	local self = setmetatable({}, Toolbox)
	self.hooks = hooks
	self.zoneChips = {} :: { [string]: TextButton }
	self.items = {} :: { { frame: GuiObject, text: string, category: string } }
	self.headers = {} :: { [string]: TextLabel }

	local search = Theme.make("TextBox", {
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 32),
		BackgroundColor3 = Colors.panel2,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = Theme.Font,
		PlaceholderText = "Search runes…",
		PlaceholderColor3 = Colors.muted,
		Text = "",
		TextColor3 = Colors.text,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, parent)
	Theme.corner(search, 6)
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 10) }, search)
	search:GetPropertyChangedSignal("Text"):Connect(function()
		self:filter(search.Text)
	end)

	local scroll = scroller(parent, { Position = UDim2.fromOffset(10, 50), Size = UDim2.new(1, -14, 1, -58) })
	Theme.list(scroll, 6)
	Theme.make("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 10) }, scroll)

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	sectionTitle(scroll, "Zones · click a pen, drag on the board", nextOrder())
	local zoneGrid = Theme.make("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), LayoutOrder = nextOrder() }, scroll)
	Theme.make("UIGridLayout", { CellSize = UDim2.new(0.5, -3, 0, 30), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }, zoneGrid)
	for index, kind in SpellRunes.ZoneKinds do
		local color = SpellRunes.Zones[kind].Color
		local chip = Theme.button(zoneGrid, kind, {
			LayoutOrder = index,
			BackgroundColor3 = color:Lerp(Colors.panel, 0.7),
			TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.5),
			TextSize = 12,
		})
		Theme.stroke(chip, color, 1, 0.5)
		chip.Activated:Connect(function()
			hooks.onArmZone(if self.armed == kind then nil else kind)
		end)
		self.zoneChips[kind] = chip
	end

	local categoryColors: { [string]: Color3 } = {}
	for _, runeId in SpellRunes.Order do
		local def = SpellRunes.Runes[runeId]
		categoryColors[def.Category] = categoryColors[def.Category] or Board.categoryColor(def)
	end
	for _, category in SpellRunes.Categories do
		local color = categoryColors[category]
		self.headers[category] = sectionTitle(scroll, category, nextOrder(), color:Lerp(Color3.new(1, 1, 1), 0.3))
		for _, runeId in SpellRunes.Order do
			local def = SpellRunes.Runes[runeId]
			if def.Category == category then
				local item = Theme.button(scroll, "", {
					LayoutOrder = nextOrder(),
					Size = UDim2.new(1, 0, 0, 46),
					BackgroundColor3 = Colors.panel2,
					AutoButtonColor = true,
				})
				Theme.make("Frame", { Size = UDim2.new(0, 4, 1, -12), Position = UDim2.fromOffset(6, 6), BackgroundColor3 = color, BorderSizePixel = 0 }, item)
				Theme.label(item, def.Name, 13, { Font = Theme.FontBold, Position = UDim2.fromOffset(18, 5), Size = UDim2.new(1, -26, 0, 18) })
				Theme.label(item, def.Description, 11, { Position = UDim2.fromOffset(18, 23), Size = UDim2.new(1, -26, 0, 16), TextColor3 = Colors.muted })
				item.InputBegan:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
						hooks.onRunePress(runeId)
					end
				end)
				table.insert(self.items, { frame = item, text = string.lower(def.Name .. " " .. def.Category .. " " .. def.Description), category = category })
			end
		end
	end
	return self
end

function Toolbox:setArmed(kind: string?)
	self.armed = kind
	for chipKind, chip in self.zoneChips do
		local color = SpellRunes.Zones[chipKind].Color
		chip.BackgroundColor3 = if chipKind == kind then color:Lerp(Colors.panel, 0.25) else color:Lerp(Colors.panel, 0.7)
	end
end

function Toolbox:filter(query: string)
	query = string.lower(query)
	local visibleCategories = {}
	for _, item in self.items do
		local visible = query == "" or string.find(item.text, query, 1, true) ~= nil
		item.frame.Visible = visible
		if visible then visibleCategories[item.category] = true end
	end
	for category, header in self.headers do
		header.Visible = visibleCategories[category] == true
	end
end

--------------------------------------------------------------------------------
-- Inspector
--------------------------------------------------------------------------------

local Inspector = {}
Inspector.__index = Inspector
Panels.Inspector = Inspector

-- hooks:
--  edit(fn)      -- record undo, run fn, then treat as a change
--  liveEdit(fn)  -- run fn and apply without recording (slider drags)
--  beginLive()   -- record undo once at the start of a slider drag
--  delete()      -- delete the current selection
--  doc()         -- current Document
function Inspector.new(parent: Frame, hooks: any)
	local self = setmetatable({}, Inspector)
	self.hooks = hooks
	self.scroll = scroller(parent, { Position = UDim2.fromOffset(12, 10), Size = UDim2.new(1, -16, 1, -18) })
	Theme.make("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 12) }, self.scroll)
	self.slider = nil :: any

	UserInputService.InputChanged:Connect(function(input)
		local slider = self.slider
		if slider and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			slider.update(Board.pointer(input))
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if self.slider and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			self.slider = nil
			self:refresh()
		end
	end)
	return self
end

function Inspector:clear()
	for _, child in self.scroll:GetChildren() do
		if not child:IsA("UIPadding") then child:Destroy() end
	end
	self.order = 0
	Theme.list(self.scroll, 8)
end

function Inspector:nextOrder(): number
	self.order += 1
	return self.order
end

function Inspector:text(text: string, size: number?, color: Color3?, bold: boolean?): TextLabel
	return Theme.label(self.scroll, text, size or 13, {
		Font = if bold then Theme.FontBold else Theme.Font,
		TextColor3 = color or Colors.text,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = self:nextOrder(),
	})
end

function Inspector:actionButton(text: string, color: Color3?, callback: () -> ()): TextButton
	local button = Theme.button(self.scroll, text, {
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundColor3 = color or Colors.panel3,
		LayoutOrder = self:nextOrder(),
	})
	button.Activated:Connect(callback)
	return button
end

function Inspector:numberParam(rune: any, param: any)
	local row = Theme.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 58), LayoutOrder = self:nextOrder() }, self.scroll)
	Theme.label(row, param.Label, 12, { Size = UDim2.new(1, -130, 0, 28), TextColor3 = Colors.muted })
	local value = rune.params[param.Name]
	local minValue, maxValue, step = param.Min, param.Max, param.Step or 1

	local function commit(newValue: number, live: boolean?)
		newValue = math.clamp(math.floor(newValue / step + 0.5) * step, minValue, maxValue)
		newValue = tonumber(string.format("%.4f", newValue)) :: number
		local apply = function() rune.params[param.Name] = newValue end
		if live then self.hooks.liveEdit(apply) else self.hooks.edit(apply) end
	end

	local minus = Theme.button(row, "−", { Position = UDim2.new(1, -124, 0, 0), Size = UDim2.fromOffset(28, 26) })
	local box = Theme.make("TextBox", {
		Position = UDim2.new(1, -92, 0, 0),
		Size = UDim2.fromOffset(60, 26),
		BackgroundColor3 = Colors.panel2,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = Theme.FontMedium,
		Text = tostring(value) .. (param.Suffix or ""),
		TextColor3 = Colors.text,
		TextSize = 13,
	}, row)
	Theme.corner(box, 5)
	local plus = Theme.button(row, "+", { Position = UDim2.new(1, -28, 0, 0), Size = UDim2.fromOffset(28, 26) })
	minus.Activated:Connect(function() commit(value - step) end)
	plus.Activated:Connect(function() commit(value + step) end)
	box.Focused:Connect(function() box.Text = tostring(value) end)
	box.FocusLost:Connect(function()
		local parsed = tonumber(string.match(box.Text, "%-?[%d%.]+") or "")
		if parsed then commit(parsed) else self:refresh() end
	end)

	local track = Theme.make("Frame", {
		Position = UDim2.fromOffset(4, 38),
		Size = UDim2.new(1, -8, 0, 8),
		BackgroundColor3 = Colors.panel3,
		BorderSizePixel = 0,
		Active = true,
	}, row)
	Theme.corner(track, 4)
	local alpha = (value - minValue) / math.max(maxValue - minValue, 1e-6)
	local fill = Theme.make("Frame", { Size = UDim2.fromScale(alpha, 1), BackgroundColor3 = Colors.accent, BorderSizePixel = 0 }, track)
	Theme.corner(fill, 4)
	local knob = Theme.make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(alpha, 0.5),
		Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
	}, track)
	Theme.corner(knob, 8)
	local function update(pointer: Vector2)
		local t = math.clamp((pointer.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		local newValue = minValue + t * (maxValue - minValue)
		newValue = math.clamp(math.floor(newValue / step + 0.5) * step, minValue, maxValue)
		local shown = (newValue - minValue) / math.max(maxValue - minValue, 1e-6)
		fill.Size = UDim2.fromScale(shown, 1)
		knob.Position = UDim2.fromScale(shown, 0.5)
		box.Text = tostring(tonumber(string.format("%.4f", newValue))) .. (param.Suffix or "")
		commit(newValue, true)
	end
	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			self.hooks.beginLive()
			self.slider = { update = update }
			update(Board.pointer(input))
		end
	end)
end

function Inspector:enumParam(rune: any, param: any)
	Theme.label(self.scroll, param.Label, 12, { Size = UDim2.new(1, 0, 0, 18), TextColor3 = Colors.muted, LayoutOrder = self:nextOrder() })
	local grid = Theme.make("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), LayoutOrder = self:nextOrder() }, self.scroll)
	local columns = math.min(#param.Options, 3)
	Theme.make("UIGridLayout", { CellSize = UDim2.new(1 / columns, -4, 0, 28), CellPadding = UDim2.fromOffset(4, 4), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
	for index, option in param.Options do
		local active = rune.params[param.Name] == option
		local chip = Theme.button(grid, option, {
			LayoutOrder = index,
			BackgroundColor3 = if active then Colors.accent:Lerp(Colors.panel, 0.35) else Colors.panel2,
		})
		chip.Activated:Connect(function()
			self.hooks.edit(function() rune.params[param.Name] = option end)
		end)
	end
end

function Inspector:boolParam(rune: any, param: any)
	local row = Theme.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = self:nextOrder() }, self.scroll)
	Theme.label(row, param.Label, 12, { Size = UDim2.new(1, -80, 1, 0), TextColor3 = Colors.muted })
	local on = rune.params[param.Name] == true
	local toggle = Theme.button(row, if on then "On" else "Off", {
		Position = UDim2.new(1, -70, 0, 0),
		Size = UDim2.fromOffset(70, 28),
		BackgroundColor3 = if on then Colors.good:Lerp(Colors.panel, 0.45) else Colors.panel2,
	})
	toggle.Activated:Connect(function()
		self.hooks.edit(function() rune.params[param.Name] = not on end)
	end)
end

function Inspector:lockToggle(target: any, noun: string)
	local locked = target.locked == true
	local button = self:actionButton(
		if locked then `🔒 {noun} locked: click to unlock  [L]` else `Lock {noun} in place  [L]`,
		if locked then Color3.fromRGB(120, 96, 40) else Colors.panel3,
		function()
			self.hooks.edit(function() target.locked = if locked then nil else true end)
		end
	)
	button.TextSize = 12
end

function Inspector:showRune(rune: any, context: any)
	local def = SpellRunes.Runes[rune.rune]
	local color = Board.categoryColor(def)
	self:text(def.Name, 18, color:Lerp(Color3.new(1, 1, 1), 0.35), true)
	self:text(`{def.Category} rune · goes in a {table.concat(def.Zones, " or ")} zone`, 12, Colors.muted)
	self:text(def.Description, 13)
	for _, problem in context.errors do
		if problem.rune == rune.id then
			self:text("✖ " .. problem.message, 12, Colors.bad)
		end
	end
	local estimate = context.estimates and context.estimates[rune.id]
	if estimate and estimate.damage then
		self:text(`Energy in: {math.floor(estimate.energy + 0.5)}  ·  {math.floor(estimate.damage + 0.5)} impact damage per copy ×{estimate.count}`, 12, SpellRunes.PortColors.flow)
	elseif estimate and estimate.energy then
		self:text(`Energy: {math.floor(estimate.energy + 0.5)}`, 12, SpellRunes.PortColors.flow)
	end

	if #def.Params > 0 then
		sectionTitle(self.scroll, "Settings", self:nextOrder())
		for _, param in def.Params do
			if param.Type == "number" then
				self:numberParam(rune, param)
			elseif param.Type == "enum" then
				self:enumParam(rune, param)
			else
				self:boolParam(rune, param)
			end
		end
	end

	if #def.Inputs + #def.Outputs > 0 then
		sectionTitle(self.scroll, "Ports", self:nextOrder())
		local function describe(prefix: string, port: any)
			local suffix = if port.Multi then ", many" elseif port.Optional then ", optional" else ""
			local typeName = if port.Type == "vessel" then "trigger link" else port.Type
			self:text(`{prefix} {port.Label}  ({typeName}{suffix})`, 12, SpellRunes.PortColors[port.Type])
		end
		for _, port in def.Inputs do describe("◀", port) end
		for _, port in def.Outputs do describe("▶", port) end
	end
	self:lockToggle(rune, "Rune")
	self:actionButton("Delete rune  [Del]", Color3.fromRGB(110, 40, 58), self.hooks.delete)
end

function Inspector:showZone(zone: any)
	local kind = SpellRunes.Zones[zone.kind]
	self:text(`{zone.kind} zone`, 18, kind.Color:Lerp(Color3.new(1, 1, 1), 0.35), true)
	self:text(kind.Description, 13)
	local inside = #self.hooks.doc():runesInZone(zone)
	self:text(`{inside} rune{if inside == 1 then "" else "s"} inside · {zone.w} × {zone.h}`, 12, Colors.muted)

	sectionTitle(self.scroll, "Label", self:nextOrder())
	local box = Theme.make("TextBox", {
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundColor3 = Colors.panel2,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = Theme.Font,
		PlaceholderText = "Optional name for this zone",
		PlaceholderColor3 = Colors.muted,
		Text = zone.label or "",
		TextColor3 = Colors.text,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = self:nextOrder(),
	}, self.scroll)
	Theme.corner(box, 6)
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 10) }, box)
	box.FocusLost:Connect(function()
		local text = string.sub(box.Text, 1, 32)
		if text ~= (zone.label or "") then
			self.hooks.edit(function() zone.label = if text == "" then nil else text end)
		end
	end)

	sectionTitle(self.scroll, "Kind", self:nextOrder())
	local grid = Theme.make("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), LayoutOrder = self:nextOrder() }, self.scroll)
	Theme.make("UIGridLayout", { CellSize = UDim2.new(0.5, -3, 0, 28), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
	for index, kindName in SpellRunes.ZoneKinds do
		local color = SpellRunes.Zones[kindName].Color
		local chip = Theme.button(grid, kindName, {
			LayoutOrder = index,
			TextSize = 12,
			BackgroundColor3 = if kindName == zone.kind then color:Lerp(Colors.panel, 0.3) else color:Lerp(Colors.panel, 0.75),
		})
		chip.Activated:Connect(function()
			if kindName ~= zone.kind then
				self.hooks.edit(function() zone.kind = kindName end)
			end
		end)
	end
	self:text("Double-click the zone's tab to pick it up with everything inside (locked runes stay put): drag it, or let go and click where it should land. Esc puts it back. Drag any edge or corner to resize.", 12, Colors.muted)
	self:lockToggle(zone, "Zone")
	self:actionButton("Delete zone (keeps its runes)  [Del]", Color3.fromRGB(110, 40, 58), self.hooks.delete)
end

function Inspector:showWire(wire: any)
	local doc = self.hooks.doc()
	local from, to = doc:rune(wire.from), doc:rune(wire.to)
	local fromName = from and SpellRunes.Runes[from.rune].Name or wire.from
	local toName = to and SpellRunes.Runes[to.rune].Name or wire.to
	self:text("Wire", 18, Colors.text, true)
	self:text(`{fromName} · {wire.fromPort}  →  {toName} · {wire.toPort}`, 13)
	self:text("Tip: drag a connected input port to pick its wire back up.", 12, Colors.muted)
	self:actionButton("Delete wire  [Del]", Color3.fromRGB(110, 40, 58), self.hooks.delete)
end

function Inspector:showOverview(context: any)
	self:text("Spell circle", 18, Colors.text, true)
	local analysis = context.analysis
	if analysis then
		self:text(`Costs {analysis.manaCost} mana per cast.`, 13, SpellRunes.PortColors.flow)
		for id, estimate in analysis.estimates do
			if estimate.damage then
				self:text(`• {id}: {math.floor(estimate.damage + 0.5)} impact damage ×{estimate.count} ({estimate.element or "no element"})`, 12)
			end
		end
	end
	if #context.errors == 0 then
		self:text("✓ Ready to save.", 13, Colors.good)
	else
		self:text(`✖ {#context.errors} problem{if #context.errors == 1 then "" else "s"} — see the list on the board.`, 13, Colors.bad)
	end
	sectionTitle(self.scroll, "How it works", self:nextOrder())
	for _, line in {
		"Mana is energy. Wire a Mana Well through a Transform (Fire, Arcane, Shock) into a Vessel; its damage comes from the mana that reaches it.",
		"The Vessel is the form the magic takes: Orb (slow, heavy), Bullet (fast tracer) or Beam (instant ray). Quantity fires several.",
		"Every rune must sit inside a zone of the right kind. Pick a zone pen in the toolbox and drag on the board to draw one.",
		"If routes all energy one way, Divide splits it. Sensors and Logic feed conditions and targeting.",
		"Vessels aim at your mouse unless something is wired into their Aim port: put an Aim rune in a Targeting zone and wire it in (feed it Nearest Entity, Cursor, etc.).",
		"Triggers are optional: wire a Vessel's Triggers port into On Impact / On Timer / etc. to run more of the circle mid-flight with a share of its energy.",
		"To cast: Save (your first saved spell is equipped automatically), close the editor with E, and click.",
	} do
		self:text(line, 12, Colors.muted)
	end
	sectionTitle(self.scroll, "Controls", self:nextOrder())
	for _, line in {
		"Right-drag: pan the view  ·  Wheel: zoom  ·  F: frame all",
		"Double-click a zone's tab to pick it up (drag, or click again to drop; Esc cancels)",
		"Drag a zone's edge or corner to resize",
		"L: lock/unlock the selected rune or zone",
		"Drag from a port to wire  ·  Del: delete  ·  Ctrl+D: duplicate",
		"Ctrl+Z / Ctrl+Y: undo / redo  ·  Shift while drawing: keep the pen",
	} do
		self:text(line, 12, Colors.muted)
	end
end

-- context: { selection, errors, estimates, analysis }
function Inspector:show(context: any)
	self.context = context
	if self.slider then return end -- don't rebuild the slider being dragged
	self:clear()
	local selection = context.selection
	local doc = self.hooks.doc()
	if selection and selection.kind == "rune" and doc:rune(selection.id) then
		self:showRune(doc:rune(selection.id), context)
	elseif selection and selection.kind == "zone" and doc:zone(selection.id) then
		self:showZone(doc:zone(selection.id))
	elseif selection and selection.kind == "wire" then
		self:showWire(selection.wire)
	else
		self:showOverview(context)
	end
end

function Inspector:refresh()
	if self.context then self:show(self.context) end
end

--------------------------------------------------------------------------------
-- Problems overlay
--------------------------------------------------------------------------------

local Problems = {}
Problems.__index = Problems
Panels.Problems = Problems

-- hooks: onFocus(problem)
function Problems.new(parent: Frame, hooks: any)
	local self = setmetatable({}, Problems)
	self.hooks = hooks
	self.expanded = true
	local frame = Theme.make("Frame", {
		Name = "Problems",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -12),
		Size = UDim2.new(0.5, 0, 0, 36),
		BackgroundColor3 = Colors.panel,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		Active = true,
		ZIndex = 10,
	}, parent)
	Theme.corner(frame, 8)
	self.stroke = Theme.stroke(frame, Colors.line, 1, 0.3)
	Theme.make("UISizeConstraint", { MaxSize = Vector2.new(520, 260), MinSize = Vector2.new(240, 36) }, frame)
	self.frame = frame
	self.header = Theme.button(frame, "", {
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Theme.FontBold,
		ZIndex = 11,
	})
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 12) }, self.header)
	self.header.Activated:Connect(function()
		self.expanded = not self.expanded
		self:show(self.errors or {}, self.summary or "")
	end)
	self.list = scroller(frame, { Position = UDim2.fromOffset(8, 36), Size = UDim2.new(1, -12, 1, -42), ZIndex = 11 })
	Theme.list(self.list, 4)
	return self
end

function Problems:show(errors: { any }, summary: string)
	self.errors, self.summary = errors, summary
	for _, child in self.list:GetChildren() do
		if child:IsA("GuiObject") then child:Destroy() end
	end
	local count = #errors
	if count == 0 then
		self.header.Text = "✓  " .. summary
		self.header.TextColor3 = Colors.good
		self.stroke.Color = Colors.good
	else
		self.header.Text = `✖  {count} problem{if count == 1 then "" else "s"}   {if self.expanded then "▾" else "▸"}`
		self.header.TextColor3 = Colors.bad
		self.stroke.Color = Colors.bad
	end
	local expanded = self.expanded and count > 0
	self.list.Visible = expanded
	self.frame.Size = UDim2.new(0.5, 0, 0, if expanded then 44 + math.min(count, 7) * 30 else 36)
	for index, problem in errors do
		local item = Theme.button(self.list, problem.message, {
			LayoutOrder = index,
			Size = UDim2.new(1, -6, 0, 26),
			BackgroundColor3 = Colors.panel2,
			TextSize = 12,
			Font = Theme.Font,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 12,
		})
		Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, item)
		item.Activated:Connect(function() self.hooks.onFocus(problem) end)
	end
end

return Panels
