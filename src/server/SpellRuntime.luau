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
	writes the caster's memory. A Vessel gives the energy form: Orb, Bullet
	and Beam fire projectiles (Projectile.luau), Explosion is an instant area
	blast, Barrier and Time Field raise things in the world, Force and Blink
	move bodies (server/SpellWorld), Body Effect works on one (server/
	SpellBody). Sustain emits overlapping Beam packets from live aim, sharing
	the cast's energy over its duration. Quantity multiplies a projectile into
	a Fan, Ring or Stream of copies sharing the energy; each Stream copy
	re-aims from the caster's live hand/cursor (see CastRequest.live), and so
	does every part of a cast that runs later (Delay, Repeat...).

	Values (sensors/logic/vectors) are evaluated on demand and memoized per
	evaluation context. A context is one moment in the world: the cast itself,
	a trigger firing (where Here is the vessel's position and Struck Entity is
	what set it off), one Repeat or For Each round, the end of a Delay, a
	conjured circle. Each context starts with a fresh memo (it senses the
	world anew) and inherits its parent's `vars`: the values flow runes and
	triggers output about their moment (a trigger's impact point, a Repeat's
	index, For Each's entity), so anything downstream can read them.

	Triggers reserve their Share of each copy's energy when it is fired and
	release it at most once: On Impact / On Expire ride the projectile's
	OnDestroy (or the end of a beam, or a barrier breaking), On Timer / On
	Proximity are polled by one Heartbeat loop.

	Every cast has a budget (SpellRunes.Budget): flow steps, vessels fired,
	parts waiting to run later, and how long after the cast they may run.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local Entity = require(Shared:WaitForChild("Entity"))
local VisualOffload = require(Shared:WaitForChild("VisualOffload"))
local Heartbeat = require(Shared:WaitForChild("Heartbeat"))
local SpellRunes = require(Shared:WaitForChild("SpellRunes"))
local SpellCompiler = require(Shared:WaitForChild("SpellCompiler"))
local SpellCircleLayout = require(Shared:WaitForChild("SpellCircleLayout"))
local StatusEffectSys = require(Shared:WaitForChild("StatusEffectSys"))
local Ragdoll = require(script.Parent:WaitForChild("Ragdoll"))
local Projectile = require(script.Parent:WaitForChild("Projectile"))
local ProjectileQuota = require(script.Parent:WaitForChild("ProjectileQuota"))
local BeamHandler = require(script.Parent:WaitForChild("Projectile"):WaitForChild("BeamProjectileHandler"))
local SpellWorld = require(script.Parent:WaitForChild("SpellWorld"))
local SpellBody = require(script.Parent:WaitForChild("SpellBody"))

local SpellRuntime = {}

local CAST_SPAWN_OFFSET = 3 -- studs in front of the caster's head
local TRIGGER_SPAWN_OFFSET = 0.75 -- studs off the trigger point
local CONJURE_SPAWN_OFFSET = 1 -- studs in front of a conjured circle
local PROXIMITY_CHECK_INTERVAL = 0.05 -- real seconds between proximity scans
local VISUAL_RANGE = 800
local SUSTAIN_INTERVAL = BeamHandler.Interval
local PIERCE_FALLOFF = 0.15
local PUSH_LIFT, PULL_LIFT = 0.45, 0.2 -- upward share mixed into Force Push / Pull

-- One cast, shared by every context it spawns: its budget and clock.
export type CastInfo = {
	player: Player,
	started: number, -- os.clock at the cast
	steps: number,
	vessels: number,
	pending: number,
	dead: boolean,
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
	-- Cast time only: the caster's current (origin, cursor), for Stream copies
	-- and parts that run later.
	live: (() -> (Vector3?, Vector3?))?,
	-- A conjured circle: live re-aiming keeps firing from it, not your hand.
	fixedOrigin: boolean?,
	-- How long the vessel whose trigger made this context had flown.
	flight: number?,
	-- Fraction of its nominal energy that reached this point after Sustain
	-- slicing and beam subdivision (1 when nothing was split). Explosions
	-- shrink with it -- see explode().
	energyScale: number?,
	-- Size multiplier (Size rune) of the vessel whose trigger created this
	-- context; an Explosion it fires scales its radius by it.
	sizeScale: number?,
	-- Normal of the surface whose hit fired this context's trigger (On
	-- Impact into geometry or an entity); explosions orient their visual to it.
	surfaceNormal: Vector3?,
	-- Cast-time only: hold-to-charge copy multiplier (>= 1) for the vessels
	-- the cast fires directly; see SpellRunes.Charge.
	copyMultiplier: number?,
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

-- Caster memory (Store / Recall), per player for the session.
local memory: { [Player]: { [string]: any } } = {}

local function memoryOf(player: Player): { [string]: any }
	local slots = memory[player]
	if not slots then
		slots = {}
		memory[player] = slots
	end
	return slots
end

local evaluate: (compiled: any, ctx: Context, id: string, port: string) -> any

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

-- A per-rune table cached for this context (one Scan / Raycast feeds all of
-- its outputs from the same result).
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
	local forward = Vector3.new(ctx.heading.X, 0, ctx.heading.Z)
	if forward.Magnitude < 1e-3 then
		forward = (ctx.character and ctx.character.Parent and ctx.character:GetPivot().LookVector or Vector3.zAxis) * Vector3.new(1, 0, 1)
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
		local params = compiled.runes[id].params
		local from = asPoint(input(compiled, ctx, id, "from")) or ctx.origin
		local found = {}
		for _, entity in ChunkManager.GetEntitiesInRadius(from, params.Radius) do
			if not alive(entity) then
				continue
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
		local params = compiled.runes[id].params
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

local function vecMath(op: string, a: Vector3, b: Vector3, n: number): Vector3
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
		return CFrame.Angles(0, math.rad(n), 0) * a
	end
	return a
end

local function compute(compiled: any, ctx: Context, id: string, port: string): any
	local rune = compiled.runes[id]
	local params = rune.params
	local kind = rune.rune
	local def = SpellRunes.Runes[kind]
	-- flow runes and triggers: what they recorded about their moment
	if def.Pass or def.Category == "Trigger" then
		local bag = ctx.vars[id]
		return if bag then bag[port] else nil
	end
	if kind == "Caster" then
		return ctx.caster
	elseif kind == "Cursor" then
		if port == "point" then return ctx.cursorPoint end
		return if alive(ctx.cursorEntity) then ctx.cursorEntity else nil
	elseif kind == "Target" then
		-- Aim: its input, else the mouse (at cast time) / the trigger's focus.
		local point = asPoint(input(compiled, ctx, id, "point"))
		if point then return point end
		return defaultTarget(ctx) or ctx.cursorPoint
	elseif kind == "Here" then
		if port == "heading" then return ctx.heading end
		if port == "normal" then return ctx.surfaceNormal end
		return ctx.origin
	elseif kind == "Struck" then
		return if alive(ctx.struck) then ctx.struck else nil
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
		local slot = memoryOf(ctx.player)[params.Slot]
		if port == "set" then return slot ~= nil end
		if not slot then return nil end
		if port == "entity" then return if alive(slot.entity) then slot.entity else nil end
		return slot[port]
	elseif kind == "Number" then
		return params.Value
	elseif kind == "Math" then
		return MATH[params.Op](number(input(compiled, ctx, id, "a")), number(input(compiled, ctx, id, "b")))
	elseif kind == "Func" then
		local result = FUNC[params.Op](number(input(compiled, ctx, id, "a")))
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
		local b = asPoint(input(compiled, ctx, id, "b")) or Vector3.zero
		local result = vecMath(params.Op, a, b, number(input(compiled, ctx, id, "n")))
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

-- Spends one flow step of the cast's budget; false once it's blown.
local function spend(ctx: Context): boolean
	local cast = ctx.cast
	if cast.dead then
		return false
	end
	cast.steps += 1
	if cast.steps > SpellRunes.Budget.Steps then
		cast.dead = true
		warn(`[SpellRuntime] {cast.player.Name}'s spell ran out of steps and fizzled`)
		return false
	end
	return true
end

type Pending = { remaining: number, position: Vector3, cast: CastInfo, run: () -> () }
local pending: { Pending } = {}

-- Runs `run` after `seconds` of time where `position` is (dilated: a slow
-- zone stretches the wait), within the cast's budget.
local function later(ctx: Context, seconds: number, position: Vector3, run: () -> ())
	local cast = ctx.cast
	if cast.dead or cast.player.Parent ~= Players then
		return
	end
	if seconds <= 0 then
		run()
		return
	end
	if cast.pending >= SpellRunes.Budget.Pending then
		return
	end
	cast.pending += 1
	table.insert(pending, { remaining = seconds, position = position, cast = cast, run = run })
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
			cast.pending -= 1
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
	energy: number,
	element: string?,
	nextCheck: number,
	nominal: number, -- energy this trigger would carry if nothing were split
	scale: number, -- the launching shot's energyScale
	sizeScale: number, -- the launching vessel's Size multiplier
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

-- Runs the sub-circle hanging off a trigger from eventPoint. heading is the
-- vessel's travel direction at that moment; On Impact reflects it off the
-- surface so what it fires ricochets unless aimed. The trigger's outputs
-- (Point, Surface, Struck, Pulse) are what it saw.
local function fireTrigger(compiled: any, parent: Context, triggerId: string, energy: number, element: string?, eventPoint: Vector3, heading: Vector3, normal: Vector3?, struck: any?, energyScale: number?, sizeScale: number?, flight: number?, pulse: number?)
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
	ctx.sizeScale = sizeScale or 1
	ctx.surfaceNormal = normal
	ctx.flight = flight or 0
	ctx.vars[triggerId] = {
		point = eventPoint,
		normal = normal,
		entity = if alive(struck) then struck else nil,
		pulse = pulse,
	}
	runFlow(compiled, ctx, triggerId, "out", energy, element)
end

-- Stats for one vessel after its modifiers. Evaluated once per firing, so a
-- Stream's later copies reuse the cast-time Homing lock.
local function vesselStats(compiled: any, ctx: Context, id: string): any
	local base = SpellRunes.Vessels[compiled.runes[id].rune]
	local tables = SpellRunes.ModifierTables
	local stats = {
		speed = base.Speed,
		radius = base.Radius,
		lifetime = base.Lifetime,
		range = base.Range,
		scale = base.Scale or 1,
		gravity = 0,
		bounces = 0,
		pierces = 0,
		homing = nil :: any,
		quantity = nil :: any,
		sustain = nil :: number?,
	}
	for _, modId in compiled.vessels[id].mods do
		local mod = compiled.runes[modId]
		local params = mod.params
		local level = params.Level
		local kind = mod.rune
		if kind == "Speed" and stats.speed then
			stats.speed *= tables.Speed[level]
		elseif kind == "Size" then
			stats.radius *= tables.Size[level]
			stats.scale *= tables.Size[level]
		elseif kind == "Gravity" then
			stats.gravity = tables.Gravity[level]
		elseif kind == "Bounce" then
			stats.bounces = level
		elseif kind == "Pierce" then
			stats.pierces = level
		elseif kind == "Range" then
			if stats.lifetime then stats.lifetime *= tables.Range[level] end
			if stats.range then stats.range *= tables.Range[level] end
		elseif kind == "Quantity" then
			-- over the chain's Quantity limit (SpellCompiler): one copy
			if not (compiled.noQuantity and compiled.noQuantity[id]) then
				stats.quantity = params
			end
		elseif kind == "Sustain" then
			stats.sustain = tables.Sustain[level]
		elseif kind == "Homing" then
			local lock = input(compiled, ctx, modId, "entity")
			stats.homing = {
				lock = if alive(lock) and lock ~= ctx.caster then lock else nil,
				radius = tables.HomingRadius[level],
				filter = params.Filter,
				turnRate = math.rad(tables.HomingTurn[level]),
			}
		end
	end
	return stats
end

-- Aim: whatever is wired into the vessel's Aim port, else the For Each /
-- trigger target, else the cursor (at cast time), else straight ahead.
local function aimDirection(compiled: any, ctx: Context, id: string): Vector3
	local aim = asPoint(input(compiled, ctx, id, "aim")) or defaultTarget(ctx)
	if aim and (aim - ctx.origin).Magnitude > 1e-3 then
		return (aim - ctx.origin).Unit
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
}

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
	local projectile = (if shot.vessel == "Beam" then BeamHandler.Launch else Projectile.new)({
		Origin = ctx.origin + direction * ctx.spawnOffset,
		Direction = direction,
		Speed = stats.speed,
		Radius = stats.radius,
		Lifetime = stats.lifetime,
		Gravity = stats.gravity,
		Bounces = stats.bounces,
		Restitution = 0.7,
		MaxPierces = stats.pierces,
		PierceFalloff = PIERCE_FALLOFF,
		Damage = shot.damageEnergy * shot.impact,
		Source = caster,
		-- (the caster's own barriers let their magic through)
		IgnoreInstances = { ctx.character, SpellWorld.BarrierFolder(ctx.player) },
		Filter = function(entity)
			return entity ~= caster and not entity.IsDestroyed and entity.Health > 0
		end,
		Homing = homing,
		Visualize = true,
		VisualRange = VISUAL_RANGE,
		VisualScale = stats.scale,
		Beam = if shot.vessel == "Beam" then { Length = if stats.sustain then math.max(24, stats.speed * SUSTAIN_INTERVAL * 2) else 24, ChannelId = shot.channelId } else nil,
		-- Built procedurally on the client -- see VisualModel's styled visuals.
		Visual = { Style = shot.vessel, Color = elementDef.Color, Core = elementDef.Core },
	})

	-- Reusable synchronous binding for both emitted packets and subdivisions.
	-- Each fork receives a fraction of the UNFIRED trigger/damage energy.
	local bind: (any, number, any?) -> ()
	bind = function(projectile, damageEnergy, triggerAmounts)
		local lastStruck = nil
		local boundWatches = {}
		projectile.OnHit:Connect(function(hit)
			local multiplier = projectile.DamageMultiplier
			if hit.Entity then
				lastStruck = hit.Entity
				strike(ctx, hit.Entity, projectile.Damage * multiplier, hit.Hurtbox, hit.CFrame.Position, element, damageEnergy * multiplier)
			else
				-- (someone else's barrier: it takes the hit)
				SpellWorld.DamagePart(hit.Part, projectile.Damage * multiplier)
			end
		end)
		local destroyTriggers = {}
		for _, triggerId in shot.info.triggers do
			local trigger = compiled.runes[triggerId]
			local nominal = shot.perCopy * trigger.params.Share / 100
			local watch: Watch = {
				projectile = projectile,
				compiled = compiled,
				ctx = ctx,
				trigger = triggerId,
				energy = if triggerAmounts then (triggerAmounts[triggerId] or 0) else nominal,
				element = element,
				nextCheck = 0,
				nominal = nominal,
				scale = shot.energyScale,
				sizeScale = shot.stats.scale or 1,
				pulses = 0,
			}
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
					fireTrigger(compiled, ctx, watch.trigger, watch.energy, element, result.Position, heading, result.Normal, if result.Kind == "entity" then lastStruck else nil, triggerScale(watch, watch.energy), watch.sizeScale, flight)
				elseif kind == "OnExpire" and result.Kind == nil then
					fireTrigger(compiled, ctx, watch.trigger, watch.energy, element, result.Position, heading, nil, nil, triggerScale(watch, watch.energy), watch.sizeScale, flight)
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
	bind(projectile, shot.damageEnergy, nil)
end

local function emitSustain(parent: Shot, index: number, share: number, channelId: number)
	local shot = table.clone(parent)
	shot.channelId = channelId
	shot.ctx = liveContext(shot.ctx)
	shot.perCopy *= share
	shot.damageEnergy *= share
	shot.energyScale *= share
	local directions = spreadDirections(aimDirection(shot.compiled, shot.ctx, shot.id), shot.stats.quantity)
	launch(shot, directions[index])
end

-- Explosion: damages every living entity (never the caster) in the radius,
-- full at the centre down to half at the edge, then broadcasts the blast for
-- the client-side visual. Radius = base (3) x its own Size rune x the Size of
-- the vessel that triggered it (a big fireball makes a big blast), at full
-- energy; a blast fed a split share of it (a Sustain packet's slice, a
-- subdivided beamlet) shrinks with the cube root of that share, so a pulse
-- beam's impact is a big blast while a sustained beam leaves small ones
-- wherever it hits. Centre: the At input, else the For Each entity, else
-- Here -- which at cast time is your hand, so a cast-time blast goes to the
-- cursor instead (clamped to MaxCastRange). Barriers in reach take the hit too.
local MIN_EXPLOSION_SCALE = 0.2 -- smallest radius fraction a split blast keeps

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
	local away = entity:GetPosition() - center
	away = Vector3.new(away.X, 0, away.Z)
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

local function explode(shot: Shot)
	local ctx = shot.ctx
	local base = SpellRunes.Vessels.Explosion
	local center = placement(shot.compiled, ctx, shot.id, base.MaxCastRange)
	local maxRadius = shot.stats.radius * (ctx.sizeScale or 1)
	local radius = maxRadius * math.clamp(shot.energyScale ^ (1 / 3), MIN_EXPLOSION_SCALE, 1)
	for _, entity in ChunkManager.GetEntitiesInRadius(center, radius) do
		if entity ~= ctx.caster and alive(entity) then
			local position = entity:GetPosition()
			local falloff = 1 - 0.5 * math.clamp((position - center).Magnitude / radius, 0, 1)
			local power = shot.damageEnergy * shot.impact * falloff
			strike(ctx, entity, power, "Body", position, shot.element, shot.damageEnergy * falloff)
			if power >= FLING_MIN_POWER and Entity.CanDamage(ctx.caster, entity) then
				fling(entity, center, power)
			end
		end
	end
	SpellWorld.DamageInRadius(center, radius, shot.damageEnergy * shot.impact)
	VisualOffload.Fire("SpellExplosion", {
		Position = center,
		Radius = radius,
		Color = SpellRunes.Elements[shot.element].Color,
		Power = shot.damageEnergy * shot.impact, -- centre damage; drives ExplosionVFX
		-- the struck surface, so the visual sits on walls/ceilings/slopes
		Normal = if ctx.isCast then nil else ctx.surfaceNormal,
	})
end

-- Triggers on a barrier / time field: On Timer and On Proximity are polled
-- like a projectile's, On Expire fires when it breaks or fades.
local function watchThing(compiled: any, ctx: Context, id: string, thing: any, perCopy: number, element: string?)
	local info = compiled.vessels[id]
	local onEnd = {}
	for _, triggerId in info.triggers do
		local trigger = compiled.runes[triggerId]
		local nominal = perCopy * trigger.params.Share / 100
		local watch: Watch = {
			projectile = thing,
			compiled = compiled,
			ctx = ctx,
			trigger = triggerId,
			energy = nominal,
			element = element,
			nextCheck = 0,
			nominal = nominal,
			scale = ctx.energyScale or 1,
			sizeScale = 1,
			pulses = 0,
		}
		if trigger.rune == "OnExpire" then
			table.insert(onEnd, watch)
		else
			table.insert(watches, watch)
		end
	end
	if #onEnd > 0 then
		thing.OnDestroy:Connect(function(result)
			if result.Kind == "removed" then
				return -- (its caster left)
			end
			for _, watch in onEnd do
				fireTrigger(compiled, ctx, watch.trigger, watch.energy, element, result.Position, ctx.heading, nil, nil, triggerScale(watch, watch.energy), 1, thing.Age)
			end
		end)
	end
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

-- Barrier, Time Field, Force, Blink and Body Effect: energy that isn't damage.
local function fireUtility(compiled: any, ctx: Context, id: string, energy: number, element: string?)
	local rune = compiled.runes[id]
	local params = rune.params
	local info = compiled.vessels[id]
	local size, range = SpellCompiler.ModifierScales(info.mods, compiled.runes)
	local perCopy = energy * (1 - math.min(info.modCost, 1))
	local own = perCopy * (1 - info.triggerShare) -- what the vessel itself spends
	local look = (element and SpellRunes.Elements[element]) or SpellRunes.Raw
	local kind = rune.rune
	local base = SpellRunes.Vessels[kind]

	if kind == "Barrier" then
		local at = placement(compiled, ctx, id, base.MaxCastRange)
		local facing = at - ctx.origin
		local thing = SpellWorld.CreateBarrier({
			player = ctx.player,
			character = ctx.character,
			position = at,
			facing = if Vector3.new(facing.X, 0, facing.Z).Magnitude > 0.5 then facing else ctx.heading,
			shape = params.Shape,
			size = size,
			duration = params.Duration * range,
			health = math.max(own * base.HealthPerEnergy, base.MinHealth),
			color = look.Color,
		})
		watchThing(compiled, ctx, id, thing, perCopy, element)
	elseif kind == "TimeField" then
		local at = placement(compiled, ctx, id, base.MaxCastRange)
		local thing = SpellWorld.CreateTimeField({
			player = ctx.player,
			position = at,
			radius = math.min(base.Radius + own * base.RadiusPerEnergy, base.MaxRadius) * size,
			scale = params.Scale,
			duration = params.Duration * range,
			color = look.Color,
		})
		watchThing(compiled, ctx, id, thing, perCopy, element)
	elseif kind == "Force" then
		local radius = params.Radius * size
		local targets = {}
		local parts = {}
		if radius > 0 then
			for _, entity in ChunkManager.GetEntitiesInRadius(ctx.origin, radius) do
				if entity ~= ctx.caster and alive(entity) then
					table.insert(targets, entity)
				end
			end
			parts = SpellWorld.LooseParts(ctx.origin, radius)
		else
			local target = input(compiled, ctx, id, "target")
			if not alive(target) then
				target = if wired(compiled, id, "target") then nil else defaultBody(ctx)
			end
			if target then
				table.insert(targets, target)
			end
		end
		local share = own / math.max(#targets, 1)
		local speed = math.min(share * base.SpeedPerEnergy, base.MaxSpeed)
		local along = asPoint(input(compiled, ctx, id, "dir"))
		local function directionFor(position: Vector3): Vector3
			if params.Mode == "Up" then
				return Vector3.yAxis
			elseif params.Mode == "Push" or params.Mode == "Pull" then
				-- level away from / toward Here, lifted a little so bodies leave
				-- the ground instead of being ground into it
				local away = position - ctx.origin
				local flat = Vector3.new(away.X, 0, away.Z)
				local level = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(ctx.heading.X, 0, ctx.heading.Z)
				if level.Magnitude < 1e-3 then
					return Vector3.yAxis
				end
				level = level.Unit
				return if params.Mode == "Push" then (level + Vector3.new(0, PUSH_LIFT, 0)).Unit else (-level + Vector3.new(0, PULL_LIFT, 0)).Unit
			end
			return if along and along.Magnitude > 1e-3 then along.Unit else ctx.heading
		end
		local shoved = {}
		for _, target in targets do
			SpellWorld.Push(target, directionFor(target:GetPosition()) * speed, params.Ragdoll)
			if target.Instance then
				table.insert(shoved, target.Instance)
			end
		end
		for _, part in parts do
			SpellWorld.PushPart(part, directionFor(part.Position) * speed)
		end
		SpellWorld.Visual({
			Kind = "Force",
			Position = ctx.origin,
			Radius = radius,
			Direction = directionFor(ctx.origin + ctx.heading),
			Mode = params.Mode,
			Targets = shoved,
			Color = look.Color,
		})
	elseif kind == "Blink" then
		local who = input(compiled, ctx, id, "who")
		if not alive(who) then
			who = if wired(compiled, id, "who") then nil else ctx.caster
		end
		local to = asPoint(input(compiled, ctx, id, "to")) or defaultPlace(ctx)
		local reach = math.min(own * base.StudsPerEnergy * range, base.MaxDistance)
		local from, landed = SpellWorld.Blink(who, to :: Vector3, reach, params.Momentum)
		if from and landed then
			SpellWorld.Visual({ Kind = "Blink", From = from, To = landed, Color = look.Color })
		end
	elseif kind == "Effect" then
		local target = input(compiled, ctx, id, "target")
		if not alive(target) then
			target = if wired(compiled, id, "target") then nil else defaultBody(ctx)
		end
		if target then
			SpellBody.Apply(ctx.caster, target, params.Effect, own, params.Duration * range)
		end
	end
end

local function fireVessel(compiled: any, ctx: Context, id: string, energy: number, element: string?)
	-- over a splitting limit (SpellCompiler's soft limits): fizzles
	if compiled.disabledVessels and compiled.disabledVessels[id] then
		return
	end
	local cast = ctx.cast
	cast.vessels += 1
	if cast.vessels > SpellRunes.Budget.Vessels then
		return
	end
	local vessel = compiled.runes[id].rune
	if not SpellRunes.Flying[vessel] and vessel ~= "Explosion" then
		fireUtility(compiled, ctx, id, energy, element)
		return
	end
	if not element then
		return -- (the compiler insists damaging vessels get an element)
	end
	local info = compiled.vessels[id]
	local stats = vesselStats(compiled, ctx, id)
	-- Overcharge adds copies (energy already scaled to match). A vessel with
	-- Quantity grows its own pattern; one without fans the extras out.
	local count = info.count
	local copies = ctx.copyMultiplier or 1
	if copies > 1 and vessel ~= "Explosion" then
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
	local perCopy = energy * (1 - info.modCost) / count
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
		impact = SpellRunes.Elements[element].Impact * SpellRunes.Vessels[vessel].Impact,
		energyScale = ctx.energyScale or 1,
	}
	if vessel == "Explosion" then
		explode(shot)
		return
	end
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
			})
		end
		return
	end
	for index, direction in spreadDirections(aimDirection(compiled, ctx, id), stats.quantity) do
		if stream and index > 1 then
			task.delay((index - 1) * stats.quantity.Interval, function()
				-- Re-aim each later copy from where the caster is pointing now.
				local liveShot = table.clone(shot)
				liveShot.ctx = liveContext(ctx)
				if liveShot.ctx.character.Parent and (not liveShot.ctx.caster or alive(liveShot.ctx.caster)) then
					launch(liveShot, aimDirection(compiled, liveShot.ctx, id))
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

type FlowHandler = (compiled: any, ctx: Context, id: string, params: any, energy: number, element: string?) -> ()

local FLOW: { [string]: FlowHandler } = {}

FLOW.If = function(compiled, ctx, id, _params, energy, element)
	local taken = if input(compiled, ctx, id, "cond") == true then "yes" else "no"
	runFlow(compiled, ctx, id, taken, energy, element)
end

FLOW.Divide = function(compiled, ctx, id, params, energy, element)
	local share = params.Share / 100
	runFlow(compiled, ctx, id, "a", energy * share, element)
	runFlow(compiled, ctx, id, "b", energy * (1 - share), element)
end

FLOW.Delay = function(compiled, ctx, id, _params, energy, element)
	local seconds = math.clamp(number(input(compiled, ctx, id, "seconds")), 0, 10)
	later(ctx, seconds, ctx.origin, function()
		runFlow(compiled, derive(liveContext(ctx)), id, "out", energy, element)
	end)
end

FLOW.Repeat = function(compiled, ctx, id, params, energy, element)
	local count = math.clamp(math.floor(number(input(compiled, ctx, id, "count")) + 0.5), 0, 20)
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
	local list = {}
	for _, entity in asList(input(compiled, ctx, id, "list")) do
		if alive(entity) and #list < params.Max then
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
	local function check()
		local probe = derive(liveContext(ctx))
		if input(compiled, probe, id, "cond") == true then
			runFlow(compiled, probe, id, "then", energy, element)
		elseif waited >= params.Timeout then
			runFlow(compiled, probe, id, "timeout", energy, element)
		else
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
	VisualOffload.Fire("SpellCircle", {
		Phase = "Conjure",
		Caster = ctx.character,
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
		child.spawnOffset = CONJURE_SPAWN_OFFSET
		child.vars[id] = { point = position }
		runFlow(compiled, child, id, "out", energy, element)
	end)
end

FLOW.Store = function(compiled, ctx, id, params, energy, element)
	local slots = memoryOf(ctx.player)
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
	slots[params.Slot] = entry
	runFlow(compiled, ctx, id, "out", energy, element)
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
			handler(compiled, ctx, id, rune.params, energy, element)
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
		cast = { player = request.player, started = os.clock(), steps = 0, vessels = 0, pending = 0, dead = false },
		live = request.live,
		flight = 0,
		copyMultiplier = SpellRunes.ChargeCopyMultiplier(request.charge or 1),
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
Heartbeat.Connect(function()
	local now = os.clock()
	for index = #watches, 1, -1 do
		local watch = watches[index]
		if not watch then
			continue
		end
		local projectile = watch.projectile
		local trigger = watch.compiled.runes[watch.trigger]
		if watch.energy <= 0 or projectile.Dead then
			table.remove(watches, index)
			continue
		end
		if trigger.rune == "OnTimer" then
			local pulses = math.max(trigger.params.Pulses or 1, 1)
			if projectile.Age >= trigger.params.Delay * (watch.pulses + 1) then
				local amount = watch.energy / math.max(pulses - watch.pulses, 1)
				watch.energy -= amount
				watch.pulses += 1
				local last = watch.pulses >= pulses
				if last then
					watch.energy = 0 -- do not duplicate a spent trigger when later subdividing
					table.remove(watches, index)
				end
				fireTrigger(watch.compiled, watch.ctx, watch.trigger, amount, watch.element, projectile.Position, headingOf(projectile, watch.ctx.heading), nil, nil, triggerScale(watch, amount * pulses), watch.sizeScale, projectile.Age, watch.pulses)
				if last and trigger.params.Detonate then
					projectile:Destroy({ Position = projectile.Position, Normal = Vector3.yAxis }, "detonate")
				end
			end
		elseif trigger.rune == "OnProximity" and now >= watch.nextCheck then
			watch.nextCheck = now + PROXIMITY_CHECK_INTERVAL
			local struck = nearestEntity(projectile.Position, trigger.params.Radius, trigger.params.Filter, watch.ctx.caster)
			if struck then
				table.remove(watches, index)
				local energy = watch.energy
				watch.energy = 0 -- do not duplicate a spent trigger when later subdividing
				fireTrigger(watch.compiled, watch.ctx, watch.trigger, energy, watch.element, projectile.Position, headingOf(projectile, watch.ctx.heading), nil, struck, triggerScale(watch, energy), watch.sizeScale, projectile.Age)
				if trigger.params.Detonate then
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
