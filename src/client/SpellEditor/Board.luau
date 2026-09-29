--!strict
--[[
	The whiteboard: an infinite, pannable, zoomable board holding zones, runes
	and wires.

	Rendering: a World frame is offset by `pan` and scaled by a UIScale of
	`zoom`, so everything inside is laid out in board units. Wires are routed
	with right angles only -- ClipsDescendants doesn't clip rotated
	GuiObjects, so angled segments would bleed over the side panels.

	Input: every board element is a plain non-Active Frame/TextLabel, and the
	controller forwards UserInputService events here. The board hit-tests in
	board space itself (ports > runes > wires > zone edges > zone headers >
	zone bodies > empty) instead of relying on GUI event bubbling, which keeps
	drag behaviour predictable.

	Mouse: right-drag (or middle-drag) pans the view over anything; wheel
	zooms around the cursor. Left-drag a rune to move it. Double-click a
	zone's tab to pick the zone up: hold and drag, or let go and it follows
	the cursor until the next click (Esc puts it back). Drag a zone's
	edge/corner to resize -- the band reaches 20px outside the border (30px at
	corners) and 8px inside, never into the tab. Drag a port to wire.
	Locked runes/zones never move or resize.

	Coordinates: AbsolutePosition space starts BELOW the Roblox top bar even
	in an IgnoreGuiInset ScreenGui, so the pointer is GetMouseLocation()
	minus the inset (verified in a playtest with GuiState hover probing).
]]

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SpellCompiler = require(Shared:WaitForChild("SpellCompiler"))
local SpellRunes = require(Shared:WaitForChild("SpellRunes"))
local Theme = require(script.Parent.Theme)

local Board = {}
Board.__index = Board

local LAYOUT = SpellCompiler.Layout
local ZONE_HEADER = 32
local MIN_ZONE_W, MIN_ZONE_H = 160, 100
local DEFAULT_ZONE_W, DEFAULT_ZONE_H = 320, 220
local MIN_ZOOM, MAX_ZOOM = 0.25, 2
local PORT_RADIUS = 7
local GRID = 40
local SNAP = 10
local DRAG_THRESHOLD = 4 -- screen px before a press counts as a drag
local EDGE_OUT = 20 -- screen px outside a zone border that still resizes
local EDGE_IN = 8 -- ...and inside it (never into the tab)
local CORNER_OUT = 30 -- corners get bigger targets: they're the usual grab
local CORNER_IN = 16
local TAB_MIN = 28 -- the tab is at least this many screen px tall at any zoom
local DOUBLE_CLICK = 0.4 -- seconds between tab presses that start a zone move
local WIRE_REACH = 7 -- screen px

local CURSORS = {
	move = "rbxasset://SystemCursors/SizeAll",
	grab = "rbxasset://SystemCursors/ClosedHand",
	hand = "rbxasset://SystemCursors/PointingHand",
	cross = "rbxasset://SystemCursors/Cross",
	ew = "rbxasset://SystemCursors/SizeEW",
	ns = "rbxasset://SystemCursors/SizeNS",
	nwse = "rbxasset://SystemCursors/SizeNWSE",
	nesw = "rbxasset://SystemCursors/SizeNESW",
}

local WHITE = Color3.new(1, 1, 1)

local function snap(value: number): number
	return math.floor(value / SNAP + 0.5) * SNAP
end

local function isPress(input: InputObject): boolean
	local t = input.UserInputType
	return t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch
end

-- Pointer in AbsolutePosition space. That space starts below the Roblox top
-- bar even inside an IgnoreGuiInset ScreenGui, while GetMouseLocation()
-- starts at the very top of the window, so the inset must be subtracted.
-- (Touch InputObject positions are already in the right space.)
function Board.pointer(input: InputObject?): Vector2
	if input and input.UserInputType == Enum.UserInputType.Touch then
		return Vector2.new(input.Position.X, input.Position.Y)
	end
	return UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
end

function Board.categoryColor(def: any): Color3
	return SpellRunes.Zones[def.Zones[1]].Color
end

function Board.portPosition(rune: any, side: string, index: number): Vector2
	local y = rune.y + LAYOUT.Header + (index - 0.5) * LAYOUT.Row
	return Vector2.new(if side == "in" then rune.x else rune.x + LAYOUT.RuneWidth, y)
end

local function portIndex(ports: { any }, name: string): number?
	for index, port in ports do
		if port.Name == name then return index end
	end
	return nil
end

local function formatNumber(value: number): string
	if value % 1 == 0 then return tostring(value) end
	return string.format("%.1f", value)
end

-- One-line parameter summary shown in each rune's footer.
function Board.summary(rune: any): string
	local def = SpellRunes.Runes[rune.rune]
	local params = rune.params
	if def.Id == "Compare" or def.Id == "Math" then
		return `A {params.Op} B`
	end
	local parts = {}
	for _, param in def.Params do
		local value = params[param.Name]
		if param.Type == "bool" then
			if value then table.insert(parts, param.Label) end
		elseif param.Type == "number" then
			if param.Name == "Level" then
				table.insert(parts, `Lv {value}`)
			else
				table.insert(parts, formatNumber(value) .. (param.Suffix or ""))
			end
		else
			table.insert(parts, tostring(value))
		end
	end
	if #parts == 0 then
		return def.Category
	end
	return table.concat(parts, "  ·  ")
end

