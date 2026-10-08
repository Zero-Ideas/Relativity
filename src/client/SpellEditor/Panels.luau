--!strict
--[[
	Side panels for the spell editor:
	 Toolbox   -- search, zone pens, and the rune palette in collapsible
	              categories (one compact row per rune); hovering a rune shows
	              what it does in the info box at the bottom (left)
	 Inspector -- whatever is selected: rune settings, zone kind/label, wire,
	              or a summary of the spell when nothing is (right)
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

local WHITE = Color3.new(1, 1, 1)
local ROW = 30
local INFO_HEIGHT = 96
local DROPDOWN_OVER = 4 -- enums with more options than this use a dropdown

local function scroller(parent: Instance, props: { [string]: any }?): ScrollingFrame
	local scroll = Theme.make("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
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

-- Which categories start open (the rest are a click away); kept for the session.
local collapsed: { [string]: boolean } = {
	Targeting = true, Sensor = true, Logic = true, Vector = true, Branch = true, Modifier = true, Trigger = true,
}
local zonesOpen = true

local HINT = "Hover a rune to see what it does. Drag it onto a zone of its colour, or click it to drop it mid-board."

-- hooks: onArmZone(kind?), onRunePress(runeId)
function Toolbox.new(parent: Frame, hooks: any)
	local self = setmetatable({}, Toolbox)
	self.hooks = hooks
	self.zoneChips = {} :: { [string]: TextButton }
	self.items = {} :: { { frame: GuiObject, text: string, category: string } }
	self.sections = {} :: { [string]: { header: TextButton, body: Frame, count: number, label: string } }
	self.query = ""

	local search = Theme.make("TextBox", {
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 32),
		BackgroundColor3 = Colors.panel2,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = Theme.Font,
		PlaceholderText = "🔍  Search runes…",
		PlaceholderColor3 = Colors.muted,
		Text = "",
		TextColor3 = Colors.text,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, parent)
	Theme.corner(search, 8)
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 10) }, search)
	search:GetPropertyChangedSignal("Text"):Connect(function()
		self:filter(search.Text)
	end)

	local scroll = scroller(parent, { Position = UDim2.fromOffset(8, 50), Size = UDim2.new(1, -10, 1, -58 - INFO_HEIGHT) })
	Theme.list(scroll, 2)
	Theme.make("UIPadding", { PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 10) }, scroll)

	-- what the hovered rune does
	local info = Theme.make("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 8, 1, -8),
		Size = UDim2.new(1, -16, 0, INFO_HEIGHT - 8),
		BackgroundColor3 = Colors.panel2,
		BorderSizePixel = 0,
	}, parent)
	Theme.corner(info, 8)
	Theme.padding(info, 8)
	self.infoTitle = Theme.label(info, "Runes", 13, { Font = Theme.FontBold, Size = UDim2.new(1, 0, 0, 18) })
	self.infoBody = Theme.label(info, HINT, 11, {
		Position = UDim2.fromOffset(0, 20),
		Size = UDim2.new(1, 0, 1, -20),
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = Colors.muted,
	})

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	-- a collapsible section: header row + body
	local function section(key: string, label: string, color: Color3, open: boolean): Frame
		local header = Theme.button(scroll, "", {
			LayoutOrder = nextOrder(),
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
		})
		local title = Theme.label(header, "", 11, {
			Font = Theme.FontBold,
			Position = UDim2.fromOffset(4, 0),
			Size = UDim2.new(1, -8, 1, 0),
			TextColor3 = color,
		})
		local body = Theme.make("Frame", {
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = nextOrder(),
			Visible = open,
		}, scroll)
		local entry = { header = header, body = body, count = 0, label = label, title = title, open = open }
		self.sections[key] = entry :: any
		header.Activated:Connect(function()
			entry.open = not entry.open
			if key == "Zones" then
				zonesOpen = entry.open
			else
				collapsed[key] = not entry.open
			end
			self:filter(self.query)
		end)
		return body
	end

	-- Zones: pens
	local zoneBody = section("Zones", "Zones · click a pen, drag on the board", Colors.muted, zonesOpen)
	local grid = Theme.make("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0) }, zoneBody)
	Theme.make("UIGridLayout", { CellSize = UDim2.new(0.5, -3, 0, 26), CellPadding = UDim2.fromOffset(6, 5), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
	Theme.make("UIPadding", { PaddingBottom = UDim.new(0, 6) }, zoneBody)
	for index, kind in SpellRunes.ZoneKinds do
		local color = SpellRunes.Zones[kind].Color
		local chip = Theme.button(grid, kind, {
			LayoutOrder = index,
			BackgroundColor3 = color:Lerp(Colors.panel, 0.72),
			TextColor3 = color:Lerp(WHITE, 0.55),
			TextSize = 12,
		})
		chip.Activated:Connect(function()
			hooks.onArmZone(if self.armed == kind then nil else kind)
		end)
		chip.MouseEnter:Connect(function()
			self:showInfo(`{kind} zone`, SpellRunes.Zones[kind].Description)
		end)
		chip.MouseLeave:Connect(function() self:showInfo(nil, nil) end)
		self.zoneChips[kind] = chip
	end
	(self.sections.Zones :: any).count = #SpellRunes.ZoneKinds

	-- Runes, by category
	for _, category in SpellRunes.Categories do
		local color: Color3? = nil
		for _, runeId in SpellRunes.Order do
			local def = SpellRunes.Runes[runeId]
			if def.Category == category then
				color = Board.categoryColor(def)
				break
			end
		end
		if not color then
			continue
		end
		local label = SpellRunes.CategoryLabels[category] or category
		local body = section(category, label, (color :: Color3):Lerp(WHITE, 0.35), not collapsed[category])
		Theme.list(body, 2)
		Theme.make("UIPadding", { PaddingBottom = UDim.new(0, 6) }, body)
		local count = 0
		for _, runeId in SpellRunes.Order do
			local def = SpellRunes.Runes[runeId]
			if def.Category ~= category then
				continue
			end
			count += 1
			local item = Theme.button(body, "", {
				LayoutOrder = count,
				Size = UDim2.new(1, 0, 0, ROW),
				BackgroundColor3 = Colors.panel2,
				AutoButtonColor = true,
			})
			Theme.make("Frame", { Size = UDim2.new(0, 3, 1, -12), Position = UDim2.fromOffset(5, 6), BackgroundColor3 = color, BorderSizePixel = 0 }, item)
			Theme.label(item, def.Glyph or "•", 15, {
				Font = Theme.FontBold,
				Position = UDim2.fromOffset(12, 0),
				Size = UDim2.new(0, 22, 1, 0),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextColor3 = (color :: Color3):Lerp(WHITE, 0.45),
			})
			Theme.label(item, def.Name, 13, { Font = Theme.FontMedium, Position = UDim2.fromOffset(40, 0), Size = UDim2.new(1, -46, 1, 0) })
			item.MouseEnter:Connect(function()
				self:showInfo(SpellRunes.DisplayName(def), def.Description)
			end)
			item.MouseLeave:Connect(function() self:showInfo(nil, nil) end)
			item.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					hooks.onRunePress(runeId)
				end
			end)
			table.insert(self.items, { frame = item, text = string.lower(def.Name .. " " .. (def.Glyph or "") .. " " .. category .. " " .. label .. " " .. def.Description), category = category })
		end
		(self.sections[category] :: any).count = count
	end
	self:filter("")
	return self
end

function Toolbox:showInfo(title: string?, body: string?)
	self.infoTitle.Text = title or "Runes"
	self.infoBody.Text = body or HINT
end

function Toolbox:setArmed(kind: string?)
	self.armed = kind
	for chipKind, chip in self.zoneChips do
		local color = SpellRunes.Zones[chipKind].Color
		chip.BackgroundColor3 = if chipKind == kind then color:Lerp(Colors.panel, 0.25) else color:Lerp(Colors.panel, 0.72)
	end
end

function Toolbox:filter(query: string)
	self.query = query
	query = string.lower(query)
	local searching = query ~= ""
	local matches: { [string]: number } = {}
	for _, item in self.items do
		local visible = not searching or string.find(item.text, query, 1, true) ~= nil
		item.frame.Visible = visible
		if visible then
			matches[item.category] = (matches[item.category] or 0) + 1
		end
	end
	for key, entry in self.sections :: any do
		local found = if key == "Zones" then entry.count else (matches[key] or 0)
		local shown = if key == "Zones" then not searching else found > 0
		local open = if searching then true else entry.open
		entry.header.Visible = shown
		entry.body.Visible = shown and open
		entry.title.Text = `{if open then "▾" else "▸"}  {string.upper(entry.label)}   {found}`
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
	self.showPorts = false
	self.dropdown = nil :: string? -- the enum param whose list is open

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

-- A small rounded tag ("120 mana", "✓ Ready").
local function chip(parent: Instance, text: string, color: Color3, order: number): TextLabel
	local label = Theme.label(parent, text, 12, {
		Font = Theme.FontMedium,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 22),
		BackgroundTransparency = 0,
		BackgroundColor3 = color:Lerp(Colors.panel, 0.78),
		TextColor3 = color:Lerp(WHITE, 0.3),
		TextXAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = order,
	})
	Theme.corner(label, 11)
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 9), PaddingRight = UDim.new(0, 9) }, label)
	return label
