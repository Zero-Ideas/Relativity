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
	 { Phase = "Begin" | "Cast" | "Cancel" | "End" | "Freeze" | "FireFrozen"
	   | "ClearFrozen", Caster = Model, Spec = Spec?, Target = Vector3?,
	   Charge = number?, Sustain = boolean?, Position = Vector3?, Direction = Vector3? }
	Freeze (R while charging) pins the charging circle in world space;
	FireFrozen (T) turns the caster's oldest frozen circle to the target and
	releases it.

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

-- Live aim of other casters' circles (SpellService's aim relay) is shown at
-- graphics level LIVE_AIM_QUALITY and up; below that a circle keeps the aim
-- it was sent with on Begin/Cast. "Automatic" graphics counts as eligible.
local LIVE_AIM_QUALITY = 5
local AIM_SMOOTHING = 14 -- 1/s: how quickly a relayed aim is eased toward

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
local OVER_RINGS = 3 -- one per third of the overcharge; the last lands at full (2x) charge
local SAT_RING = 0.45 -- a satellite canvas's outer ring radius (its part is sized from this)
local SAT_MOD_R = 0.27 -- satellite modifier nodes: radius they sit at, and their size
local SAT_MOD_SIZE = 0.11
local SAT_SCALE = 0.755 --satellite radius relative to the circle it hangs from
local SAT_GAP = 0.7 -- studs each satellite level sits in front of its parent
local SAT_SPREAD = 0.6 -- sibling satellites circle the parent's axis at this fraction of its radius
local SAT_ORBIT = 0.5 -- radians per (dilated, spin-boosted) second siblings circle that axis
local MAX_SAT_DEPTH = 3
local CLOUD_DISPERSE = 0.6 -- seconds for a frozen circle to come apart into its cloud
local CLOUD_DRIFT_MIN, CLOUD_DRIFT_MAX = 0.15, 0.6 -- radians per second each piece circles the cloud centre
-- Cloud placement is random per cast (not from the spell's seed), so no two
-- frozen clouds move alike.
local cloudRng = Random.new()

-- Sounds: cloned from ReplicatedStorage.audio and played from each cast's own
-- emitter at its main circle, so everyone hears them in 3D.
local SOUND_CHARGE = "spell charge" -- while charging; cut off on a tap release
local SOUND_FIRE = "Fire" -- the spell going off (a frozen one: once it has reassembled)
local SOUND_MANIFEST = "Mang Manifest" -- an overcharge ring appearing...
local SOUND_MANIFEST_END = "Mang End" -- ...and the last one
local SOUND_HUM = "Generator Hum" -- looped around a frozen spell
local TAP_TIME = 0.3 -- a release this soon after Begin counts as a tap
local HUM_RANGE = 40 -- studs: the frozen spell's hum fades to silence by here
local SOUND_LINGER = 6 -- seconds a cast's emitter outlives it so one-shots can finish
local GLOW_BOOST, GLOW_TIME = 4, 0.35 -- extra brightness when an overcharge ring manifests, and its fade
local PIECE_GAP = 0.02 -- studs between a circle's stacked pieces (avoids z-fighting)

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

-- One flat canvas of a circle. A main circle is several stacked pieces (outer
-- ring, overcharge rings, band, star, core) so a frozen spell can come apart
-- into a tumbling cloud of rings and glyphs; Drift/Axis/Rate/Tilt are that
-- piece's place and spin in the cloud.
type Piece = {
	Part: Part,
	Gui: SurfaceGui,
	Drift: Vector3,
	DriftAxis: Vector3,
	DriftRate: number, -- radians per second around the cloud centre (signed)
	Bob: number, -- how far it swings in and out from the centre, studs
	BobRate: number,
	BobPhase: number,
	Axis: Vector3,
	Rate: number,
	Tilt: CFrame,
}

type Circle = {
	Part: Part, -- the first piece's part (where the circle sits when assembled)
	Gui: SurfaceGui,
	Pieces: { Piece },
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
	State: string, -- "charge" | "frozen" | "assemble" | "sustain" | "release" | "cancel"
	Began: number, -- os.clock at Begin (charge is held in real time)
	Charge: number, -- current draw progress 0..Charge.Max
	Age: number, -- dilated seconds
	StateAge: number,
	Spin: number,
	SustainLeft: number,
	Target: Vector3?,
	AimGoal: Vector3?, -- latest relayed live aim (other casters); Target eases toward it
	IsLocal: boolean,
	-- set while frozen (and for its release): the circle hangs in world space
	-- at FrozenOrigin + FrozenDirection * HAND_DISTANCE instead of following
	-- the caster
	FrozenOrigin: Vector3?,
	FrozenDirection: Vector3?,
	ChargeCap: number?, -- frozen before full charge: keeps drawing up to 1x, never overcharges
	AssembleStart: number?, -- os.clock when a frozen cloud began reassembling (T)
	Emitter: Attachment, -- where this cast's sounds play from (follows the main circle)
	ChargeSound: Sound?,
	Hum: Sound?,
	RingsShown: number, -- overcharge rings that have manifested (sound + glow played)
	Glow: number, -- 1 right after a ring manifests, fading to 0
	LastP: number,
	LastO: number,
	LastV: number,
}

local casts: { CastState } = {}
local current: { [Model]: CastState } = {}
-- Frozen (R) spells per caster, oldest first; FireFrozen (T) releases the head.
local frozen: { [Model]: { CastState } } = {}
local MAX_FROZEN_SAFETY = 6 -- the gameplay cap (3) lives in SpellRunes.Freeze; this only bounds a desync
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

-- `canvas()` returns a fresh piece (its own part) for the next layer group.
local function buildCircle(builder: Builder, canvas: () -> Frame, cs: any, numeral: string)
	local rng = Random.new(cs.Seed)
	local color, core = cs.Color, cs.Core
	local dir = if rng:NextNumber() < 0.5 then -1 else 1

	-- 0 - 0.25: outer ring traces around, numerals written behind it
	local outerRoot = canvas()
	local outerLayer = layer(builder, outerRoot, dir * 6, rng:NextNumber(0, 360))
	sweepRing(builder, outerLayer, OUTER, 3, color, 0, 0.25)
	ring(builder, outerLayer, OUTER_INNER, 2, color, 0.12, 0.25)
	local numeralSlots = math.floor(2 * math.pi * NUMERAL_R / 0.032)
	textRing(builder, outerLayer, fillTokens(chars(numeral), "·", numeralSlots), NUMERAL_R, 0.034, core, 0, 0.25, NUMERAL_FONT)

	-- overcharge rings (driven by charge past 1, not by draw progress)
	local overLayer = layer(builder, canvas(), -dir * 14, rng:NextNumber(0, 360))
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
	local bandLayer = layer(builder, canvas(), -dir * 10, rng:NextNumber(0, 360))
	ring(builder, bandLayer, BAND_OUT, 2, color, 0.25, 0.38)
	ring(builder, bandLayer, BAND_IN, 2, color, 0.27, 0.4)
	local polyLayer = layer(builder, canvas(), dir * 4, rng:NextNumber(0, 360))
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
	local coreRoot = canvas()
	ring(builder, coreRoot, CORE_R, 2, color, 0.75, 0.85)
	glyph(builder, coreRoot, cs.ElementGlyph, 0.5, 0.5, 0.14, core, 0, 0.78, 0.95)
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
				glyph(builder, outerRoot, "▲", x, y, 0.026, core, math.deg(angle) + 90, 0.75 + 0.2 * k / count, 0.8 + 0.2 * k / count)
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

-- HUD canvas: identical primitives, timing, seeds and glyphs; no world cast,
-- audio, global update registration or Workspace objects are created here.
function SpellCircleVFX.BuildPreview(root: Frame, spec: any): any
	local builder: Builder = { Items = {}, Layers = {} }
	local count = #spec.Circles
	local columns = math.max(1, math.ceil(math.sqrt(count)))
	local rows = math.max(1, math.ceil(count / columns))
	local size = 1 / math.max(columns, rows)
	local function satellites(cs: any, parent: Frame, depth: number)
		if depth > MAX_SAT_DEPTH then return end
		for index, sat in cs.Satellites do
			local angle = (index - 1) / math.max(#cs.Satellites, 1) * math.pi * 2
			local x, y = polar(0.28, angle)
			local frame = squareFrame(parent, x, y, 0.35)
			buildSatellite(builder, frame, sat, cs.Color, Random.new(cs.Seed + depth), 0.75, 1)
			for _, child in sat.Circles do satellites(child, frame, depth + 1) end
		end
	end
	for index, cs in spec.Circles do
		local column, row = (index - 1) % columns, (index - 1) // columns
		local frame = squareFrame(root, 0.5 + (column - (columns - 1) / 2) * size, 0.5 + (row - (rows - 1) / 2) * size, size)
		buildCircle(builder, function() return squareFrame(frame, 0.5, 0.5, 1) end, cs, spec.Numeral or "")
		satellites(cs, frame, 1)
	end
	return builder
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

-- A piece's random place in the frozen cloud: up to `reach` studs from the
-- centre, circling it on its own axis at its own speed, swinging in and out,
-- and tumbling. Random per cast.
local function newPiece(part: Part, gui: SurfaceGui, reach: number): Piece
	local rng = cloudRng
	local distance = reach * rng:NextNumber(0.35, 1)
	return {
		Part = part,
		Gui = gui,
		Drift = rng:NextUnitVector() * distance,
		DriftAxis = rng:NextUnitVector(),
		DriftRate = rng:NextNumber(CLOUD_DRIFT_MIN, CLOUD_DRIFT_MAX) * (if rng:NextNumber() < 0.5 then -1 else 1),
		Bob = distance * rng:NextNumber(0.1, 0.35),
		BobRate = rng:NextNumber(0.6, 1.6),
		BobPhase = rng:NextNumber(0, math.pi * 2),
		Axis = rng:NextUnitVector(),
		Rate = rng:NextNumber(0.3, 0.9) * (if rng:NextNumber() < 0.5 then -1 else 1),
		Tilt = CFrame.fromAxisAngle(rng:NextUnitVector(), rng:NextNumber(0, math.pi)),
	}
end

local audioFolder: Instance? = nil

-- Plays a clone of ReplicatedStorage.audio[name] at the cast's emitter.
-- `configure` runs before Play. One-shots clean themselves up.
local function playSound(cast: CastState, name: string, configure: ((Sound) -> ())?): Sound?
	audioFolder = audioFolder or ReplicatedStorage:FindFirstChild("audio")
	local template = audioFolder and audioFolder:FindFirstChild(name)
	if not template or not template:IsA("Sound") then
		return nil
	end
	local sound = template:Clone()
	if configure then
		configure(sound)
	end
	sound.Parent = cast.Emitter
	sound:Play()
	if not sound.Looped then
		sound.Ended:Once(function()
			sound:Destroy()
		end)
	end
	return sound
end

local function stopSound(sound: Sound?)
	if sound and sound.Parent then
		sound:Stop()
		sound:Destroy()
	end
end

local function configureHum(sound: Sound)
	sound.Looped = true
	sound.RollOffMode = Enum.RollOffMode.Linear
	sound.RollOffMaxDistance = HUM_RANGE
	sound.RollOffMinDistance = math.min(sound.RollOffMinDistance, HUM_RANGE / 4)
	-- start somewhere random so several frozen spells don't hum in unison
	if sound.TimeLength > 1 then
		sound.TimePosition = cloudRng:NextNumber(0, sound.TimeLength - 1)
	end
end

--------------------------------------------------------------------------------
-- Cast lifecycle
--------------------------------------------------------------------------------

local function destroyCast(cast: CastState)
	for _, circle in cast.Circles do
		for _, piece in circle.Pieces do
			piece.Part:Destroy()
		end
	end
	table.clear(cast.Circles)
	stopSound(cast.Hum)
	cast.Hum = nil
	local emitter = cast.Emitter
	task.delay(SOUND_LINGER, function()
		emitter:Destroy()
	end)
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
				Pieces = { newPiece(part, gui, BASE_RADIUS * (1 + 0.4 * depth)) },
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
		local pieces: { Piece } = {}
		buildCircle(builder, function()
			local part, gui, root = newCanvas(side)
			part.Parent = parent
			table.insert(pieces, newPiece(part, gui, radius * (0.6 + 0.3 * index)))
			return root
		end, cs, spec.Numeral or "")
		local circle: Circle = { Part = pieces[1].Part, Gui = pieces[1].Gui, Pieces = pieces, Size = side, Distance = distance }
		table.insert(circles, circle)
		addSatellites(cs, circle, radius, 1)
		-- the next vessel's circle stacks past this one's satellites
		distance += STACK_GAP + SAT_GAP * satelliteDepth(cs)
		local quantity = cs.Quantity
		if index == 1 and quantity and quantity.Pattern == "Stream" and quantity.Count > 1 then
			for k = 1, math.min(quantity.Count - 1, 4) do
				local ghostPart, ghostGui, ghostRoot = newCanvas(side * (1 - 0.06 * k))
				buildGhost(builder, ghostRoot, cs, 0.75 + 0.05 * k, 0.85 + 0.05 * k)
				table.insert(circles, {
					Part = ghostPart,
					Gui = ghostGui,
					Pieces = { newPiece(ghostPart, ghostGui, radius * 1.2) },
					Size = side * (1 - 0.06 * k),
					Distance = HAND_DISTANCE - 0.4 * k,
					Ghost = true,
				})
				ghostPart.Parent = parent
			end
		end
	end
	local emitter = Instance.new("Attachment")
	emitter.Name = "SpellCircleSound"
	emitter.Parent = workspace.Terrain
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
		Emitter = emitter,
		RingsShown = 0,
		Glow = 0,
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
		local origin = cast.FrozenOrigin or head.Position - Vector3.new(0, 0.3, 0)
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
			-- each overcharge ring that finishes drawing manifests: a sound and a flare
			local shown = math.floor(over * OVER_RINGS + 1e-6)
			while cast.RingsShown < shown do
				cast.RingsShown += 1
				playSound(cast, if cast.RingsShown >= OVER_RINGS then SOUND_MANIFEST_END else SOUND_MANIFEST)
				cast.Glow = 1
			end
		elseif cast.State == "frozen" then
			-- held in place, idling and pulsing; one frozen mid-draw finishes
			-- drawing (its charge keeps growing to 1x, like the server's)
			local cap = cast.ChargeCap or cast.Charge
			if cast.Charge < cap then
				cast.Charge = math.min(cap, math.max(cast.Charge, (os.clock() - cast.Began) / SpellRunes.Charge.FullTime))
			end
			progress = math.min(cast.Charge, 1)
			over = math.clamp((cast.Charge - 1) / (SpellRunes.Charge.Max - 1), 0, 1)
			spinBoost = 0.6 + over
			flash = 0.4 + math.sin(cast.Age * 4) * 0.4
		elseif cast.State == "assemble" then
			-- the cloud flies back together facing the target, then releases
			local f = math.clamp((os.clock() - (cast.AssembleStart or 0)) / SpellRunes.Freeze.AssembleTime, 0, 1)
			over = math.clamp((cast.Charge - 1) / (SpellRunes.Charge.Max - 1), 0, 1)
			spinBoost = 3 + 5 * f
			flash = 1.5 * f
			if f >= 1 then
				cast.State, cast.StateAge = "release", 0
				playSound(cast, SOUND_FIRE)
			end
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
		if cast.State == "frozen" then
			if not cast.Hum then
				cast.Hum = playSound(cast, SOUND_HUM, configureHum)
			end
		elseif cast.Hum then
			stopSound(cast.Hum)
			cast.Hum = nil
		end
		cast.Glow = math.max(0, cast.Glow - dt / GLOW_TIME)

		cast.Spin += ddt * spinBoost
		for _, l in cast.Layers do
			l.Frame.Rotation = l.Phase + l.Speed * cast.Spin
		end
		applyItems(cast, progress, over, visible)

		if cast.AimGoal and cast.Target then
			cast.Target = cast.Target:Lerp(cast.AimGoal, 1 - math.exp(-dt * AIM_SMOOTHING))
		end
		local direction = cast.FrozenDirection
		if not direction then
			local aim = aimPoint(cast, origin) - origin
			direction = if aim.Magnitude > 1e-3 then aim.Unit else caster:GetPivot().LookVector
		end
		assert(direction)
		local brightness = 2.5 + over * 1.5 + math.sin(cast.Age * 10) * over * 0.8 + flash + cast.Glow * GLOW_BOOST
		local basis = CFrame.lookAt(origin, origin + direction)
		-- how far apart the pieces are: 0 = assembled circle(s), 1 = frozen cloud
		local cloud = 0
		if cast.State == "frozen" then
			cloud = math.min(1, cast.StateAge / CLOUD_DISPERSE)
		elseif cast.State == "assemble" then
			cloud = 1 - math.clamp((os.clock() - (cast.AssembleStart or 0)) / SpellRunes.Freeze.AssembleTime, 0, 1)
		end
		cloud = cloud * cloud * (3 - 2 * cloud) -- smoothstep
		local cloudCentre = origin + direction * HAND_DISTANCE
		cast.Emitter.WorldPosition = cloudCentre
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
			local side = circle.Size * sizeMul * (1 - 0.25 * cloud)
			local pieceBrightness = if circle.Ghost then brightness * 0.6 else brightness
			for index, piece in circle.Pieces do
				local placed = frame * CFrame.new(0, 0, -PIECE_GAP * (index - 1))
				if cloud > 0 then
					local swing = 1 + piece.Bob / math.max(piece.Drift.Magnitude, 1e-3) * math.sin(cast.Age * piece.BobRate + piece.BobPhase)
					local drift = CFrame.fromAxisAngle(piece.DriftAxis, cast.Age * piece.DriftRate) * (piece.Drift * swing)
					local tumble = CFrame.fromAxisAngle(piece.Axis, cast.Age * piece.Rate) * piece.Tilt
					placed = placed:Lerp(CFrame.new(cloudCentre + drift) * tumble, cloud)
				end
				local part = piece.Part
				part.CFrame = placed
				if part.Size.X ~= side then
					part.Size = Vector3.new(side, side, 0.05)
				end
				-- SurfaceGuis only draw on one side: show whichever faces the camera
				local face = if (cameraPosition - placed.Position):Dot(placed.LookVector) > 0 then Enum.NormalId.Front else Enum.NormalId.Back
				if piece.Gui.Face ~= face then
					piece.Gui.Face = face
				end
				piece.Gui.Brightness = pieceBrightness
			end
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
		cast.ChargeSound = playSound(cast, SOUND_CHARGE)
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
	if cast.State == "charge" and os.clock() - cast.Began < TAP_TIME then
		stopSound(cast.ChargeSound) -- a tap: no wind-up to hear
	end
	playSound(cast, SOUND_FIRE)
	cast.Charge = math.max(charge, 1) -- draw everything; >1 keeps the overcharge rings
	if target then
		cast.Target = target
		cast.AimGoal = nil -- the real shot's aim wins over the last relayed one
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
		stopSound(cast.ChargeSound)
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

-- Freezes the caster's charging circle where it is (R). `position` is the
-- main circle's centre and `direction` its facing; omitted, the circle's
-- current placement is used (the caster's own client). A client that missed
-- Begin builds it from `spec` at `charge`. Returns where the main circle
-- now hangs.
function SpellCircleVFX.Freeze(caster: Model, position: Vector3?, direction: Vector3?, spec: any?, charge: number?): Vector3?
	local cast = current[caster]
	if not cast then
		cast = createCast(caster, spec, nil, false)
		if not cast then
			return nil
		end
		ensureRunning()
	end
	current[caster] = nil
	if charge then
		cast.Charge = charge
		cast.Began = os.clock() - charge * SpellRunes.Charge.FullTime -- so it keeps growing from there
	end
	cast.ChargeCap = if cast.Charge < 1 then 1 else cast.Charge
	local main = cast.Circles[1].Part
	local facing = direction or main.CFrame.LookVector
	local centre = position or main.Position
	cast.FrozenDirection = facing
	cast.FrozenOrigin = centre - facing * HAND_DISTANCE
	cast.State, cast.StateAge = "frozen", 0
	local queue = frozen[caster]
	if not queue then
		queue = {}
		frozen[caster] = queue
	end
	table.insert(queue, cast)
	while #queue > MAX_FROZEN_SAFETY do
		local oldest = table.remove(queue, 1) :: CastState
		oldest.State, oldest.StateAge = "cancel", 0
	end
	return centre
end

-- Fires the caster's oldest frozen circle (T): its cloud reassembles into the
-- circle(s) facing `target` over SpellRunes.Freeze.AssembleTime (the server
-- launches the spell then), and releases.
function SpellCircleVFX.FireFrozen(caster: Model, target: Vector3)
	local queue = frozen[caster]
	local cast = queue and table.remove(queue, 1)
	if not cast then
		return
	end
	local origin, facing = cast.FrozenOrigin, cast.FrozenDirection
	if origin and facing then
		local centre = origin + facing * HAND_DISTANCE
		local aim = target - centre
		local direction = if aim.Magnitude > 1e-3 then aim.Unit else facing
		cast.FrozenDirection = direction
		cast.FrozenOrigin = centre - direction * HAND_DISTANCE
	end
	cast.State, cast.StateAge = "assemble", 0
	cast.AssembleStart = os.clock()
end

-- Drops every frozen circle of the caster (death, respawn, leaving).
function SpellCircleVFX.ClearFrozen(caster: Model)
	for _, cast in frozen[caster] or {} do
		cast.State, cast.StateAge = "cancel", 0
	end
	frozen[caster] = nil
end

function SpellCircleVFX.FrozenCount(caster: Model): number
	local queue = frozen[caster]
	return if queue then #queue else 0
end

-- A relayed live aim for `caster`'s charging/channelling circle.
function SpellCircleVFX.SetAim(caster: Model, position: Vector3)
	local cast = current[caster]
	if not cast or cast.IsLocal then
		return
	end
	cast.AimGoal = position
	if not cast.Target then
		cast.Target = position
	end
end

do
	local remotes = ReplicatedStorage:WaitForChild("SpellRemotes")
	local relay = remotes:WaitForChild("SpellAimRelay") :: UnreliableRemoteEvent
	local channel = remotes:WaitForChild("SpellChannel") :: RemoteEvent
	local gameSettings = UserSettings():GetService("UserGameSettings")

	local function wantsLiveAim(): boolean
		local saved = gameSettings.SavedQualityLevel
		return saved == Enum.SavedQualitySetting.Automatic or saved.Value >= LIVE_AIM_QUALITY
	end

	local subscribed: boolean? = nil
	local function updateSubscription()
		local wanted = wantsLiveAim()
		if wanted ~= subscribed then
			subscribed = wanted
			channel:FireServer("AimSubscribe", wanted)
		end
	end
	updateSubscription()
	gameSettings:GetPropertyChangedSignal("SavedQualityLevel"):Connect(updateSubscription)

	relay.OnClientEvent:Connect(function(caster: any, position: any)
		if subscribed and typeof(caster) == "Instance" and caster:IsA("Model") and typeof(position) == "Vector3" then
			SpellCircleVFX.SetAim(caster, position)
		end
	end)
end

VisualOffload.On("SpellCircle", function(data)
	if typeof(data) ~= "table" then
		return
	end
	local caster = data.Caster
	if typeof(caster) ~= "Instance" or not caster:IsA("Model") then
		return
	end
	if data.Phase == "ClearFrozen" then
		SpellCircleVFX.ClearFrozen(caster) -- also for our own character: the server decides when
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
	elseif data.Phase == "Freeze" then
		local position = if typeof(data.Position) == "Vector3" then data.Position else nil
		local direction = if typeof(data.Direction) == "Vector3" and data.Direction.Magnitude > 1e-3 then data.Direction.Unit else nil
		SpellCircleVFX.Freeze(caster, position, direction, data.Spec, if typeof(data.Charge) == "number" then data.Charge else nil)
	elseif data.Phase == "FireFrozen" and target then
		SpellCircleVFX.FireFrozen(caster, target)
	end
end)

return SpellCircleVFX
