--!optimize 2
--[[
	SpellCircleVFX (client, purely cosmetic)
	Draws the magic circle(s) of a spell in front of the caster's hand,
	facing their aim, from a SpellCircleLayout spec:
	 - Begin: the circle draws itself in while the cast is charged (outer
	   numeral ring -> polygon -> modifier/band glyphs -> core + satellites
	   over Charge.FullTime); overcharge adds outer rings and pulses.
	 - Cast: whatever isn't drawn yet completes, then it spins up, swells,
	   pushes forward and fades. Sustain spells hold until End.
	 - Cancel: a quick shrink and fade.

	The caster's own client calls these directly (SpellAssemblerGui) with a
	locally built spec; everyone else gets the server's "SpellCircle"
	VisualOffload messages:
	 { Phase = "Begin" | "Cast" | "Cancel" | "End", Caster = Model,
	   Spec = Spec?, Target = Vector3?, Charge = number?, Sustain = boolean? }

	Each circle is one transparent Part carrying a fixed-size SurfaceGui;
	everything inside is laid out in 0..1 canvas coordinates so satellites
	reuse the same drawing code at a smaller size. Animation runs on the
	caster's dilated clock (global x chunk time scale), like ExplosionVFX.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)
local Heartbeat = require(Shared.Heartbeat)
local ChunkManager = require(Shared.ChunkManager)
local SpellRunes = require(Shared.SpellRunes)

local SpellCircleVFX = {}

local localPlayer = Players.LocalPlayer

-- Canvas layout (fractions of the circle's square canvas, centre 0.5).
local CANVAS = 512
local OUTER = 0.36 -- outer (segmented) ring; the part is sized so this is the circle's radius
local OUTER_INNER = 0.325
local NUMERAL_R = (OUTER + OUTER_INNER) / 2
local BAND_OUT, BAND_IN = 0.30, 0.25
local BAND_R = (BAND_OUT + BAND_IN) / 2
local MOD_R = 0.205
local POLY_R = 0.17
local CORE_R = 0.09
local MARK_R = 0.385
local OVER_RINGS = 4
local SAT_RING = 0.45 -- a satellite canvas's outer ring radius (its part is sized from this)
local SAT_MOD_R = 0.27 -- satellite modifier nodes: radius they sit at, and their size
local SAT_MOD_SIZE = 0.11
local SAT_SCALE = 0.755 --satellite radius relative to the circle it hangs from
local SAT_GAP = 0.7 -- studs each satellite level sits in front of its parent
local SAT_SPREAD = 0.6 -- sibling satellites circle the parent's axis at this fraction of its radius
local SAT_ORBIT = 0.5 -- radians per (dilated, spin-boosted) second siblings circle that axis
local MAX_SAT_DEPTH = 3

local BASE_RADIUS = 3 -- studs, for a full-share first circle
local HAND_DISTANCE = 5
local STACK_GAP = 1.2
local STACK_SHRINK = 0.85
local SEGMENTS = 48
local RELEASE_TIME = 0.45
local CANCEL_TIME = 0.25
local MAX_CASTS = 24

local GLYPH_FONT = Enum.Font.Arial
local NUMERAL_FONT = Enum.Font.Antique

type Item = {
	Start: number,
	Finish: number,
	Over: boolean?, -- driven by overcharge instead of draw progress
	Set: (reveal: number, visible: number) -> (),
	LastR: number,
	LastV: number,
}

type Layer = { Frame: Frame, Speed: number, Phase: number }

type Circle = {
	Part: Part,
	Gui: SurfaceGui,
	Size: number, -- part side in studs
	Distance: number,
	Ghost: boolean?,
	-- satellites: placed relative to the circle they hang from, circling its
	-- axis when they have siblings (offsets are studs in the circle's plane)
	Anchor: Circle?,
	OrbitRadius: number?,
	OrbitAngle: number?,
	OrbitSpeed: number?,
	Offset: Vector2?,
}

type CastState = {
	Caster: Model,
	Spec: any,
	Circles: { Circle },
	Items: { Item },
	Layers: { Layer },
	State: string, -- "charge" | "sustain" | "release" | "cancel"
	Began: number, -- os.clock at Begin (charge is held in real time)
	Charge: number, -- current draw progress 0..Charge.Max
	Age: number, -- dilated seconds
	StateAge: number,
	Spin: number,
	SustainLeft: number,
	Target: Vector3?,
	IsLocal: boolean,
	LastP: number,
	LastO: number,
	LastV: number,
}

local casts: { CastState } = {}
local current: { [Model]: CastState } = {}
local folder: Folder? = nil
local connection: RBXScriptConnection? = nil

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "SpellCircles"
	f.Parent = workspace
	folder = f
	return f
end

--------------------------------------------------------------------------------
-- Drawing primitives (all positions are fractions of `parent`, a square Frame)
--------------------------------------------------------------------------------

type Builder = { Items: { Item }, Layers: { Layer } }

local function addItem(builder: Builder, start: number, finish: number, set: (number, number) -> (), over: boolean?)
	set(0, 1)
	table.insert(builder.Items, {
		Start = start,
		Finish = math.max(finish, start + 1e-3),
		Over = over,
		Set = set,
		LastR = 0,
		LastV = 1,
	})
end

local function layer(builder: Builder, parent: GuiObject, speed: number, phase: number): Frame
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.Rotation = phase
	frame.Parent = parent
	table.insert(builder.Layers, { Frame = frame, Speed = speed, Phase = phase })
	return frame
end

local function polar(radius: number, angle: number): (number, number)
	return 0.5 + math.cos(angle) * radius, 0.5 + math.sin(angle) * radius
end

-- A straight stroke from (x1,y1) to (x2,y2) that grows from its start.
local function line(builder: Builder, parent: GuiObject, x1: number, y1: number, x2: number, y2: number, thickness: number, color: Color3, start: number, finish: number, over: boolean?)
	local dx, dy = x2 - x1, y2 - y1
	local length = math.sqrt(dx * dx + dy * dy)
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = color
	frame.Rotation = math.deg(math.atan2(dy, dx))
	frame.Parent = parent
	addItem(builder, start, finish, function(reveal, visible)
		if reveal <= 0 then
			frame.BackgroundTransparency = 1
			return
		end
		frame.Position = UDim2.fromScale(x1 + dx * reveal / 2, y1 + dy * reveal / 2)
		frame.Size = UDim2.new(length * reveal, 0, 0, thickness)
		frame.BackgroundTransparency = 1 - visible
	end, over)
end

-- A smooth ring (UIStroke) that fades and settles in.
local function ring(builder: Builder, parent: GuiObject, radius: number, thickness: number, color: Color3, start: number, finish: number, over: boolean?, opacity: number?)
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.BackgroundTransparency = 1
	frame.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = thickness
	stroke.Color = color
	stroke.Parent = frame
	local alpha = opacity or 1
	addItem(builder, start, finish, function(reveal, visible)
		local size = radius * 2 * (0.85 + 0.15 * reveal)
		frame.Size = UDim2.fromScale(size, size)
		stroke.Transparency = 1 - alpha * reveal * visible
	end, over)
end

-- A ring of small straight segments that traces itself around in order.
local function sweepRing(builder: Builder, parent: GuiObject, radius: number, thickness: number, color: Color3, start: number, finish: number)
	local step = math.pi * 2 / SEGMENTS
	for k = 0, SEGMENTS - 1 do
		local x1, y1 = polar(radius, k * step - math.pi / 2)
		local x2, y2 = polar(radius, (k + 1) * step - math.pi / 2)
		local s = start + (finish - start) * k / SEGMENTS
		line(builder, parent, x1, y1, x2, y2, thickness, color, s, s + (finish - start) / SEGMENTS)
	end
end

local function glyph(builder: Builder, parent: GuiObject, text: string, x: number, y: number, size: number, color: Color3, rotation: number, start: number, finish: number, font: Enum.Font?)
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(x, y)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.Font = font or GLYPH_FONT
	label.TextColor3 = color
	label.Rotation = rotation
	label.Parent = parent
	addItem(builder, start, finish, function(reveal, visible)
		local s = size * (0.6 + 0.4 * reveal)
		label.Size = UDim2.fromScale(s, s)
		label.TextTransparency = 1 - reveal * visible
	end)
end

-- Text written around a circle, one character per slot, reading clockwise.
local function textRing(builder: Builder, parent: GuiObject, tokens: { string }, radius: number, size: number, color: Color3, start: number, finish: number, font: Enum.Font?)
	local count = #tokens
	if count == 0 then
		return
	end
	for index, token in tokens do
		local angle = (index - 1) / count * math.pi * 2 - math.pi / 2
		local x, y = polar(radius, angle)
		local s = start + (finish - start) * (index - 1) / count
		glyph(builder, parent, token, x, y, size, color, math.deg(angle) + 90, s, s + math.max((finish - start) / count * 3, 0.03), font)
	end
end

-- Repeats `sequence` (with a separator) to fill a ring of `slots` characters.
local function fillTokens(sequence: { string }, separator: string?, slots: number): { string }
	local tokens = {}
	if #sequence == 0 then
		return tokens
	end
	local unit = table.clone(sequence)
	if separator then
		table.insert(unit, separator)
	end
	local repeats = math.max(1, math.floor(slots / #unit))
	for _ = 1, repeats do
		for _, token in unit do
			table.insert(tokens, token)
		end
	end
	return tokens
end

local function chars(text: string): { string }
	local out = {}
	for _, code in utf8.codes(text) do
		table.insert(out, utf8.char(code))
	end
	return out
end

-- The inscribed star: n points at `radius`, each joined to the one `step`
-- ahead (n edges always, so compound stars like {6/2} come out whole).
local function star(builder: Builder, parent: GuiObject, points: number, step: number, radius: number, rotation: number, thickness: number, color: Color3, start: number, finish: number)
	for i = 0, points - 1 do
		local a = rotation + i / points * math.pi * 2 - math.pi / 2
		local b = rotation + ((i + step) % points) / points * math.pi * 2 - math.pi / 2
		local x1, y1 = polar(radius, a)
		local x2, y2 = polar(radius, b)
		local s = start + (finish - start) * i / points
		line(builder, parent, x1, y1, x2, y2, thickness, color, s, s + (finish - start) / points)
	end
end

local function polygonFor(builder: Builder, parent: GuiObject, cs: any, radius: number, thickness: number, start: number, finish: number)
	local n = cs.Points
	local color = cs.Color
	if cs.Vessel == "Explosion" then
		star(builder, parent, 8, 3, radius, 0, thickness, color, start, finish)
	elseif cs.Vessel == "Bullet" then
		star(builder, parent, n, if n >= 7 then 3 elseif n >= 5 then 2 else 1, radius, 0, thickness, color, start, finish)
	elseif cs.Vessel == "Beam" then
		if n >= 5 then
			star(builder, parent, n, 2, radius, 0, thickness, color, start, finish)
		else
			local mid = (start + finish) / 2
			star(builder, parent, n, 1, radius, 0, thickness, color, start, mid)
			star(builder, parent, n, 1, radius, math.pi / n, thickness, color, mid, finish)
		end
	else -- Orb: polygon in a circle
		star(builder, parent, n, 1, radius, 0, thickness, color, start, finish)
		ring(builder, parent, radius, thickness, color, start, finish, nil, 0.7)
	end
end

local function squareFrame(parent: GuiObject, x: number, y: number, size: number): Frame
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(x, y)
	frame.Size = UDim2.fromScale(size, size)
	frame.BackgroundTransparency = 1
	frame.Parent = parent
	return frame
end

-- A trigger satellite (its own canvas, drawn in front of the circle it hangs
-- from): its glyph in the centre, a band naming what it fires (element +
-- vessel glyphs) and that vessel's star. Its own satellites are separate
-- canvases further in front (see addSatellites).
local function buildSatellite(builder: Builder, frame: Frame, sat: any, color: Color3, rng: Random, start: number, finish: number)
	local child = sat.Circles[1]
	local tint = if child then child.Color else color
	local thick = 3
	local span = finish - start
	ring(builder, frame, SAT_RING, thick * 1.5, tint, start, start + span * 0.3)
	ring(builder, frame, 0.36, thick, tint, start + span * 0.1, start + span * 0.4, nil, 0.8)
	local spin = layer(builder, frame, rng:NextNumber(-40, 40), rng:NextNumber(0, 360))
	if child then
		polygonFor(builder, spin, child, 0.3, thick, start + span * 0.2, start + span * 0.7)
		-- the fired vessel's modifiers, as small nodes riding the star
		local modCount = #child.Mods
		for index, mod in child.Mods do
			local angle = (index - 1) / modCount * math.pi * 2 - math.pi / 2
			local x, y = polar(SAT_MOD_R, angle)
			local s = start + span * (0.4 + 0.4 * (index - 1) / modCount)
			local node = squareFrame(spin, x, y, SAT_MOD_SIZE)
			ring(builder, node, 0.5, 2, tint, s, s + span * 0.15)
			glyph(builder, node, mod.Glyph, 0.5, 0.45, 0.75, child.Core, 0, s, s + span * 0.15)
			if mod.Level then
				glyph(builder, node, string.rep("•", mod.Level), 0.5, 0.88, 0.45, tint, 0, s + span * 0.05, s + span * 0.2)
			end
		end
	end
	local tokens = {}
	for _, circle in sat.Circles do
		table.insert(tokens, circle.ElementGlyph)
		table.insert(tokens, circle.VesselGlyph)
	end
	textRing(builder, spin, fillTokens(tokens, nil, 8), 0.405, 0.09, tint, start + span * 0.3, start + span * 0.8)
	glyph(builder, frame, sat.Glyph, 0.5, 0.5, 0.36, if child then child.Core else color, 0, start + span * 0.5, finish)
end

local function buildCircle(builder: Builder, root: Frame, cs: any, numeral: string)
	local rng = Random.new(cs.Seed)
	local color, core = cs.Color, cs.Core
	local dir = if rng:NextNumber() < 0.5 then -1 else 1

	-- 0 - 0.25: outer ring traces around, numerals written behind it
	local outerLayer = layer(builder, root, dir * 6, rng:NextNumber(0, 360))
	sweepRing(builder, outerLayer, OUTER, 3, color, 0, 0.25)
	ring(builder, outerLayer, OUTER_INNER, 2, color, 0.12, 0.25)
	local numeralSlots = math.floor(2 * math.pi * NUMERAL_R / 0.032)
	textRing(builder, outerLayer, fillTokens(chars(numeral), "·", numeralSlots), NUMERAL_R, 0.034, core, 0, 0.25, NUMERAL_FONT)

	-- overcharge rings (driven by charge past 1, not by draw progress)
	local overLayer = layer(builder, root, -dir * 14, rng:NextNumber(0, 360))
	for k = 1, OVER_RINGS do
		local radius = 0.395 + 0.022 * k
		ring(builder, overLayer, radius, 2, core, (k - 1) / OVER_RINGS, k / OVER_RINGS, true, 0.85)
		for t = 0, 2 do -- three ticks per ring so its spin reads
			local a = (t / 3 + k * 0.17) * math.pi * 2
			local x1, y1 = polar(radius - 0.008, a)
			local x2, y2 = polar(radius + 0.008, a)
			line(builder, overLayer, x1, y1, x2, y2, 2, core, (k - 1) / OVER_RINGS, k / OVER_RINGS, true)
		end
	end

	-- 0.25 - 0.5: script band rings and the vessel's star
	local bandLayer = layer(builder, root, -dir * 10, rng:NextNumber(0, 360))
	ring(builder, bandLayer, BAND_OUT, 2, color, 0.25, 0.38)
	ring(builder, bandLayer, BAND_IN, 2, color, 0.27, 0.4)
	local polyLayer = layer(builder, root, dir * 4, rng:NextNumber(0, 360))
	polygonFor(builder, polyLayer, cs, POLY_R, 2, 0.25, 0.5)

	-- 0.5 - 0.75: modifier nodes and band glyphs pop in
	local modCount = #cs.Mods
	for index, mod in cs.Mods do
		local angle = (index - 1) / modCount * math.pi * 2 - math.pi / 2
		local x, y = polar(MOD_R, angle)
		local s = 0.5 + 0.25 * (index - 1) / math.max(modCount, 1)
		local node = squareFrame(polyLayer, x, y, 0.075)
		ring(builder, node, 0.5, 2, color, s, s + 0.06)
		glyph(builder, node, mod.Glyph, 0.5, 0.45, 0.75, core, 0, s, s + 0.06)
		if mod.Level then
			glyph(builder, node, string.rep("•", mod.Level), 0.5, 0.88, 0.45, color, 0, s + 0.03, s + 0.09)
		end
	end
	local bandSlots = math.floor(2 * math.pi * BAND_R / 0.045)
	textRing(builder, bandLayer, fillTokens(cs.Band, nil, bandSlots), BAND_R, 0.042, core, 0.5, 0.75)

	-- 0.75 - 1: core and quantity marks (satellites are their own canvases)
	ring(builder, root, CORE_R, 2, color, 0.75, 0.85)
	glyph(builder, root, cs.ElementGlyph, 0.5, 0.5, 0.14, core, 0, 0.78, 0.95)
	local quantity = cs.Quantity
	if quantity and quantity.Count > 1 then
		local count = quantity.Count
		if quantity.Pattern == "Ring" then
			for k = 1, count do
				local x, y = polar(MARK_R, (k - 1) / count * math.pi * 2 - math.pi / 2)
				ring(builder, squareFrame(outerLayer, x, y, 0.024), 0.5, 2, core, 0.75 + 0.2 * k / count, 0.8 + 0.2 * k / count)
			end
		elseif quantity.Pattern == "Fan" then
			local spread = math.rad(math.clamp(quantity.Spread, 10, 120))
			for k = 1, count do
				local angle = -math.pi / 2 + (if count > 1 then ((k - 1) / (count - 1) - 0.5) * spread else 0)
				local x, y = polar(MARK_R, angle)
				glyph(builder, root, "▲", x, y, 0.026, core, math.deg(angle) + 90, 0.75 + 0.2 * k / count, 0.8 + 0.2 * k / count)
			end
		end
	end
end

-- A faint echo ring for Stream copies.
local function buildGhost(builder: Builder, root: Frame, cs: any, start: number, finish: number)
	ring(builder, root, OUTER, 2, cs.Color, start, finish, nil, 0.45)
	ring(builder, root, OUTER_INNER, 1, cs.Color, start, finish, nil, 0.3)
	glyph(builder, root, cs.ElementGlyph, 0.5, 0.5, 0.1, cs.Core, 0, start, finish)
end

local function newCanvas(sizeStuds: number): (Part, SurfaceGui, Frame)
	local part = Instance.new("Part")
	part.Name = "SpellCircle"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(sizeStuds, sizeStuds, 0.05)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(CANVAS, CANVAS)
	gui.LightInfluence = 0
	gui.Brightness = 2.5
	gui.ClipsDescendants = false
	gui.Parent = part
	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui
	return part, gui, root
end

--------------------------------------------------------------------------------
-- Cast lifecycle
--------------------------------------------------------------------------------

local function destroyCast(cast: CastState)
	for _, circle in cast.Circles do
		circle.Part:Destroy()
	end
	table.clear(cast.Circles)
	if current[cast.Caster] == cast then
		current[cast.Caster] = nil
	end
end

local function createCast(caster: Model, spec: any, target: Vector3?, isLocal: boolean): CastState?
	if typeof(spec) ~= "table" or typeof(spec.Circles) ~= "table" or #spec.Circles == 0 then
		return nil
	end
	local builder: Builder = { Items = {}, Layers = {} }
	local circles: { Circle } = {}
	local parent = getFolder()

	-- Each trigger's satellite hangs SAT_GAP in front of the circle it belongs
	-- to (toward the target), half its size; siblings share that level and
	-- circle its axis. Nested triggers repeat this further forward.
	local function addSatellites(cs: any, anchor: Circle, radius: number, depth: number)
		local count = #cs.Satellites
		if count == 0 or depth > MAX_SAT_DEPTH then
			return
		end
		local rng = Random.new(cs.Seed + depth)
		local satRadius = radius * SAT_SCALE
		local side = satRadius / SAT_RING
		local phase = rng:NextNumber(0, math.pi * 2)
		local direction = if depth % 2 == 1 then 1 else -1
		local start = 0.75 + 0.06 * (depth - 1)
		for index, sat in cs.Satellites do
			local part, gui, root = newCanvas(side)
			buildSatellite(builder, root, sat, cs.Color, rng, start, math.min(start + 0.2, 1))
			local circle: Circle = {
				Part = part,
				Gui = gui,
				Size = side,
				Distance = anchor.Distance + SAT_GAP,
				Anchor = anchor,
				OrbitRadius = if count > 1 then radius * SAT_SPREAD else 0,
				OrbitAngle = phase + (index - 1) / count * math.pi * 2,
				OrbitSpeed = direction * SAT_ORBIT,
			}
			table.insert(circles, circle)
			part.Parent = parent
			for _, child in sat.Circles do
				addSatellites(child, circle, satRadius, depth + 1)
			end
		end
	end
	local function satelliteDepth(cs: any): number
		local deepest = 0
		for _, sat in cs.Satellites do
			for _, child in sat.Circles do
				deepest = math.max(deepest, 1 + satelliteDepth(child))
			end
			deepest = math.max(deepest, 1)
		end
		return math.min(deepest, MAX_SAT_DEPTH)
	end

	local scale = 1
	local distance = HAND_DISTANCE
	for index, cs in spec.Circles do
		if index > 1 then
			scale *= STACK_SHRINK
		end
		local radius = BASE_RADIUS * cs.Scale * scale
		local side = radius / OUTER
		local part, gui, root = newCanvas(side)
		buildCircle(builder, root, cs, spec.Numeral or "")
		local circle: Circle = { Part = part, Gui = gui, Size = side, Distance = distance }
		table.insert(circles, circle)
		part.Parent = parent
		addSatellites(cs, circle, radius, 1)
		-- the next vessel's circle stacks past this one's satellites
		distance += STACK_GAP + SAT_GAP * satelliteDepth(cs)
		local quantity = cs.Quantity
		if index == 1 and quantity and quantity.Pattern == "Stream" and quantity.Count > 1 then
			for k = 1, math.min(quantity.Count - 1, 4) do
				local ghostPart, ghostGui, ghostRoot = newCanvas(side * (1 - 0.06 * k))
				buildGhost(builder, ghostRoot, cs, 0.75 + 0.05 * k, 0.85 + 0.05 * k)
				table.insert(circles, { Part = ghostPart, Gui = ghostGui, Size = side * (1 - 0.06 * k), Distance = HAND_DISTANCE - 0.4 * k, Ghost = true })
				ghostPart.Parent = parent
			end
		end
	end
	local cast: CastState = {
		Caster = caster,
		Spec = spec,
		Circles = circles,
		Items = builder.Items,
		Layers = builder.Layers,
		State = "charge",
		Began = os.clock(),
		Charge = 0,
		Age = 0,
		StateAge = 0,
		Spin = 0,
		SustainLeft = 0,
		Target = target,
		IsLocal = isLocal,
		LastP = -1,
		LastO = -1,
		LastV = -1,
	}
	table.insert(casts, cast)
	while #casts > MAX_CASTS do
		destroyCast(table.remove(casts, 1) :: CastState)
	end
	return cast
end

local function aimPoint(cast: CastState, origin: Vector3): Vector3
	if cast.IsLocal and cast.Caster == localPlayer.Character then
		return localPlayer:GetMouse().Hit.Position
	end
	return cast.Target or origin + cast.Caster:GetPivot().LookVector * 20
end

local function applyItems(cast: CastState, progress: number, over: number, visible: number)
	if progress == cast.LastP and over == cast.LastO and visible == cast.LastV then
		return
	end
	cast.LastP, cast.LastO, cast.LastV = progress, over, visible
	for _, item in cast.Items do
		local value = if item.Over then over else progress
		local reveal = math.clamp((value - item.Start) / (item.Finish - item.Start), 0, 1)
		if reveal ~= item.LastR or visible ~= item.LastV then
			item.LastR, item.LastV = reveal, visible
			item.Set(reveal, visible)
		end
	end
end

local function step(dt: number)
	local camera = workspace.CurrentCamera
	local cameraPosition = if camera then camera.CFrame.Position else Vector3.zero
	for index = #casts, 1, -1 do
		local cast = casts[index]
		local caster = cast.Caster
		local head = caster.Parent and (caster:FindFirstChild("Head") or caster.PrimaryPart)
		if not head or not head:IsA("BasePart") or #cast.Circles == 0 then
			destroyCast(cast)
			table.remove(casts, index)
			continue
		end
		local origin = head.Position - Vector3.new(0, 0.3, 0)
		local dilation = Heartbeat.GetGlobalTimeScale() * ChunkManager.GetTimeScaleAt(origin)
		local ddt = dt * dilation
		cast.Age += ddt
		cast.StateAge += ddt

		local progress, over, visible = 1, 0, 1
		local sizeMul, push, spinBoost, flash = 1, 0, 1, 0
		local finished = false
		if cast.State == "charge" then
			local held = os.clock() - cast.Began
			if held > SpellRunes.Charge.StaleAfter then
				cast.State, cast.StateAge = "cancel", 0
			end
			cast.Charge = math.clamp(held / SpellRunes.Charge.FullTime, 0, SpellRunes.Charge.Max)
			progress = math.min(cast.Charge, 1)
			over = math.clamp((cast.Charge - 1) / (SpellRunes.Charge.Max - 1), 0, 1)
			spinBoost = 1 + over * 2
		elseif cast.State == "sustain" then
			over = math.clamp((cast.Charge - 1) / (SpellRunes.Charge.Max - 1), 0, 1)
			spinBoost = 2.5
			cast.SustainLeft -= ddt
			if cast.SustainLeft <= 0 then
				cast.State, cast.StateAge = "release", 0
			end
		end
		if cast.State == "release" then
			local f = math.clamp(cast.StateAge / RELEASE_TIME, 0, 1)
			over = math.clamp((cast.Charge - 1) / (SpellRunes.Charge.Max - 1), 0, 1)
			visible = 1 - f * f
			sizeMul = 1 + 0.3 * f
			push = f
			spinBoost = 6 * (1 - f) + 1
			flash = (1 - f) * 4
			finished = f >= 1
		elseif cast.State == "cancel" then
			local f = math.clamp(cast.StateAge / CANCEL_TIME, 0, 1)
			progress = math.min(cast.Charge, 1)
			visible = 1 - f
			sizeMul = 1 - 0.3 * f
			finished = f >= 1
		end
		if finished then
			destroyCast(cast)
			table.remove(casts, index)
			continue
		end

		cast.Spin += ddt * spinBoost
		for _, l in cast.Layers do
			l.Frame.Rotation = l.Phase + l.Speed * cast.Spin
		end
		applyItems(cast, progress, over, visible)

		local aim = aimPoint(cast, origin)
		local direction = aim - origin
		direction = if direction.Magnitude > 1e-3 then direction.Unit else caster:GetPivot().LookVector
		local brightness = 2.5 + over * 1.5 + math.sin(cast.Age * 10) * over * 0.8 + flash
		local basis = CFrame.lookAt(origin, origin + direction)
		for _, circle in cast.Circles do
			local anchor = circle.Anchor
			if anchor then
				circle.OrbitAngle = (circle.OrbitAngle or 0) + ddt * spinBoost * (circle.OrbitSpeed or 0)
				local r = (circle.OrbitRadius or 0) * sizeMul
				local angle = circle.OrbitAngle or 0
				circle.Offset = (anchor.Offset or Vector2.zero) + Vector2.new(math.cos(angle) * r, math.sin(angle) * r)
			end
			local offset = circle.Offset or Vector2.zero
			local distance = circle.Distance + push
			local position = (basis * CFrame.new(offset.X, offset.Y, -distance)).Position
			local frame = CFrame.lookAt(position, position + direction)
			circle.Part.CFrame = frame
			local side = circle.Size * sizeMul
			if circle.Part.Size.X ~= side then
				circle.Part.Size = Vector3.new(side, side, 0.05)
			end
			-- SurfaceGuis only draw on one side: show whichever faces the camera
			local face = if (cameraPosition - position):Dot(direction) > 0 then Enum.NormalId.Front else Enum.NormalId.Back
			if circle.Gui.Face ~= face then
				circle.Gui.Face = face
			end
			circle.Gui.Brightness = if circle.Ghost then brightness * 0.6 else brightness
		end
	end
	if #casts == 0 and connection then
		connection:Disconnect()
		connection = nil
	end
end

local function ensureRunning()
	if not connection then
		connection = RunService.RenderStepped:Connect(step)
	end
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- Starts drawing a charging circle for `caster` (replacing one in progress).
function SpellCircleVFX.Begin(caster: Model, spec: any, target: Vector3?, isLocal: boolean?)
	local previous = current[caster]
	if previous then
		previous.State, previous.StateAge = "cancel", 0
		current[caster] = nil
	end
	local cast = createCast(caster, spec, target, isLocal == true)
	if cast then
		current[caster] = cast
		ensureRunning()
	end
end

-- Releases the charging circle (creating it fully drawn if Begin was missed).
-- Sustain casts hold at full until End (or their maximum channel time).
function SpellCircleVFX.Cast(caster: Model, spec: any?, charge: number, target: Vector3?, sustain: boolean?, isLocal: boolean?)
	local cast = current[caster]
	if not cast then
		cast = createCast(caster, spec, target, isLocal == true)
		if not cast then
			return
		end
		ensureRunning()
	end
	cast.Charge = math.max(charge, 1) -- draw everything; >1 keeps the overcharge rings
	if target then
		cast.Target = target
	end
	cast.StateAge = 0
	if sustain then
		cast.State = "sustain"
		cast.SustainLeft = (if typeof(cast.Spec.Sustain) == "number" then cast.Spec.Sustain else 0) + 0.5
		current[caster] = cast
	else
		cast.State = "release"
		current[caster] = nil
	end
end

function SpellCircleVFX.Cancel(caster: Model)
	local cast = current[caster]
	if cast then
		cast.State, cast.StateAge = "cancel", 0
		current[caster] = nil
	end
end

-- Ends a sustained (channelled) circle.
function SpellCircleVFX.End(caster: Model)
	local cast = current[caster]
	if cast and cast.State == "sustain" then
		cast.State, cast.StateAge = "release", 0
		current[caster] = nil
	end
end

VisualOffload.On("SpellCircle", function(data)
	if typeof(data) ~= "table" then
		return
	end
	local caster = data.Caster
	if typeof(caster) ~= "Instance" or not caster:IsA("Model") then
		return
	end
	-- the caster's own client already drew it locally
	if caster == localPlayer.Character then
		return
	end
	local target = if typeof(data.Target) == "Vector3" then data.Target else nil
	if data.Phase == "Begin" then
		SpellCircleVFX.Begin(caster, data.Spec, target)
	elseif data.Phase == "Cast" then
		SpellCircleVFX.Cast(caster, data.Spec, if typeof(data.Charge) == "number" then data.Charge else 1, target, data.Sustain == true)
	elseif data.Phase == "Cancel" then
		SpellCircleVFX.Cancel(caster)
	elseif data.Phase == "End" then
		SpellCircleVFX.End(caster)
	end
end)

return SpellCircleVFX
