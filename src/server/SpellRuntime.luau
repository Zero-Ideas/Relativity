--!strict
--[[
	SpellRuntime.luau
	Executes a compiled spell circle (see shared/SpellCompiler.luau) on the
	server. SpellService handles the cast request, mana and cooldown; this
	module turns energy into magic.

	Flow: every Mana Well pushes its energy along its flow wire. Transforms
	set the element, If routes all of it one way, Divide splits it, and the
	flow runes shape when and where the rest runs: Delay waits, Repeat runs it
	several times, For Each once per entity of a list, Wait Until polls a
	condition, Conjure Circle moves it to a new circle somewhere else, Store
	writes memory, Invoke runs another of the caster's spells from here (with
	this moment's Here / aim / targets and the values handed to it). A Vessel
	gives the energy form: Orb, Bullet and Beam fire projectiles
	(Projectile.luau), Explosion and Smite hit instantly, Barrier and Time
	Field raise things in the world, Force and Blink move bodies (server/
	SpellWorld), Body Effect works on them (server/SpellBody). Sustain emits
	overlapping Beam packets from live aim, sharing the cast's energy over
	its duration. Quantity multiplies a projectile into a Fan, Ring or Stream
	of copies sharing the energy; each Stream copy re-aims from the caster's
	live hand/cursor (see CastRequest.live), and so does every part of a cast
	that runs later (Delay, Repeat...).

	Settings: every rune's number / bool params can be wired. settings()
	resolves them for one context: the wire's value (clamped to the param's
	range) where one is plugged in, else the value set on the rune.
	Non-damaging vessels do exactly what their settings say and charge the
	energy that reaches them for it (SpellRunes costs); fed less, they do
	proportionally less.

	Values (sensors/logic/vectors/lists) are evaluated on demand and memoized
	per evaluation context. A context is one moment in the world: the cast
	itself, a trigger firing (where Here is the vessel's position and Struck
	Entity is what set it off), one Repeat or For Each round, the end of a
	Delay, a conjured circle, an invoked spell. Each context starts with a
	fresh memo (it senses the world anew) and inherits its parent's `vars`:
	the values flow runes and triggers output about their moment, so
	anything downstream can read them. Filter and Pick judge each item of a
	list in a child context whose vars hold that Item.

	Triggers reserve their Share of each copy's energy when it is fired and
	release it at most once: On Impact / On Expire ride the projectile's
	OnDestroy (or the end of a beam, or a barrier breaking), On Timer / On
	Proximity are polled by one Heartbeat loop.

	Every cast has a budget (SpellRunes.Budget): flow steps, vessels fired,
	parts waiting to run later, how long after the cast they may run, and
	how deep Invoke may nest. Explosions don't count as vessels fired, and
	each trigger event (an impact, a timer tick...) gets its own allowance
	of flow steps and waiting parts -- so how many explosions a spell sets off is limited by
	its energy and projectiles, not by how many have gone off already.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local Entity = require(Shared:WaitForChild("Entity"))
local VisualOffload = require(Shared:WaitForChild("VisualOffload"))
local Heartbeat = require(Shared:WaitForChild("Heartbeat"))
local SpellRunes = require(Shared:WaitForChild("SpellRunes"))
local SpellCircleLayout = require(Shared:WaitForChild("SpellCircleLayout"))
local StatusEffectSys = require(Shared:WaitForChild("StatusEffectSys"))
local Ragdoll = require(script.Parent:WaitForChild("Ragdoll"))
local Projectile = require(script.Parent:WaitForChild("Projectile"))
local ProjectileQuota = require(script.Parent:WaitForChild("ProjectileQuota"))
local BeamHandler = require(script.Parent:WaitForChild("Projectile"):WaitForChild("Beams"))
local SpellWorld = require(script.Parent:WaitForChild("SpellWorld"))
local SpellBody = require(script.Parent:WaitForChild("SpellBody"))

local SpellRuntime = {}

local CAST_SPAWN_OFFSET = 3 -- studs in front of the caster's head
local TRIGGER_SPAWN_OFFSET = 0.75 -- studs off the trigger point
local CONJURE_SPAWN_OFFSET = 1 -- studs in front of a conjured circle
local PROXIMITY_CHECK_INTERVAL = 0.05 -- real seconds between proximity scans
local VISUAL_RANGE = 800
local SUSTAIN_INTERVAL = BeamHandler.Interval
local LOOSE_PART_WEIGHT = 0.25 -- a loose part costs this share of a body to shove

-- One cast, shared by every context it spawns: its budget, clock and
-- private memory ("This cast" Store / Recall).
export type CastInfo = {
	player: Player,
	started: number, -- os.clock at the cast
	steps: number,
	vessels: number,
	pending: number,
	dead: boolean,
	memory: { [string]: any },
}

export type Context = {
	player: Player,
	caster: any,
	character: Model,
	origin: Vector3, -- "Here"
	cursorPoint: Vector3,
	cursorEntity: any?,
	struck: any?,
	heading: Vector3, -- direction for vessels with no aim
	focus: Vector3?, -- default aim point when not aiming at the cursor (trigger target, For Each entity, conjured circle's mark)
	subject: any?, -- the entity For Each is on: vessels act on / at it by default
	isCast: boolean,
	spawnOffset: number,
	memo: { [string]: any },
	vars: { [string]: any }, -- outputs of flow runes / triggers upstream (inherits the parent's)
	cast: CastInfo,
	-- The caster's current (head, cursor), for Stream copies, parts that run
	-- later and Locate's aim.
	live: (() -> (Vector3?, Vector3?))?,
	-- A conjured circle: live re-aiming keeps firing from it, not your hand.
	fixedOrigin: boolean?,
	-- How long the vessel whose trigger made this context had flown.
	flight: number?,
	-- Fraction of its nominal energy that reached this point after Sustain
	-- slicing and beam subdivision (1 when nothing was split). Explosions
	-- shrink with it -- see explode().
	energyScale: number?,
	-- Normal of the surface whose hit fired this context's trigger (On
	-- Impact into geometry or an entity); explosions orient their visual to it.
	surfaceNormal: Vector3?,
	-- Cast-time only: hold-to-charge copy multiplier (>= 1) for the vessels
	-- the cast fires directly; see SpellRunes.Charge.
	copyMultiplier: number?,
	-- The conjured circle this part runs from (Wait Until keeps it showing).
	conjureId: number?,
	-- this trigger event's own flow-step count (see spend), shared by
	-- everything the event runs
	eventSteps: { n: number }?,
	-- this trigger event's own count of delayed parts waiting (see later)
	eventPending: { pending: number }?,
	-- Invoke: how deep this spell runs inside others, and what it was handed.
	depth: number?,
	args: { point: Vector3?, entity: any?, number: number? }?,
}

local rng = Random.new()

--------------------------------------------------------------------------------
-- Values
--------------------------------------------------------------------------------

local function alive(entity: any): boolean
	return typeof(entity) == "table" and not entity.IsDestroyed and (entity.Health == nil or entity.Health > 0)
end

local function isEntity(value: any): boolean
	return typeof(value) == "table" and value.GetPosition ~= nil
end

local function asPoint(value: any): Vector3?
	if typeof(value) == "Vector3" then
		return value
	end
	if alive(value) then
		return value:GetPosition()
	end
	return nil
end

-- A list input: a list, or a single entity as a list of one.
local function asList(value: any): { any }
	if isEntity(value) then
		return { value }
	end
	return if typeof(value) == "table" then value else {}
end

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function matchesFilter(caster: any, entity: any, filter: string): boolean
	if filter == "Any" then
		return true
	elseif filter == "Hostile" then
		return Entity.CanDamage(caster, entity)
	elseif filter == "Ally" then
		return not Entity.CanDamage(caster, entity)
	end
	return entity:HasTag(filter)
end

local function nearestEntity(from: Vector3, radius: number, filter: string, caster: any): any?
	local best, bestDistance = nil, math.huge
	for _, entity in ChunkManager.GetEntitiesInRadius(from, radius) do
		if entity ~= caster and alive(entity) and matchesFilter(caster, entity, filter) then
			local distance = (entity:GetPosition() - from).Magnitude
			if distance < bestDistance then
				best, bestDistance = entity, distance
			end
		end
	end
	return best
end

-- Caster memory (Store / Recall "Yours"), per player for the session.
local memory: { [Player]: { [string]: any } } = {}

local function memoryOf(ctx: Context, scope: string): { [string]: any }
	if scope == "This cast" then
		return ctx.cast.memory
	end
	local slots = memory[ctx.player]
	if not slots then
		slots = {}
		memory[ctx.player] = slots
	end
	return slots
end

local evaluate: (compiled: any, ctx: Context, id: string, port: string) -> any
local queueExplosionVisual: (center: Vector3, radius: number, element: string, power: number, normal: Vector3?) -> ()

-- Value arriving at `port` of rune `id`: from its wire, else the param the
-- port falls back to (SpellRunes PortDef.Param), else nil.
local function input(compiled: any, ctx: Context, id: string, port: string): any
	local links = compiled.inputs[id][port]
	local link = links and links[1]
	if not link then
		local rune = compiled.runes[id]
		local param = SpellRunes.ParamOf[rune.rune][port]
		return if param then rune.params[param] else nil
	end
	return evaluate(compiled, ctx, link.from, link.port)
end

local function wired(compiled: any, id: string, port: string): boolean
	local links = compiled.inputs[id][port]
	return links ~= nil and links[1] ~= nil
end

local function number(value: any): number
	return if typeof(value) == "number" and value == value then value else 0
end

-- Rune `id`'s settings in this context: each number / bool param from its
-- wire when one is plugged in (clamped to the param's range), else the value
-- set on the rune. Cached per context.
local function settings(compiled: any, ctx: Context, id: string): { [string]: any }
	local key = id .. "@"
	local cached = ctx.memo[key]
	if cached then
		return cached
	end
	local rune = compiled.runes[id]
	local def = SpellRunes.Runes[rune.rune]
	local portOf = SpellRunes.PortOf[rune.rune]
	local links = compiled.inputs[id]
	local resolved = rune.params
	local copied = false
	for _, param in def.Params do
		local port = portOf[param.Name]
		local link = port and links[port] and links[port][1]
		if link then
			if not copied then
				resolved = table.clone(rune.params)
				copied = true
			end
			resolved[param.Name] = SpellRunes.ClampParam(param, evaluate(compiled, ctx, link.from, link.port))
		end
	end
	ctx.memo[key] = resolved
	return resolved
end

-- A per-rune table cached for this context (one Scan / Raycast / Locate
-- feeds all of its outputs from the same result).
local function memoRune(ctx: Context, id: string, build: () -> any): any
	local key = id .. "#"
	local cached = ctx.memo[key]
	if cached == nil then
		cached = build()
		ctx.memo[key] = cached
	end
	return cached
end

-- Facing axes: X right, Y up, Z forward along the context's (level) heading.
local function facingBasis(ctx: Context): CFrame
	local forward = flat(ctx.heading)
	if forward.Magnitude < 1e-3 then
		forward = flat(if ctx.character and ctx.character.Parent then ctx.character:GetPivot().LookVector else Vector3.zAxis)
		if forward.Magnitude < 1e-3 then
			forward = Vector3.zAxis
		end
	end
	return CFrame.lookAt(Vector3.zero, forward.Unit, Vector3.yAxis)
end

local function facingToWorld(ctx: Context, local_: Vector3): Vector3
	local basis = facingBasis(ctx)
	-- (CFrame.lookAt looks down -Z: forward is LookVector, right RightVector)
	return basis.RightVector * local_.X + Vector3.yAxis * local_.Y + basis.LookVector * local_.Z
end

-- The way the caster is aiming now (head to cursor).
local function casterAim(ctx: Context): Vector3
	local head, cursor
	if ctx.live then
		head, cursor = ctx.live()
	end
	head = head or (if alive(ctx.caster) then ctx.caster:GetPosition() else ctx.origin)
	local offset = (cursor or ctx.cursorPoint) - (head :: Vector3)
	return if offset.Magnitude > 1e-3 then offset.Unit else ctx.heading
end

-- Where this part of the circle aims when nothing is wired: the For Each /
-- trigger target, else the cursor at cast time.
local function defaultTarget(ctx: Context): Vector3?
	if ctx.focus then
		return ctx.focus
	end
	return if ctx.isCast then ctx.cursorPoint else nil
end

local function subjectPoint(ctx: Context): Vector3?
	return if alive(ctx.subject) then ctx.subject:GetPosition() else nil
end

local MATH = {
	["+"] = function(a, b) return a + b end,
	["-"] = function(a, b) return a - b end,
	["×"] = function(a, b) return a * b end,
	["÷"] = function(a, b) return if b == 0 then 0 else a / b end,
	min = math.min,
	max = math.max,
	["^"] = function(a, b)
		local result = a ^ b
		return if result == result and math.abs(result) < 1e9 then result else 0
	end,
	mod = function(a, b) return if b == 0 then 0 else a % b end,
}
local FUNC = {
	abs = math.abs,
	["−x"] = function(a) return -a end,
	floor = math.floor,
	ceil = math.ceil,
	round = function(a) return math.floor(a + 0.5) end,
	["√"] = function(a) return math.sqrt(math.max(a, 0)) end,
	sin = function(a) return math.sin(math.rad(a)) end,
	cos = function(a) return math.cos(math.rad(a)) end,
	sign = math.sign,
}
local COMPARE = {
	["<"] = function(a, b) return a < b end,
	["≤"] = function(a, b) return a <= b end,
	["="] = function(a, b) return math.abs(a - b) < 1e-6 end,
	["≠"] = function(a, b) return math.abs(a - b) >= 1e-6 end,
	["≥"] = function(a, b) return a >= b end,
	[">"] = function(a, b) return a > b end,
}
local BODY_CHECKS = { Shielded = "Shield", Hasted = "Haste", Slowed = "Slow", Rooted = "Root", Levitating = "Levitate" }

local function bodyRay(character: Instance?): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if character then { character } else {}
	params.IgnoreWater = true
	return params
end

local function grounded(entity: any): boolean
	local root: BasePart? = entity._root
	if not root or not root.Parent then
		return true
	end
	local humanoid: Humanoid? = entity.Humanoid
	local reach = (if humanoid then humanoid.HipHeight else 0) + root.Size.Y / 2 + 1
	return workspace:Raycast(root.Position, Vector3.new(0, -reach, 0), bodyRay(entity.Instance)) ~= nil
end

local function checkEntity(ctx: Context, entity: any, check: string): boolean
	if check == "You" then
		return entity == ctx.caster
	elseif check == "Hostile" then
		return entity ~= ctx.caster and Entity.CanDamage(ctx.caster, entity)
	elseif check == "Ally" then
		return entity ~= ctx.caster and not Entity.CanDamage(ctx.caster, entity)
	elseif check == "Grounded" then
		return grounded(entity)
	elseif check == "Airborne" then
		return not grounded(entity)
	elseif check == "Moving" then
		local root: BasePart? = entity._root
		return root ~= nil and root.AssemblyLinearVelocity.Magnitude > 2
	elseif check == "Burning" then
		return StatusEffectSys:HasEffect(entity, "Burn")
	elseif check == "Stunned" then
		return StatusEffectSys:HasEffect(entity, "Stun")
	end
	local effect = BODY_CHECKS[check]
	return effect ~= nil and SpellBody.Has(entity, effect)
end

local SORTS: { [string]: (any, any, Vector3) -> boolean } = {
	Nearest = function(a, b, from) return (a:GetPosition() - from).Magnitude < (b:GetPosition() - from).Magnitude end,
	Farthest = function(a, b, from) return (a:GetPosition() - from).Magnitude > (b:GetPosition() - from).Magnitude end,
	Weakest = function(a, b) return (a.Health or 0) < (b.Health or 0) end,
	Strongest = function(a, b) return (a.Health or 0) > (b.Health or 0) end,
}

local function scanArea(compiled: any, ctx: Context, id: string): { any }
	return memoRune(ctx, id, function()
		local params = settings(compiled, ctx, id)
		local from = asPoint(input(compiled, ctx, id, "from")) or ctx.origin
		local coneDir: Vector3? = nil
		local coneCos = -1
		if params.Cone < 360 then
			local toward = asPoint(input(compiled, ctx, id, "dir")) or ctx.heading
			coneDir = if toward.Magnitude > 1e-3 then toward.Unit else ctx.heading
			coneCos = math.cos(math.rad(params.Cone / 2))
		end
		local found = {}
		for _, entity in ChunkManager.GetEntitiesInRadius(from, params.Radius) do
			if not alive(entity) then
				continue
			end
			if coneDir then
				local offset = entity:GetPosition() - from
				if offset.Magnitude > 1e-3 and offset.Unit:Dot(coneDir) < coneCos then
					continue
				end
			end
			if entity == ctx.caster then
				if params.Self then
					table.insert(found, entity)
				end
			elseif matchesFilter(ctx.caster, entity, params.Filter) then
				table.insert(found, entity)
			end
		end
		local sort = SORTS[params.Sort]
		if sort then
			table.sort(found, function(a, b) return sort(a, b, from) end)
		else -- Random
			for index = #found, 2, -1 do
				local other = rng:NextInteger(1, index)
				found[index], found[other] = found[other], found[index]
			end
		end
		for index = #found, params.Max + 1, -1 do
			found[index] = nil
		end
		return found
	end)
end

local function castRay(compiled: any, ctx: Context, id: string): any
	return memoRune(ctx, id, function()
		local params = settings(compiled, ctx, id)
		local from = asPoint(input(compiled, ctx, id, "from")) or ctx.origin
		local direction = asPoint(input(compiled, ctx, id, "dir"))
		direction = if direction and direction.Magnitude > 1e-3 then direction.Unit else -Vector3.yAxis
		local reach = (direction :: Vector3) * params.Distance
		local result = workspace:Raycast(from, reach, bodyRay(ctx.character))
		if not result then
			return { hit = false, point = from + reach, distance = params.Distance }
		end
		local entity = Entity.Get(result.Instance)
		return {
			hit = true,
			point = result.Position,
			normal = result.Normal,
			entity = if alive(entity) then entity else nil,
			distance = result.Distance,
		}
	end)
end

-- Locate: a point (and basis) relative to From along the chosen axes.
local function locate(compiled: any, ctx: Context, id: string): any
	return memoRune(ctx, id, function()
		local params = settings(compiled, ctx, id)
		local reference = if wired(compiled, id, "from") then input(compiled, ctx, id, "from") else ctx.caster
		local base = asPoint(reference) or ctx.origin
		local up = Vector3.yAxis
		local forward: Vector3
		local toward = asPoint(input(compiled, ctx, id, "dir"))
		local basis = params.Basis
		if toward and toward.Magnitude > 1e-3 then
			forward = toward
		elseif basis == "Body" then
			local entity = if isEntity(reference) and alive(reference) then reference else ctx.caster
			local root: BasePart? = if alive(entity) then entity._root else nil
			forward = if root then root.CFrame.LookVector else ctx.heading
		elseif basis == "Heading" then
			forward = ctx.heading
		elseif basis == "Surface" then
			up = ctx.surfaceNormal or Vector3.yAxis
			forward = ctx.heading - up * ctx.heading:Dot(up)
		else
			forward = casterAim(ctx)
		end
		if basis == "Level aim" and not toward then
			forward = flat(forward)
		end
		if forward.Magnitude < 1e-3 then
			forward = flat(ctx.heading)
			if forward.Magnitude < 1e-3 then
				forward = Vector3.zAxis
			end
		end
		forward = forward.Unit
		local right = forward:Cross(up)
		if right.Magnitude < 1e-3 then
			right = forward:Cross(Vector3.zAxis)
		end
		right = right.Unit
		local point = base + forward * params.Forward + up * params.Up + right * params.Right
		if params.Ground then
			point = SpellWorld.Ground(point, 200) or point
		end
		return { point = point, forward = forward, up = up, right = right }
	end)
end

local function vecMath(op: string, a: Vector3, b: Vector3, n: number, hasB: boolean): Vector3
	if op == "A+B" then
		return a + b
	elseif op == "A−B" then
		return a - b
	elseif op == "A×N" then
		return a * n
	elseif op == "Lerp" then
		return a:Lerp(b, n)
	elseif op == "Midpoint" then
		return (a + b) / 2
	elseif op == "Unit" then
		return if a.Magnitude > 1e-6 then a.Unit else Vector3.zero
	elseif op == "Cross" then
		return a:Cross(b)
	elseif op == "Rotate" then
		local axis = if hasB and b.Magnitude > 1e-6 then b.Unit else Vector3.yAxis
		return CFrame.fromAxisAngle(axis, math.rad(n)) * a
	elseif op == "Reflect" then
		if b.Magnitude < 1e-6 then
			return a
		end
		local normal = b.Unit
		return a - 2 * a:Dot(normal) * normal
	elseif op == "Project" then
		if b.Magnitude < 1e-6 then
			return Vector3.zero
		end
		local axis = b.Unit
		return axis * a:Dot(axis)
	end
	return a
end

-- Filter / Pick: judges each living entity of the list in a child context
-- whose vars hold it as Item; `judge` reads the rune's condition / score.
local function eachItem(compiled: any, ctx: Context, id: string, judge: (probe: Context, entity: any) -> ())
	local seen = {}
	for _, entity in asList(input(compiled, ctx, id, "list")) do
		if alive(entity) and not seen[entity] then
			seen[entity] = true
			local probe = table.clone(ctx)
			probe.memo = {}
			probe.vars = setmetatable({ [id] = { item = entity } }, { __index = ctx.vars }) :: any
			judge(probe, entity)
		end
	end
end

local function compute(compiled: any, ctx: Context, id: string, port: string): any
	local rune = compiled.runes[id]
	local kind = rune.rune
	local def = SpellRunes.Runes[kind]
	-- flow runes, triggers and per-item outputs: what they recorded
	local portDef = SpellRunes.FindPort(def.Outputs, port)
	if def.Pass or def.Category == "Trigger" or (portDef and portDef.Scoped) then
		local bag = ctx.vars[id]
		return if bag then bag[port] else nil
	end
	local params = settings(compiled, ctx, id)
	if kind == "Caster" then
		return ctx.caster
	elseif kind == "Cursor" then
		if port == "point" then return ctx.cursorPoint end
		return if alive(ctx.cursorEntity) then ctx.cursorEntity else nil
	elseif kind == "Target" then
		-- Aim: its input, else the current target, else the mouse.
		local point = asPoint(input(compiled, ctx, id, "point"))
		if point then return point end
		return defaultTarget(ctx) or ctx.cursorPoint
	elseif kind == "Here" then
		if port == "heading" then return ctx.heading end
		if port == "normal" then return ctx.surfaceNormal end
		return ctx.origin
	elseif kind == "Struck" then
		return if alive(ctx.struck) then ctx.struck else nil
	elseif kind == "Given" then
		local args = ctx.args
		if port == "invoked" then return (ctx.depth or 0) > 0 end
		if not args then return nil end
		if port == "entity" then return if alive(args.entity) then args.entity else nil end
		return (args :: any)[port]
	elseif kind == "Nearest" then
		local from = asPoint(input(compiled, ctx, id, "from")) or ctx.origin
		return nearestEntity(from, params.Radius, params.Filter, ctx.caster)
	elseif kind == "Scan" then
		local found = scanArea(compiled, ctx, id)
		if port == "list" then return found end
		if port == "first" then return found[1] end
		return #found
	elseif kind == "Distance" then
		local a = asPoint(input(compiled, ctx, id, "a"))
		local b = asPoint(input(compiled, ctx, id, "b"))
		return if a and b then (a - b).Magnitude else math.huge
	elseif kind == "Health" then
		local entity = input(compiled, ctx, id, "entity")
		if not alive(entity) then return 0 end
		if params.Mode == "Percent" then
			return if entity.MaxHealth and entity.MaxHealth > 0 then entity.Health / entity.MaxHealth * 100 else 0
		end
		return entity.Health or 0
	elseif kind == "Exists" then
		return alive(input(compiled, ctx, id, "entity"))
	elseif kind == "IsPlayer" then
		local entity = input(compiled, ctx, id, "entity")
		return alive(entity) and entity.Instance ~= nil and Players:GetPlayerFromCharacter(entity.Instance) ~= nil
	elseif kind == "Is" then
		local entity = input(compiled, ctx, id, "entity")
		return alive(entity) and checkEntity(ctx, entity, params.Check)
	elseif kind == "Motion" then
		local entity = input(compiled, ctx, id, "entity")
		local root: BasePart? = if alive(entity) then entity._root else nil
		local velocity = if root then root.AssemblyLinearVelocity else Vector3.zero
		if port == "velocity" then return velocity end
		if port == "speed" then return velocity.Magnitude end
		return if root then root.CFrame.LookVector else nil
	elseif kind == "Raycast" then
		local result = castRay(compiled, ctx, id)
		return result[port]
	elseif kind == "Clock" then
		if port == "elapsed" then return os.clock() - ctx.cast.started end
		return ctx.flight or 0
	elseif kind == "Recall" then
		local slot = memoryOf(ctx, params.Scope)[params.Slot]
		if port == "set" then return slot ~= nil end
		if not slot then return nil end
		if port == "entity" then return if alive(slot.entity) then slot.entity else nil end
		if port == "list" then
			local living = {}
			for _, entity in slot.list or {} do
				if alive(entity) then table.insert(living, entity) end
			end
			return living
		end
		return slot[port]
	elseif kind == "Number" then
		return params.Value
	elseif kind == "Math" then
		return MATH[params.Op](number(input(compiled, ctx, id, "a")), number(input(compiled, ctx, id, "b")))
	elseif kind == "Func" then
		local value = number(input(compiled, ctx, id, "a"))
		if params.Op == "clamp" then
			return math.clamp(value, math.min(params.Min, params.Max), math.max(params.Min, params.Max))
		end
		local result = FUNC[params.Op](value)
		return if result == result then result else 0
	elseif kind == "Compare" then
		return COMPARE[params.Op](number(input(compiled, ctx, id, "a")), number(input(compiled, ctx, id, "b")))
	elseif kind == "And" then
		return input(compiled, ctx, id, "a") == true and input(compiled, ctx, id, "b") == true
	elseif kind == "Or" then
		return input(compiled, ctx, id, "a") == true or input(compiled, ctx, id, "b") == true
	elseif kind == "Not" then
		return input(compiled, ctx, id, "a") ~= true
	elseif kind == "Select" then
		local chosen = if input(compiled, ctx, id, "cond") == true then "a" else "b"
		return asPoint(input(compiled, ctx, id, chosen))
	elseif kind == "SelectNumber" then
		local chosen = if input(compiled, ctx, id, "cond") == true then "a" else "b"
		return number(input(compiled, ctx, id, chosen))
	elseif kind == "SelectEntity" then
		local chosen = if input(compiled, ctx, id, "cond") == true then "a" else "b"
		local entity = input(compiled, ctx, id, chosen)
		return if alive(entity) then entity else nil
	elseif kind == "Random" then
		if port == "value" then
			return params.Min + rng:NextNumber() * (params.Max - params.Min)
		elseif port == "roll" then
			return rng:NextNumber() * 100 < params.Chance
		end
		return rng:NextUnitVector()
	elseif kind == "Filter" then
		local kept = memoRune(ctx, id, function()
			local list = {}
			eachItem(compiled, ctx, id, function(probe, entity)
				if input(compiled, probe, id, "cond") == true then
					table.insert(list, entity)
				end
			end)
			return list
		end)
		return if port == "list" then kept else #kept
	elseif kind == "Pick" then
		local best = memoRune(ctx, id, function()
			local result: { entity: any, value: number? } = { entity = nil, value = nil }
			local highest = params.Mode == "Highest"
			eachItem(compiled, ctx, id, function(probe, entity)
				local score = input(compiled, probe, id, "key")
				if typeof(score) ~= "number" or score ~= score then
					return
				end
				if result.value == nil or (if highest then score > result.value else score < result.value) then
					result.entity, result.value = entity, score
				end
			end)
			return result
		end)
		return if port == "entity" then best.entity else best.value
	elseif kind == "ListItem" then
		local list = {}
		for _, entity in asList(input(compiled, ctx, id, "list")) do
			if alive(entity) then table.insert(list, entity) end
		end
		if port == "count" then return #list end
		if #list == 0 then return nil end
		if port == "random" then return list[rng:NextInteger(1, #list)] end
		local index = params.Index
		if index < 0 then index = #list + 1 + index end
		return list[index]
	elseif kind == "Combine" then
		local combined = memoRune(ctx, id, function()
			local a, b = asList(input(compiled, ctx, id, "a")), asList(input(compiled, ctx, id, "b"))
			local inB = {}
			for _, entity in b do inB[entity] = true end
			local result, seen = {}, {}
			local function add(entity: any)
				if alive(entity) and not seen[entity] then
					seen[entity] = true
					table.insert(result, entity)
				end
			end
			for _, entity in a do
				if params.Op == "Both" or (params.Op == "Common") == (inB[entity] == true) then
					add(entity)
				end
			end
			if params.Op == "Both" then
				for _, entity in b do add(entity) end
			end
			return result
		end)
		return if port == "list" then combined else #combined
	elseif kind == "Locate" then
		return locate(compiled, ctx, id)[port]
	elseif kind == "Vector" then
		local vector = Vector3.new(number(input(compiled, ctx, id, "x")), number(input(compiled, ctx, id, "y")), number(input(compiled, ctx, id, "z")))
		return if params.Space == "Facing" then facingToWorld(ctx, vector) else vector
	elseif kind == "Offset" then
		local point = asPoint(input(compiled, ctx, id, "point")) or ctx.origin
		local by = asPoint(input(compiled, ctx, id, "by"))
		if not by then
			local vector = Vector3.new(params.X, params.Y, params.Z)
			by = if params.Space == "Facing" then facingToWorld(ctx, vector) else vector
		end
		return point + (by :: Vector3)
	elseif kind == "VecMath" then
		local a = asPoint(input(compiled, ctx, id, "a")) or Vector3.zero
		local bValue = asPoint(input(compiled, ctx, id, "b"))
		local b = bValue or Vector3.zero
		if port == "dot" then return a:Dot(b) end
		local result = vecMath(params.Op, a, b, number(input(compiled, ctx, id, "n")), bValue ~= nil)
		if port == "length" then return result.Magnitude end
		return result
	elseif kind == "Direction" then
		local from = asPoint(input(compiled, ctx, id, "from")) or ctx.origin
		local to = asPoint(input(compiled, ctx, id, "to")) or defaultTarget(ctx) or (from + ctx.heading)
		local offset = to - from
		if port == "dist" then return offset.Magnitude end
		return if offset.Magnitude > 1e-3 then offset.Unit else ctx.heading
	elseif kind == "Split" then
		local point = asPoint(input(compiled, ctx, id, "point"))
		if not point then return 0 end
		if port == "x" then return point.X end
		if port == "y" then return point.Y end
		if port == "z" then return point.Z end
		return point.Magnitude
	end
	return nil
end

local NONE = table.freeze({}) -- memoized "no value" (nil can't be stored)

evaluate = function(compiled: any, ctx: Context, id: string, port: string): any
	local key = `{id}.{port}`
	local cached = ctx.memo[key]
	if cached == nil then
		cached = compute(compiled, ctx, id, port)
		ctx.memo[key] = if cached == nil then NONE else cached
	end
	return if cached == NONE then nil else cached
end

--------------------------------------------------------------------------------
-- Contexts and scheduling
--------------------------------------------------------------------------------

-- A child moment of `parent`: same cast, fresh senses, inherited outputs.
local function derive(parent: Context): Context
	local ctx = table.clone(parent)
	ctx.memo = {}
	ctx.vars = setmetatable({}, { __index = parent.vars }) :: any
	return ctx
end

-- A fresh cast-time context from the caster's live hand and cursor, so each
-- Stream copy (and each part of the cast that runs later) aims where you're
-- pointing now. Values are re-evaluated too (fresh memo): an Aim fed by
-- Nearest Entity re-targets per copy. A conjured circle keeps its place.
local function liveContext(ctx: Context): Context
	if not ctx.isCast or not ctx.live then
		return ctx
	end
	local origin, cursor = ctx.live()
	local fresh = table.clone(ctx)
	if not ctx.fixedOrigin then
		fresh.origin = origin or ctx.origin
	end
	fresh.cursorPoint = cursor or ctx.cursorPoint
	local offset = fresh.cursorPoint - fresh.origin
	fresh.heading = if offset.Magnitude > 1e-3 then offset.Unit else ctx.heading
	fresh.memo = {}
	return fresh
end

-- Spends one flow step: of the trigger event's own allowance inside one
-- (blowing it stops only that event), else of the cast's budget. False once
-- it's blown.
local function spend(ctx: Context): boolean
	local cast = ctx.cast
	if cast.dead then
		return false
	end
	local event = ctx.eventSteps
	if event then
		event.n += 1
		return event.n <= SpellRunes.Budget.Steps
	end
	cast.steps += 1
	if cast.steps > SpellRunes.Budget.Steps then
		cast.dead = true
		warn(`[SpellRuntime] {cast.player.Name}'s spell ran out of steps and fizzled`)
		return false
	end
	return true
end

type Pending = { remaining: number, position: Vector3, cast: CastInfo, budget: { pending: number }, run: () -> () }
local pending: { Pending } = {}

-- Runs `run` after `seconds` of time where `position` is (dilated: a slow
-- zone stretches the wait), within the budget of waiting parts -- the
-- trigger event's own inside one (like flow steps), else the cast's.
local function later(ctx: Context, seconds: number, position: Vector3, run: () -> ())
	local cast = ctx.cast
	if cast.dead or cast.player.Parent ~= Players then
		return
	end
	if seconds <= 0 then
		run()
		return
	end
	local budget: { pending: number } = ctx.eventPending or cast
	if budget.pending >= SpellRunes.Budget.Pending then
		return
	end
	budget.pending += 1
	table.insert(pending, { remaining = seconds, position = position, cast = cast, budget = budget, run = run })
end

Heartbeat.Connect(function(dt)
	if #pending == 0 then
		return
	end
	local due = {}
	for index = #pending, 1, -1 do
		local entry = pending[index]
		entry.remaining -= dt * ChunkManager.GetTimeScaleAt(entry.position)
		local cast = entry.cast
		local expired = cast.dead or cast.player.Parent ~= Players or os.clock() - cast.started > SpellRunes.Budget.Lifetime
		if expired or entry.remaining <= 0 then
			table.remove(pending, index)
			entry.budget.pending -= 1
			if not expired then
				table.insert(due, entry)
			end
		end
	end
	for index = #due, 1, -1 do
		local ok, err = pcall(due[index].run)
		if not ok then
			warn(`[SpellRuntime] a delayed part of a spell failed: {tostring(err)}`)
		end
	end
end, { Name = "SpellRuntime.Later", Priority = 6 })

--------------------------------------------------------------------------------
-- Damage
--------------------------------------------------------------------------------

local function deal(caster: any, target: any, amount: number, info: any)
	if amount <= 0 then return end
	if alive(caster) and caster.DealDamage then
		caster:DealDamage(target, amount, info)
	else
		target:TakeDamage(amount, info)
	end
end

-- Damages `target` (before headshot scaling) and applies the element's
-- secondary effect sized from `energy`, the damage energy this hit carried.
local function strike(ctx: Context, target: any, amount: number, hurtbox: string?, position: Vector3, element: string, energy: number)
	if not alive(target) or target == ctx.caster or not Entity.CanDamage(ctx.caster, target) then
		return -- (an ally: no damage, burn or stun either)
	end
	if hurtbox == "Head" then
		amount *= target.HeadshotMultiplier
	end
	deal(ctx.caster, target, amount, {
		Type = "Spell",
		Element = element,
		Source = ctx.caster,
		Position = position,
		Hurtbox = hurtbox,
	})
	local elementDef = SpellRunes.Elements[element]
	if elementDef.BurnRatio and alive(target) then
		local effect = StatusEffectSys:ApplyEffect(target, "Burn", elementDef.BurnDuration, energy * elementDef.BurnRatio)
		if effect then
			effect.Source = ctx.caster
		end
	elseif elementDef.StunPerEnergy and alive(target) then
		StatusEffectSys:ApplyEffect(target, "Stun", math.min(energy * elementDef.StunPerEnergy, elementDef.StunMax))
	end
end

--------------------------------------------------------------------------------
-- Flow
--------------------------------------------------------------------------------

type Watch = {
	projectile: any, -- a projectile, or a SpellWorld thing (barrier / time field)
	compiled: any,
	ctx: Context,
	trigger: string,
	params: { [string]: any }, -- the trigger's settings, read when the vessel fired
	energy: number,
	element: string?,
	nextCheck: number,
	nominal: number, -- energy this trigger would carry if nothing were split
	scale: number, -- the launching shot's energyScale
	pulses: number, -- On Timer pulses already fired
}
local watches: { Watch } = {}

function SpellRuntime.IsSustaining(player: Player): boolean
	return BeamHandler.IsActive(player)
end

local runFlow: (compiled: any, ctx: Context, fromId: string, port: string, energy: number, element: string?) -> ()

local function headingOf(projectile: any, fallback: Vector3): Vector3
	local velocity = projectile.Velocity
	return if velocity.Magnitude > 1e-3 then velocity.Unit else fallback
end

-- Share of a watch's nominal energy it actually fires with: the shot's own
-- Sustain slice x whatever beam subdivision took from it since.
local function triggerScale(watch: Watch, energy: number): number
	local split = if watch.nominal > 0 then math.clamp(energy / watch.nominal, 0, 1) else 1
	return watch.scale * split
end

local function newWatch(projectile: any, compiled: any, ctx: Context, triggerId: string, energy: number, element: string?, scale: number): Watch
	return {
		projectile = projectile,
		compiled = compiled,
		ctx = ctx,
		trigger = triggerId,
		params = settings(compiled, ctx, triggerId),
		energy = energy,
		element = element,
		nextCheck = 0,
		nominal = energy,
		scale = scale,
		pulses = 0,
	}
end

-- Runs the sub-circle hanging off a trigger from eventPoint. heading is the
-- vessel's travel direction at that moment; On Impact reflects it off the
-- surface so what it fires ricochets unless aimed. The trigger's outputs
-- (Point, Surface, Struck, Pulse) are what it saw.
local function fireTrigger(compiled: any, parent: Context, triggerId: string, energy: number, element: string?, eventPoint: Vector3, heading: Vector3, normal: Vector3?, struck: any?, energyScale: number?, flight: number?, pulse: number?)
	if normal and compiled.runes[triggerId].rune == "OnImpact" then
		heading = heading - 2 * heading:Dot(normal) * normal
	end
	local ctx = derive(parent)
	ctx.origin = eventPoint + (normal or Vector3.zero) * 0.5
	ctx.struck = struck
	ctx.heading = heading
	ctx.focus = if alive(struck) then struck:GetPosition() else nil
	ctx.subject = nil
	ctx.isCast = false
	ctx.fixedOrigin = nil
	ctx.copyMultiplier = nil
	ctx.spawnOffset = TRIGGER_SPAWN_OFFSET
	ctx.energyScale = energyScale or 1
	ctx.surfaceNormal = normal
	ctx.flight = flight or 0
	ctx.conjureId = nil
	ctx.eventSteps = { n = 0 }
	ctx.eventPending = { pending = 0 }
	ctx.vars[triggerId] = {
		point = eventPoint,
		normal = normal,
		entity = if alive(struck) then struck else nil,
		pulse = pulse,
	}
	runFlow(compiled, ctx, triggerId, "out", energy, element)
end

-- Flight/placement stats for one vessel after its modifiers (their
-- settings resolved in this context), and the energy fraction the
-- modifiers take. Evaluated once per firing, so a Stream's later copies
-- reuse the cast-time Homing lock.
local function vesselStats(compiled: any, ctx: Context, id: string): (any, number)
	local base = SpellRunes.Vessels[compiled.runes[id].rune]
	local stats = {
		speed = base.Speed or 0,
		radius = base.Radius or 1,
		lifetime = base.Lifetime or 1,
		castRange = base.MaxCastRange or 0,
		scale = base.Scale or 1,
		gravity = 0,
		bounces = 0,
		restitution = 0.7,
		pierces = 0,
		falloff = 0.15,
		homing = nil :: any,
		quantity = nil :: any,
		sustain = nil :: number?,
	}
	local modCost = 0
	for _, modId in compiled.vessels[id].mods do
		local kind = compiled.runes[modId].rune
		local p = settings(compiled, ctx, modId)
		modCost += SpellRunes.ModifierCost(kind, p)
		if kind == "Speed" then
			stats.speed *= p.Factor
		elseif kind == "Size" then
			stats.radius *= p.Factor
			stats.scale *= p.Factor
		elseif kind == "Gravity" then
			stats.gravity = p.Pull
		elseif kind == "Bounce" then
			stats.bounces = p.Count
			stats.restitution = p.Bounciness
		elseif kind == "Pierce" then
			stats.pierces = p.Count
			stats.falloff = p.Falloff / 100
		elseif kind == "Range" then
			stats.lifetime *= p.Factor
			stats.castRange *= p.Factor
		elseif kind == "Quantity" then
			-- over the chain's Quantity limit (SpellCompiler): one copy
			if not (compiled.noQuantity and compiled.noQuantity[id]) then
				stats.quantity = p
			end
		elseif kind == "Sustain" then
			stats.sustain = p.Seconds
		elseif kind == "Homing" then
			local lock = input(compiled, ctx, modId, "entity")
			stats.homing = {
				lock = if alive(lock) and lock ~= ctx.caster then lock else nil,
				radius = p.Radius,
				filter = p.Filter,
				turnRate = math.rad(p.Turn),
			}
		end
	end
	return stats, math.min(modCost, SpellRunes.MaxModifierCost)
end

-- Aim from `from` (default Here): whatever is wired into the vessel's Aim
-- port, else the For Each / trigger target, else the cursor (at cast time),
-- else straight ahead.
local function aimDirection(compiled: any, ctx: Context, id: string, from: Vector3?): Vector3
	local origin = from or ctx.origin
	local aim = asPoint(input(compiled, ctx, id, "aim")) or defaultTarget(ctx)
	if aim and (aim - origin).Magnitude > 1e-3 then
		return (aim - origin).Unit
	end
	return ctx.heading
end

-- One direction per copy a Quantity rune asks for: a Fan spreads Spread
-- degrees across the aim, a Ring circles the aim at Spread/2 off-axis, and a
-- Stream repeats the aim (its copies are staggered in time instead).
local function spreadDirections(direction: Vector3, quantity: any): { Vector3 }
	local count = if quantity then quantity.Count else 1
	if count <= 1 or quantity.Pattern == "Stream" then
		return table.create(count, direction)
	end
	local up = if math.abs(direction.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local basis = CFrame.lookAt(Vector3.zero, direction, up)
	local spread = math.rad(quantity.Spread)
	local directions = table.create(count)
	for index = 1, count do
		if quantity.Pattern == "Ring" then
			local roll = (index - 1) / count * math.pi * 2
			directions[index] = (basis * CFrame.Angles(0, 0, roll) * CFrame.Angles(spread / 2, 0, 0)).LookVector
		else
			local t = (index - 1) / (count - 1) - 0.5
			directions[index] = (basis * CFrame.Angles(0, -t * spread, 0)).LookVector
		end
	end
	return directions
end

-- Sustained quantity channels need only their own direction. Building the
-- whole spread once per channel made N copies do N^2 work every emission.
local function spreadDirectionAt(direction: Vector3, quantity: any, index: number): Vector3
	local count = if quantity then quantity.Count else 1
	if count <= 1 or quantity.Pattern == "Stream" then return direction end
	local up = if math.abs(direction.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local basis = CFrame.lookAt(Vector3.zero, direction, up)
	local spread = math.rad(quantity.Spread)
	if quantity.Pattern == "Ring" then
		local roll = (index - 1) / count * math.pi * 2
		return (basis * CFrame.Angles(0, 0, roll) * CFrame.Angles(spread / 2, 0, 0)).LookVector
	end
	local t = (index - 1) / (count - 1) - 0.5
	return (basis * CFrame.Angles(0, -t * spread, 0)).LookVector
end

type Shot = {
	compiled: any,
	ctx: Context,
	id: string,
	vessel: string,
	element: string,
	info: any,
	stats: any,
	perCopy: number, -- energy one copy carries (triggers take shares of this)
	damageEnergy: number, -- the part of it spent on hits
	impact: number, -- damage per damage-energy (element x vessel)
	channelId: number?,
	energyScale: number, -- see Context.energyScale
	spawn: Vector3?, -- the From input: where it launches (else Here + spawnOffset)
}

-- Does any trigger on this vessel watch each projectile's own position over
-- time (On Timer / On Proximity), rather than firing on its impact/expiry?
local function positionalTriggers(compiled: any, info: any): boolean
	for _, triggerId in info.triggers do
		local rune = compiled.runes[triggerId].rune
		if rune ~= "OnImpact" and rune ~= "OnExpire" then
			return true
		end
	end
	return false
end

-- Does this vessel carry an On Expire trigger? (A sustained beam's packets
-- that never touch anything then still have to fire it as they run out.)
local function expireTriggers(compiled: any, info: any): boolean
	for _, triggerId in info.triggers do
		if compiled.runes[triggerId].rune == "OnExpire" then
			return true
		end
	end
	return false
end

-- A sustained channel launches up to ~67 packets a second with the same
-- caster: its ignore list and target filter are built once per channel and
-- reused (the list is rebuilt every SUSTAIN_SHARED_REFRESH seconds, so a
-- barrier raised mid-beam still counts). Reusing the same list also lets
-- BeamChain keep one normalized config and one RaycastParams per chain.
local SUSTAIN_SHARED_REFRESH = 0.25
local sustainShared: { [number]: { at: number, ignore: { Instance }, filter: (any) -> boolean } } = {}

local function sharedFor(shot: Shot): ({ Instance }, (any) -> boolean)
	local ctx = shot.ctx
	local caster = ctx.caster
	local id = shot.channelId
	local now = os.clock()
	local entry = id and sustainShared[id]
	if entry and now - entry.at < SUSTAIN_SHARED_REFRESH then
		return entry.ignore, entry.filter
	end
	local ignore = SpellWorld.SpellIgnore(ctx.player, caster)
	table.insert(ignore, 1, ctx.character)
	local filter = function(entity)
		return entity ~= caster and not entity.IsDestroyed and entity.Health > 0
	end
	if id then
		for other, old in sustainShared do
			if now - old.at > 5 then
				sustainShared[other] = nil -- (that channel has ended)
			end
		end
		sustainShared[id] = { at = now, ignore = ignore, filter = filter }
	end
	return ignore, filter
end

-- All flying vessels use the same swept-radius simulation and trigger pipeline.
local function launch(shot: Shot, direction: Vector3)
	local ctx = shot.ctx
	if not ProjectileQuota.TryAcquire(ctx.player, 1) then
		return -- over the live-projectile budget: this copy fizzles
	end
	local stats, element, compiled = shot.stats, shot.element, shot.compiled
	local elementDef = SpellRunes.Elements[element]
	local caster = ctx.caster
	local homing = stats.homing and {
		Target = stats.homing.lock,
		AcquireRadius = stats.homing.radius,
		TargetTag = if stats.homing.filter ~= "Any" then stats.homing.filter else nil,
		Retarget = true,
		ReacquireRate = 0.3,
		TurnRate = stats.homing.turnRate,
		Delay = if shot.vessel == "Beam" then 0 else 0.05,
	}
	local ignore, filter = sharedFor(shot)
	-- A sustained beam's packet may stay a dormant record until something is
	-- near it (see BeamChain): its triggers and damage are bound only then,
	-- and if it never is, it just gives its quota slot back.
	local bind: (any, number, any?) -> ()
	-- Reusable synchronous binding for both emitted packets and subdivisions.
	-- Each fork receives a fraction of the UNFIRED trigger/damage energy.
	-- (Defined before the launch: BeamHandler.Launch binds a packet it can't
	-- keep dormant -- a single beam, a homing or triggered chain -- at once.)
	bind = function(projectile, damageEnergy, triggerAmounts)
		local lastStruck = nil
		local boundWatches = {}
		projectile.OnHit:Connect(function(hit)
			local multiplier = projectile.DamageMultiplier
			if hit.Entity then
				lastStruck = hit.Entity
				strike(ctx, hit.Entity, projectile.Damage * multiplier, hit.Hurtbox, hit.CFrame.Position, element, damageEnergy * multiplier)
			else
				-- (a barrier that stops this caster's magic: it takes the hit)
				SpellWorld.DamagePart(hit.Part, projectile.Damage * multiplier)
			end
		end)
		local destroyTriggers = {}
		for _, triggerId in shot.info.triggers do
			local trigger = compiled.runes[triggerId]
			local nominal = shot.perCopy * trigger.params.Share / 100
			local watch = newWatch(projectile, compiled, ctx, triggerId, nominal, element, shot.energyScale)
			if triggerAmounts then
				watch.energy = triggerAmounts[triggerId] or 0
			end
			table.insert(boundWatches, watch)
			if trigger.rune == "OnImpact" or trigger.rune == "OnExpire" then
				table.insert(destroyTriggers, watch)
			else
				table.insert(watches, watch)
			end
		end
		local released = false
		projectile.OnDestroy:Connect(function(result)
			if not released then
				released = true
				ProjectileQuota.Release(ctx.player, 1)
			end
			for _, watch in destroyTriggers do
				local kind = compiled.runes[watch.trigger].rune
				local heading = headingOf(projectile, ctx.heading)
				local flight = projectile.Age
				if kind == "OnImpact" and (result.Kind == "entity" or result.Kind == "world") then
					fireTrigger(compiled, ctx, watch.trigger, watch.energy, element, result.Position, heading, result.Normal, if result.Kind == "entity" then lastStruck else nil, triggerScale(watch, watch.energy), flight)
				elseif kind == "OnExpire" and result.Kind == nil then
					fireTrigger(compiled, ctx, watch.trigger, watch.energy, element, result.Position, heading, nil, nil, triggerScale(watch, watch.energy), flight)
				end
			end
		end)
		projectile._beamReserveChildren = function(count)
			return ProjectileQuota.TryAcquire(ctx.player, count)
		end
		projectile._beamBindChild = function(child, share)
			local amounts = {}
			for _, watch in boundWatches do amounts[watch.trigger] = watch.energy * share end
			bind(child, damageEnergy * share, amounts)
		end
		projectile._beamScaleEnergy = function(share)
			damageEnergy *= share
			projectile.Damage *= share
			for _, watch in boundWatches do watch.energy *= share end
		end
	end
	local deferred = if shot.vessel == "Beam" and BeamHandler.DefersBinding then {
		Bind = function(packet)
			bind(packet, shot.damageEnergy, nil)
		end,
		Discard = function()
			ProjectileQuota.Release(ctx.player, 1)
		end,
	} else nil
	local projectile = (if shot.vessel == "Beam" then BeamHandler.Launch else Projectile.new)({
		Origin = shot.spawn or (ctx.origin + direction * ctx.spawnOffset),
		Direction = direction,
		Speed = stats.speed,
		Radius = stats.radius,
		Lifetime = stats.lifetime,
		Gravity = stats.gravity,
		Bounces = stats.bounces,
		Restitution = stats.restitution,
		MaxPierces = stats.pierces,
		PierceFalloff = stats.falloff,
		Damage = shot.damageEnergy * shot.impact,
		Source = caster,
		-- (barriers that let this caster's magic through)
		IgnoreInstances = ignore,
		Filter = filter,
		Homing = homing,
		Visualize = true,
		VisualRange = VISUAL_RANGE,
		VisualScale = stats.scale,
		Beam = if shot.vessel == "Beam" then {
			Length = if stats.sustain then math.max(24, stats.speed * SUSTAIN_INTERVAL * 2) else 24,
			ChannelId = shot.channelId,
			-- (a sustained beam may keep a long link as one body until it meets
			-- something -- unless a trigger watches every joiner's own position)
			Lazy = positionalTriggers(compiled, shot.info) == false,
			ExpireTriggers = expireTriggers(compiled, shot.info),
		} else nil,
		-- Built procedurally on the client -- see VisualModel's styled visuals.
		Visual = { Style = shot.vessel, Color = elementDef.Color, Core = elementDef.Core },
	}, deferred)

	if not deferred then
		bind(projectile, shot.damageEnergy, nil)
	end
end

-- A sustained channel's next shot, aimed from where the caster is now, and
-- where / which way it would launch (BeamChain looks before it launches).
local function aimSustain(parent: Shot, index: number): (Shot, Vector3, Vector3)
	local shot = table.clone(parent)
	shot.ctx = liveContext(shot.ctx)
	shot.spawn = asPoint(input(shot.compiled, shot.ctx, shot.id, "from"))
	local direction = spreadDirectionAt(aimDirection(shot.compiled, shot.ctx, shot.id, shot.spawn), shot.stats.quantity, index)
	return shot, shot.spawn or (shot.ctx.origin + direction * shot.ctx.spawnOffset), direction
end

local function fireSustain(shot: Shot, direction: Vector3, share: number, channelId: number)
	shot.channelId = channelId
	shot.perCopy *= share
	shot.damageEnergy *= share
	shot.energyScale *= share
	launch(shot, direction)
end

local function emitSustain(parent: Shot, index: number, share: number, channelId: number)
	local shot, _, direction = aimSustain(parent, index)
	fireSustain(shot, direction, share, channelId)
end

-- Fling: a blast whose power at a target (centre damage x falloff) reaches
-- FLING_MIN_POWER ragdolls it (the Stun effect) and launches it away from the
-- centre with an upward bias; speed and ragdoll time grow with the power.
local FLING_MIN_POWER = 40
local FLING_SPEED_PER_POWER = 1.6 -- studs/s per point of power at the target
local FLING_MIN_SPEED, FLING_MAX_SPEED = 80, 180
local FLING_UPWARD = 0.75 -- upward share mixed into the launch direction
local FLING_RAGDOLL_MIN, FLING_RAGDOLL_MAX = 0.8, 3 -- seconds of Stun
local FLING_RAGDOLL_PER_POWER = 1 / 150
local FLING_SPIN_MIN, FLING_SPIN_MAX = 4, 14 -- rad/s of random tumble; grows with power
local FLING_SPIN_PER_POWER = 0.05
local FLING_TRAIL_LIFETIME = 0.5

local flingRandom = Random.new()
local flingTrailTokens: { [Instance]: number } = {}

-- White trail on the torso while flung: tapers to nothing and fades over its
-- lifetime. A fresh fling reuses the trail and pushes back its end; when the
-- ragdoll time is up it stops emitting, then is removed once the tail fades.
local function flingTrail(character: Instance, duration: number)
	local part = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
		or character:FindFirstChild("HumanoidRootPart")
	if not part or not part:IsA("BasePart") then
		return
	end
	local trail = part:FindFirstChild("FlingTrail") :: Trail?
	if not trail then
		local a0 = Instance.new("Attachment")
		a0.Name = "FlingTrailTop"
		a0.Position = Vector3.new(0, 0.6, 0)
		a0.Parent = part
		local a1 = Instance.new("Attachment")
		a1.Name = "FlingTrailBottom"
		a1.Position = Vector3.new(0, -0.6, 0)
		a1.Parent = part
		local newTrail = Instance.new("Trail")
		newTrail.Name = "FlingTrail"
		newTrail.Attachment0 = a0
		newTrail.Attachment1 = a1
		newTrail.Color = ColorSequence.new(Color3.new(1, 1, 1))
		newTrail.Transparency = NumberSequence.new(0.1, 1)
		newTrail.WidthScale = NumberSequence.new(1, 0)
		newTrail.Lifetime = FLING_TRAIL_LIFETIME
		newTrail.MinLength = 0.05
		newTrail.FaceCamera = true
		newTrail.LightEmission = 0.4
		newTrail.Parent = part
		trail = newTrail
	end
	local active = trail :: Trail
	active.Enabled = true
	local token = (flingTrailTokens[character] or 0) + 1
	flingTrailTokens[character] = token
	task.delay(duration, function()
		if flingTrailTokens[character] ~= token then
			return
		end
		if not active.Parent then
			flingTrailTokens[character] = nil
			return
		end
		active.Enabled = false
		task.delay(FLING_TRAIL_LIFETIME, function()
			if flingTrailTokens[character] ~= token then
				return
			end
			flingTrailTokens[character] = nil
			local top, bottom = active.Attachment0, active.Attachment1
			active:Destroy()
			if top then top:Destroy() end
			if bottom then bottom:Destroy() end
		end)
	end)
end

local function fling(entity: any, center: Vector3, power: number)
	local character = entity.Instance
	if not character or not character:IsA("Model") or not entity.Humanoid then
		return
	end
	local ragdollTime = math.clamp(FLING_RAGDOLL_MIN + power * FLING_RAGDOLL_PER_POWER, FLING_RAGDOLL_MIN, FLING_RAGDOLL_MAX)
	-- Stun first: it ragdolls (server takes ownership of every limb); the
	-- launch then re-asserts ownership so a client can't overwrite it.
	if alive(entity) then
		StatusEffectSys:ApplyEffect(entity, "Stun", ragdollTime)
	end
	local away = flat(entity:GetPosition() - center)
	local direction = (if away.Magnitude > 1e-3 then away.Unit else Vector3.zero) + Vector3.new(0, FLING_UPWARD, 0)
	local velocity = direction.Unit * math.clamp(power * FLING_SPEED_PER_POWER, FLING_MIN_SPEED, FLING_MAX_SPEED)
	-- random tumble axis; up to +-30% jitter on the power-scaled spin rate
	local spinRate = math.clamp(power * FLING_SPIN_PER_POWER, FLING_SPIN_MIN, FLING_SPIN_MAX)
		* flingRandom:NextNumber(0.7, 1.3)
	Ragdoll.Launch(character, velocity, flingRandom:NextUnitVector() * spinRate)
	flingTrail(character, ragdollTime)
end

-- Where something goes when nothing says: the For Each entity, else a
-- conjured circle's mark (or the circle itself), else the cursor at cast
-- time, else Here.
local function defaultPlace(ctx: Context): Vector3
	local point = subjectPoint(ctx)
	if point then
		return point
	elseif ctx.fixedOrigin then
		return ctx.focus or ctx.origin
	end
	return if ctx.isCast then ctx.cursorPoint else ctx.origin
end

-- Where a placed vessel goes (Explosion, Barrier, Time Field): its At input,
-- else defaultPlace -- at cast time no further than maxRange from the caster.
local function placement(compiled: any, ctx: Context, id: string, maxRange: number): Vector3
	local point = asPoint(input(compiled, ctx, id, "aim")) or defaultPlace(ctx)
	if ctx.isCast and not ctx.fixedOrigin then
		local offset = (point :: Vector3) - ctx.origin
		if offset.Magnitude > maxRange then
			point = ctx.origin + offset.Unit * maxRange
		end
	end
	return point :: Vector3
end

-- The body a Force / Body Effect works on when nothing is wired: the For
-- Each entity, else you at cast time, else whoever set off the trigger.
local function defaultBody(ctx: Context): any?
	if alive(ctx.subject) then
		return ctx.subject
	end
	if ctx.isCast then
		return if alive(ctx.caster) then ctx.caster else nil
	end
	return if alive(ctx.struck) then ctx.struck else nil
end

-- Who a Smite hits when nothing is wired: the For Each entity, else
-- whoever set off the trigger, else what's under the crosshair at cast time.
local function defaultVictim(ctx: Context): any?
	if alive(ctx.subject) then
		return ctx.subject
	elseif alive(ctx.struck) then
		return ctx.struck
	end
	return if ctx.isCast and alive(ctx.cursorEntity) then ctx.cursorEntity else nil
end

-- The living entities a vessel's Target input names (a list or one), each
-- once; unwired, `fallback`.
local function targetsOf(compiled: any, ctx: Context, id: string, fallback: any?): { any }
	local result, seen = {}, {}
	local source = if wired(compiled, id, "target") then asList(input(compiled, ctx, id, "target")) else { fallback }
	for _, entity in source do
		if alive(entity) and not seen[entity] then
			seen[entity] = true
			table.insert(result, entity)
		end
	end
	return result
end

-- Explosion: damages every living entity (never the caster) within Radius,
-- full at the centre down to Edge at the rim, then broadcasts the blast for
-- the client-side visual. Radius beyond the free size costs a share of the
-- energy (SpellRunes.ExplosionCost); a blast fed a split share of its
-- nominal energy (a Sustain packet's slice, a subdivided beamlet) shrinks
-- with the cube root of that share. Barriers in reach that stop the
-- caster's magic take the hit too.
local MIN_EXPLOSION_SCALE = 0.2 -- smallest radius fraction a split blast keeps

-- Explosion visuals go out once a frame, as one "SpellExplosions" list per
-- player holding only the blasts that player could see or hear (audio
-- carries up to ~3000 studs for the biggest), instead of one message to
-- everyone per blast. Each carries its element (the client's colour theme,
-- ExplosionVFX) and that element's colour (for elements without a theme).
-- Blasts of one element going off this frame within
-- half a radius of each other are drawn as one (powers add) -- purely
-- cosmetic: every blast still deals its own damage.
local EXPLOSION_SEND_RANGE = 3000
local explosionQueue: { any } = {}

function queueExplosionVisual(center: Vector3, radius: number, element: string, power: number, normal: Vector3?)
	for _, queued in explosionQueue do
		if queued.Element == element and (queued.Position - center).Magnitude <= math.max(queued.Radius, radius) * .5 then
			queued.Power += power
			queued.Radius = math.max(queued.Radius, radius)
			return
		end
	end
	table.insert(explosionQueue, { Position = center, Radius = radius, Element = element,
		Color = SpellRunes.Elements[element].Color, Power = power, Normal = normal })
end

Heartbeat.Connect(function()
	if #explosionQueue == 0 then
		return
	end
	local batch = explosionQueue
	explosionQueue = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character.PrimaryPart
		local list = batch
		if root then
			list = {}
			local at = root.Position
			for _, blast in batch do
				if (blast.Position - at).Magnitude <= EXPLOSION_SEND_RANGE + blast.Radius then
					table.insert(list, blast)
				end
			end
		end
		if #list > 0 then
			VisualOffload.FireClient(player, "SpellExplosions", list)
		end
	end
end, { Name = "SpellRuntime.ExplosionVisuals", Priority = 7 })

local function explode(shot: Shot)
	local ctx = shot.ctx
	local params = settings(shot.compiled, ctx, shot.id)
	local center = placement(shot.compiled, ctx, shot.id, shot.stats.castRange or SpellRunes.Vessels.Explosion.MaxCastRange)
	local desiredRadius = SpellRunes.ExplosionRadius(params.Radius, shot.stats.scale)
	local radius = desiredRadius * math.clamp(shot.energyScale ^ (1 / 3), MIN_EXPLOSION_SCALE, 1)
	local damageEnergy = shot.damageEnergy * (1 - SpellRunes.ExplosionCost(desiredRadius))
	local edge = params.Edge / 100
	for _, entity in ChunkManager.GetEntitiesInRadius(center, radius) do
		if entity ~= ctx.caster and alive(entity) then
			local position = entity:GetPosition()
			local falloff = 1 - (1 - edge) * math.clamp((position - center).Magnitude / radius, 0, 1)
			local power = damageEnergy * shot.impact * falloff
			strike(ctx, entity, power, "Body", position, shot.element, damageEnergy * falloff)
			if params.Fling and power >= FLING_MIN_POWER and Entity.CanDamage(ctx.caster, entity) then
				fling(entity, center, power)
			end
		end
	end
	SpellWorld.DamageInRadius(center, radius, damageEnergy * shot.impact, ctx.player, ctx.caster)
	queueExplosionVisual(center, radius, shot.element, damageEnergy * shot.impact,
		-- the struck surface, so the visual sits on walls/ceilings/slopes
		if ctx.isCast then nil else ctx.surfaceNormal)
end

-- Smite: an instant bolt from From to each target within Range (and in
-- sight, when Sight is on), sharing the energy. A barrier that stops the
-- caster's magic stops the bolt and takes the hit.
local SMITE_SIGHT_TRIES = 4

local function smite(shot: Shot)
	local ctx = shot.ctx
	local params = settings(shot.compiled, ctx, shot.id)
	local from = asPoint(input(shot.compiled, ctx, shot.id, "from")) or ctx.origin
	local color = SpellRunes.Elements[shot.element].Color
	local hits: { { entity: any, position: Vector3 } } = {}
	local blocked: { { part: BasePart, position: Vector3 } } = {}
	for _, target in targetsOf(shot.compiled, ctx, shot.id, defaultVictim(ctx)) do
		if target == ctx.caster then
			continue
		end
		local position = target:GetPosition()
		local offset = position - from
		if offset.Magnitude > params.Range then
			continue
		end
		if params.Sight and offset.Magnitude > 1e-3 then
			local exclude: { Instance } = SpellWorld.SpellIgnore(ctx.player, ctx.caster)
			table.insert(exclude, ctx.character)
			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			rayParams.IgnoreWater = true
			local clear = false
			for _ = 1, SMITE_SIGHT_TRIES do
				rayParams.FilterDescendantsInstances = exclude
				local result = workspace:Raycast(from, offset, rayParams)
				if not result then
					clear = true
					break
				end
				local hitEntity = Entity.Get(result.Instance)
				if hitEntity == target then
					clear = true
					break
				elseif hitEntity and hitEntity.Instance then
					table.insert(exclude, hitEntity.Instance) -- (bolts pass other bodies)
				else
					if SpellWorld.BarrierOf(result.Instance) then
						table.insert(blocked, { part = result.Instance :: BasePart, position = result.Position })
					end
					break
				end
			end
			if not clear then
				continue
			end
		end
		table.insert(hits, { entity = target, position = position })
	end
	local count = #hits + #blocked
	if count == 0 then
		SpellWorld.Visual({ Kind = "Smite", From = from, To = from + ctx.heading * 3, Color = color, Fizzle = true })
		return
	end
	local each = shot.damageEnergy / count
	for _, hit in hits do
		strike(ctx, hit.entity, each * shot.impact, "Body", hit.position, shot.element, each)
		SpellWorld.Visual({ Kind = "Smite", From = from, To = hit.position, Color = color })
	end
	for _, hit in blocked do
		SpellWorld.DamagePart(hit.part, each * shot.impact)
		SpellWorld.Visual({ Kind = "Smite", From = from, To = hit.position, Color = color })
	end
end

-- Triggers on a barrier / time field: On Timer and On Proximity are polled
-- like a projectile's, On Expire fires when it breaks or fades.
local function watchThing(compiled: any, ctx: Context, id: string, thing: any, perCopy: number, element: string?)
	local info = compiled.vessels[id]
	local onEnd = {}
	for _, triggerId in info.triggers do
		local trigger = compiled.runes[triggerId]
		local watch = newWatch(thing, compiled, ctx, triggerId, perCopy * trigger.params.Share / 100, element, ctx.energyScale or 1)
		if trigger.rune == "OnExpire" then
			table.insert(onEnd, watch)
		else
			table.insert(watches, watch)
		end
	end
	if #onEnd > 0 then
		thing.OnDestroy:Connect(function(result)
			if result.Kind == "removed" or result.Kind == "moderated" then
				return -- (its caster left, or shape moderation took it down)
			end
			for _, watch in onEnd do
				fireTrigger(compiled, ctx, watch.trigger, watch.energy, element, result.Position, ctx.heading, nil, nil, triggerScale(watch, watch.energy), thing.Age)
			end
		end)
	end
end

local function fedBy(energy: number, cost: number): number
	return if cost > 0 then math.clamp(energy / cost, 0, 1) else 1
end

-- Barrier, Time Field, Force, Blink and Body Effect: magic that does what
-- its settings say, paid for by the energy that reaches it.
local function fireUtility(compiled: any, ctx: Context, id: string, energy: number, element: string?)
	local rune = compiled.runes[id]
	local p = settings(compiled, ctx, id)
	local info = compiled.vessels[id]
	local own = energy * (1 - info.triggerShare) -- what the vessel itself spends
	local look = (element and SpellRunes.Elements[element]) or SpellRunes.Raw
	local kind = rune.rune
	local base = SpellRunes.Vessels[kind]
	local costs = SpellRunes.Costs

	if kind == "Barrier" then
		local at = placement(compiled, ctx, id, base.MaxCastRange)
		local follow = input(compiled, ctx, id, "follow")
		local fed = fedBy(own, SpellRunes.BarrierCost(p))
		local thing = SpellWorld.CreateBarrier({
			player = ctx.player,
			caster = ctx.caster,
			position = at,
			face = asPoint(input(compiled, ctx, id, "face")) or ctx.origin,
			fallbackFacing = -ctx.heading,
			shape = p.Shape,
			size = Vector3.new(p.Width, p.Height, p.Depth),
			tilt = p.Tilt,
			anchor = p.Anchor,
			ground = p.Ground,
			rise = p.Rise,
			health = p.Health * fed,
			duration = p.Duration * fed,
			pass = p.Pass,
			blocks = p.Blocks,
			follow = if alive(follow) then follow else nil,
			color = look.Color,
		})
		watchThing(compiled, ctx, id, thing, energy, element)
	elseif kind == "TimeField" then
		local at = placement(compiled, ctx, id, base.MaxCastRange)
		local follow = input(compiled, ctx, id, "follow")
		local fed = fedBy(own, SpellRunes.FieldCost(p))
		local thing = SpellWorld.CreateTimeField({
			player = ctx.player,
			position = at,
			radius = p.Radius,
			scale = p.Scale,
			duration = p.Duration * fed,
			follow = if alive(follow) then follow else nil,
			color = look.Color,
		})
		watchThing(compiled, ctx, id, thing, energy, element)
	elseif kind == "Force" then
		local center = asPoint(input(compiled, ctx, id, "center")) or ctx.origin
		local targets = targetsOf(compiled, ctx, id, if p.Radius > 0 then nil else defaultBody(ctx))
		local parts = {}
		if p.Radius > 0 then
			local seen = {}
			for _, target in targets do seen[target] = true end
			for _, entity in ChunkManager.GetEntitiesInRadius(center, p.Radius) do
				if entity ~= ctx.caster and alive(entity) and not seen[entity] then
					seen[entity] = true
					table.insert(targets, entity)
				end
			end
			parts = SpellWorld.LooseParts(center, p.Radius)
		end
		local bodies = #targets + #parts * LOOSE_PART_WEIGHT
		local fed = fedBy(own / math.max(bodies, 1), SpellRunes.ForceCost(p))
		local speed = p.Speed * fed
		local along = asPoint(input(compiled, ctx, id, "dir"))
		local alongDir = if along and along.Magnitude > 1e-3 then along.Unit else ctx.heading
		local function directionFor(position: Vector3): Vector3
			if p.Mode == "Up" then
				return Vector3.yAxis
			elseif p.Mode == "Away" or p.Mode == "Toward" then
				local level = flat(position - center)
				if level.Magnitude < 1e-3 then
					return if p.Mode == "Away" then Vector3.yAxis else Vector3.zero
				end
				level = level.Unit * (if p.Mode == "Away" then 1 else -1)
				return (level + Vector3.new(0, p.Lift, 0)).Unit
			end
			return alongDir
		end
		local shoved = {}
		for _, target in targets do
			SpellWorld.Drive(target, {
				velocity = directionFor(target:GetPosition()) * speed,
				ragdoll = p.Ragdoll,
				replace = p.Replace,
				duration = p.Duration,
				mode = p.Mode,
				center = center,
				speed = speed,
				lift = p.Lift,
			})
			if target.Instance then
				table.insert(shoved, target.Instance)
			end
		end
		for _, part in parts do
			SpellWorld.PushPart(part, directionFor(part.Position) * speed)
		end
		SpellWorld.Visual({
			Kind = "Force",
			Position = center,
			Radius = p.Radius,
			Direction = if p.Mode == "Along" then alongDir else directionFor(center + ctx.heading),
			Mode = p.Mode,
			Targets = shoved,
			Color = look.Color,
		})
	elseif kind == "Blink" then
		local who = if wired(compiled, id, "who") then input(compiled, ctx, id, "who") else ctx.caster
		if not alive(who) then
			return
		end
		local to = asPoint(input(compiled, ctx, id, "to")) or defaultPlace(ctx)
		local reach = math.min(p.Distance, own / costs.BlinkStud)
		local from, landed = SpellWorld.Blink(who, to :: Vector3, reach, p.Momentum)
		if from and landed then
			SpellWorld.Visual({ Kind = "Blink", From = from, To = landed, Color = look.Color })
		end
	elseif kind == "Effect" then
		local effect = p.Effect
		local def = SpellRunes.Effects[effect]
		if not def then
			return
		end
		local targets = targetsOf(compiled, ctx, id, defaultBody(ctx))
		local power = SpellRunes.EffectPower(effect, p.Power)
		local fed = fedBy(own / math.max(#targets, 1), SpellRunes.EffectCost(effect, power, p.Duration))
		for _, target in targets do
			if def.Kind == "Timed" then
				SpellBody.Apply(ctx.caster, target, effect, power, p.Duration * fed)
			elseif fed > 0 then
				SpellBody.Apply(ctx.caster, target, effect, power * fed, p.Duration)
			end
		end
	end
end

local function fireVessel(compiled: any, ctx: Context, id: string, energy: number, element: string?)
	-- over a splitting limit (SpellCompiler's soft limits): fizzles
	if compiled.disabledVessels and compiled.disabledVessels[id] then
		return
	end
	local cast = ctx.cast
	local vessel = compiled.runes[id].rune
	-- (explosions are uncapped: they spawn nothing further, so they can't
	-- run away -- their energy already bounds them)
	if vessel ~= "Explosion" then
		cast.vessels += 1
		if cast.vessels > SpellRunes.Budget.Vessels then
			return
		end
	end
	local def = SpellRunes.Runes[vessel]
	if not def.Damaging then
		fireUtility(compiled, ctx, id, energy, element)
		return
	end
	if not element then
		return -- (the compiler insists damaging vessels get an element)
	end
	local info = compiled.vessels[id]
	local impact = SpellRunes.Elements[element].Impact * SpellRunes.Vessels[vessel].Impact
	if def.Instant then
		local stats, modCost = {}, 0
		if vessel == "Explosion" then stats, modCost = vesselStats(compiled, ctx, id) end
		local perCopy = energy * (1 - modCost)
		local shot: Shot = {
			compiled = compiled, ctx = ctx, id = id, vessel = vessel, element = element, info = info,
			stats = stats, perCopy = perCopy, damageEnergy = perCopy * (1 - info.triggerShare), impact = impact,
			energyScale = ctx.energyScale or 1,
		}
		if vessel == "Explosion" then
			explode(shot)
		else
			smite(shot)
		end
		return
	end
	local stats, modCost = vesselStats(compiled, ctx, id)
	-- Overcharge adds copies (energy already scaled to match). A vessel with
	-- Quantity grows its own pattern; one without fans the extras out.
	local count = info.count
	local copies = ctx.copyMultiplier or 1
	if copies > 1 then
		count = math.max(info.count, math.floor(info.count * copies + 0.5))
		if count ~= info.count then
			local quantity = if stats.quantity then table.clone(stats.quantity) else {
				Pattern = "Fan",
				Spread = SpellRunes.Charge.OverchargeSpread,
			}
			quantity.Count = count
			stats.quantity = quantity
		end
	end
	local perCopy = energy * (1 - modCost) / count
	local shot: Shot = {
		compiled = compiled,
		ctx = ctx,
		id = id,
		vessel = vessel,
		element = element,
		info = info,
		stats = stats,
		perCopy = perCopy,
		damageEnergy = perCopy * (1 - info.triggerShare),
		impact = impact,
		energyScale = ctx.energyScale or 1,
		spawn = asPoint(input(compiled, ctx, id, "from")),
	}
	local stream = stats.quantity and stats.quantity.Pattern == "Stream"
	if vessel == "Beam" and stats.sustain then
		for index = 1, count do
			BeamHandler.Start({
				Player = ctx.player, Character = ctx.character, Caster = ctx.caster,
				Duration = stats.sustain,
				Speed = stats.speed,
				Delay = if stream then (index - 1) * stats.quantity.Interval else 0,
				Origin = function() return liveContext(ctx).origin end,
				Emit = function(share, channelId) emitSustain(shot, index, share, channelId) end,
				-- (BeamChain: aim every tick, launch only the samples a lazy beam needs)
				Aim = function() return aimSustain(shot, index) end,
				Fire = function(aimed, direction, share, channelId) fireSustain(aimed, direction, share, channelId) end,
			})
		end
		return
	end
	for index, direction in spreadDirections(aimDirection(compiled, ctx, id, shot.spawn), stats.quantity) do
		if stream and index > 1 then
			task.delay((index - 1) * stats.quantity.Interval, function()
				-- Re-aim each later copy from where the caster is pointing now.
				local liveShot = table.clone(shot)
				liveShot.ctx = liveContext(ctx)
				liveShot.spawn = asPoint(input(compiled, liveShot.ctx, id, "from"))
				if liveShot.ctx.character.Parent and (not liveShot.ctx.caster or alive(liveShot.ctx.caster)) then
					launch(liveShot, aimDirection(compiled, liveShot.ctx, id, liveShot.spawn))
				end
			end)
		else
			launch(shot, direction)
		end
	end
end

--------------------------------------------------------------------------------
-- Flow runes
--------------------------------------------------------------------------------

-- The circle a Conjure Circle draws, built once per compiled spell and rune.
local conjureSpecs: { [any]: { [string]: any } } = setmetatable({}, { __mode = "k" }) :: any

local function conjureSpec(compiled: any, id: string): any
	local byRune = conjureSpecs[compiled]
	if not byRune then
		byRune = {}
		conjureSpecs[compiled] = byRune
	end
	local spec = byRune[id]
	if spec == nil then
		spec = SpellCircleLayout.BuildFrom(compiled, id)
		byRune[id] = spec
	end
	return spec
end

-- Invoke: (player, hotbar slot) -> that spell's compiled plan, or nil.
local resolver: ((player: Player, slot: number) -> any?)? = nil

function SpellRuntime.SetResolver(fn: (player: Player, slot: number) -> any?)
	resolver = fn
end

type FlowHandler = (compiled: any, ctx: Context, id: string, params: any, energy: number, element: string?) -> ()

local FLOW: { [string]: FlowHandler } = {}
local nextConjure = 0

FLOW.If = function(compiled, ctx, id, _params, energy, element)
	local taken = if input(compiled, ctx, id, "cond") == true then "yes" else "no"
	runFlow(compiled, ctx, id, taken, energy, element)
end

FLOW.Divide = function(compiled, ctx, id, params, energy, element)
	local share = params.Share / 100
	runFlow(compiled, ctx, id, "a", energy * share, element)
	runFlow(compiled, ctx, id, "b", energy * (1 - share), element)
end

FLOW.Delay = function(compiled, ctx, id, params, energy, element)
	later(ctx, params.Seconds, ctx.origin, function()
		runFlow(compiled, derive(liveContext(ctx)), id, "out", energy, element)
	end)
end

FLOW.Repeat = function(compiled, ctx, id, params, energy, element)
	local count = params.Count
	if count <= 0 then
		return
	end
	local each = energy / count
	for index = 1, count do
		local function run()
			local child = derive(if index > 1 then liveContext(ctx) else ctx)
			child.vars[id] = { index = index }
			runFlow(compiled, child, id, "each", each, element)
		end
		if index == 1 or params.Interval <= 0 then
			run()
		else
			later(ctx, (index - 1) * params.Interval, ctx.origin, run)
		end
	end
end

FLOW.ForEach = function(compiled, ctx, id, params, energy, element)
	local list, seen = {}, {}
	for _, entity in asList(input(compiled, ctx, id, "list")) do
		if alive(entity) and not seen[entity] and #list < params.Max then
			seen[entity] = true
			table.insert(list, entity)
		end
	end
	local count = #list
	if count == 0 then
		runFlow(compiled, ctx, id, "none", energy, element)
		return
	end
	local each = energy / count
	for index, entity in list do
		local function run()
			if not alive(entity) then
				return -- (it fell while waiting its turn)
			end
			local child = derive(if index > 1 and params.Interval > 0 then liveContext(ctx) else ctx)
			child.subject = entity
			child.focus = entity:GetPosition()
			child.vars[id] = { entity = entity, index = index, count = count }
			runFlow(compiled, child, id, "each", each, element)
		end
		if index == 1 or params.Interval <= 0 then
			run()
		else
			later(ctx, (index - 1) * params.Interval, ctx.origin, run)
		end
	end
end

FLOW.Await = function(compiled, ctx, id, params, energy, element)
	local waited = 0
	local holding = false
	-- a conjured circle that's waiting (a trap) stays up until it goes off
	local function hold(on: boolean)
		if ctx.conjureId and on ~= holding then
			holding = on
			VisualOffload.Fire("SpellCircle", {
				Phase = if on then "ConjureHold" else "ConjureRelease",
				Caster = ctx.character,
				Id = ctx.conjureId,
				Duration = params.Timeout + 1,
			})
		end
	end
	local function check()
		local probe = derive(liveContext(ctx))
		if input(compiled, probe, id, "cond") == true then
			hold(false)
			runFlow(compiled, probe, id, "then", energy, element)
		elseif waited >= params.Timeout then
			hold(false)
			runFlow(compiled, probe, id, "timeout", energy, element)
		else
			hold(true)
			waited += params.Every
			later(ctx, params.Every, probe.origin, check)
		end
	end
	check()
end

FLOW.Conjure = function(compiled, ctx, id, params, energy, element)
	local anchor = asPoint(input(compiled, ctx, id, "at")) or ctx.origin
	local position = anchor + Vector3.new(0, params.Height, 0)
	local face = asPoint(input(compiled, ctx, id, "face"))
	local raised = math.abs(params.Height) > 0.5
	-- what it looks at: Face, else the current target, else your aim at cast
	-- time, else back down at where it was conjured from
	local look = face or ctx.focus or (if ctx.isCast then ctx.cursorPoint else nil) or (if raised then anchor else nil)
	local direction = if look and (look - position).Magnitude > 1e-3 then (look - position).Unit else ctx.heading
	nextConjure += 1
	local conjureId = nextConjure
	VisualOffload.Fire("SpellCircle", {
		Phase = "Conjure",
		Caster = ctx.character,
		Id = conjureId,
		Position = position,
		Direction = direction,
		Spec = conjureSpec(compiled, id),
		Duration = params.Delay,
		Size = params.Size,
	})
	later(ctx, params.Delay, position, function()
		-- (a cast-time circle fires at where you're aiming once it's drawn)
		local child = derive(liveContext(ctx))
		child.origin = position
		child.heading = direction
		child.focus = face or ctx.focus or (if not ctx.isCast and raised then anchor else nil)
		child.fixedOrigin = true
		child.conjureId = conjureId
		child.spawnOffset = CONJURE_SPAWN_OFFSET
		child.vars[id] = { point = position }
		runFlow(compiled, child, id, "out", energy, element)
	end)
end

FLOW.Store = function(compiled, ctx, id, params, energy, element)
	local slots = memoryOf(ctx, params.Scope)
	local entry = slots[params.Slot] or {}
	if wired(compiled, id, "point") then
		entry.point = asPoint(input(compiled, ctx, id, "point"))
	end
	if wired(compiled, id, "number") then
		entry.number = number(input(compiled, ctx, id, "number"))
	end
	if wired(compiled, id, "entity") then
		local entity = input(compiled, ctx, id, "entity")
		entry.entity = if alive(entity) then entity else nil
	end
	if wired(compiled, id, "list") then
		entry.list = table.clone(asList(input(compiled, ctx, id, "list")))
	end
	slots[params.Slot] = entry
	runFlow(compiled, ctx, id, "out", energy, element)
end

FLOW.Invoke = function(compiled, ctx, id, params, energy, _element)
	local depth = ctx.depth or 0
	if depth >= SpellRunes.Budget.InvokeDepth or not resolver then
		return
	end
	local callee = resolver(ctx.player, params.Slot)
	if not callee then
		return
	end
	local total = 0
	for _, rootId in callee.manaRoots do
		total += callee.runes[rootId].params.Amount
	end
	if total <= 0 then
		return
	end
	local entity = input(compiled, ctx, id, "entity")
	-- (rune ids are per spell: the callee starts with no vars of its own)
	local child = derive(ctx)
	child.vars = {}
	child.depth = depth + 1
	child.copyMultiplier = nil
	child.args = {
		point = asPoint(input(compiled, ctx, id, "point")),
		entity = if alive(entity) then entity else nil,
		number = if wired(compiled, id, "number") then number(input(compiled, ctx, id, "number")) else nil,
	}
	for _, rootId in callee.manaRoots do
		runFlow(callee, child, rootId, "out", energy * callee.runes[rootId].params.Amount / total, nil)
	end
end

runFlow = function(compiled: any, ctx: Context, fromId: string, port: string, energy: number, element: string?)
	local links = compiled.outputs[fromId][port]
	local link = links and links[1]
	if not link or energy <= 1e-4 or not spend(ctx) then
		return -- an unwired flow output fizzles
	end
	local id = link.to
	local rune = compiled.runes[id]
	local def = SpellRunes.Runes[rune.rune]
	if def.Element then
		runFlow(compiled, ctx, id, "out", energy, def.Element)
	elseif def.Vessel then
		fireVessel(compiled, ctx, id, energy, element)
	else
		local handler = FLOW[rune.rune]
		if handler then
			handler(compiled, ctx, id, settings(compiled, ctx, id), energy, element)
		end
	end
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------

export type CastRequest = {
	player: Player,
	caster: any,
	character: Model,
	origin: Vector3,
	cursorPoint: Vector3,
	cursorEntity: any?,
	live: (() -> (Vector3?, Vector3?))?, -- current (origin, cursor); see liveContext
	charge: number?, -- hold-to-charge level (SpellRunes.Charge); 1 = a normal cast
}

-- Runs every Mana Well's flow. Mana is charged by the caller.
function SpellRuntime.Cast(compiled: any, request: CastRequest)
	BeamHandler.BeginCast(request.player)
	local offset = request.cursorPoint - request.origin
	local ctx: Context = {
		player = request.player,
		caster = request.caster,
		character = request.character,
		origin = request.origin,
		cursorPoint = request.cursorPoint,
		cursorEntity = request.cursorEntity,
		struck = nil,
		heading = if offset.Magnitude > 1e-3 then offset.Unit else Vector3.zAxis,
		focus = nil,
		subject = nil,
		isCast = true,
		spawnOffset = CAST_SPAWN_OFFSET,
		memo = {},
		vars = {},
		cast = { player = request.player, started = os.clock(), steps = 0, vessels = 0, pending = 0, dead = false, memory = {} },
		live = request.live,
		flight = 0,
		copyMultiplier = SpellRunes.ChargeCopyMultiplier(request.charge or 1),
		depth = 0,
	}
	-- Partial charge spends that fraction of every well's energy; overcharge
	-- spends more, matching the extra copies (the caller already took mana).
	local energyMultiplier = SpellRunes.ChargeEnergyMultiplier(request.charge or 1)
	for _, rootId in compiled.manaRoots do
		runFlow(compiled, ctx, rootId, "out", compiled.runes[rootId].params.Amount * energyMultiplier, nil)
	end
end

-- Timer / proximity triggers. Age is the vessel's own dilated clock, so a
-- timer inside a slow zone burns slower, like everything else.
-- (swap-remove: the loop runs backwards, so the watch moved in was visited)
local function unwatch(index: number)
	local last = #watches
	watches[index] = watches[last]
	watches[last] = nil
end

Heartbeat.Connect(function()
	local now = os.clock()
	for index = #watches, 1, -1 do
		local watch = watches[index]
		if not watch then
			continue
		end
		local projectile = watch.projectile
		local trigger = watch.compiled.runes[watch.trigger]
		local params = watch.params
		if watch.energy <= 0 or projectile.Dead then
			unwatch(index)
			continue
		end
		if trigger.rune == "OnTimer" then
			local pulses = math.max(params.Pulses or 1, 1)
			if projectile.Age >= params.Delay * (watch.pulses + 1) then
				local amount = watch.energy / math.max(pulses - watch.pulses, 1)
				watch.energy -= amount
				watch.pulses += 1
				local last = watch.pulses >= pulses
				if last then
					watch.energy = 0 -- do not duplicate a spent trigger when later subdividing
					unwatch(index)
				end
				fireTrigger(watch.compiled, watch.ctx, watch.trigger, amount, watch.element, projectile.Position, headingOf(projectile, watch.ctx.heading), nil, nil, triggerScale(watch, amount * pulses), projectile.Age, watch.pulses)
				if last and params.Detonate then
					projectile:Destroy({ Position = projectile.Position, Normal = Vector3.yAxis }, "detonate")
				end
			end
		elseif trigger.rune == "OnProximity" and now >= watch.nextCheck then
			watch.nextCheck = now + PROXIMITY_CHECK_INTERVAL
			local struck = nearestEntity(projectile.Position, params.Radius, params.Filter, watch.ctx.caster)
			if struck then
				unwatch(index)
				local energy = watch.energy
				watch.energy = 0 -- do not duplicate a spent trigger when later subdividing
				fireTrigger(watch.compiled, watch.ctx, watch.trigger, energy, watch.element, projectile.Position, headingOf(projectile, watch.ctx.heading), nil, struck, triggerScale(watch, energy), projectile.Age)
				if params.Detonate then
					projectile:Destroy({ Position = projectile.Position, Normal = Vector3.yAxis }, "detonate")
				end
			end
		end
	end
end, { Name = "SpellRuntime.Triggers", Priority = 6 })

Players.PlayerRemoving:Connect(function(player)
	memory[player] = nil
end)

return SpellRuntime
