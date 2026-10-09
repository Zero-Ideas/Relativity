--!strict
--[[
	SpellWorld.luau (server)
	What spells do to the world besides damage -- the Barrier, Time Field,
	Force and Blink vessels (server/SpellRuntime decides what and where;
	this module does it):

	 Barriers -- anchored ForceField parts: a Box (one part), or a Dome,
	   Sphere or Ring of panels, sized, turned, tilted and anchored as asked,
	   with one health pool. They may Follow an entity (keeping their offset
	   and turning with it). Who walks through: Pass = "Allies" (the caster
	   and their party: each such client turns the parts' CanCollide off for
	   its own character -- client/SpellBodyClient, from the model's "Pass"
	   attribute), "Everyone" (no collisions at all) or "Nobody". Whose
	   magic they stop: Blocks = "Hostile" (anyone who can hurt the caster:
	   they live in workspace.SpellBarriers.<UserId>, which the caster's and
	   their allies' spells ignore -- SpellIgnore), "All" (<UserId>_all,
	   ignored by nobody) or "None" (SpellBarriers.Pass, ignored by every
	   spell). Spell projectiles, blasts and smites damage them (DamagePart /
	   DamageInRadius); at 0 they shatter, otherwise they fade after their
	   duration.
	 Time fields -- a ChunkManager time-scale zone (replicated; projectiles,
	   bodies and every dilated clock respect it) plus a translucent sphere;
	   they may Follow an entity too.
	 Both are "things" for SpellRuntime's triggers, shaped like a projectile:
	   Position, Velocity, Age (dilated seconds), Dead, Static = true,
	   OnDestroy (Signal: { Position, Normal, Kind }), Destroy(result?, kind?).

	 Forces -- Drive(entity, options) sets a body moving: one shove (a
	   velocity change, or a new velocity with `replace`), or with a duration
	   a steady drive that keeps it moving for that long (Toward re-aims at
	   its centre every frame and holds it there). NPCs and ragdolls are
	   moved here (the server owns them), a player's own character by their
	   client (VisualOffload "SpellImpulse", SpellBodyClient). Loose
	   unanchored parts: PushPart. A horizontal shove is held for a moment
	   (LinearVelocity) so a grounded Humanoid can't brake it away instantly.
	 Blink -- Blink(entity, to, maxDistance, keepMomentum): moves a body
	   toward a point, stopping short of anything in the way.

	Visuals: VisualOffload "SpellFX" (client/SpellBodyClient) for blink
	flashes, force rings and smite bolts; barriers and fields are replicated
	parts.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local Entity = require(Shared:WaitForChild("Entity"))
local Heartbeat = require(Shared:WaitForChild("Heartbeat"))
local Signal = require(Shared:WaitForChild("Signal"))
local StatusEffectSys = require(Shared:WaitForChild("StatusEffectSys"))
local VisualOffload = require(Shared:WaitForChild("VisualOffload"))
local Ragdoll = require(script.Parent:WaitForChild("Ragdoll"))
local BarrierShapes = require(Shared:WaitForChild("BarrierShapes"))

local SpellWorld = {}

local FADE_IN = 0.25
local FADE_OUT = 0.35
local RISE_TIME = 0.5
local HIT_FLASH = 0.12
local SHOVE_HOLD_MIN, SHOVE_HOLD_MAX = 0.12, 0.35 -- seconds a horizontal shove is held (longer when faster)
local SHOVE_HOLD_PER_SPEED = 1 / 350
local RAGDOLL_MIN, RAGDOLL_MAX = 0.8, 2.5
local MAX_LOOSE_PARTS = 40
local MAX_THINGS_PER_PLAYER = 24 -- live barriers + fields per caster; the oldest goes first
local MAX_PANELS = 140 -- panels in one dome / sphere / ring
local FIELD_FOLLOW_STEP = 0.75 -- studs a following field moves before its zone is re-sent
local FIELD_FOLLOW_INTERVAL = 0.1
local ARRIVE_SLOWDOWN = 4 -- a steady pull's speed near its centre: distance x this

export type Thing = {
	Kind: string, -- "Barrier" | "TimeField"
	Position: Vector3,
	Velocity: Vector3,
	Age: number,
	Duration: number,
	Dead: boolean,
	Static: boolean,
	OnDestroy: any,
	Destroy: (self: Thing, result: any?, kind: string?) -> (),
	Health: number?,
	MaxHealth: number?,
	Radius: number, -- rough bounding radius (blast damage, proximity)
	Owner: Player?,
	Blocks: string?, -- (barriers) "Hostile" | "All" | "None"
	_model: Instance?,
	_parts: { BasePart }?,
	_color: Color3?,
	_zone: any?,
	_follow: any?, -- an entity it moves with
	_frame: CFrame?, -- (barriers) where it stands
	_shape: string?, -- (barriers) "Box" | "Dome" | "Sphere" | "Ring"
	_size: Vector3?, -- (barriers) width, height, depth as built
	_offset: CFrame?, -- (following) its frame relative to the entity
	_relative: { [BasePart]: CFrame }?, -- (barriers) each part relative to _frame
	_id: number?, -- (barriers) the BarrierId clients report it by
	_judgedAt: number?, -- (barriers) os.clock of its cluster's last shape verdict
	_cleanFrame: CFrame?, -- (barriers) _frame when its cluster was last judged clean
	_zoneRadius: number?,
	_zoneScale: number?,
	_lastSent: number?,
}

local things: { Thing } = {}
local thingOfPart: { [BasePart]: Thing } = {}
local thingsByOwner: { [Player]: { Thing } } = {}

--------------------------------------------------------------------------------
-- Folders
--------------------------------------------------------------------------------

local function folderUnder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local barrierRoot = folderUnder(workspace, "SpellBarriers")
local fieldRoot = folderUnder(workspace, "SpellFields")
local passFolder = folderUnder(barrierRoot, "Pass") -- Blocks = "None": every spell ignores it

-- The folder a player's Blocks = "Hostile" barriers live in. Their spells and
-- their allies' ignore it (SpellIgnore), so it only stops their enemies' magic.
function SpellWorld.BarrierFolder(player: Player): Folder
	return folderUnder(barrierRoot, tostring(player.UserId))
end

local function folderFor(player: Player?, blocks: string): Folder
	if blocks == "None" then
		return passFolder
	elseif not player then
		return barrierRoot
	elseif blocks == "All" then
		return folderUnder(barrierRoot, `{player.UserId}_all`)
	end
	return SpellWorld.BarrierFolder(player)
end

local function entityOf(player: Player): any?
	local character = player.Character
	return if character then Entity.Get(character) else nil
end

-- Folders whose barriers let `player`'s magic through: Blocks = "None"
-- ones, their own Hostile ones, and those of anyone they can't hurt (their
-- party). For a spell's IgnoreInstances / line-of-sight rays.
function SpellWorld.SpellIgnore(player: Player, caster: any?): { Instance }
	local ignore: { Instance } = { passFolder, SpellWorld.BarrierFolder(player) }
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local folder = barrierRoot:FindFirstChild(tostring(other.UserId))
			local otherEntity = folder and entityOf(other)
			if folder and otherEntity and not Entity.CanDamage(caster, otherEntity) then
				table.insert(ignore, folder)
			end
		end
	end
	return ignore
end

-- Does `thing` (a barrier) stop the magic of `player` / `caster`?
local function stopsMagicOf(thing: Thing, player: Player?, caster: any?): boolean
	if thing.Blocks == "None" then
		return false
	elseif thing.Blocks == "All" or not player or not thing.Owner then
		return true
	elseif thing.Owner == player then
		return false
	end
	local owner = entityOf(thing.Owner :: Player)
	return owner == nil or Entity.CanDamage(caster, owner)
end

Players.PlayerRemoving:Connect(function(player)
	for _, thing in table.clone(thingsByOwner[player] or {}) do
		thing:Destroy(nil, "removed")
	end
	thingsByOwner[player] = nil
	for _, name in { tostring(player.UserId), `{player.UserId}_all` } do
		local folder = barrierRoot:FindFirstChild(name)
		if folder then
			task.delay(FADE_OUT + 0.1, function()
				folder:Destroy()
			end)
		end
	end
end)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function horizontal(vector: Vector3, fallback: Vector3): Vector3
	local level = flat(vector)
	return if level.Magnitude > 1e-3 then level.Unit else fallback
end

-- The ground under `position` (within `depth` studs), ignoring bodies and
-- spell barriers / fields.
local function groundBelow(position: Vector3, depth: number, ignore: { Instance }?): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { barrierRoot, fieldRoot }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	for _, instance in ignore or {} do
		table.insert(exclude, instance)
	end
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	return workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -(depth + 2), 0), params)
end

