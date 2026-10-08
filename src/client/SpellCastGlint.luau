--!strict
--[[
	Cast glint: a short flare on a spell circle -- a crosshair star in the
	cast's mana-tier colour:

	  * an extremely thin ring;
	  * a cross whose arms run past the ring and taper off towards their tips
	    (layers that get shorter as they get thicker, each fading out along
	    its length) -- thick at the centre, where they make a small four-point
	    star, thinning to hairlines at the ends;
	  * a near-white core with soft tier-coloured glow around every stroke.

	It gets fancier with the tier (each adds to the last):
	  1  a tiny inner ring and four hollow diamonds on the ring
	  2  tapered diagonal rays
	  3  a second, wider ring and a slowly turning ring of tick marks
	  4  a turning ring of eight hollow diamonds and a burst of sparkles
	  5  a counter-turning dashed ring, hairline diagonals and more sparkles
	and brightens and lingers a little more each tier.

	It's part of its spell circle: SpellCircleVFX places it on the circle in
	the same step that moves the circle (handle:Place, every frame), and
	locks it where it was when the spell fires (handle:Lock) -- it finishes
	there. Never placed (Play's handle unused), it puts itself in front of
	the caster towards `target`.

	A transparent Part with a SurfaceGui (lit at full brightness, so bloom
	picks it up). It flares in, shimmers (brightness flicker and a light
	sweep along the lines), then fades out: every stroke's own transparency
	and the glow's brightness fall together while it swells slightly (no
	CanvasGroup, whose fade inside a SurfaceGui doesn't take the bloom with
	it). One cut short (its caster gone, or too many at once) fades from
	wherever it had got to. Parts are pooled per tier.
]]

local RunService = game:GetService("RunService")
local ManaTier = require(game:GetService("ReplicatedStorage").Shared.SpellManaTier)

local Glint = {}

-- The player's "Glints" setting (client/ClientSettings): off by default.
local enabled = false

function Glint.SetEnabled(on: boolean)
	enabled = on
end

function Glint.IsEnabled(): boolean
	return enabled
end

local CANVAS = 512
local DISTANCE = 5.5 -- (self-placed only) studs in front of the hand
local AHEAD = 0.3 -- studs in front of its circle, so it draws over it
local RING = 0.5 -- the ring's diameter, as a share of the glint's size
local RISE = 0.07 -- flare in
local FADE_SHARE = 0.15 -- the last part of a glint's life is its fade-out
local CUT_FADE = 0.15 -- seconds a glint cut short takes to fade out
local MAX_ACTIVE = 24

local function fallbackSize(tier: number): number
	return 12 + tier * 1.3
end
local function lifetimeOf(tier: number): number
	return 0.35 + tier * 0.01
end 

-- arms: { length (fraction of the canvas), thickness (px) }, longest first
local ARM_LAYERS = { { 1.0, 1.5 }, { 0.62, 3 }, { 0.34, 6 }, { 0.16, 11 } }
local RAY_LAYERS = { { 0.5, 1 }, { 0.26, 2.5 } }
-- each arm layer fades out towards both ends
local TAPER = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.2, 0.7),
	NumberSequenceKeypoint.new(0.5, 0),
	NumberSequenceKeypoint.new(0.8, 0.7),
	NumberSequenceKeypoint.new(1, 1),
})

-- something drawn: its transparency property and its fully-shown value
type Fade = { object: Instance, property: string, base: number }

type Look = {
	part: Part,
	gui: SurfaceGui,
	fades: { Fade },
	sweeps: { UIGradient },
	spinners: { { frame: GuiObject, speed: number } },
	sparkles: ParticleEmitter?,
}

type Entry = Look & {
	tier: number,
	caster: Model,
	head: BasePart,
	target: Vector3?,
	began: number,
	lifetime: number,
	seed: number,
	base: CFrame?, -- where its circle put it (nil: place itself)
	side: number, -- its size in studs
	locked: boolean,
	cutAt: number?, -- cut short: fading from `cutFrom` since then
	cutFrom: number,
	shown: number, -- how visible it is now (0-1)
	lastShown: number,
}

