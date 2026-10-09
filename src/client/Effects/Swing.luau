--!strict
--[[
	Effects/Swing.luau
	Blade swing trails that stay smooth however fast the blade moves.

	A Roblox Trail samples once per rendered frame, so a swing that covers
	120 degrees in two frames draws as a triangle. Here each frame the
	blade's frame is interpolated (CFrame:Lerp slerps the rotation) from where
	it was last frame to where it is now, in as many sub-steps as the tip's
	travel needs, and every sub-step adds a curved Beam segment to each arc:
	a white-hot edge at the tip, wider glow behind it, and fainter arcs down
	the blade. Segments fade on the local time scale (a frozen zone freezes
	the smear in place).

	Optionally a regular Trail fills the sheet between the arcs, and each
	sub-step's tip path is raycast so a blade dragged through a wall, the
	floor or water throws the right sparks / dust / splash (Effects.Impact
	with kind "scrape").

	Swing.Start(options) -> handle
	  options: {
	    Base: Attachment, Tip: Attachment   -- on the blade (same part)
	    or Part: BasePart + Length?         -- the blade runs along its -Z... see bladeAttachments
	    Color: Color3?, Core: Color3?, Width: number?, Life: number?,
	    Arcs: { { Fraction, Width, Glow } }?, Sheet: boolean?, Contact: boolean?,
	    Ignore: { Instance }?, Strength: number?, MinSpeed: number?,
	  }
	  handle:Stop()     stop adding to the trail (what's drawn fades out)
	  handle:Destroy()  stop and remove now
]]

local Util = require(script.Parent.Util)

local Swing = {}

Swing.Enabled = true
local SEGMENT = 0.9 -- studs of tip travel per sub-step
local MAX_SUBSTEPS = 16
local MAX_SEGMENTS = 900
local CONTACT_INTERVAL = 0.035

type Arc = { Fraction: number, Width: number, Glow: boolean }

local DEFAULT_ARCS: { Arc } = {
	{ Fraction = 1, Width = 1, Glow = false },
	{ Fraction = 0.97, Width = 3.2, Glow = true },
	{ Fraction = 0.75, Width = 1.6, Glow = true },
	{ Fraction = 0.5, Width = 1, Glow = true },
}

type Segment = {
	Beam: Beam,
	A0: Attachment,
	A1: Attachment,
	Born0: number, -- sample ages (dilated seconds)
	Born1: number,
	Width: number,
	Glow: boolean,
	Key: number,
	FreeEnd: boolean?, -- the arc ended here: A1 goes with this segment
}

type Point = { Attachment: Attachment, Born: number }

type State = {
	Base: Attachment,
	Tip: Attachment,
	TipLocal: Vector3,
	Previous: CFrame?,
	Color: Color3,
	Core: Color3,
	Width: number,
	Life: number,
	Arcs: { Arc },
	LastPoints: { Point? },
	Trail: Trail?,
	Contact: boolean,
	Params: RaycastParams?,
	Strength: number,
	MinSpeed: number,
	Emitting: boolean,
	Segments: { Segment },
	Clock: number, -- this swing's dilated time
	LastContact: number,
	Owned: { Instance },
	Stopped: boolean, -- Stop() called or the blade is gone: finish once faded
	Dead: boolean,
}

local swings: { State } = {}
local freeBeams: { Beam } = {}
local freeAttachments: { Attachment } = {}
local segmentCount = 0
local onContact: ((Vector3, Vector3, Vector3, number) -> ())? = nil

local terrain = workspace.Terrain

-- Quantized transparency ramps, shared: no NumberSequence per segment per frame.
local rampCache: { [number]: NumberSequence } = {}
local function ramp(t0: number, t1: number): (NumberSequence, number)
	local a, b = math.floor(t0 * 20 + 0.5), math.floor(t1 * 20 + 0.5)
	local key = a * 32 + b
	local cached = rampCache[key]
	if not cached then
		cached = NumberSequence.new(a / 20, b / 20)
		rampCache[key] = cached
	end
	return cached, key
end

local function takeAttachment(): Attachment
	local attachment = table.remove(freeAttachments)
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = "SwingPoint"
	end
	attachment.Parent = terrain
	return attachment :: Attachment
end

local function takeBeam(): Beam
	local beam = table.remove(freeBeams)
	if not beam then
		beam = Instance.new("Beam")
		beam.Name = "SwingArc"
		beam.FaceCamera = true
		beam.Segments = 4
		beam.LightInfluence = 0
		beam.Enabled = true
	end
	return beam :: Beam
end

-- Attachments are shared by consecutive segments of an arc; one is free
-- once no live segment uses it, which (segments dying oldest first) is when
-- the segment that starts at it dies.
local function releaseSegment(segment: Segment)
	segment.Beam.Attachment0 = nil
	segment.Beam.Attachment1 = nil
	segment.Beam.Parent = nil
	table.insert(freeBeams, segment.Beam)
	segment.A0.Parent = nil
	table.insert(freeAttachments, segment.A0)
	if segment.FreeEnd then
		segment.A1.Parent = nil
		table.insert(freeAttachments, segment.A1)
	end
	segmentCount -= 1
end

local function bladeFrame(state: State): CFrame
	return state.Base.WorldCFrame
end

local function pointAt(state: State, frame: CFrame, fraction: number): Vector3
	return frame:PointToWorldSpace(state.TipLocal * fraction)
end

local function addPoint(state: State, arcIndex: number, frame: CFrame, nextFrame: CFrame, born: number)
	local arc = state.Arcs[arcIndex]
	local previous = state.LastPoints[arcIndex]
	if previous and segmentCount >= MAX_SEGMENTS then
		return -- at the cap: the arc just stops growing
	end
	local position = pointAt(state, frame, arc.Fraction)
	local ahead = pointAt(state, nextFrame, arc.Fraction)
	local tangent = Util.Unit(ahead - position, frame.LookVector)
	local attachment = takeAttachment()
	-- the Beam curves along each attachment's X axis (its Axis)
	attachment.WorldCFrame = CFrame.lookAt(position, position + tangent) * CFrame.Angles(0, math.rad(90), 0)
	state.LastPoints[arcIndex] = { Attachment = attachment, Born = born }
	if not previous then
		return
	end
	local beam = takeBeam()
	local length = (position - previous.Attachment.WorldPosition).Magnitude
	beam.Attachment0 = previous.Attachment
	beam.Attachment1 = attachment
	beam.CurveSize0 = length / 3
	beam.CurveSize1 = length / 3
	beam.Color = ColorSequence.new(if arc.Glow then state.Color else state.Core)
	beam.LightEmission = if arc.Glow then 0.8 else 1
	beam.ZOffset = if arc.Glow then 0 else 0.1
	beam.Parent = previous.Attachment
	segmentCount += 1
	table.insert(state.Segments, {
		Beam = beam, A0 = previous.Attachment, A1 = attachment, Born0 = previous.Born, Born1 = born,
		Width = state.Width * arc.Width, Glow = arc.Glow, Key = -1,
	})
end

-- Ends every arc: the next sample starts new arcs instead of bridging a gap.
-- An arc's last point is freed with the segment that ends at it (or now, if
-- no segment does).
local function breakArcs(state: State)
	for index, point in state.LastPoints do
		if point then
			local owner: Segment? = nil
			for position = #state.Segments, 1, -1 do
				if state.Segments[position].A1 == point.Attachment then
					owner = state.Segments[position]
					break
				end
			end
			if owner then
				owner.FreeEnd = true
			else
				point.Attachment.Parent = nil
				table.insert(freeAttachments, point.Attachment)
			end
		end
		state.LastPoints[index] = nil
	end