end

function Inspector:chips(entries: { { any } })
	local row = Theme.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = self:nextOrder() }, self.scroll)
	Theme.list(row, 6, true)
	for index, entry in entries do
		chip(row, entry[1], entry[2], index)
	end
end

-- Header: a glyph badge, title and subtitle, and small action buttons.
function Inspector:header(glyph: string, title: string, subtitle: string, color: Color3, actions: { { any } }?)
	local frame = Theme.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = self:nextOrder() }, self.scroll)
	local badge = Theme.label(frame, glyph, 20, {
		Font = Theme.FontBold,
		Size = UDim2.fromOffset(44, 44),
		BackgroundTransparency = 0,
		BackgroundColor3 = color:Lerp(Colors.panel, 0.6),
		TextColor3 = color:Lerp(WHITE, 0.55),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	Theme.corner(badge, 10)
	Theme.stroke(badge, color, 1, 0.4)
	local buttons = actions or {}
	local reserve = #buttons * 34
	Theme.label(frame, title, 16, {
		Font = Theme.FontBold,
		Position = UDim2.fromOffset(54, 2),
		Size = UDim2.new(1, -(56 + reserve), 0, 22),
		TextColor3 = color:Lerp(WHITE, 0.6),
	})
	Theme.label(frame, subtitle, 11, {
		Position = UDim2.fromOffset(54, 24),
		Size = UDim2.new(1, -(56 + reserve), 0, 16),
		TextColor3 = Colors.muted,
	})
	for index, action in buttons do
		local button = Theme.button(frame, action[1], {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -(index - 1) * 34, 0, 6),
			Size = UDim2.fromOffset(30, 30),
			BackgroundColor3 = action[3] or Colors.panel3,
			TextSize = 14,
		})
		button.Activated:Connect(action[2])
	end
end

-- A collapsible sub-heading; returns whether it's open.
function Inspector:fold(title: string, open: boolean, toggle: () -> ()): boolean
	local header = Theme.button(self.scroll, `{if open then "▾" else "▸"}  {string.upper(title)}`, {
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Font = Theme.FontBold,
		TextSize = 11,
		TextColor3 = Colors.muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = self:nextOrder(),
	})
	header.Activated:Connect(toggle)
	return open
end

local function formatValue(value: number): string
	return tostring(tonumber(string.format("%.4f", value)))
end

function Inspector:numberParam(rune: any, param: any)
	local row = Theme.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 46), LayoutOrder = self:nextOrder() }, self.scroll)
	Theme.label(row, param.Label, 12, { Size = UDim2.new(1, -124, 0, 24), TextColor3 = Colors.muted })
	local value = rune.params[param.Name]
	local minValue, maxValue, step = param.Min, param.Max, param.Step or 1

	local function commit(newValue: number, live: boolean?)
		newValue = math.clamp(math.floor(newValue / step + 0.5) * step, minValue, maxValue)
		newValue = tonumber(string.format("%.4f", newValue)) :: number
		local apply = function() rune.params[param.Name] = newValue end
		if live then self.hooks.liveEdit(apply) else self.hooks.edit(apply) end
	end

	local minus = Theme.button(row, "−", { Position = UDim2.new(1, -120, 0, 0), Size = UDim2.fromOffset(26, 24), BackgroundColor3 = Colors.panel2 })
	local box = Theme.make("TextBox", {
		Position = UDim2.new(1, -90, 0, 0),
		Size = UDim2.fromOffset(60, 24),
		BackgroundColor3 = Colors.panel2,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = Theme.FontMedium,
		Text = formatValue(value) .. (param.Suffix or ""),
		TextColor3 = Colors.text,
		TextSize = 13,
	}, row)
	Theme.corner(box, 6)
	local plus = Theme.button(row, "+", { Position = UDim2.new(1, -26, 0, 0), Size = UDim2.fromOffset(26, 24), BackgroundColor3 = Colors.panel2 })
	minus.Activated:Connect(function() commit(value - step) end)
	plus.Activated:Connect(function() commit(value + step) end)
	box.Focused:Connect(function() box.Text = formatValue(value) end)
	box.FocusLost:Connect(function()
		local parsed = tonumber(string.match(box.Text, "%-?[%d%.]+") or "")
		if parsed then commit(parsed) else self:refresh() end
	end)

	local track = Theme.make("Frame", {
		Position = UDim2.fromOffset(2, 34),
		Size = UDim2.new(1, -4, 0, 6),
		BackgroundColor3 = Colors.panel3,
		BorderSizePixel = 0,
		Active = true,
	}, row)
	Theme.corner(track, 3)
	local alpha = (value - minValue) / math.max(maxValue - minValue, 1e-6)
	local fill = Theme.make("Frame", { Size = UDim2.fromScale(alpha, 1), BackgroundColor3 = Colors.accent, BorderSizePixel = 0 }, track)
	Theme.corner(fill, 3)
	local knob = Theme.make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(alpha, 0.5),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
	}, track)
	Theme.corner(knob, 7)
	local function update(pointer: Vector2)
		local t = math.clamp((pointer.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		local newValue = minValue + t * (maxValue - minValue)
		newValue = math.clamp(math.floor(newValue / step + 0.5) * step, minValue, maxValue)
		local shown = (newValue - minValue) / math.max(maxValue - minValue, 1e-6)
		fill.Size = UDim2.fromScale(shown, 1)
		knob.Position = UDim2.fromScale(shown, 0.5)
		box.Text = formatValue(newValue) .. (param.Suffix or "")
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
	local current = rune.params[param.Name]
	local options = param.Options :: { string }
	if #options > DROPDOWN_OVER then
		-- a dropdown: the current value, opening into the list
		local row = Theme.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = self:nextOrder() }, self.scroll)
		Theme.label(row, param.Label, 12, { Size = UDim2.new(0.4, 0, 1, 0), TextColor3 = Colors.muted })
		local open = self.dropdown == param.Name
		local button = Theme.button(row, `{current}   {if open then "▴" else "▾"}`, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0.6, 0, 1, 0),
			BackgroundColor3 = Colors.panel2,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 10) }, button)
		button.Activated:Connect(function()
			self.dropdown = if open then nil else param.Name
			self:refresh()
		end)
		if open then
			local list = Theme.make("Frame", { BackgroundColor3 = Colors.panel2, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), LayoutOrder = self:nextOrder() }, self.scroll)
			Theme.corner(list, 6)
			Theme.padding(list, 4)
			Theme.make("UIGridLayout", { CellSize = UDim2.new(0.5, -2, 0, 26), CellPadding = UDim2.fromOffset(4, 3), SortOrder = Enum.SortOrder.LayoutOrder }, list)
			for index, option in options do
				local pick = Theme.button(list, option, {
					LayoutOrder = index,
					TextSize = 12,
					BackgroundColor3 = if option == current then Colors.accent:Lerp(Colors.panel, 0.35) else Colors.panel3,
				})
				pick.Activated:Connect(function()
					self.dropdown = nil
					self.hooks.edit(function() rune.params[param.Name] = option end)
				end)
			end
		end
		return
	end
	-- a few options: a segmented row
	Theme.label(self.scroll, param.Label, 12, { Size = UDim2.new(1, 0, 0, 16), TextColor3 = Colors.muted, LayoutOrder = self:nextOrder() })
	local grid = Theme.make("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), LayoutOrder = self:nextOrder() }, self.scroll)
	local columns = math.max(#options, 1)
	Theme.make("UIGridLayout", { CellSize = UDim2.new(1 / columns, -4, 0, 26), CellPadding = UDim2.fromOffset(4, 4), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
	for index, option in options do
		local active = current == option
		local segment = Theme.button(grid, option, {
			LayoutOrder = index,
			TextSize = 12,
			BackgroundColor3 = if active then Colors.accent:Lerp(Colors.panel, 0.35) else Colors.panel2,
		})
		segment.Activated:Connect(function()
			self.hooks.edit(function() rune.params[param.Name] = option end)
		end)
	end
end

function Inspector:boolParam(rune: any, param: any)
	local row = Theme.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = self:nextOrder() }, self.scroll)
	Theme.label(row, param.Label, 12, { Size = UDim2.new(1, -60, 1, 0), TextColor3 = Colors.muted })
	local on = rune.params[param.Name] == true
	local pill = Theme.button(row, "", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(44, 22),
		BackgroundColor3 = if on then Colors.good:Lerp(Colors.panel, 0.35) else Colors.panel3,
		AutoButtonColor = false,
	})
	Theme.corner(pill, 11)
	local knob = Theme.make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(if on then 1 else 0, if on then -11 else 11, 0.5, 0),
		Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
	}, pill)
	Theme.corner(knob, 8)
	pill.Activated:Connect(function()
		self.hooks.edit(function() rune.params[param.Name] = not on end)
	end)