-- Right-angle route from an output port (a) to an input port (b).
local function route(a: Vector2, b: Vector2): { Vector2 }
	if b.X >= a.X + 30 then
		local mid = math.floor((a.X + b.X) / 2)
		return { a, Vector2.new(mid, a.Y), Vector2.new(mid, b.Y), b }
	end
	local out, back = a.X + 20, b.X - 20
	local lane = if math.abs(a.Y - b.Y) < 60 then math.max(a.Y, b.Y) + 70 else (a.Y + b.Y) / 2
	return { a, Vector2.new(out, a.Y), Vector2.new(out, lane), Vector2.new(back, lane), Vector2.new(back, b.Y), b }
end

local function distanceToSegment(p: Vector2, a: Vector2, b: Vector2): number
	local ab = b - a
	local lengthSq = ab:Dot(ab)
	local t = if lengthSq > 0 then math.clamp((p - a):Dot(ab) / lengthSq, 0, 1) else 0
	return (p - (a + ab * t)).Magnitude
end

function Board.new(viewport: Frame, doc: any, hooks: any)
	local self = setmetatable({}, Board)
	self.viewport = viewport
	self.doc = doc
	self.hooks = hooks
	self.pan = Vector2.new(60, 60)
	self.zoom = 1
	self.selection = nil :: any
	self.errors = {} :: { [string]: boolean }
	self.estimates = {} :: { [string]: any }
	self.overlays = {} :: { GuiObject }
	self.armedZone = nil :: string?
	self.drag = nil :: any
	self.zoneFrames = {} :: { [string]: Frame }
	self.zoneStrokes = {} :: { [string]: any }
	self.hoverZone = nil :: string?
	self.cursor = ""
	self.lastTabPress = nil :: any
	self.carry = nil :: any -- a double-clicked zone following the cursor
	self.runeFrames = {} :: { [string]: Frame }
	self.segments = {} :: { Frame }
	self.gridLines = {} :: { Frame }

	viewport.ClipsDescendants = true
	viewport.BackgroundColor3 = Theme.Colors.board
	self.gridLayer = Theme.make("Frame", { Name = "Grid", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 1 }, viewport)
	self.world = Theme.make("Frame", { Name = "World", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), ZIndex = 2 }, viewport)
	self.scale = Theme.make("UIScale", {}, self.world)
	local function layer(name: string, z: number): Frame
		return Theme.make("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), ZIndex = z }, self.world)
	end
	self.zoneLayer = layer("Zones", 1)
	self.wireLayer = layer("Wires", 2)
	self.runeLayer = layer("Runes", 3)
	self.previewLayer = layer("Preview", 4)
	self.drawPreview = Theme.make("Frame", { Visible = false, BackgroundTransparency = 0.85, BorderSizePixel = 0 }, self.previewLayer)
	Theme.corner(self.drawPreview, 10)
	self.drawStroke = Theme.stroke(self.drawPreview, WHITE, 2, 0)

	viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:renderGrid()
	end)
	self:applyTransform()
	return self
end

--------------------------------------------------------------------------------
-- View
--------------------------------------------------------------------------------

function Board:toWorld(p: Vector2): Vector2
	return (p - self.viewport.AbsolutePosition - self.pan) / self.zoom
end

function Board:applyTransform()
	self.world.Position = UDim2.fromOffset(self.pan.X, self.pan.Y)
	self.scale.Scale = self.zoom
	self:renderGrid()
	if self.hooks.onView then
		self.hooks.onView(self.zoom)
	end
end

function Board:zoomAt(screen: Vector2, zoom: number)
	zoom = math.clamp(zoom, MIN_ZOOM, MAX_ZOOM)
	local world = self:toWorld(screen)
	self.zoom = zoom
	self.pan = screen - self.viewport.AbsolutePosition - world * zoom
	self:applyTransform()
	self:render() -- zone handles are sized in screen pixels
end

function Board:zoomBy(factor: number)
	local center = self.viewport.AbsolutePosition + self.viewport.AbsoluteSize / 2
	self:zoomAt(center, self.zoom * factor)
end

function Board:centerOn(point: Vector2)
	self.pan = self.viewport.AbsoluteSize / 2 - point * self.zoom
	self:applyTransform()
end

-- Screen-centre in board units (where click-to-place drops runes).
function Board:viewCenter(): Vector2
	return self:toWorld(self.viewport.AbsolutePosition + self.viewport.AbsoluteSize / 2)
end

function Board:frameAll()
	local graph = self.doc.graph
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	local function include(x: number, y: number, w: number, h: number)
		minX, minY = math.min(minX, x), math.min(minY, y)
		maxX, maxY = math.max(maxX, x + w), math.max(maxY, y + h)
	end
	for _, zone in graph.zones do include(zone.x, zone.y, zone.w, zone.h) end
	for _, rune in graph.runes do include(rune.x, rune.y, LAYOUT.RuneWidth, SpellCompiler.RuneHeight(rune.rune)) end
	if minX == math.huge then
		self.zoom = 1
		self.pan = Vector2.new(60, 60)
	else
		local size = self.viewport.AbsoluteSize
		local margin = 60
		local zoom = math.min((size.X - margin * 2) / math.max(maxX - minX, 1), (size.Y - margin * 2) / math.max(maxY - minY, 1))
		self.zoom = math.clamp(zoom, MIN_ZOOM, 1.25)
		self.pan = size / 2 - Vector2.new(minX + maxX, minY + maxY) / 2 * self.zoom
	end
	self:applyTransform()
	self:render()
end

