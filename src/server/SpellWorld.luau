--!strict
--[[
	SpellWorld.luau (server)
	What spells do to the world besides damage -- the Barrier, Time Field,
	Force and Blink vessels (server/SpellRuntime decides when and where; this
	module does it):

	 Barriers -- anchored ForceField parts (Wall / Dome / Platform / Pillar)
	   with one health pool. They block bodies and every projectile except
	   their caster's own: they live in workspace.SpellBarriers.<UserId>,
	   which SpellRuntime adds to its projectiles' IgnoreInstances (a raycast
	   filter covers descendants added later). Spell projectiles and blasts
	   damage them (DamagePart / DamageInRadius); at 0 they shatter, otherwise
	   they fade after their duration.
	 Time fields -- a ChunkManager time-scale zone (replicated; projectiles,
	   bodies and every dilated clock respect it) plus a translucent sphere.
	 Both are "things" for SpellRuntime's triggers, shaped like a projectile:
	   Position, Velocity, Age (dilated seconds), Dead, Static = true,
	   OnDestroy (Signal: { Position, Normal, Kind }), Destroy(result?, kind?).

	 Forces -- Push(entity, deltaV, ragdoll) changes a body's velocity: NPCs
	   and ragdolls here (the server owns them), a player's own character on
	   their client (VisualOffload "SpellImpulse", SpellBodyClient). Loose
	   unanchored parts: PushPart. A horizontal shove is held for a moment
	   (LinearVelocity) so a grounded Humanoid can't brake it away instantly.
	 Blink -- Blink(entity, to, maxDistance, keepMomentum): moves a body
	   toward a point, stopping short of anything in the way.

	Visuals: VisualOffload "SpellFX" (client/SpellBodyClient) for blink
	flashes and force rings; barriers and fields are replicated parts.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local Heartbeat = require(Shared:WaitForChild("Heartbeat"))
local Signal = require(Shared:WaitForChild("Signal"))
local SpellRunes = require(Shared:WaitForChild("SpellRunes"))
local StatusEffectSys = require(Shared:WaitForChild("StatusEffectSys"))
local VisualOffload = require(Shared:WaitForChild("VisualOffload"))
local Ragdoll = require(script.Parent:WaitForChild("Ragdoll"))

local SpellWorld = {}

local FADE_IN = 0.25
local FADE_OUT = 0.35
local PILLAR_RISE = 0.5
local PANEL_THICKNESS = 0.6
local HIT_FLASH = 0.12
local SHOVE_HOLD_MIN, SHOVE_HOLD_MAX = 0.12, 0.35 -- seconds a horizontal shove is held (longer when faster)
local SHOVE_HOLD_PER_SPEED = 1 / 350
local RAGDOLL_MIN, RAGDOLL_MAX = 0.8, 2.5
local MAX_LOOSE_PARTS = 40
local MAX_THINGS_PER_PLAYER = 24 -- live barriers + fields per caster; the oldest goes first

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
	_model: Instance?,
	_parts: { BasePart }?,
	_color: Color3?,
	_zone: any?,
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

-- The folder a player's barriers live in. Their spell projectiles ignore it
-- (SpellRuntime puts it in IgnoreInstances), so their own barriers let their
-- magic through.
function SpellWorld.BarrierFolder(player: Player): Folder
	return folderUnder(barrierRoot, tostring(player.UserId))
end

Players.PlayerRemoving:Connect(function(player)
	for _, thing in table.clone(thingsByOwner[player] or {}) do
		thing:Destroy(nil, "removed")
	end
	thingsByOwner[player] = nil
	local folder = barrierRoot:FindFirstChild(tostring(player.UserId))
	if folder then
		task.delay(FADE_OUT + 0.1, function()
			folder:Destroy()
		end)
	end
end)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function horizontal(vector: Vector3, fallback: Vector3): Vector3
	local flat = Vector3.new(vector.X, 0, vector.Z)
	return if flat.Magnitude > 1e-3 then flat.Unit else fallback
end

-- The ground under `position` (within `depth` studs), ignoring bodies and
-- spell barriers.
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
	part.Size = size
	part.CFrame = cframe
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

-- Panels tiling a hemisphere of `radius` over `centre` (open at the bottom,
-- so whoever's inside stays inside).
local function domePanels(model: Model, centre: Vector3, radius: number, color: Color3): { BasePart }
	local parts = {}
	local bands = 4
	local bandAngle = (math.pi / 2) / (bands + 0.5)
	for band = 0, bands - 1 do
		local elevation = (band + 0.5) * bandAngle
		local ringRadius = radius * math.cos(elevation)
		local count = math.max(5, math.floor(2 * math.pi * ringRadius / 3.2 + 0.5))
		local width = 2 * math.pi * ringRadius / count * 1.08
		local height = radius * bandAngle * 1.12
		for index = 0, count - 1 do
			local azimuth = (index + (band % 2) * 0.5) / count * math.pi * 2
			local outward = Vector3.new(math.cos(azimuth) * math.cos(elevation), math.sin(elevation), math.sin(azimuth) * math.cos(elevation))
			local position = centre + outward * radius
			local frame = CFrame.lookAt(position, position + outward)
			table.insert(parts, makePanel(model, frame, Vector3.new(width, height, PANEL_THICKNESS), color))
		end
	end
	-- the cap
	local capSize = radius * math.sin(bandAngle * 0.75) * 2.2
	local top = centre + Vector3.new(0, radius - PANEL_THICKNESS / 2, 0)
	table.insert(parts, makePanel(model, CFrame.new(top), Vector3.new(capSize, PANEL_THICKNESS, capSize), color))
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

local function untrack(thing: Thing)
	local index = table.find(things, thing)
	if index then
		table.remove(things, index)
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

--------------------------------------------------------------------------------
-- Barriers
--------------------------------------------------------------------------------

export type BarrierOptions = {
	player: Player?,
	character: Model?,
	position: Vector3,
	facing: Vector3, -- the way the caster looks at it (a Wall turns to face back)
	shape: string,
	size: number,
	duration: number,
	health: number,
	color: Color3,
}

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

function SpellWorld.CreateBarrier(options: BarrierOptions): Thing
	local size = math.clamp(options.size, 0.25, 6)
	local color = options.color
	local facing = horizontal(options.facing, Vector3.zAxis)
	local model = Instance.new("Model")
	model.Name = "Barrier"
	local parts: { BasePart } = {}
	local centre = options.position
	local radius = 4
	local ground = groundBelow(options.position, 6)
	local base = if ground then ground.Position else options.position
	local shape = options.shape
	local rise: { { part: BasePart, goal: CFrame } } = {}

	if shape == "Dome" then
		radius = SpellRunes.BarrierShapes.Dome * size
		centre = base
		parts = domePanels(model, centre, radius, color)
	elseif shape == "Platform" then
		local dims = SpellRunes.BarrierShapes.Platform * Vector3.new(size, 1, size)
		centre = options.position + Vector3.new(0, dims.Y / 2, 0)
		table.insert(parts, makePanel(model, CFrame.lookAt(centre, centre + facing), dims, color))
		radius = math.max(dims.X, dims.Z) / 2
	elseif shape == "Pillar" then
		local dims = SpellRunes.BarrierShapes.Pillar * Vector3.new(size, size, size)
		centre = base + Vector3.new(0, dims.Y / 2 - 0.3, 0)
		local goal = CFrame.lookAt(centre, centre + facing)
		local part = makePanel(model, goal - Vector3.new(0, dims.Y, 0), dims, color)
		table.insert(parts, part)
		table.insert(rise, { part = part, goal = goal })
		radius = dims.Y / 2
	else -- Wall: stands on the ground, facing back at the caster
		local dims = SpellRunes.BarrierShapes.Wall * Vector3.new(size, size, 1)
		centre = (if ground then base else options.position - Vector3.new(0, dims.Y / 2, 0)) + Vector3.new(0, dims.Y / 2 - 0.3, 0)
		table.insert(parts, makePanel(model, CFrame.lookAt(centre, centre - facing), dims, color))
		radius = math.max(dims.X, dims.Y) / 2
	end

	local folder = if options.player then SpellWorld.BarrierFolder(options.player) else barrierRoot
	model.Parent = folder
	local fadeIn = TweenInfo.new(FADE_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, part in parts do
		TweenService:Create(part, fadeIn, { Transparency = 0 }):Play()
	end
	for _, entry in rise do
		TweenService:Create(entry.part, TweenInfo.new(PILLAR_RISE, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = entry.goal }):Play()
	end

	local health = math.max(options.health, 1)
	local thing: Thing = {
		Kind = "Barrier",
		Position = centre,
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
		_model = model,
		_parts = parts,
		_color = color,
	}
	for _, part in parts do
		thingOfPart[part] = thing
	end
	track(thing, options.player)
	return thing
end

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

-- A blast: every barrier within reach takes `amount`, half at the edge.
function SpellWorld.DamageInRadius(centre: Vector3, radius: number, amount: number)
	for _, thing in table.clone(things) do
		if thing.Kind == "Barrier" and not thing.Dead then
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
	color: Color3,
}

function SpellWorld.CreateTimeField(options: FieldOptions): Thing
	nextZone += 1
	local id = `SpellField{nextZone}`
	local radius = math.max(options.radius, 1)
	ChunkManager.AddTimeScaleZone(id, options.position, radius, math.max(options.scale, 0))
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
	}
	track(thing, options.player)
	return thing
end

-- Barriers and fields age in world time (a field doesn't slow its own clock),
-- barriers also by the time where they stand.
Heartbeat.Connect(function(dt)
	for index = #things, 1, -1 do
		local thing = things[index]
		if not thing or thing.Dead then
			continue
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

-- A shove of `deltaV` (studs/s, world time) on an assembly the server owns:
-- added to its velocity, and when it's mostly sideways held for a moment so
-- a Humanoid on the ground can't brake it straight away.
local function shove(root: BasePart, deltaV: Vector3, scale: number, humanoid: Humanoid?)
	-- a body standing on the ground can't be shoved into it: aimed down at
	-- the floor ahead, it goes level instead, just as fast
	local flat = Vector3.new(deltaV.X, 0, deltaV.Z)
	if humanoid and deltaV.Y < 0 and humanoid.FloorMaterial ~= Enum.Material.Air and flat.Magnitude > 1e-3 then
		deltaV = flat.Unit * deltaV.Magnitude
	end
	local velocity = root.AssemblyLinearVelocity + deltaV * scale
	local sideways = Vector3.new(deltaV.X, 0, deltaV.Z).Magnitude
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

-- Changes an entity's velocity by `deltaV`. `ragdoll` flings it limp
-- (stunned for a moment). A player who isn't ragdolled is shoved by their
-- own client, which owns their character.
function SpellWorld.Push(entity: any, deltaV: Vector3, ragdoll: boolean?)
	if deltaV.Magnitude < 1e-3 or not entity or entity.IsDestroyed then
		return
	end
	local character = entity.Instance
	local root: BasePart? = entity._root
	if not character or not root or not root.Parent then
		if entity._gravityVelocity ~= nil then
			entity._gravityVelocity += deltaV
		end
		return
	end
	local scale = ChunkManager.GetEffectiveTimeScaleAt(root.Position)
	local humanoid: Humanoid? = entity.Humanoid
	local player = Players:GetPlayerFromCharacter(character)
	if ragdoll and humanoid and character:IsA("Model") then
		local power = deltaV.Magnitude
		StatusEffectSys:ApplyEffect(entity, "Stun", math.clamp(power / 120, RAGDOLL_MIN, RAGDOLL_MAX))
		Ragdoll.Launch(character, root.AssemblyLinearVelocity / math.max(scale, 1e-3) + deltaV, Random.new():NextUnitVector() * math.clamp(power / 30, 2, 10))
		return
	end
	if player and not StatusEffectSys:HasEffect(entity, "Stun") then
		VisualOffload.FireClient(player, "SpellImpulse", { Velocity = deltaV })
		return
	end
	if root:CanSetNetworkOwnership() then
		root:SetNetworkOwner(nil)
	end
	shove(root, deltaV, scale, humanoid)
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
	if not entity or entity.IsDestroyed then
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
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { character, fieldRoot }
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	local radius = 1.2
	local hit = workspace:Spherecast(from, radius, offset, params)
	for _ = 1, 6 do
		local body = hit and hit.Instance:FindFirstAncestorOfClass("Model")
		while body and not body:FindFirstChildOfClass("Humanoid") do
			body = body:FindFirstAncestorOfClass("Model")
		end
		if not body then
			break
		end
		table.insert(exclude, body)
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