export type Handle = {
	Place: (self: Handle, frame: CFrame, circleSize: number?) -> (),
	Lock: (self: Handle) -> (),
}

local active: { Entry } = {}
local pools: { [number]: { Look } } = {}
local folder: Folder? = nil
local connection: RBXScriptConnection? = nil

local function container(): Folder
	if folder and folder.Parent then
		return folder
	end
	local made = Instance.new("Folder")
	made.Name = "SpellCastGlints"
	made.Parent = workspace
	folder = made
	return made
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local function layer(parent: GuiObject): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.one * 0.5
	f.Position = UDim2.fromScale(0.5, 0.5)
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundTransparency = 1
	f.Parent = parent
	return f
end

-- (everything drawn is listed in `fades`, so it can fade as one)
local fades: { Fade } = {} -- the glint being built's

local function stroke(parent: GuiObject, color: Color3, thickness: number, transparency: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	table.insert(fades, { object = s, property = "Transparency", base = transparency })
end

-- A filled frame (a line or mark) that fades.
local function fill(f: Frame, transparency: number)
	f.BorderSizePixel = 0
	f.BackgroundTransparency = 1
	table.insert(fades, { object = f, property = "BackgroundTransparency", base = transparency })
end

-- A thin ring: a hairline core and two soft halos.
local function ring(parent: GuiObject, diameter: number, color: Color3, core: Color3, faint: boolean?)
	for index = 1, 3 do
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.one * 0.5
		f.Position = UDim2.fromScale(0.5, 0.5)
		f.Size = UDim2.fromScale(diameter, diameter)
		f.BackgroundTransparency = 1
		f.Parent = parent
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = f
		if index == 1 then
			stroke(f, color, 9, if faint then 0.96 else 0.93)
		elseif index == 2 then
			stroke(f, color, 3.5, if faint then 0.86 else 0.78)
		else
			stroke(f, core, 1, if faint then 0.35 else 0.05)
		end
	end
end

-- A line through the centre at `rotation`, built from `layers` (shorter as
-- they get thicker), each fading towards its ends; `sweeps` collects the
-- bright cores' gradients for the shimmer.
local function taperedLine(parent: GuiObject, rotation: number, layers: { { number } }, color: Color3, core: Color3, sweeps: { UIGradient }?)
	for _, spec in layers do
		local length, thickness = spec[1], spec[2]
		for pass = 1, 2 do
			-- pass 1: coloured glow (wider, faint); pass 2: bright core
			local f = Instance.new("Frame")
			f.AnchorPoint = Vector2.one * 0.5
			f.Position = UDim2.fromScale(0.5, 0.5)
			f.Size = UDim2.new(length, 0, 0, if pass == 1 then thickness * 3 else thickness)
			f.Rotation = rotation
			f.BackgroundColor3 = if pass == 1 then color else core
			fill(f, if pass == 1 then 0.82 else 0)
			f.Parent = parent
			local fade = Instance.new("UIGradient")
			fade.Transparency = TAPER
			fade.Parent = f
			if pass == 2 and sweeps then
				-- (its Offset sweeps a highlight along the line while it shimmers)
				fade.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, core),
					ColorSequenceKeypoint.new(0.5, Color3.new(1, 1, 1)),
					ColorSequenceKeypoint.new(1, core),
				})
				table.insert(sweeps, fade)
			end
		end
	end
end

-- A small hollow diamond at polar (radius, angle) on the canvas.
local function diamond(parent: GuiObject, radius: number, angle: number, size: number, color: Color3, core: Color3)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.one * 0.5
	f.Position = UDim2.fromScale(0.5 + math.cos(angle) * radius, 0.5 + math.sin(angle) * radius)
	f.Size = UDim2.fromScale(size, size)
	f.Rotation = 45 + math.deg(angle)
	f.BackgroundTransparency = 1
	f.Parent = parent
	stroke(f, color, 4, 0.85)
	local inner = Instance.new("Frame")
	inner.Size = UDim2.fromScale(1, 1)
	inner.BackgroundTransparency = 1
	inner.Parent = f
	stroke(inner, core, 1, 0.1)