function Board:renderGrid()
	local size = self.viewport.AbsoluteSize
	local spacing = GRID
	while spacing * self.zoom < 18 do spacing *= 2 end
	local step = spacing * self.zoom
	local used = 0
	local function line(vertical: boolean, offset: number)
		used += 1
		local frame = self.gridLines[used]
		if not frame then
			frame = Theme.make("Frame", { BorderSizePixel = 0, BackgroundColor3 = Theme.Colors.grid }, self.gridLayer)
			self.gridLines[used] = frame
		end
		frame.Visible = true
		if vertical then
			frame.Position = UDim2.fromOffset(offset, 0)
			frame.Size = UDim2.new(0, 1, 1, 0)
		else
			frame.Position = UDim2.fromOffset(0, offset)
			frame.Size = UDim2.new(1, 0, 0, 1)
		end
	end
	local x = self.pan.X % step
	while x < size.X do line(true, math.floor(x)); x += step end
	local y = self.pan.Y % step
	while y < size.Y do line(false, math.floor(y)); y += step end
	for index = used + 1, #self.gridLines do
		self.gridLines[index].Visible = false
	end
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

function Board:setAnnotations(errors: { [string]: boolean }, estimates: { [string]: any })
	self.errors = errors
	self.estimates = estimates
end

function Board:isSelected(kind: string, value: any): boolean
	local selection = self.selection
	if not selection or selection.kind ~= kind then return false end
	return if kind == "wire" then selection.wire == value else selection.id == value
end

function Board:select(selection: any)
	self.selection = selection
	self:render()
	if self.hooks.onSelect then self.hooks.onSelect(selection) end
end

-- Drops a selection whose target no longer exists (after undo, delete...).
function Board:validateSelection()
	local selection = self.selection
	if not selection then return end
	local graph = self.doc.graph
	local exists = if selection.kind == "rune" then self.doc:rune(selection.id) ~= nil
		elseif selection.kind == "zone" then self.doc:zone(selection.id) ~= nil
		else table.find(graph.wires, selection.wire) ~= nil
	if not exists then
		self.selection = nil
		if self.hooks.onSelect then self.hooks.onSelect(nil) end
	end
end

function Board:tabHeight(): number
	return math.max(ZONE_HEADER, TAB_MIN / self.zoom)
end

-- Zones in draw order. The selected zone is drawn (and hit-tested) last so
-- its handles are never buried under a neighbour.
function Board:orderedZones(): { any }
	local zones = self.doc.graph.zones
	local selection = self.selection
	if not selection or selection.kind ~= "zone" then
		return zones
	end
	local ordered, top = {}, nil
	for _, zone in zones do
		if zone.id == selection.id then top = zone else table.insert(ordered, zone) end
	end
	if top then table.insert(ordered, top) end
	return ordered
end

function Board:buildZone(zone: any)
	local kind = SpellRunes.Zones[zone.kind]
	local selected = self:isSelected("zone", zone.id)
	local frame = Theme.make("Frame", {
		Name = zone.id,
		Position = UDim2.fromOffset(zone.x, zone.y),
		Size = UDim2.fromOffset(zone.w, zone.h),
		BackgroundColor3 = kind.Color,
		BackgroundTransparency = if selected then 0.86 else 0.91,
		BorderSizePixel = 0,
	}, self.zoneLayer)
	Theme.corner(frame, 12)
	local stroke = Theme.stroke(frame, if selected then WHITE else kind.Color, if selected then 2.5 else 1.5, if selected then 0.1 else 0.35)
	self.zoneStrokes[zone.id] = { stroke = stroke, color = stroke.Color, thickness = stroke.Thickness, transparency = stroke.Transparency }
	local header = Theme.make("Frame", {
		Size = UDim2.new(1, 0, 0, self:tabHeight()),
		BackgroundColor3 = kind.Color,
		BackgroundTransparency = 0.72,
		BorderSizePixel = 0,
	}, frame)
	Theme.corner(header, 12)
	local title = (if zone.locked then "🔒 " else "") .. string.upper(zone.kind)
		.. if zone.label and zone.label ~= "" then `  ·  {zone.label}` else ""
	Theme.label(header, title, 14, {
		Font = Theme.FontBold,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -24, 1, 0),
		TextColor3 = kind.Color:Lerp(WHITE, 0.55),
	})
	if selected and not zone.locked then
		Theme.label(header, "double-click to move", 11, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -12, 0, 0),
			Size = UDim2.new(0.5, 0, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = kind.Color:Lerp(WHITE, 0.3),
			ZIndex = 2,
		})
	end
	-- Grips are sized in screen pixels so they stay grabbable at any zoom.
	-- Every unlocked zone shows its corners; the selected one also shows edge
	-- midpoints. Locked zones show none because they can't be resized.
	local size = (if selected then 14 else 10) / self.zoom
	local spots = if zone.locked then {} else { Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1) }
	if selected and not zone.locked then
		for _, spot in { Vector2.new(0.5, 0), Vector2.new(0, 0.5), Vector2.new(1, 0.5), Vector2.new(0.5, 1) } do
			table.insert(spots, spot)
		end
	end
	for _, spot in spots do
		local handle = Theme.make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(spot.X, spot.Y),
			Size = UDim2.fromOffset(size, size),
			BackgroundColor3 = if selected then WHITE else kind.Color,
			BackgroundTransparency = if selected then 0 else 0.25,
			BorderSizePixel = 0,
			ZIndex = 3,
		}, frame)
		Theme.corner(handle, 3)
	end
	self.zoneFrames[zone.id] = frame
end