-- The ground point beneath `position` (within `depth` studs), or nil.
function SpellWorld.Ground(position: Vector3, depth: number): Vector3?
	local hit = groundBelow(position, depth)
	return if hit then hit.Position else nil
end

local function makePanel(model: Model, cframe: CFrame, size: Vector3, color: Color3): BasePart
	local part = Instance.new("Part")
	part.Name = "BarrierPanel"
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = true
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.ForceField
	part.Color = color
	part.Transparency = 1
	part.Size = Vector3.new(math.max(size.X, 0.05), math.max(size.Y, 0.05), math.max(size.Z, 0.05))
	part.CFrame = cframe
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

-- Panels tiling an ellipsoid shell (radius rx across, ry up) from elevation
-- `fromAngle` to `toAngle` (radians; a dome is 0..pi/2), in `frame`'s space
-- around `centre` (local). Panel counts are capped (MAX_PANELS).
local function shellPanels(model: Model, frame: CFrame, centre: Vector3, rx: number, ry: number, fromAngle: number, toAngle: number, thickness: number, color: Color3): { BasePart }
	local parts = {}
	local span = toAngle - fromAngle
	local arc = span * math.max(rx, ry)
	local bands = math.clamp(math.floor(arc / 3.5 + 0.5), 3, 10)
	local bandAngle = span / bands
	local perBand = math.max(math.floor(MAX_PANELS / bands), 5)
	for band = 0, bands - 1 do
		local elevation = fromAngle + (band + 0.5) * bandAngle
		local ring = rx * math.cos(elevation)
		if ring < 0.3 then
			continue
		end
		local count = math.clamp(math.floor(2 * math.pi * ring / 3.2 + 0.5), 5, perBand)
		local width = 2 * math.pi * ring / count * 1.1
		local slope = math.sqrt((rx * math.sin(elevation)) ^ 2 + (ry * math.cos(elevation)) ^ 2)
		local height = bandAngle * slope * 1.12
		for index = 0, count - 1 do
			local azimuth = (index + (band % 2) * 0.5) / count * math.pi * 2
			local c, s = math.cos(azimuth), math.sin(azimuth)
			local unit = Vector3.new(c * math.cos(elevation), math.sin(elevation), s * math.cos(elevation))
			local position = centre + Vector3.new(unit.X * rx, unit.Y * ry, unit.Z * rx)
			local normal = Vector3.new(unit.X / rx, unit.Y / ry, unit.Z / rx).Unit
			local up = if math.abs(normal.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
			local cf = frame * CFrame.lookAt(position, position + normal, up)
			table.insert(parts, makePanel(model, cf, Vector3.new(width, height, thickness), color))
		end
	end
	-- caps where the shell closes (a dome's top, a sphere's poles)
	for _, pole in { toAngle, fromAngle } do
		if math.abs(math.abs(pole) - math.pi / 2) < 1e-3 then
			local sign = math.sign(pole)
			local capSize = rx * math.sin(bandAngle * 0.75) * 2.2
			local position = centre + Vector3.new(0, sign * (ry - thickness / 2), 0)
			table.insert(parts, makePanel(model, frame * CFrame.new(position), Vector3.new(capSize, thickness, capSize), color))
		end
	end
	return parts
end

local function ringPanels(model: Model, frame: CFrame, radius: number, height: number, thickness: number, color: Color3): { BasePart }
	local parts = {}
	local count = math.clamp(math.ceil(2 * math.pi * radius / 3), 6, MAX_PANELS)
	local width = 2 * math.pi * radius / count * 1.08
	for index = 0, count - 1 do
		local azimuth = index / count * math.pi * 2
		local outward = Vector3.new(math.cos(azimuth), 0, math.sin(azimuth))
		local position = outward * radius
		table.insert(parts, makePanel(model, frame * CFrame.lookAt(position, position + outward), Vector3.new(width, height, thickness), color))
	end
	return parts
end

local function track(thing: Thing, owner: Player?)
	table.insert(things, thing)
	if owner then
		local list = thingsByOwner[owner]
		if not list then
			list = {}
			thingsByOwner[owner] = list
		end
		table.insert(list, thing)
		while #list > MAX_THINGS_PER_PLAYER do
			list[1]:Destroy(nil, "replaced")
		end
	end
end

local barrierById: { [number]: Thing } = {}
local nextBarrierId = 0

local function untrack(thing: Thing)
	local index = table.find(things, thing)
	if index then
		table.remove(things, index)
	end
	if thing._id then
		barrierById[thing._id] = nil
	end
	local owner = thing.Owner
	local list = owner and thingsByOwner[owner]
	if list then
		local at = table.find(list, thing)
		if at then
			table.remove(list, at)
		end
	end
	for _, part in thing._parts or {} do
		thingOfPart[part] = nil
	end
end

local function fadeOut(parts: { BasePart }, container: Instance?, shatter: boolean)
	local info = TweenInfo.new(FADE_OUT, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, part in parts do
		if part.Parent then
			part.CanCollide = false
			part.CanQuery = false
			local goal: { [string]: any } = { Transparency = 1 }
			if shatter then
				goal.Size = part.Size * 0.4
				goal.Color = Color3.new(1, 1, 1)
			end
			TweenService:Create(part, info, goal):Play()
		end
	end
	task.delay(FADE_OUT + 0.05, function()
		if container then
			container:Destroy()
		else
			for _, part in parts do
				part:Destroy()
			end
		end
	end)
end

local function destroyThing(thing: Thing, result: any?, kind: string?)
	if thing.Dead then
		return
	end
	thing.Dead = true
	untrack(thing)
	if thing._zone then
		ChunkManager.RemoveTimeScaleZone(thing._zone)
	end
	fadeOut(thing._parts or {}, thing._model, kind == "broken")
	thing.OnDestroy:Fire({
		Position = if result and result.Position then result.Position else thing.Position,
		Normal = if result and result.Normal then result.Normal else Vector3.yAxis,
		Kind = kind,
	})
	thing.OnDestroy:DisconnectAll()
end

-- The pivot an entity carries things on (its root's CFrame, or its position).
local function carrierFrame(entity: any): CFrame?
	if not entity or entity.IsDestroyed then
		return nil
	end
	local root: BasePart? = entity._root
	if root and root.Parent then
		return root.CFrame
	end
	local ok, position = pcall(entity.GetPosition, entity)
	return if ok and typeof(position) == "Vector3" then CFrame.new(position) else nil
end

--------------------------------------------------------------------------------
-- Barriers
--------------------------------------------------------------------------------

export type BarrierOptions = {
	player: Player?,
	caster: any?,
	position: Vector3, -- At
	face: Vector3, -- the point its front turns toward (level)
	fallbackFacing: Vector3?, -- when `face` is straight above / below At
	shape: string, -- "Box" | "Dome" | "Sphere" | "Ring"
	size: Vector3, -- width, height, depth (studs)
	tilt: number?, -- degrees; positive raises its far side
	anchor: string?, -- which part sits on At: "Base" | "Centre" | "Top"
	ground: boolean?, -- drop At onto the ground first
	rise: boolean?, -- grows up out of the ground
	health: number,
	duration: number,
	pass: string?, -- who walks through: "Allies" | "Everyone" | "Nobody"
	blocks: string?, -- whose magic it stops: "Hostile" | "All" | "None"
	follow: any?, -- an entity it moves with
	color: Color3,
}

-- ",<userId>,<userId>," of the players who may walk through (the caster and
-- everyone their magic can't hurt).
local function passList(player: Player?, caster: any?): string
	local ids = {}
	if player then
		table.insert(ids, tostring(player.UserId))
	end
	for _, other in Players:GetPlayers() do
		local otherEntity = if other ~= player then entityOf(other) else nil
		if otherEntity and caster and not Entity.CanDamage(caster, otherEntity) then
			table.insert(ids, tostring(other.UserId))
		end
	end
	return "," .. table.concat(ids, ",") .. ","
end

-- Where a barrier with these options stands, and its clamped size.
local function barrierPlacement(options: BarrierOptions): (CFrame, number, number, number)
	local width = math.clamp(options.size.X, 0.3, 120)
	local height = math.clamp(options.size.Y, 0.3, 120)
	local depth = math.clamp(options.size.Z, 0.3, 60)
	local at = options.position
	if options.ground then
		local ground = groundBelow(at, 60)
		if ground then
			at = ground.Position
		end
	end
	-- turned so its front looks (level) at the face point, then tilted
	local toward = horizontal(options.face - at, horizontal(options.fallbackFacing or Vector3.zAxis, Vector3.zAxis))
	local rotation = CFrame.lookAt(Vector3.zero, toward) * CFrame.Angles(-math.rad(options.tilt or 0), 0, 0)
	local half = height / 2
	local lift = if options.anchor == "Top" then -half elseif options.anchor == "Centre" then 0 else half - (if options.ground then 0.3 else 0)
	return CFrame.new(at + rotation.UpVector * lift) * rotation, width, height, depth
end

local function primitiveShape(shape: string): string
	return if shape == "Dome" or shape == "Sphere" or shape == "Ring" then shape else "Box"
end

-- The barrier these options would raise, as BarrierShapes sees it, without
-- raising it (SpellRuntime's shape probe).
function SpellWorld.BarrierPrimitive(options: BarrierOptions): BarrierShapes.Primitive
	local frame, width, height, depth = barrierPlacement(options)
	return { Frame = frame, Shape = primitiveShape(options.shape), Size = Vector3.new(width, height, depth) }
end

function SpellWorld.CreateBarrier(options: BarrierOptions): Thing
	local frame, width, height, depth = barrierPlacement(options)
	local color = options.color
	local shape = options.shape
	local blocks = options.blocks or "Hostile"
	local half = height / 2

	local model = Instance.new("Model")
	model.Name = "Barrier"
	local parts: { BasePart }
	local radius: number
	if shape == "Dome" then
		parts = shellPanels(model, frame, Vector3.new(0, -half, 0), width / 2, height, 0, math.pi / 2, math.clamp(depth, 0.3, 3), color)
		radius = math.max(width / 2, height)
	elseif shape == "Sphere" then
		parts = shellPanels(model, frame, Vector3.zero, width / 2, half, -math.pi / 2, math.pi / 2, math.clamp(depth, 0.3, 3), color)
		radius = math.max(width / 2, half)
	elseif shape == "Ring" then
		parts = ringPanels(model, frame, width / 2, height, math.clamp(depth, 0.3, 6), color)
		radius = math.max(width / 2, half)
	else
		parts = { makePanel(model, frame, Vector3.new(width, height, depth), color) }
		radius = math.max(width, height, depth) / 2
	end
	-- what clients need to run the shape check on it (client/BarrierWatch):
	-- its id, shape and size, and where its frame is from its first panel
	nextBarrierId += 1
	local barrierId = nextBarrierId
	model:SetAttribute("BarrierId", barrierId)
	model:SetAttribute("BarrierShape", primitiveShape(shape))
	model:SetAttribute("BarrierSize", Vector3.new(width, height, depth))
	if parts[1] then
		parts[1]:SetAttribute("BarrierFrame", parts[1].CFrame:ToObjectSpace(frame))
	end

	local pass = options.pass or "Allies"
	if pass == "Everyone" then
		for _, part in parts do
			part.CanCollide = false
		end
	elseif pass == "Allies" then
		model:SetAttribute("Pass", passList(options.player, options.caster))
	end
	model.Parent = folderFor(options.player, blocks)

	local fadeIn = TweenInfo.new(FADE_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local relative: { [BasePart]: CFrame } = {}
	for _, part in parts do
		relative[part] = frame:ToObjectSpace(part.CFrame)
		TweenService:Create(part, fadeIn, { Transparency = 0 }):Play()
	end
	if options.rise and not options.follow then
		local rise = TweenInfo.new(RISE_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		for _, part in parts do
			local goal = part.CFrame
			part.CFrame = goal - Vector3.new(0, height + 0.5, 0)
			TweenService:Create(part, rise, { CFrame = goal }):Play()
		end
	end

	local health = math.max(options.health, 1)
	local thing: Thing = {
		Kind = "Barrier",
		Position = frame.Position,
		Velocity = Vector3.zero,
		Age = 0,
		Duration = options.duration,
		Dead = false,
		Static = true,
		OnDestroy = Signal.new(),
		Destroy = destroyThing,
		Health = health,
		MaxHealth = health,
		Radius = radius,
		Owner = options.player,
		Blocks = blocks,
		_model = model,
		_parts = parts,
		_color = color,
		_frame = frame,
		_shape = primitiveShape(shape),
		_size = Vector3.new(width, height, depth),
		_relative = relative,
		_id = barrierId,
	}
	barrierById[barrierId] = thing
	local carrier = carrierFrame(options.follow)
	if carrier then
		thing._follow = options.follow
		thing._offset = carrier:ToObjectSpace(frame)
	end
	for _, part in parts do
		thingOfPart[part] = thing
	end
	track(thing, options.player)
	SpellWorld.CheckBarrierShape(thing)
	return thing
end

--------------------------------------------------------------------------------
-- Shape moderation (see server/BarrierShapes)
--------------------------------------------------------------------------------

-- New barriers are judged together a moment after they appear, so a spell
-- that builds many at once is judged as the finished shape, once.
local SHAPE_CHECK_DELAY = 0.35
local MAX_CLUSTER = 120
local STRIKE_WINDOW = 600 -- seconds a flag counts against its casters
local STRIKES_TO_LOCK = 3
local LOCK_SECONDS = 60

local pendingShapes: { Thing } = {}
local shapeCheckQueued = false
local strikes: { [Player]: { number } } = {}
local lockedUntil: { [Player]: number } = {}

local function primitiveOf(thing: Thing): BarrierShapes.Primitive
	return { Frame = thing._frame :: CFrame, Shape = thing._shape or "Box", Size = thing._size :: Vector3 }
end

local function notice(player: Player, text: string)
	VisualOffload.FireClient(player, "Notice", { Title = "Barriers", Text = text })
end

-- Every live barrier touching `seed`, transitively (any caster's).
local function clusterOf(seed: Thing): { Thing }
	local barriers = {}
	for _, thing in things do
		if thing.Kind == "Barrier" and not thing.Dead and thing._frame and thing._size then
			table.insert(barriers, thing)
		end
	end
	local bounds: { [Thing]: number } = {}
	for _, thing in barriers do
		bounds[thing] = BarrierShapes.Bound(primitiveOf(thing))
	end
	local cluster, seen = { seed }, { [seed] = true }
	local index = 1
	while index <= #cluster and #cluster < MAX_CLUSTER do
		local current = cluster[index]
		local position = (current._frame :: CFrame).Position
		local reach = (bounds[current] or 0) + BarrierShapes.GAP
		for _, other in barriers do
			if not seen[other] and ((other._frame :: CFrame).Position - position).Magnitude <= reach + bounds[other] then
				seen[other] = true
				table.insert(cluster, other)
			end
		end
		index += 1
	end
	return cluster
end

local function strike(player: Player)
	local now = os.clock()
	local list = strikes[player] or {}
	strikes[player] = list
	table.insert(list, now)
	while list[1] and now - list[1] > STRIKE_WINDOW do
		table.remove(list, 1)
	end
	if #list >= STRIKES_TO_LOCK then
		table.clear(list)
		lockedUntil[player] = now + LOCK_SECONDS
		notice(player, `Barrier casting is disabled for {LOCK_SECONDS} seconds.`)
	end
end

-- Judges `thing`'s cluster now: a flagged one is dissolved (its casters
-- told and struck), a clean one remembered as clean where it stands.
-- `reporters`: the players whose reports asked for it (logged).
local function judgeCluster(thing: Thing, cluster: { Thing }, reporters: { Player }?): boolean
	local primitives = {}
	for _, member in cluster do
		table.insert(primitives, primitiveOf(member))
	end
	local flagged, report = BarrierShapes.Analyze(primitives)
	local now = os.clock()
	for _, member in cluster do
		member._judgedAt = now
		member._cleanFrame = if flagged then nil else member._frame
	end
	if not flagged then
		return false
	end
	local owners: { [Player]: boolean } = {}
	for _, member in cluster do
		if member.Owner then
			owners[member.Owner] = true
		end
		member:Destroy(nil, "moderated")
	end
	local names = {}
	for owner in owners do
		table.insert(names, `{owner.Name} ({owner.UserId})`)
		notice(owner, "A barrier build was removed for its shape.")
		strike(owner)
	end
	local reportedBy = ""
	if reporters and #reporters > 0 then
		local who = {}
		for _, reporter in reporters do
			table.insert(who, reporter.Name)
		end
		reportedBy = ", reported by " .. table.concat(who, ", ")
	end
	warn(string.format("[BarrierShapes] removed %d barriers by %s at %s (length %.0f, shaft %.1f, base %.1f; %.2f ms%s)",
		#cluster, table.concat(names, ", "), tostring((thing._frame :: CFrame).Position),
		report.Length or 0, report.ShaftWidth or 0, report.BaseWidth or 0, report.Ms, reportedBy))
	return true
end

local function runShapeChecks()
	shapeCheckQueued = false
	local batch = pendingShapes
	pendingShapes = {}
	local judged: { [Thing]: boolean } = {}
	for _, thing in batch do
		if thing.Dead or judged[thing] then
			continue
		end
		local cluster = clusterOf(thing)
		for _, member in cluster do
			judged[member] = true
		end
		judgeCluster(thing, cluster, nil)
	end
end

function SpellWorld.CheckBarrierShape(thing: Thing)
	local owner = thing.Owner
	if owner and (lockedUntil[owner] or 0) > os.clock() then
		-- still on cooldown: it doesn't get to stand
		task.defer(function()
			thing:Destroy(nil, "moderated")
		end)
		return
	end
	if not BarrierShapes.Enabled then
		return
	end
	table.insert(pendingShapes, thing)
	if not shapeCheckQueued then
		shapeCheckQueued = true
		task.delay(SHAPE_CHECK_DELAY, runShapeChecks)
	end
end

--------------------------------------------------------------------------------
-- Client reports (client/BarrierWatch)
--------------------------------------------------------------------------------
-- The check above runs when barriers appear; barriers that follow an entity
-- can come together into a shape later. Every client runs the same check on
-- the barriers it sees as they move, hides a flagged group locally at once
-- and reports one barrier of it here. A report is only a hint: the server
-- rebuilds the cluster from its own state and judges it itself. Spamming
-- reports can't make that expensive:
--  - a report is read for at most MAX_REPORT_IDS ids; anything that isn't a
--    live barrier's id is ignored
--  - each player has a token bucket: REPORT_BURST reports, one more every
--    REPORT_REFILL seconds; the rest are dropped unread
--  - duplicates are ignored: a barrier already queued just adds the reporter
--    to that entry, and a cluster judged within CLUSTER_COOLDOWN seconds
--    isn't judged again, however many players report it
--  - a cluster where nothing moved since it was judged clean is never
--    analysed again (that verdict stands)
--  - judging runs from one server-wide queue (QUEUE_MAX entries, the rest
--    dropped): at most JUDGE_PER_FRAME a frame and JUDGE_MS_PER_SECOND of
--    analysis a second
--  - a player whose reports keep coming back clean (FALSE_LIMIT within
--    FALSE_WINDOW seconds) has their reports ignored for MUTE_SECONDS
local MAX_REPORT_IDS = 8
local REPORT_BURST, REPORT_REFILL = 4, 2
local CLUSTER_COOLDOWN = 1
local QUEUE_MAX = 32
local JUDGE_PER_FRAME = 2
local JUDGE_MS_PER_SECOND = 12
local FALSE_LIMIT, FALSE_WINDOW, MUTE_SECONDS = 6, 60, 120

local remotes = ReplicatedStorage:FindFirstChild("SpellRemotes") or Instance.new("Folder")
remotes.Name = "SpellRemotes"
remotes.Parent = ReplicatedStorage
local reportRemote = remotes:FindFirstChild("BarrierReport") or Instance.new("RemoteEvent")
reportRemote.Name = "BarrierReport"
reportRemote.Parent = remotes

type Reporter = { tokens: number, refilled: number, falses: { number }, mutedUntil: number }
type ReportEntry = { thing: Thing, reporters: { Player } }
local reporters: { [Player]: Reporter } = {}
local reportQueue: { ReportEntry } = {}
local queuedEntry: { [Thing]: ReportEntry } = {}
local judgeBudget = JUDGE_MS_PER_SECOND -- ms of analysis left; refills over time

local function falseReport(player: Player)
	local reporter = reporters[player]
	if not reporter then
		return
	end
	local now = os.clock()
	local falses = reporter.falses
	table.insert(falses, now)
	while falses[1] and now - falses[1] > FALSE_WINDOW do
		table.remove(falses, 1)
	end
	if #falses >= FALSE_LIMIT then
		table.clear(falses)
		reporter.mutedUntil = now + MUTE_SECONDS
	end
end

reportRemote.OnServerEvent:Connect(function(player: Player, ids: any)
	local now = os.clock()
	local reporter = reporters[player]
	if not reporter then
		reporter = { tokens = REPORT_BURST, refilled = now, falses = {}, mutedUntil = 0 }
		reporters[player] = reporter
	end
	if now < reporter.mutedUntil then
		return
	end
	reporter.tokens = math.min(REPORT_BURST, reporter.tokens + (now - reporter.refilled) / REPORT_REFILL)
	reporter.refilled = now
	if reporter.tokens < 1 or typeof(ids) ~= "table" then
		return
	end
	reporter.tokens -= 1
	for index = 1, MAX_REPORT_IDS do
		local id = ids[index]
		if typeof(id) ~= "number" then
			break
		end
		local thing = barrierById[id]
		if not thing or thing.Dead or (thing._judgedAt and now - thing._judgedAt < CLUSTER_COOLDOWN) then
			continue
		end
		local entry = queuedEntry[thing]
		if entry then
			if not table.find(entry.reporters, player) then
				table.insert(entry.reporters, player)
			end
		elseif #reportQueue < QUEUE_MAX then
			entry = { thing = thing, reporters = { player } }
			queuedEntry[thing] = entry
			table.insert(reportQueue, entry)
		end
	end
end)

local function judgeReport(entry: ReportEntry)
	local thing = entry.thing
	if thing.Dead then
		return
	end
	local now = os.clock()
	local cluster = clusterOf(thing)
	local unchanged = true
	for _, member in cluster do
		if member._judgedAt and now - member._judgedAt < CLUSTER_COOLDOWN then
			return -- (judged moments ago, through another of its barriers)
		end
		if member._cleanFrame ~= member._frame then
			unchanged = false
		end
	end
	local flagged = false
	if not unchanged and #cluster >= BarrierShapes.MIN_PARTS then
		flagged = judgeCluster(thing, cluster, entry.reporters)
	end
	if not flagged then
		for _, reporter in entry.reporters do
			falseReport(reporter)
		end
	end
end

Heartbeat.Connect(function(dt)
	judgeBudget = math.min(judgeBudget + dt * JUDGE_MS_PER_SECOND, JUDGE_MS_PER_SECOND)
	local judged = 0
	while reportQueue[1] and judged < JUDGE_PER_FRAME and judgeBudget > 0 do
		local entry = table.remove(reportQueue, 1) :: ReportEntry
		queuedEntry[entry.thing] = nil
		judged += 1
		local started = os.clock()
		local ok, err = pcall(judgeReport, entry)
		if not ok then
			warn(`[BarrierShapes] judging a report failed: {tostring(err)}`)
		end
		judgeBudget -= (os.clock() - started) * 1000
	end
end, { Name = "SpellWorld.BarrierReports", Priority = 5 })

Players.PlayerRemoving:Connect(function(player)
	strikes[player] = nil
	lockedUntil[player] = nil
	reporters[player] = nil
end)

local function flash(thing: Thing)
	local color = thing._color or Color3.new(1, 1, 1)
	local info = TweenInfo.new(HIT_FLASH * 2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, part in thing._parts or {} do
		if part.Parent then
			part.Color = Color3.new(1, 1, 1)
			TweenService:Create(part, info, { Color = color }):Play()
		end
	end
end

local function hurt(thing: Thing, amount: number)
	if thing.Dead or not thing.Health or amount <= 0 then
		return
	end
	thing.Health = (thing.Health :: number) - amount
	if (thing.Health :: number) <= 0 then
		thing:Destroy(nil, "broken")
	else
		flash(thing)
	end
end

-- The barrier `part` belongs to, if any.
function SpellWorld.BarrierOf(part: Instance?): Thing?
	if part and part:IsA("BasePart") then
		return thingOfPart[part]
	end
	return nil
end

-- A spell's hit on a barrier panel. Returns true if `part` was one.
function SpellWorld.DamagePart(part: Instance?, amount: number): boolean
	local thing = SpellWorld.BarrierOf(part)
	if not thing then
		return false
	end
	hurt(thing, amount)
	return true
end

-- A blast by `player`'s magic: every barrier within reach that stops it
-- takes `amount`, half at the edge.
function SpellWorld.DamageInRadius(centre: Vector3, radius: number, amount: number, player: Player?, caster: any?)
	for _, thing in table.clone(things) do
		if thing.Kind == "Barrier" and not thing.Dead and stopsMagicOf(thing, player, caster) then
			local distance = math.max((thing.Position - centre).Magnitude - thing.Radius, 0)
			if distance <= radius then
				hurt(thing, amount * (1 - 0.5 * math.clamp(distance / math.max(radius, 1e-3), 0, 1)))
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Time fields
--------------------------------------------------------------------------------

local nextZone = 0

export type FieldOptions = {
	player: Player?,
	position: Vector3,
	radius: number,
	scale: number,
	duration: number,
	follow: any?,
	color: Color3,
}

function SpellWorld.CreateTimeField(options: FieldOptions): Thing
	nextZone += 1
	local id = `SpellField{nextZone}`
	local radius = math.max(options.radius, 1)
	local scale = math.max(options.scale, 0)
	ChunkManager.AddTimeScaleZone(id, options.position, radius, scale)
	local sphere = Instance.new("Part")
	sphere.Name = "TimeField"
	sphere.Shape = Enum.PartType.Ball
	sphere.Anchored = true
	sphere.CanCollide = false
	sphere.CanQuery = false
	sphere.CanTouch = false
	sphere.CastShadow = false
	sphere.Material = Enum.Material.ForceField
	-- slow time reads cold, fast time warm, whatever the element
	sphere.Color = if options.scale < 1 then options.color:Lerp(Color3.fromRGB(120, 160, 255), 0.5) else options.color:Lerp(Color3.fromRGB(255, 210, 120), 0.5)
	sphere.Transparency = 1
	sphere.Size = Vector3.one * 0.5
	sphere.CFrame = CFrame.new(options.position)
	sphere.Parent = fieldRoot
	TweenService:Create(sphere, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = Vector3.one * radius * 2, Transparency = 0.2 }):Play()
	local thing: Thing = {
		Kind = "TimeField",
		Position = options.position,
		Velocity = Vector3.zero,
		Age = 0,
		Duration = options.duration,
		Dead = false,
		Static = true,
		OnDestroy = Signal.new(),
		Destroy = destroyThing,
		Radius = radius,
		Owner = options.player,
		_parts = { sphere },
		_color = sphere.Color,
		_zone = id,
		_zoneRadius = radius,
		_zoneScale = scale,
		_lastSent = os.clock(),
	}
	local carrier = carrierFrame(options.follow)
	if carrier then
		thing._follow = options.follow
		thing._offset = CFrame.new(carrier:PointToObjectSpace(options.position))
	end
	track(thing, options.player)
	return thing
end

-- Moves a following thing with its entity (a fallen entity leaves it where
-- it was).
local function followStep(thing: Thing)
	local carrier = carrierFrame(thing._follow)
	if not carrier or not thing._offset then
		thing._follow = nil
		return
	end
	if thing.Kind == "Barrier" then
		local frame = carrier * (thing._offset :: CFrame)
		local previous = thing._frame :: CFrame
		if (frame.Position - previous.Position).Magnitude < 0.02 and frame.LookVector:Dot(previous.LookVector) > 0.9999 then
			return
		end
		thing._frame = frame
		thing.Position = frame.Position
		for part, offset in thing._relative or {} do
			if part.Parent then
				part.CFrame = frame * offset
			end
		end
	else
		local position = (carrier * (thing._offset :: CFrame)).Position
		local now = os.clock()
		if (position - thing.Position).Magnitude < FIELD_FOLLOW_STEP or now - (thing._lastSent or 0) < FIELD_FOLLOW_INTERVAL then
			return
		end
		thing._lastSent = now
		thing.Position = position
		ChunkManager.AddTimeScaleZone(thing._zone, position, thing._zoneRadius or thing.Radius, thing._zoneScale or 1)
		local sphere = thing._parts and thing._parts[1]
		if sphere and sphere.Parent then
			sphere.CFrame = CFrame.new(position)
		end
	end
end

-- Barriers and fields age in world time (a field doesn't slow its own clock),
-- barriers also by the time where they stand.
Heartbeat.Connect(function(dt)
	for index = #things, 1, -1 do
		local thing = things[index]
		if not thing or thing.Dead then
			continue
		end
		if thing._follow then
			followStep(thing)
		end
		local scale = if thing.Kind == "Barrier" then ChunkManager.GetTimeScaleAt(thing.Position) else 1
		thing.Age += dt * scale
		if thing.Age >= thing.Duration then
			thing:Destroy(nil, nil)
		end
	end
end, { Name = "SpellWorld", Priority = 5 })

--------------------------------------------------------------------------------
-- Forces
--------------------------------------------------------------------------------

export type DriveOptions = {
	velocity: Vector3, -- the shove (or the drive's velocity for Along / Up)
	ragdoll: boolean?,
	replace: boolean?, -- set the velocity instead of adding to it
	duration: number?, -- above 0: keep driving for this long (world seconds)
	mode: string?, -- "Along" | "Away" | "Toward" | "Up": how a drive re-aims
	center: Vector3?,
	speed: number?,
	lift: number?,
}

-- The velocity a steady drive wants at `position` (Away / Toward re-aim at
-- the centre every frame; a pull slows as it arrives and holds there).
function SpellWorld.DriveVelocity(options: DriveOptions, position: Vector3): Vector3
	local center = options.center
	local speed = options.speed or options.velocity.Magnitude
	if center and options.mode == "Toward" then
		local offset = center - position
		local distance = offset.Magnitude
		if distance < 0.3 then
			return Vector3.zero
		end
		return offset.Unit * math.min(speed, distance * ARRIVE_SLOWDOWN)
	elseif center and options.mode == "Away" then
		local level = flat(position - center)
		if level.Magnitude < 1e-3 then
			return Vector3.yAxis * speed
		end
		return (level.Unit + Vector3.new(0, options.lift or 0, 0)).Unit * speed
	end
	return options.velocity
end

-- A shove on an assembly the server owns: added to (or replacing) its
-- velocity, and when it's mostly sideways held for a moment so a Humanoid on
-- the ground can't brake it straight away.
local function shove(root: BasePart, deltaV: Vector3, scale: number, humanoid: Humanoid?, replace: boolean?)
	-- a body standing on the ground can't be shoved into it: aimed down at
	-- the floor ahead, it goes level instead, just as fast
	local level = flat(deltaV)
	if humanoid and deltaV.Y < 0 and humanoid.FloorMaterial ~= Enum.Material.Air and level.Magnitude > 1e-3 then
		deltaV = level.Unit * deltaV.Magnitude
	end
	local velocity = (if replace then Vector3.zero else root.AssemblyLinearVelocity) + deltaV * scale
	local sideways = flat(deltaV).Magnitude
	if humanoid and sideways > 20 then
		local attachment = Instance.new("Attachment")
		attachment.Name = "SpellShove"
		attachment.Parent = root
		local hold = Instance.new("LinearVelocity")
		hold.Name = "SpellShove"
		hold.Attachment0 = attachment
		hold.RelativeTo = Enum.ActuatorRelativeTo.World
		hold.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		hold.MaxForce = math.huge
		hold.VectorVelocity = velocity
		hold.Parent = root
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		task.delay(math.clamp(sideways * SHOVE_HOLD_PER_SPEED, SHOVE_HOLD_MIN, SHOVE_HOLD_MAX), function()
			attachment:Destroy()
			hold:Destroy()
		end)
	end
	root.AssemblyLinearVelocity = velocity
end

-- Steady drives on server-owned bodies, re-aimed every frame.
type Steady = { root: BasePart, attachment: Attachment, hold: LinearVelocity, remaining: number, options: DriveOptions }
local steadies: { [BasePart]: Steady } = {}

local function endSteady(steady: Steady)
	steady.attachment:Destroy()
	steady.hold:Destroy()
	if steadies[steady.root] == steady then
		steadies[steady.root] = nil
	end
end

local function startSteady(root: BasePart, humanoid: Humanoid?, options: DriveOptions)
	local existing = steadies[root]
	if existing then
		endSteady(existing)
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "SpellDrive"
	attachment.Parent = root
	local hold = Instance.new("LinearVelocity")
	hold.Name = "SpellDrive"
	hold.Attachment0 = attachment
	hold.RelativeTo = Enum.ActuatorRelativeTo.World
	hold.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	hold.MaxForce = math.huge
	hold.VectorVelocity = SpellWorld.DriveVelocity(options, root.Position)
	hold.Parent = root
	if humanoid then
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	end
	steadies[root] = { root = root, attachment = attachment, hold = hold, remaining = options.duration or 0, options = options }
end

Heartbeat.Connect(function(dt)
	for root, steady in steadies do
		local scale = ChunkManager.GetEffectiveTimeScaleAt(root.Position)
		steady.remaining -= dt * scale
		if steady.remaining <= 0 or not root.Parent then
			endSteady(steady)
		else
			steady.hold.VectorVelocity = SpellWorld.DriveVelocity(steady.options, root.Position) * scale
		end
	end
end, { Name = "SpellWorld.Drive", Priority = 5 })

-- Sets an entity moving (see DriveOptions). `ragdoll` flings it limp
-- (stunned for a moment) instead. A player who isn't ragdolled is moved by
-- their own client, which owns their character.
function SpellWorld.Drive(entity: any, options: DriveOptions)
	if not entity or entity.IsDestroyed then
		return
	end
	local duration = options.duration or 0
	local deltaV = options.velocity
	if duration <= 0 and deltaV.Magnitude < 1e-3 and not options.replace then
		return
	end
	local character = entity.Instance
	local root: BasePart? = entity._root
	if not character or not root or not root.Parent then
		if entity._gravityVelocity ~= nil then
			entity._gravityVelocity = (if options.replace then Vector3.zero else entity._gravityVelocity) + deltaV
		end
		return
	end
	local scale = ChunkManager.GetEffectiveTimeScaleAt(root.Position)
	local humanoid: Humanoid? = entity.Humanoid
	local player = Players:GetPlayerFromCharacter(character)
	if options.ragdoll and humanoid and character:IsA("Model") then
		local power = deltaV.Magnitude
		StatusEffectSys:ApplyEffect(entity, "Stun", math.clamp(power / 120 + duration, RAGDOLL_MIN, RAGDOLL_MAX))
		local base = if options.replace then Vector3.zero else root.AssemblyLinearVelocity / math.max(scale, 1e-3)
		Ragdoll.Launch(character, base + deltaV, Random.new():NextUnitVector() * math.clamp(power / 30, 2, 10))
		return
	end
	if player and not StatusEffectSys:HasEffect(entity, "Stun") then
		VisualOffload.FireClient(player, "SpellImpulse", {
			Velocity = deltaV,
			Set = options.replace,
			Duration = if duration > 0 then duration else nil,
			Mode = options.mode,
			Center = options.center,
			Speed = options.speed,
			Lift = options.lift,
		})
		return
	end
	if root:CanSetNetworkOwnership() then
		root:SetNetworkOwner(nil)
	end
	if duration > 0 then
		startSteady(root, humanoid, options)
	else
		shove(root, deltaV, scale, humanoid, options.replace)
	end
end

-- Changes an entity's velocity by `deltaV` (a one-off shove).
function SpellWorld.Push(entity: any, deltaV: Vector3, ragdoll: boolean?)
	SpellWorld.Drive(entity, { velocity = deltaV, ragdoll = ragdoll })
end

-- Stops an entity dead (Blink without momentum).
function SpellWorld.Halt(entity: any)
	local character = entity and entity.Instance
	local root: BasePart? = entity and entity._root
	if not character or not root then
		return
	end
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		VisualOffload.FireClient(player, "SpellImpulse", { Velocity = Vector3.zero, Set = true })
	else
		root.AssemblyLinearVelocity = Vector3.zero
	end
end

-- Shoves a loose part (anything unanchored that isn't part of a body).
function SpellWorld.PushPart(part: BasePart, deltaV: Vector3)
	if part.Anchored then
		return
	end
	local root = part.AssemblyRootPart or part
	if root:CanSetNetworkOwnership() then
		root:SetNetworkOwner(nil)
		task.delay(3, function()
			if root.Parent and root:CanSetNetworkOwnership() then
				root:SetNetworkOwnershipAuto()
			end
		end)
	end
	root.AssemblyLinearVelocity += deltaV * ChunkManager.GetEffectiveTimeScaleAt(root.Position)
end

local function isBodyPart(part: BasePart): boolean
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if model:FindFirstChildOfClass("Humanoid") then
			return true
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return false
end

-- Loose (unanchored, not part of a body or a spell) assemblies within
-- `radius` of `centre`, one part per assembly.
function SpellWorld.LooseParts(centre: Vector3, radius: number): { BasePart }
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { barrierRoot, fieldRoot }
	local seen: { [BasePart]: boolean } = {}
	local result = {}
	for _, part in workspace:GetPartBoundsInRadius(centre, radius, params) do
		if #result >= MAX_LOOSE_PARTS then
			break
		end
		if part.Anchored or part:IsGrounded() then
			continue
		end
		local root = part.AssemblyRootPart or part
		if seen[root] then
			continue
		end
		seen[root] = true
		if not isBodyPart(part) then
			table.insert(result, root)
		end
	end
	return result
end

--------------------------------------------------------------------------------
-- Blink
--------------------------------------------------------------------------------

-- Moves `entity` toward `target` (at most `maxDistance` studs), stopping
-- short of walls and keeping it above the ground. Returns where it was and
-- where it ended up, or nil when it can't move.
function SpellWorld.Blink(entity: any, target: Vector3, maxDistance: number, keepMomentum: boolean): (Vector3?, Vector3?)
	if not entity or entity.IsDestroyed or maxDistance <= 0 then
		return nil, nil
	end
	local character = entity.Instance
	local root: BasePart? = entity._root
	if not character or not root or not root.Parent or not character:IsA("Model") then
		if not character then
			local from = entity:GetPosition()
			local offset = target - from
			local to = if offset.Magnitude > maxDistance then from + offset.Unit * maxDistance else target
			entity:SetPosition(to)
			return from, to
		end
		return nil, nil
	end
	local humanoid: Humanoid? = entity.Humanoid
	local lift = if humanoid then humanoid.HipHeight + root.Size.Y / 2 else root.Size.Y / 2
	local from = root.Position
	-- a point on the ground means "stand there"
	local goal = target + Vector3.new(0, lift, 0)
	local offset = goal - from
	if offset.Magnitude > maxDistance then
		offset = offset.Unit * maxDistance
	end
	if offset.Magnitude < 0.5 then
		return nil, nil
	end
	-- the path stops at walls but goes through bodies (a blink past an enemy)
	-- and the barriers its owner may walk through
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { character, fieldRoot }
	local player = Players:GetPlayerFromCharacter(character)
	local passKey = if player then `,{player.UserId},` else nil
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	local radius = 1.2
	local hit = workspace:Spherecast(from, radius, offset, params)
	for _ = 1, 8 do
		if not hit then
			break
		end
		local passable: Instance? = nil
		local barrier = thingOfPart[hit.Instance :: BasePart]
		if barrier and barrier._model then
			local pass = barrier._model:GetAttribute("Pass")
			if not (hit.Instance :: BasePart).CanCollide or (passKey and typeof(pass) == "string" and string.find(pass, passKey, 1, true)) then
				passable = barrier._model
			end
		else
			local body = hit.Instance:FindFirstAncestorOfClass("Model")
			while body and not body:FindFirstChildOfClass("Humanoid") do
				body = body:FindFirstAncestorOfClass("Model")
			end
			passable = body
		end
		if not passable then
			break
		end
		table.insert(exclude, passable)
		params.FilterDescendantsInstances = exclude
		hit = workspace:Spherecast(from, radius, offset, params)
	end
	local to = if hit then from + offset.Unit * math.max(hit.Distance - 0.3, 0) else from + offset
	-- don't end up sunk into the floor
	local floor = workspace:Raycast(to + Vector3.new(0, lift, 0), Vector3.new(0, -lift * 2, 0), params)
	if floor and floor.Position.Y + lift > to.Y then
		to = Vector3.new(to.X, floor.Position.Y + lift, to.Z)
	end
	if (to - from).Magnitude < 0.5 then
		return nil, nil
	end
	local pivot = character:GetPivot()
	character:PivotTo(pivot.Rotation + (pivot.Position + (to - from)))
	if not keepMomentum then
		SpellWorld.Halt(entity)
	end
	return from, to
end

--------------------------------------------------------------------------------
-- Visuals
--------------------------------------------------------------------------------

function SpellWorld.Visual(payload: any)
	VisualOffload.Fire("SpellFX", payload)
end

return SpellWorld