end

-- A param whose input port has a wire plugged in: the wire wins.
function Inspector:wiredParam(param: any)
	local row = Theme.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = self:nextOrder() }, self.scroll)
	Theme.label(row, param.Label, 12, { Size = UDim2.new(0.5, 0, 1, 0), TextColor3 = Colors.muted })
	Theme.label(row, "◀ from its wire", 12, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.5, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = SpellRunes.PortColors.number,
	})
end

local function categoryNoun(def: any): string
	return SpellRunes.CategoryLabels[def.Category] or def.Category
end

function Inspector:showRune(rune: any, context: any)
	local def = SpellRunes.Runes[rune.rune]
	local color = Board.categoryColor(def)
	local doc = self.hooks.doc()
	self:header(def.Glyph or "•", def.Name, `{categoryNoun(def)} · {table.concat(def.Zones, " / ")} zone`, color, {
		{ "🗑", self.hooks.delete, Color3.fromRGB(110, 40, 58) },
		{ if rune.locked then "🔒" else "🔓", function()
			self.hooks.edit(function() rune.locked = if rune.locked then nil else true end)
		end },
	})
	self:text(def.Description, 12, Colors.muted)
	for _, problem in context.errors do
		if problem.rune == rune.id then
			self:text("✖ " .. problem.message, 12, Colors.bad)
		end
	end
	for _, warning in (context.analysis and context.analysis.warnings) or {} do
		if warning.rune == rune.id then
			self:text("⚠ " .. warning.message, 12, Colors.warn)
		end
	end
	local estimate = context.estimates and context.estimates[rune.id]
	if estimate then
		local tags = {}
		if estimate.energy then
			table.insert(tags, { `⚡ {math.floor(estimate.energy + 0.5)} energy`, SpellRunes.PortColors.flow })
		end
		if estimate.damage then
			local count = if estimate.count and estimate.count > 1 then ` ×{estimate.count}` else ""
			table.insert(tags, { `{math.floor(estimate.damage + 0.5)} damage{count}`, Colors.bad })
		elseif estimate.text and estimate.text ~= "" then
			table.insert(tags, { estimate.text, Colors.good })
		end
		if #tags > 0 then
			self:chips(tags)
		end
	end

	if #def.Params > 0 then
		sectionTitle(self.scroll, "Settings", self:nextOrder())
		-- params fed by a wire show that instead of a control
		local wiredParams = {}
		for _, port in def.Inputs do
			if port.Param and #doc:wiresInto(rune.id, port.Name) > 0 then
				wiredParams[port.Param] = true
			end
		end
		for _, param in def.Params do
			if wiredParams[param.Name] then
				self:wiredParam(param)
			elseif param.Type == "number" then
				self:numberParam(rune, param)
			elseif param.Type == "enum" then
				self:enumParam(rune, param)
			else
				self:boolParam(rune, param)
			end
		end
	end

	if #def.Inputs + #def.Outputs > 0 then
		if self:fold(`Ports ({#def.Inputs + #def.Outputs})`, self.showPorts, function()
			self.showPorts = not self.showPorts
			self:refresh()
		end) then
			local function describe(prefix: string, port: any)
				local suffix = if port.Multi then ", many" elseif port.Param then ", or the setting" elseif port.Optional then ", optional" else ""
				local typeName = if port.Type == "vessel" then "trigger link" else port.Type
				self:text(`{prefix} {port.Label}  ({typeName}{suffix})`, 12, SpellRunes.PortColors[port.Type])
			end
			for _, port in def.Inputs do describe("◀", port) end
			for _, port in def.Outputs do describe("▶", port) end
		end
	end