function Board:estimateText(rune: any): string
	local estimate = self.estimates[rune.id]
	if not estimate then return "" end
	if estimate.damage then
		local text = `{math.floor(estimate.damage + 0.5)} dmg`
		return if estimate.count and estimate.count > 1 then `{text} ×{estimate.count}` else text
	end
	if estimate.energy then
		return `⚡{math.floor(estimate.energy + 0.5)}`
	end
	return ""
end

function Board:buildRune(rune: any)
	local def = SpellRunes.Runes[rune.rune]
	local color = Board.categoryColor(def)
	local selected = self:isSelected("rune", rune.id)
	local invalid = self.errors[rune.id] == true
	local height = SpellCompiler.RuneHeight(rune.rune)
	local width = LAYOUT.RuneWidth

	local card = Theme.make("Frame", {
		Name = rune.id,
		Position = UDim2.fromOffset(rune.x, rune.y),
		Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = Theme.Colors.panel2,
		BorderSizePixel = 0,
	}, self.runeLayer)
	Theme.corner(card, 8)
	Theme.stroke(card, if invalid then Theme.Colors.bad elseif selected then WHITE else color, if selected or invalid then 2.5 else 1.5, 0.05)

	local header = Theme.make("Frame", {
		Size = UDim2.new(1, 0, 0, LAYOUT.Header),
		BackgroundColor3 = color:Lerp(Theme.Colors.panel2, 0.5),
		BorderSizePixel = 0,
	}, card)
	Theme.corner(header, 8)
	-- square off the header's bottom corners
	Theme.make("Frame", {
		Position = UDim2.new(0, 0, 1, -8),
		Size = UDim2.new(1, 0, 0, 8),
		BackgroundColor3 = header.BackgroundColor3,
		BorderSizePixel = 0,
	}, header)
	Theme.label(header, (if rune.locked then "🔒 " else "") .. def.Name, 14, { Font = Theme.FontBold, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -86, 1, 0), ZIndex = 2 })
	Theme.label(header, self:estimateText(rune), 12, {
		Font = Theme.FontMedium,
		Position = UDim2.new(1, -80, 0, 0),
		Size = UDim2.new(0, 72, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = SpellRunes.PortColors.flow,
		ZIndex = 2,
	})

	local function port(side: string, index: number, portDef: any)
		local y = LAYOUT.Header + (index - 1) * LAYOUT.Row
		local isInput = side == "in"
		Theme.label(card, portDef.Label, 12, {
			Position = UDim2.fromOffset(if isInput then 14 else width / 2, y),
			Size = UDim2.fromOffset(width / 2 - 14, LAYOUT.Row),
			TextXAlignment = if isInput then Enum.TextXAlignment.Left else Enum.TextXAlignment.Right,
			TextColor3 = if portDef.Optional then Theme.Colors.muted else Theme.Colors.text,
		})
		local dot = Theme.make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(if isInput then 0 else width, y + LAYOUT.Row / 2),
			Size = UDim2.fromOffset(PORT_RADIUS * 2, PORT_RADIUS * 2),
			BackgroundColor3 = SpellRunes.PortColors[portDef.Type],
			BorderSizePixel = 0,
			ZIndex = 3,
		}, card)
		Theme.corner(dot, if portDef.Multi then 3 else PORT_RADIUS)
		Theme.stroke(dot, Theme.Colors.background, 2, 0)
	end
	for index, portDef in def.Inputs do port("in", index, portDef) end
	for index, portDef in def.Outputs do port("out", index, portDef) end

	Theme.label(card, Board.summary(rune), 12, {
		Position = UDim2.new(0, 10, 1, -LAYOUT.Footer),
		Size = UDim2.new(1, -20, 0, LAYOUT.Footer - 4),
		TextColor3 = Theme.Colors.muted,
	})
	self.runeFrames[rune.id] = card
end

function Board:render()
	self:validateSelection()
	for _, child in self.zoneLayer:GetChildren() do child:Destroy() end
	for _, child in self.runeLayer:GetChildren() do child:Destroy() end
	table.clear(self.zoneFrames)
	table.clear(self.zoneStrokes)
	table.clear(self.runeFrames)
	self.hoverZone = nil
	for _, zone in self:orderedZones() do self:buildZone(zone) end
	for _, rune in self.doc.graph.runes do self:buildRune(rune) end
	self:renderWires()
end

function Board:wireRoute(wire: any): ({ Vector2 }?, Color3?)
	local fromRune, toRune = self.doc:rune(wire.from), self.doc:rune(wire.to)
	if not fromRune or not toRune then return nil, nil end
	local fromDef, toDef = SpellRunes.Runes[fromRune.rune], SpellRunes.Runes[toRune.rune]
	local outIndex, inIndex = portIndex(fromDef.Outputs, wire.fromPort), portIndex(toDef.Inputs, wire.toPort)
	if not outIndex or not inIndex then return nil, nil end
	local a = Board.portPosition(fromRune, "out", outIndex)
	local b = Board.portPosition(toRune, "in", inIndex)
	return route(a, b), SpellRunes.PortColors[fromDef.Outputs[outIndex].Type]
end