end

local function sample(state: State, dt: number, timeScale: number)
	local current = bladeFrame(state)
	local previous = state.Previous
	state.Previous = current
	if not previous or not state.Emitting or not Swing.Enabled then
		breakArcs(state)
		return
	end
	local tipNow = pointAt(state, current, 1)
	local tipBefore = pointAt(state, previous, 1)
	local travel = (tipNow - tipBefore).Magnitude
	local realSpeed = if dt > 0 then travel / dt else 0
	if realSpeed < state.MinSpeed * math.max(timeScale, 0.05) then
		breakArcs(state)
		return
	end
	local steps = math.clamp(math.ceil(travel / SEGMENT), 1, MAX_SUBSTEPS)
	local clockBefore = state.Clock - dt * timeScale
	local last = previous
	for step = 1, steps do
		local alpha = step / steps
		local frame = previous:Lerp(current, alpha)
		local nextFrame = previous:Lerp(current, math.min(alpha + 0.5 / steps, 1) + 1e-3)
		local born = clockBefore + (state.Clock - clockBefore) * alpha
		if step == 1 and not state.LastPoints[1] then
			-- a fresh arc starts where the blade was last frame
			for index in state.Arcs do
				addPoint(state, index, previous, frame, clockBefore)
			end
		end
		for index in state.Arcs do
			addPoint(state, index, frame, nextFrame, born)
		end
		if state.Contact and onContact and state.Clock - state.LastContact >= CONTACT_INTERVAL then
			local from = pointAt(state, last, 1)
			local to = pointAt(state, frame, 1)
			local hit = workspace:Raycast(from, to - from, state.Params)
			if not hit then
				local fromMid, toMid = pointAt(state, last, 0.6), pointAt(state, frame, 0.6)
				hit = workspace:Raycast(fromMid, toMid - fromMid, state.Params)
			end
			if hit then
				state.LastContact = state.Clock
				local velocity = (to - from) / math.max(dt / steps, 1e-3)
				onContact(hit.Position, hit.Normal, velocity, state.Strength)
			end
		end
		last = frame
	end