end

function Inspector:showZone(zone: any)
	local kind = SpellRunes.Zones[zone.kind]
	local inside = #self.hooks.doc():runesInZone(zone)
	self:header((kind :: any).Glyph or "▢", `{zone.kind} zone`, `{inside} rune{if inside == 1 then "" else "s"} · {zone.w} × {zone.h}`, kind.Color, {
		{ "🗑", self.hooks.delete, Color3.fromRGB(110, 40, 58) },
		{ if zone.locked then "🔒" else "🔓", function()
			self.hooks.edit(function() zone.locked = if zone.locked then nil else true end)
		end },
	})
	self:text(kind.Description, 12, Colors.muted)

	sectionTitle(self.scroll, "Label", self:nextOrder())
	local box = Theme.make("TextBox", {
		Size = UDim2.new(1, 0, 0, 30),
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
	Theme.make("UIGridLayout", { CellSize = UDim2.new(0.5, -3, 0, 26), CellPadding = UDim2.fromOffset(6, 5), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
	for index, kindName in SpellRunes.ZoneKinds do
		local color = SpellRunes.Zones[kindName].Color
		local option = Theme.button(grid, kindName, {
			LayoutOrder = index,
			TextSize = 12,
			BackgroundColor3 = if kindName == zone.kind then color:Lerp(Colors.panel, 0.3) else color:Lerp(Colors.panel, 0.75),
		})
		option.Activated:Connect(function()
			if kindName ~= zone.kind then
				self.hooks.edit(function() zone.kind = kindName end)
			end
		end)
	end
	self:text("Double-click the zone's tab to pick it up with everything inside (locked runes stay put). Drag an edge or corner to resize.", 11, Colors.muted)
end

function Inspector:showWire(wire: any)
	local doc = self.hooks.doc()
	local from, to = doc:rune(wire.from), doc:rune(wire.to)
	local fromDef = from and SpellRunes.Runes[from.rune]
	local toDef = to and SpellRunes.Runes[to.rune]
	local fromPort = fromDef and SpellRunes.FindPort(fromDef.Outputs, wire.fromPort)
	local toPort = toDef and SpellRunes.FindPort(toDef.Inputs, wire.toPort)
	local color = if fromPort then SpellRunes.PortColors[fromPort.Type] else Colors.text
	self:header("⟶", "Wire", if fromPort then `carries {fromPort.Type}` else "", color, {
		{ "🗑", self.hooks.delete, Color3.fromRGB(110, 40, 58) },
	})
	self:text(`{if fromDef then fromDef.Name else wire.from} · {if fromPort then fromPort.Label else wire.fromPort}`, 13)
	self:text("  ↓", 13, Colors.muted)
	self:text(`{if toDef then toDef.Name else wire.to} · {if toPort then toPort.Label else wire.toPort}`, 13)
	self:text("Drag a connected input port to pick its wire back up.", 11, Colors.muted)
end

function Inspector:showOverview(context: any)
	local doc = self.hooks.doc()
	local analysis = context.analysis
	local name = if doc.graph.name ~= "" then doc.graph.name else "Untitled spell"
	self:header("✦", name, "Nothing selected · the whole spell", Colors.accent)
	local tags = {}
	if analysis then
		table.insert(tags, { `{analysis.manaCost} mana`, SpellRunes.PortColors.flow })
	end
	if #context.errors == 0 then
		table.insert(tags, { "✓ Ready to save", Colors.good })
	else
		table.insert(tags, { `✖ {#context.errors} problem{if #context.errors == 1 then "" else "s"}`, Colors.bad })
	end
	self:chips(tags)

	-- what each vessel does
	local lines = {}
	for _, rune in doc.graph.runes do
		local def = SpellRunes.Runes[rune.rune]
		local estimate = analysis and analysis.estimates[rune.id]
		if def and def.Vessel and estimate then
			local what = if estimate.damage then `{math.floor(estimate.damage + 0.5)} damage{if estimate.count and estimate.count > 1 then ` ×{estimate.count}` else ""}`
				else (estimate.text or "")
			table.insert(lines, `{def.Glyph or "•"}  {def.Name}{if what ~= "" then "  —  " .. what else ""}`)
		end
	end
	if #lines > 0 then
		sectionTitle(self.scroll, "What it does", self:nextOrder())
		for _, line in lines do
			self:text(line, 12)
		end
	end
	-- soft limits: still valid, but these parts won't work (SpellCompiler)
	for _, warning in (analysis and analysis.warnings) or {} do
		self:text(`⚠ {warning.message}`, 12, Colors.warn)
	end

	sectionTitle(self.scroll, "Getting started", self:nextOrder())
	for _, line in {
		"Mana Well → a Transform (Fire, Arcane, Shock) → a Vessel. Utility vessels (Barrier, Force, Blink, Body Effect, Time Field) don't need a Transform.",
		"Every rune sits in a zone of its colour: pick a pen under Zones and drag on the board.",
		"Click a rune to tune it here. Press ? in the top bar for the full guide.",
	} do
		self:text(line, 12, Colors.muted)
	end
end

-- context: { selection, errors, estimates, analysis }
function Inspector:show(context: any)
	self.context = context
	if self.slider then return end -- don't rebuild the slider being dragged
	local selection = context.selection
	local key = if selection then (selection.id or tostring(selection.wire)) else nil
	local same = key == self.lastKey
	if not same then
		self.dropdown = nil -- (a new selection starts with its dropdowns shut)
		self.lastKey = key
	end
	local scroll = if same then self.scroll.CanvasPosition else Vector2.zero
	self:clear()
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
	-- (keep the place when the same thing is rebuilt; after the canvas resizes)
	self.scroll.CanvasPosition = scroll
	task.defer(function()
		self.scroll.CanvasPosition = scroll
	end)
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
		Size = UDim2.new(0.5, 0, 0, 34),
		BackgroundColor3 = Colors.panel,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		Active = true,
		ZIndex = 10,
	}, parent)
	Theme.corner(frame, 8)
	self.stroke = Theme.stroke(frame, Colors.line, 1, 0.3)
	Theme.make("UISizeConstraint", { MaxSize = Vector2.new(520, 260), MinSize = Vector2.new(240, 34) }, frame)
	self.frame = frame
	self.header = Theme.button(frame, "", {
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Font = Theme.FontBold,
		TextSize = 12,
		ZIndex = 11,
	})
	Theme.make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, self.header)
	self.header.Activated:Connect(function()
		self.expanded = not self.expanded
		self:show(self.errors or {}, self.summary or "")
	end)
	self.list = scroller(frame, { Position = UDim2.fromOffset(8, 34), Size = UDim2.new(1, -12, 1, -40), ZIndex = 11 })
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
	self.frame.Size = UDim2.new(0.5, 0, 0, if expanded then 42 + math.min(count, 7) * 30 else 34)
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