function Board:renderWires()
	local used = 0
	local function draw(points: { Vector2 }, color: Color3, thickness: number)
		for index = 1, #points - 1 do
			local a, b = points[index], points[index + 1]
			used += 1
			local segment = self.segments[used]
			if not segment then
				segment = Theme.make("Frame", { BorderSizePixel = 0 }, self.wireLayer)
				self.segments[used] = segment
			end
			segment.Visible = true
			segment.BackgroundColor3 = color
			segment.Position = UDim2.fromOffset(math.min(a.X, b.X) - thickness / 2, math.min(a.Y, b.Y) - thickness / 2)
			segment.Size = UDim2.fromOffset(math.abs(b.X - a.X) + thickness, math.abs(b.Y - a.Y) + thickness)
		end
	end
	for _, wire in self.doc.graph.wires do
		local points, color = self:wireRoute(wire)
		if points and color then
			local selected = self:isSelected("wire", wire)
			draw(points, if selected then WHITE else color, if selected then 5 else 3)
		end
	end
	local drag = self.drag
	if drag and drag.kind == "wire" and drag.current then
		local anchorIndex = portIndex(if drag.side == "out" then SpellRunes.Runes[drag.rune.rune].Outputs else SpellRunes.Runes[drag.rune.rune].Inputs, drag.port.Name) :: number
		local anchor = Board.portPosition(drag.rune, drag.side, anchorIndex)
		local points = if drag.side == "out" then route(anchor, drag.current) else route(drag.current, anchor)
		draw(points, SpellRunes.PortColors[drag.port.Type]:Lerp(WHITE, 0.3), 3)
	end
	for index = used + 1, #self.segments do
		self.segments[index].Visible = false
	end
end

--------------------------------------------------------------------------------
-- Hit testing
--------------------------------------------------------------------------------