end

-- `count` short strokes around a circle of `radius`, tangent (dashes) or
-- pointing outwards (ticks).
local function marks(parent: GuiObject, count: number, radius: number, length: number, tangent: boolean, core: Color3, transparency: number)
	for index = 1, count do
		local angle = (index - 1) / count * math.pi * 2
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.one * 0.5
		f.Position = UDim2.fromScale(0.5 + math.cos(angle) * radius, 0.5 + math.sin(angle) * radius)
		f.Size = UDim2.new(length, 0, 0, 1.2)
		f.Rotation = math.deg(angle) + (if tangent then 90 else 0)
		f.BackgroundColor3 = core
		fill(f, transparency)
		f.Parent = parent
	end
end

local function build(tier: number): Look
	local color = ManaTier.Colors[tier + 1]
	local core = color:Lerp(Color3.new(1, 1, 1), 0.7)
	local size = fallbackSize(tier)
	fades = {}
	local part = Instance.new("Part")
	part.Name = "Glint"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(size, size, 0.05)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(CANVAS, CANVAS)
	gui.LightInfluence = 0
	gui.Brightness = 3
	gui.ClipsDescendants = false
	gui.Parent = part
	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui
	local sweeps, spinners = {}, {}

	ring(root, RING, color, core)
	taperedLine(root, 0, ARM_LAYERS, color, core, sweeps)
	taperedLine(root, 90, ARM_LAYERS, color, core, sweeps)
	if tier >= 1 then
		ring(root, 0.08, color, core, true)
		for index = 0, 3 do
			diamond(root, RING / 2, index * math.pi / 2, 0.028, color, core)
		end
	end
	if tier >= 2 then
		taperedLine(root, 45, RAY_LAYERS, color, core, sweeps)
		taperedLine(root, -45, RAY_LAYERS, color, core, sweeps)
	end
	if tier >= 3 then
		ring(root, 0.62, color, core, true)
		local ticks = layer(root)
		marks(ticks, 24, 0.285, 0.018, false, core, 0.25)
		table.insert(spinners, { frame = ticks, speed = 25 })
	end
	if tier >= 4 then
		local orbit = layer(root)
		for index = 0, 7 do
			diamond(orbit, 0.36, index * math.pi / 4 + math.pi / 8, 0.024, color, core)
		end
		table.insert(spinners, { frame = orbit, speed = -40 })
	end
	if tier >= 5 then
		local dashes = layer(root)
		marks(dashes, 36, 0.42, 0.022, true, core, 0.3)
		table.insert(spinners, { frame = dashes, speed = 55 })
		for _, rotation in { 45, -45 } do
			local f = Instance.new("Frame")
			f.AnchorPoint = Vector2.one * 0.5
			f.Position = UDim2.fromScale(0.5, 0.5)
			f.Size = UDim2.new(0.95, 0, 0, 1)
			f.Rotation = rotation
			f.BackgroundColor3 = core
			fill(f, 0.4)
			f.Parent = root
			local fade = Instance.new("UIGradient")
			fade.Transparency = TAPER
			fade.Parent = f
		end
	end

	local sparkles: ParticleEmitter? = nil
	if tier >= 4 then
		local attachment = Instance.new("Attachment")
		attachment.Parent = part
		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		emitter.Color = ColorSequence.new(core, color)
		emitter.LightEmission = 1
		emitter.LightInfluence = 0
		emitter.Brightness = 3
		emitter.Rate = 0
		emitter.Lifetime = NumberRange.new(0.35, 0.7)
		emitter.Speed = NumberRange.new(3, 9)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Drag = 4
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Parent = attachment
		sparkles = emitter
	end
	return { part = part, gui = gui, fades = fades, sweeps = sweeps, spinners = spinners, sparkles = sparkles }