end

local function fade(state: State)
	local life = state.Life
	local clock = state.Clock
	local index = 1
	local segments = state.Segments
	-- oldest first: drop dead ones from the front
	while index <= #segments do
		local segment = segments[index]
		if clock - segment.Born1 >= life then
			releaseSegment(segment)
			table.remove(segments, index)
		else
			index += 1
		end
	end
	for _, segment in segments do
		local f0 = math.clamp((clock - segment.Born0) / life, 0, 1)
		local f1 = math.clamp((clock - segment.Born1) / life, 0, 1)
		local base = if segment.Glow then 0.55 else 0.05
		local sequence, key = ramp(base + (1 - base) * f0 ^ 1.5, base + (1 - base) * f1 ^ 1.5)
		if key ~= segment.Key then
			segment.Key = key
			segment.Beam.Transparency = sequence
			segment.Beam.Width0 = segment.Width * (1 - f0 * 0.8)
			segment.Beam.Width1 = segment.Width * (1 - f1 * 0.8)
		end
	end
end

local function cleanup(state: State)
	breakArcs(state)
	for _, segment in state.Segments do
		releaseSegment(segment)
	end
	table.clear(state.Segments)
	-- the sheet (and attachments made for a bare part) outlive the arcs by
	-- one trail lifetime, so the sheet fades instead of vanishing
	local trail, owned = state.Trail, state.Owned
	state.Trail = nil
	if trail or #owned > 0 then
		task.delay(state.Life, function()
			if trail then
				trail:Destroy()
			end
			for _, instance in owned do
				instance:Destroy()
			end
		end)
	end
end

function Swing.SetContactHandler(fn: (position: Vector3, normal: Vector3, velocity: Vector3, strength: number) -> ())
	onContact = fn
end

export type Options = {
	Base: Attachment?,
	Tip: Attachment?,
	Part: BasePart?,
	Length: number?,
	Color: Color3?,
	Core: Color3?,
	Width: number?,
	Life: number?,
	Arcs: { Arc }?,
	Sheet: boolean?,
	Contact: boolean?,
	Ignore: { Instance }?,
	Strength: number?,
	MinSpeed: number?,
}

export type Handle = {
	Stop: (Handle) -> (),
	Destroy: (Handle) -> (),
	SetActive: (Handle, boolean) -> (),
}