-- Resize hit for one zone, using signed distances from each border
-- (positive = inside). `outside`/`inside` are how far the band reaches past
-- and into the border; corners use cornerOut/cornerIn. The top border never
-- reaches inside because that's the tab. When both sides of an axis are in
-- reach (a zone that's tiny on screen) the nearer side wins.
local function zoneEdgeAt(zone: any, w: Vector2, outside: number, inside: number, cornerOut: number, cornerIn: number): any?
	local dl, dr = w.X - zone.x, zone.x + zone.w - w.X
	local dt, db = w.Y - zone.y, zone.y + zone.h - w.Y
	if math.min(dl, dr, dt, db) < -math.max(outside, cornerOut) then
		return nil
	end
	local function band(a: number, b: number, out: number, intoA: number, intoB: number): (boolean, boolean)
		local nearA = a >= -out and a <= intoA
		local nearB = b >= -out and b <= intoB
		if nearA and nearB then
			return a <= b, a > b
		end
		return nearA, nearB
	end
	local function result(left: boolean, right: boolean, top: boolean, bottom: boolean)
		return { kind = "zone-edge", zone = zone, left = left, right = right, top = top, bottom = bottom }
	end
	if math.min(dl, dr, dt, db) >= -cornerOut then
		local left, right = band(dl, dr, cornerOut, cornerIn, cornerIn)
		local top, bottom = band(dt, db, cornerOut, 0, cornerIn)
		if (left or right) and (top or bottom) then
			return result(left, right, top, bottom)
		end
	end
	if math.min(dl, dr, dt, db) < -outside then
		return nil
	end
	local left, right = band(dl, dr, outside, inside, inside)
	local top, bottom = band(dt, db, outside, 0, inside)
	if left or right or top or bottom then
		return result(left, right, top, bottom)
	end
	return nil
end

local function zoneContains(zone: any, w: Vector2): boolean
	return w.X >= zone.x and w.X <= zone.x + zone.w and w.Y >= zone.y and w.Y <= zone.y + zone.h
end

-- What a press at board point w would grab, respecting what's drawn on top:
--  1. ports (small, exact targets)
--  2. resize bands OUTSIDE a zone's border -- nothing of the zone is drawn
--     there, so this is pure leniency; skipped where a zone drawn above
--     covers the point
--  3. runes
--  4. wires
--  5. the topmost zone under the point: inner resize band, tab, or interior
function Board:hitTest(w: Vector2): any
	local graph = self.doc.graph
	local zones = self:orderedZones()
	local zoom = self.zoom

	local portReach = math.max(PORT_RADIUS + 3, 8 / zoom)
	for index = #graph.runes, 1, -1 do
		local rune = graph.runes[index]
		local def = SpellRunes.Runes[rune.rune]
		for portIndexValue, portDef in def.Inputs do
			if (Board.portPosition(rune, "in", portIndexValue) - w).Magnitude <= portReach then
				return { kind = "port", rune = rune, side = "in", port = portDef }
			end
		end
		for portIndexValue, portDef in def.Outputs do
			if (Board.portPosition(rune, "out", portIndexValue) - w).Magnitude <= portReach then
				return { kind = "port", rune = rune, side = "out", port = portDef }
			end
		end
	end

	for index = #zones, 1, -1 do
		local zone = zones[index]
		if not zone.locked and not zoneContains(zone, w) then
			local covered = false
			for above = index + 1, #zones do
				if zoneContains(zones[above], w) then covered = true break end
			end
			if not covered then
				local edge = zoneEdgeAt(zone, w, EDGE_OUT / zoom, 0, CORNER_OUT / zoom, 0)
				if edge then return edge end
			end
		end
	end

	for index = #graph.runes, 1, -1 do
		local rune = graph.runes[index]
		if w.X >= rune.x and w.X <= rune.x + LAYOUT.RuneWidth and w.Y >= rune.y and w.Y <= rune.y + SpellCompiler.RuneHeight(rune.rune) then
			return { kind = "rune", rune = rune }
		end
	end

	local wireReach = WIRE_REACH / zoom
	for _, wire in graph.wires do
		local points = self:wireRoute(wire)
		if points then
			for index = 1, #points - 1 do
				if distanceToSegment(w, points[index], points[index + 1]) <= wireReach then
					return { kind = "wire", wire = wire }
				end
			end
		end
	end

	for index = #zones, 1, -1 do
		local zone = zones[index]
		if zoneContains(zone, w) then
			if not zone.locked then
				local edge = zoneEdgeAt(zone, w, 0, EDGE_IN / zoom, 0, CORNER_IN / zoom)
				if edge then return edge end
			end
			return { kind = if w.Y <= zone.y + self:tabHeight() then "zone-tab" else "zone", zone = zone }
		end
	end
	return { kind = "empty" }
end

-- Nearest port on the opposite side of a wire drag that could accept it.
function Board:findDropPort(w: Vector2, drag: any): any?
	local reach = math.max(PORT_RADIUS * 2.5, 20 / self.zoom)
	local best, bestDistance = nil, reach
	local wantSide = if drag.side == "out" then "in" else "out"
	for _, rune in self.doc.graph.runes do
		if rune ~= drag.rune then
			local def = SpellRunes.Runes[rune.rune]
			for index, portDef in (if wantSide == "in" then def.Inputs else def.Outputs) do
				local compatible = if wantSide == "in" then SpellRunes.Compatible(drag.port.Type, portDef.Type)
					else SpellRunes.Compatible(portDef.Type, drag.port.Type)
				local distance = (Board.portPosition(rune, wantSide, index) - w).Magnitude
				if compatible and distance < bestDistance then
					best, bestDistance = { rune = rune, port = portDef }, distance
				end
			end
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Input (forwarded by the controller)
--------------------------------------------------------------------------------

function Board:addOverlay(frame: GuiObject)
	table.insert(self.overlays, frame)
end

-- Is this screen point on the board itself (inside the viewport, not over a
-- HUD overlay like the zoom buttons or problem list)?
function Board:accepts(p: Vector2): boolean
	local function inside(object: GuiObject): boolean
		local position, size = object.AbsolutePosition, object.AbsoluteSize
		return p.X >= position.X and p.Y >= position.Y and p.X <= position.X + size.X and p.Y <= position.Y + size.Y
	end
	if not self.viewport.Visible or not inside(self.viewport) then return false end
	for _, overlay in self.overlays do
		if overlay.Visible and inside(overlay) then return false end
	end
	return true
end

function Board:armZone(kind: string?)
	self.armedZone = kind
	if self.hooks.onArm then self.hooks.onArm(kind) end
end

function Board:changed()
	if self.hooks.onChanged then self.hooks.onChanged() end
end

-- Records undo exactly once per drag, on its first real movement.
local function recordOnce(self: any, drag: any)
	if not drag.recorded then
		drag.recorded = true
		self.doc:record()
	end
end

local function edgeCursor(hit: any): string
	local horizontal, vertical = hit.left or hit.right, hit.top or hit.bottom
	if horizontal and vertical then
		return if (hit.left and hit.top) or (hit.right and hit.bottom) then CURSORS.nwse else CURSORS.nesw
	end
	return if horizontal then CURSORS.ew else CURSORS.ns
end

function Board:setCursor(icon: string)
	if self.cursor ~= icon then
		self.cursor = icon
		UserInputService.MouseIcon = icon
	end
end

function Board:setHoverZone(id: string?)
	if self.hoverZone == id then return end
	local previous = self.hoverZone and self.zoneStrokes[self.hoverZone]
	if previous then
		previous.stroke.Color = previous.color
		previous.stroke.Thickness = previous.thickness
		previous.stroke.Transparency = previous.transparency
	end
	self.hoverZone = id
	local current = id and self.zoneStrokes[id]
	if current then
		current.stroke.Color = WHITE
		current.stroke.Thickness = 3
		current.stroke.Transparency = 0
	end
end

-- Previews what a press at p would do: cursor shape plus zone outline.
function Board:hover(p: Vector2)
	if not self:accepts(p) then
		self:setCursor("")
		self:setHoverZone(nil)
		return
	end
	if self.carry then
		self:setCursor(CURSORS.move)
		return
	end
	if self.armedZone then
		self:setCursor(CURSORS.cross)
		self:setHoverZone(nil)
		return
	end
	local hit = self:hitTest(self:toWorld(p))
	local zoneHit = hit.kind == "zone-edge" or hit.kind == "zone-tab"
	self:setHoverZone(if zoneHit then hit.zone.id else nil)
	if hit.kind == "zone-edge" then
		self:setCursor(edgeCursor(hit))
	elseif hit.kind == "zone-tab" then
		self:setCursor(if hit.zone.locked then "" else CURSORS.move)
	elseif hit.kind == "rune" then
		self:setCursor(if hit.rune.locked then "" else CURSORS.move)
	elseif hit.kind == "port" or hit.kind == "wire" then
		self:setCursor(CURSORS.hand)
	else
		self:setCursor("")
	end
end

local function message(self: any, text: string)
	if self.hooks.onMessage then self.hooks.onMessage(text) end
end

-- Moves a picked-up zone (and its unlocked runes) so the grab point follows w.
function Board:moveZone(drag: any, w: Vector2)
	recordOnce(self, drag)
	local delta = Vector2.new(snap(w.X - drag.start.X), snap(w.Y - drag.start.Y))
	local zone = drag.zone
	zone.x, zone.y = drag.origin.X + delta.X, drag.origin.Y + delta.Y
	local frame = self.zoneFrames[zone.id]
	if frame then frame.Position = UDim2.fromOffset(zone.x, zone.y) end
	for _, member in drag.members do
		member.rune.x, member.rune.y = member.x + delta.X, member.y + delta.Y
		local runeFrame = self.runeFrames[member.rune.id]
		if runeFrame then runeFrame.Position = UDim2.fromOffset(member.rune.x, member.rune.y) end
	end
	self:renderWires()
end

function Board:pickUpZone(zone: any, w: Vector2, p: Vector2)
	-- Locked runes are pinned to the board and stay put.
	local members = {}
	for _, rune in self.doc:runesInZone(zone) do
		if not rune.locked then
			table.insert(members, { rune = rune, x = rune.x, y = rune.y })
		end
	end
	self.drag = { kind = "zone", zone = zone, start = w, origin = Vector2.new(zone.x, zone.y), members = members, startScreen = p }
	self:setCursor(CURSORS.move)
end

-- Esc while carrying a zone puts it back. Returns true if it handled Esc.
function Board:cancel(): boolean
	local carry = self.carry
	if not carry then return false end
	self.carry = nil
	carry.zone.x, carry.zone.y = carry.origin.X, carry.origin.Y
	for _, member in carry.members do
		member.rune.x, member.rune.y = member.x, member.y
	end
	if carry.recorded then
		table.remove(self.doc.undoStack) -- nothing changed; drop its undo step
	end
	self:changed()
	return true
end

function Board:inputBegan(input: InputObject): boolean
	local t = input.UserInputType
	local p = Board.pointer(input)
	if not self:accepts(p) then return false end
	local w = self:toWorld(p)

	-- Right (or middle) drag always pans the view, whatever is under it.
	if t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.MouseButton3 then
		self.drag = { kind = "pan", button = t, start = p, startPan = self.pan }
		self:setCursor(CURSORS.grab)
		return true
	end
	if not isPress(input) then return false end

	if self.carry then
		-- A click drops the zone being carried.
		self.carry = nil
		self:changed()
		return true
	end

	if self.armedZone then
		self.drag = { kind = "draw", zoneKind = self.armedZone, start = w, current = w, startScreen = p }
		return true
	end

	local hit = self:hitTest(w)
	if hit.kind == "port" then
		if hit.side == "in" and not hit.port.Multi then
			local existing = self.doc:wiresInto(hit.rune.id, hit.port.Name)[1]
			if existing then
				-- Pick the wire back up from its source.
				local source = self.doc:rune(existing.from)
				local sourceDef = SpellRunes.Runes[source.rune]
				self.doc:record()
				self.doc:removeWire(existing)
				self.drag = { kind = "wire", rune = source, side = "out", port = SpellRunes.FindPort(sourceDef.Outputs, existing.fromPort), current = w, recorded = true }
				self:changed()
				return true
			end
		end
		self.drag = { kind = "wire", rune = hit.rune, side = hit.side, port = hit.port, current = w }
		self:renderWires()
	elseif hit.kind == "rune" then
		self:select({ kind = "rune", id = hit.rune.id })
		if hit.rune.locked then
			message(self, "This rune is locked. Press L to unlock it.")
		else
			self.drag = { kind = "rune", rune = hit.rune, grab = w - Vector2.new(hit.rune.x, hit.rune.y), startScreen = p }
		end
	elseif hit.kind == "wire" then
		self:select({ kind = "wire", wire = hit.wire })
	elseif hit.kind == "zone-edge" then
		local zone = hit.zone
		if not self:isSelected("zone", zone.id) then self:select({ kind = "zone", id = zone.id }) end
		self.drag = { kind = "resize", zone = zone, hit = hit, start = w, rect = { zone.x, zone.y, zone.w, zone.h }, startScreen = p }
		self:setCursor(edgeCursor(hit))
	elseif hit.kind == "zone-tab" or hit.kind == "zone" then
		local zone = hit.zone
		if not self:isSelected("zone", zone.id) then self:select({ kind = "zone", id = zone.id }) end
		if hit.kind == "zone-tab" then
			local now = os.clock()
			local last = self.lastTabPress
			if last and last.id == zone.id and now - last.time <= DOUBLE_CLICK then
				self.lastTabPress = nil
				if zone.locked then
					message(self, "This zone is locked. Press L to unlock it.")
				else
					self:pickUpZone(zone, w, p)
				end
			else
				self.lastTabPress = { id = zone.id, time = now }
			end
		end
	elseif t == Enum.UserInputType.Touch then
		-- No right button on touch: dragging empty board pans.
		if self.selection then self:select(nil) end
		self.drag = { kind = "pan", button = t, start = p, startPan = self.pan }
	else
		if self.selection then self:select(nil) end
	end
	return true
end

function Board:inputChanged(input: InputObject): boolean
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseWheel then
		local p = Board.pointer(input)
		if not self:accepts(p) then return false end
		self:zoomAt(p, self.zoom * (1.12 ^ input.Position.Z))
		return true
	end
	if t ~= Enum.UserInputType.MouseMovement and t ~= Enum.UserInputType.Touch then return false end
	local drag = self.drag
	if not drag then
		if self.carry then
			self:moveZone(self.carry, self:toWorld(Board.pointer(input)))
			return true
		end
		if t == Enum.UserInputType.MouseMovement then self:hover(Board.pointer(input)) end
		return false
	end
	local p = Board.pointer(input)
	local w = self:toWorld(p)
	if drag.startScreen and not drag.moved then
		if (p - drag.startScreen).Magnitude < DRAG_THRESHOLD then return true end
		drag.moved = true
	end

	if drag.kind == "pan" then
		self.pan = drag.startPan + (p - drag.start)
		self:applyTransform()
	elseif drag.kind == "rune" then
		recordOnce(self, drag)
		local rune = drag.rune
		rune.x, rune.y = snap(w.X - drag.grab.X), snap(w.Y - drag.grab.Y)
		local frame = self.runeFrames[rune.id]
		if frame then frame.Position = UDim2.fromOffset(rune.x, rune.y) end
		self:renderWires()
	elseif drag.kind == "zone" then
		self:moveZone(drag, w)
	elseif drag.kind == "resize" then
		recordOnce(self, drag)
		local zone, hit = drag.zone, drag.hit
		local x, y, width, height = drag.rect[1], drag.rect[2], drag.rect[3], drag.rect[4]
		local dx, dy = snap(w.X - drag.start.X), snap(w.Y - drag.start.Y)
		if hit.left then
			local newX = math.min(x + dx, x + width - MIN_ZONE_W)
			width, x = width + (x - newX), newX
		elseif hit.right then
			width = math.max(width + dx, MIN_ZONE_W)
		end
		if hit.top then
			local newY = math.min(y + dy, y + height - MIN_ZONE_H)
			height, y = height + (y - newY), newY
		elseif hit.bottom then
			height = math.max(height + dy, MIN_ZONE_H)
		end
		zone.x, zone.y, zone.w, zone.h = x, y, width, height
		local frame = self.zoneFrames[zone.id]
		if frame then
			frame.Position = UDim2.fromOffset(x, y)
			frame.Size = UDim2.fromOffset(width, height)
		end
	elseif drag.kind == "draw" then
		drag.current = w
		local minPoint = Vector2.new(math.min(drag.start.X, w.X), math.min(drag.start.Y, w.Y))
		local size = Vector2.new(math.abs(w.X - drag.start.X), math.abs(w.Y - drag.start.Y))
		local color = SpellRunes.Zones[drag.zoneKind].Color
		self.drawPreview.Visible = true
		self.drawPreview.BackgroundColor3 = color
		self.drawStroke.Color = color
		self.drawPreview.Position = UDim2.fromOffset(minPoint.X, minPoint.Y)
		self.drawPreview.Size = UDim2.fromOffset(size.X, size.Y)
	elseif drag.kind == "wire" then
		drag.current = w
		self:renderWires()
	end
	return true
end

function Board:inputEnded(input: InputObject): boolean
	local t = input.UserInputType
	local drag = self.drag
	if not drag then return false end
	local ends = if drag.kind == "pan" then t == drag.button else isPress(input)
	if not ends then return false end
	self.drag = nil
	task.defer(function() self:hover(Board.pointer()) end) -- after the change re-renders

	if drag.kind == "zone" and not drag.moved then
		-- Double-click without dragging: carry the zone until the next click.
		drag.start = self:toWorld(Board.pointer(input))
		self.carry = drag
		message(self, "Moving zone: click to drop it, Esc to put it back.")
		return true
	end
	if drag.kind == "wire" then
		local target = drag.current and self:findDropPort(drag.current, drag)
		if target then
			if not drag.recorded then self.doc:record() end
			local ok, reason
			if drag.side == "out" then
				ok, reason = self.doc:connect(drag.rune.id, drag.port.Name, target.rune.id, target.port.Name)
			else
				ok, reason = self.doc:connect(target.rune.id, target.port.Name, drag.rune.id, drag.port.Name)
			end
			if not ok and reason then message(self, reason) end
			self:changed()
		elseif drag.recorded then
			self:changed() -- a picked-up wire was dropped on nothing: it stays removed
		else
			self:renderWires()
		end
	elseif drag.kind == "draw" then
		self.drawPreview.Visible = false
		local a, b = drag.start, drag.current
		local minPoint = Vector2.new(math.min(a.X, b.X), math.min(a.Y, b.Y))
		local size = Vector2.new(math.abs(b.X - a.X), math.abs(b.Y - a.Y))
		if size.X < 40 and size.Y < 40 then
			-- A click (not a drag) drops a default-sized zone there.
			minPoint, size = a - Vector2.new(DEFAULT_ZONE_W, DEFAULT_ZONE_H) / 2, Vector2.new(DEFAULT_ZONE_W, DEFAULT_ZONE_H)
		end
		self.doc:record()
		local zone = self.doc:addZone(drag.zoneKind, snap(minPoint.X), snap(minPoint.Y), math.max(snap(size.X), MIN_ZONE_W), math.max(snap(size.Y), MIN_ZONE_H))
		if not UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
			self:armZone(nil) -- hold Shift to keep drawing the same kind
		end
		self.selection = if zone then { kind = "zone", id = zone.id } else nil
		if self.hooks.onSelect then self.hooks.onSelect(self.selection) end
		self:changed()
	elseif (drag.kind == "rune" or drag.kind == "zone" or drag.kind == "resize") and drag.recorded then
		self:changed()
	end
	return true
end

-- Palette drop: anchor the new rune's header at the screen point.
function Board:placeRune(runeId: string, screen: Vector2?): any?
	local w = if screen then self:toWorld(screen) else self:viewCenter()
	self.doc:record()
	local rune = self.doc:addRune(runeId, snap(w.X), snap(w.Y))
	if rune then
		self.selection = { kind = "rune", id = rune.id }
		if self.hooks.onSelect then self.hooks.onSelect(self.selection) end
	end
	self:changed()
	return rune
end

return Board