end

-- Shows everything drawn at `shown` (0 hidden .. 1 fully shown).
local function setShown(entry: any, shown: number)
	if shown == entry.lastShown then
		return
	end
	entry.lastShown = shown
	for _, fade in entry.fades do
		(fade.object :: any)[fade.property] = 1 - (1 - fade.base) * shown
	end
end

--------------------------------------------------------------------------------
-- Running
--------------------------------------------------------------------------------

local function recycle(entry: Entry)
	entry.part.Parent = nil
	local pool = pools[entry.tier]
	if not pool then
		pool = {}
		pools[entry.tier] = pool
	end
	if #pool < 3 then
		table.insert(pool, {
			part = entry.part, gui = entry.gui, fades = entry.fades,
			sweeps = entry.sweeps, spinners = entry.spinners, sparkles = entry.sparkles,
		})
	else
		entry.part:Destroy()
	end
end

-- Ends a glint early: it stays where it is and fades out from wherever it
-- had got to (never just vanishes).
local function cut(entry: Entry, now: number)
	if not entry.cutAt then
		entry.cutAt = now
		entry.cutFrom = entry.shown
		entry.locked = true
	end
end

-- Puts the glint where its circle (or, self-placed, the aim) says, with its
-- flare twist and swell for its age; draws on the side facing the camera.
local function place(entry: Entry, now: number)
	local t = math.clamp((now - entry.began) / entry.lifetime, 0, 1)
	local base = entry.base
	if not base then
		local origin = entry.head.Position - Vector3.new(0, 0.3, 0)
		local aim = if entry.target then entry.target - origin else entry.caster:GetPivot().LookVector
		local direction = if aim.Magnitude > 1e-3 then aim.Unit else entry.caster:GetPivot().LookVector
		local centre = origin + direction * DISTANCE
		base = CFrame.lookAt(centre, centre + direction)
		if entry.locked then
			entry.base = base -- (self-placed and cut short: stays put)
		end
	end
	-- a slight twist about the aim as it flares, and a swell: up as it
	-- flares, a little more as it fades
	local twist = math.rad(-10 + 22 * (1 - (1 - t) ^ 2) + entry.seed)
	local placed = (base :: CFrame) * CFrame.new(0, 0, -AHEAD) * CFrame.Angles(0, 0, twist)
	entry.part.CFrame = placed
	local swell = 0.8 + 0.25 * (1 - (1 - math.min(t * 1.6, 1)) ^ 3) + 0.15 * (1 - entry.shown)
	local side = entry.side * swell
	if math.abs(entry.part.Size.X - side) > 1e-3 then
		entry.part.Size = Vector3.new(side, side, 0.05)
	end
	local camera = workspace.CurrentCamera
	if camera then
		local face = if (camera.CFrame.Position - placed.Position):Dot(placed.LookVector) > 0 then Enum.NormalId.Front else Enum.NormalId.Back
		if entry.gui.Face ~= face then
			entry.gui.Face = face
		end
	end
end