function Swing.Start(options: Options): Handle
	local owned: { Instance } = {}
	local base, tip = options.Base, options.Tip
	if not (base and tip) then
		-- a blade part: its long axis, from the centre of one end to the other
		local part = options.Part :: BasePart
		assert(part, "Effects.Swing needs Base + Tip attachments or a Part")
		local size = part.Size
		local axis = if size.X >= size.Y and size.X >= size.Z then Vector3.xAxis
			elseif size.Y >= size.Z then Vector3.yAxis else Vector3.zAxis
		local half = (axis * size).Magnitude / 2
		local length = options.Length or half * 2
		local b = Instance.new("Attachment")
		b.Name = "SwingBase"
		b.Position = -axis * half
		b.Parent = part
		local t = Instance.new("Attachment")
		t.Name = "SwingTip"
		t.Position = -axis * half + axis * length
		t.Parent = part
		base, tip = b, t
		table.insert(owned, b)
		table.insert(owned, t)
	end
	local baseAttachment = base :: Attachment
	local tipAttachment = tip :: Attachment
	local color = options.Color or Color3.fromRGB(150, 210, 255)
	local core = options.Core or color:Lerp(Color3.new(1, 1, 1), 0.75)
	local life = options.Life or 0.2

	local trail: Trail? = nil
	if options.Sheet ~= false then
		local sheet = Instance.new("Trail")
		sheet.Name = "SwingSheet"
		sheet.Attachment0 = baseAttachment
		sheet.Attachment1 = tipAttachment
		sheet.Lifetime = life * 0.8
		sheet.FaceCamera = false
		sheet.LightEmission = 0.6
		sheet.LightInfluence = 0
		sheet.Color = ColorSequence.new(color)
		sheet.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.7),
			NumberSequenceKeypoint.new(1, 1),
		})
		sheet.WidthScale = NumberSequence.new(1)
		sheet.MinLength = 0.05
		sheet.Parent = baseAttachment
		trail = sheet
	end

	local params: RaycastParams? = nil
	if options.Contact ~= false then
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.IgnoreWater = false
		local ignore = table.clone(Util.IgnoreList())
		for _, instance in options.Ignore or {} do
			table.insert(ignore, instance)
		end
		local model = baseAttachment.Parent and baseAttachment.Parent:FindFirstAncestorOfClass("Model")
		table.insert(ignore, model or baseAttachment.Parent :: Instance)
		rayParams.FilterDescendantsInstances = ignore
		params = rayParams
	end

	local state: State = {
		Base = baseAttachment,
		Tip = tipAttachment,
		TipLocal = baseAttachment.WorldCFrame:PointToObjectSpace(tipAttachment.WorldPosition),
		Previous = nil,
		Color = color,
		Core = core,
		Width = options.Width or 0.18,
		Life = life,
		Arcs = options.Arcs or DEFAULT_ARCS,
		LastPoints = {},
		Trail = trail,
		Contact = params ~= nil,
		Params = params,
		Strength = options.Strength or 0.6,
		MinSpeed = options.MinSpeed or 18,
		Emitting = true,
		Segments = {},
		Clock = 0,
		LastContact = -math.huge,
		Owned = owned,
		Stopped = false,
		Dead = false,
	}
	table.insert(swings, state)

	local handle = {}
	function handle.Stop(_self)
		state.Emitting = false
		state.Stopped = true
		if state.Trail then
			state.Trail.Enabled = false
		end
	end
	function handle.SetActive(_self, active: boolean)
		if state.Stopped then
			return
		end
		state.Emitting = active
		if state.Trail then
			state.Trail.Enabled = active
		end
	end
	function handle.Destroy(_self)
		if state.Dead then
			return
		end
		state.Dead = true
		cleanup(state)
		local index = table.find(swings, state)
		if index then
			table.remove(swings, index)
		end
	end
	return (handle :: any) :: Handle
end

function Swing.Step(dt: number)
	local index = 1
	while index <= #swings do
		local state = swings[index]
		if not state.Base.Parent or not state.Tip.Parent then
			state.Emitting = false
			state.Stopped = true
		end
		local timeScale = Util.TimeScaleAt(state.Base.WorldPosition)
		state.Clock += dt * timeScale
		sample(state, dt, timeScale)
		fade(state)
		if state.Stopped and #state.Segments == 0 then
			-- finished: nothing drawn and nothing left to draw
			state.Dead = true
			cleanup(state)
			table.remove(swings, index)
			continue
		end
		index += 1
	end
end

function Swing.GetStats(): { Swings: number, Segments: number }
	return { Swings = #swings, Segments = segmentCount }
end

return Swing