local function step()
	local now = os.clock()
	for index = #active, 1, -1 do
		local entry = active[index]
		local age = now - entry.began
		if entry.head.Parent == nil or entry.caster.Parent == nil then
			cut(entry, now)
		end
		-- visibility: flare in, hold, fade out -- or, cut short, fade from
		-- where it was
		local shown
		if entry.cutAt then
			local f = math.clamp((now - entry.cutAt) / CUT_FADE, 0, 1)
			shown = entry.cutFrom * (1 - f * f * (3 - 2 * f))
		else
			local rise = math.clamp(age / RISE, 0, 1)
			rise = rise * rise * (3 - 2 * rise)
			local fadeFrom = entry.lifetime * (1 - FADE_SHARE)
			local fade = math.clamp((age - fadeFrom) / (entry.lifetime - fadeFrom), 0, 1)
			-- (eased out: quick at first, trailing off to nothing)
			fade = 1 - (1 - fade) * (1 - fade)
			shown = rise * (1 - fade)
		end
		if (shown <= 0.002 and age > RISE) or age > entry.lifetime + CUT_FADE then
			recycle(entry)
			table.remove(active, index)
			continue
		end
		entry.shown = shown
		setShown(entry, shown)
		-- (on its circle -- Place keeps `base` current; locked, it stays where
		-- it was fired, still twisting and swelling)
		place(entry, now)
		-- shimmer: brightness flicker (falling with the fade, so the glow goes
		-- too), a light sweeping along the lines, the higher tiers' rings
		-- turning
		local shimmer = 0.5 + 0.5 * math.sin(age * 38 + entry.seed) * math.sin(age * 23)
		local flare = 1.5 * math.max(0, 1 - age / RISE)
		entry.gui.Brightness = ((2.2 + entry.tier * 0.35) * (1 + shimmer) + flare) * shown
		local sweep = -1 + 2 * ((age * 2.6 + entry.seed * 0.01) % 1)
		for _, gradient in entry.sweeps do
			gradient.Offset = Vector2.new(sweep * 0.5, 0)
		end
		for _, spinner in entry.spinners do
			spinner.frame.Rotation = age * spinner.speed
		end
	end
	if #active == 0 and connection then
		connection:Disconnect()
		connection = nil
	end
end

-- Flashes a glint for a cast by `caster` costing `manaCost`. Returns a
-- handle: :Place(frame, circleSize) puts it on its spell circle (call it
-- every frame from where the circle is moved), :Lock() keeps it where it is
-- from then on. Never placed, it faces `target` from in front of the caster.
function Glint.Play(caster: Model, manaCost: number, target: Vector3?): Handle?
	if not enabled then
		return nil -- (the player's Glints setting; off by default)
	end
	local head = caster:FindFirstChild("Head") or caster.PrimaryPart
	if not head or not head:IsA("BasePart") then
		return nil
	end
	local now = os.clock()
	local tier = ManaTier.GetTier(manaCost)
	local pool = pools[tier]
	local look = if pool and #pool > 0 then table.remove(pool) :: Look else build(tier)
	-- too many at once: the oldest still showing fades out early
	local showing = 0
	for _, entry in active do
		if not entry.cutAt then
			showing += 1
		end
	end
	if showing >= MAX_ACTIVE then
		for _, entry in active do
			if not entry.cutAt then
				cut(entry, now)
				break
			end
		end
	end
	local entry: Entry = {
		part = look.part,
		gui = look.gui,
		fades = look.fades,
		sweeps = look.sweeps,
		spinners = look.spinners,
		sparkles = look.sparkles,
		tier = tier,
		caster = caster,
		head = head,
		target = target,
		began = now,
		lifetime = lifetimeOf(tier),
		seed = math.random() * 10,
		base = nil,
		side = fallbackSize(tier),
		locked = false,
		cutAt = nil,
		cutFrom = 0,
		shown = 0,
		lastShown = -1,
	}
	setShown(entry, 0)
	entry.part.Parent = container()
	table.insert(active, entry)
	step() -- placed on the input frame
	if entry.sparkles then
		entry.sparkles:Emit(if tier >= 5 then 26 else 14)
	end
	if not connection then
		connection = RunService.RenderStepped:Connect(step)
	end

	local handle = {}
	function handle.Place(_, frame: CFrame, circleSize: number?)
		if entry.locked or entry.part.Parent == nil then
			return
		end
		entry.base = frame
		if circleSize then
			-- (its ring wraps just outside the circle)
			entry.side = circleSize * 1.15 / RING
		end
		place(entry, os.clock())
	end
	function handle.Lock(_)
		entry.locked = true
	end
	return handle :: any
end

return Glint
