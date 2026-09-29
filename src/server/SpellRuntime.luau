--!strict
--[[
	SpellRuntime.luau
	Executes a compiled spell circle (see shared/SpellCompiler.luau) on the
	server. SpellService handles the cast request, mana and cooldown; this
	module turns energy into magic.

	Flow: every Mana Well pushes its energy along its flow wire. Transforms
	set the element, If routes all of it one way, Divide splits it, and a
	Vessel gives it form: Orb and Bullet fire projectiles (Projectile.luau),
	Beam is an instant server-side ray (pierces, reflects) and Explosion an
	instant area blast; their visuals are broadcast on the SpellBeam /
	SpellExplosion channels (client/SpellEffects.luau). Quantity multiplies
	a vessel into a Fan, Ring or Stream of copies sharing the energy; each
	Stream copy re-aims from the caster's live hand/cursor (see
	CastRequest.live). Values (sensors/logic) are evaluated on demand and memoized per
	evaluation context. A context is one moment in the world: the cast
	itself, or a trigger firing (where Here is the vessel's position and
	Struck Entity is what set it off).

	Triggers reserve their Share of each copy's energy when it is fired and
	release it at most once: On Impact / On Expire ride the projectile's
	OnDestroy (or the end of a beam), On Timer / On Proximity are polled by
	one Heartbeat loop.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local Entity = require(Shared:WaitForChild("Entity"))
local VisualOffload = require(Shared:WaitForChild("VisualOffload"))
local Heartbeat = require(Shared:WaitForChild("Heartbeat"))
local SpellRunes = require(Shared:WaitForChild("SpellRunes"))
local StatusEffectSys = require(Shared:WaitForChild("StatusEffectSys"))
local Projectile = require(script.Parent:WaitForChild("Projectile"))
local ProjectileQuota = require(script.Parent:WaitForChild("ProjectileQuota"))

local SpellRuntime = {}

local CAST_SPAWN_OFFSET = 3 -- studs in front of the caster's head
local TRIGGER_SPAWN_OFFSET = 0.75 -- studs off the trigger point
local PROXIMITY_CHECK_INTERVAL = 0.05 -- real seconds between proximity scans
local VISUAL_RANGE = 800
local BEAM_MAX_SEGMENTS = 24 -- guards the beam trace loop (bounces + pierces)
local PIERCE_FALLOFF = 0.15

export type Context = {
	player: Player,
	caster: any,
	character: Model,
	origin: Vector3, -- "Here"
	cursorPoint: Vector3,
	cursorEntity: any?,
	struck: any?,
	heading: Vector3, -- direction for vessels with no aim
	focus: Vector3?, -- default aim point for triggered vessels (proximity target)
	isCast: boolean,
	spawnOffset: number,
	memo: { [string]: any },
	-- Cast time only: the caster's current (origin, cursor), for Stream copies.
	live: (() -> (Vector3?, Vector3?))?,
}

--------------------------------------------------------------------------------
-- Values
--------------------------------------------------------------------------------

local function alive(entity: any): boolean
	return typeof(entity) == "table" and not entity.IsDestroyed and (entity.Health == nil or entity.Health > 0)
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

local function matchesFilter(entity: any, filter: string): boolean
	if filter == "Any" then
		return true
	end
	return entity:HasTag(filter)
end

local function nearestEntity(from: Vector3, radius: number, filter: string, exclude: any): any?
	local best, bestDistance = nil, math.huge
	for _, entity in ChunkManager.GetEntitiesInRadius(from, radius) do
		if entity ~= exclude and alive(entity) and matchesFilter(entity, filter) then
			local distance = (entity:GetPosition() - from).Magnitude
			if distance < bestDistance then
				best, bestDistance = entity, distance
			end
		end
	end
	return best
end

local evaluate: (compiled: any, ctx: Context, id: string, port: string) -> any

-- Value arriving at `port` of rune `id`, or nil when unwired.
local function input(compiled: any, ctx: Context, id: string, port: string): any
	local links = compiled.inputs[id][port]
	local link = links and links[1]
	if not link then
		return nil
	end
	return evaluate(compiled, ctx, link.from, link.port)
end

local function number(value: any): number
	return if typeof(value) == "number" and value == value then value else 0
end

local MATH = {
	["+"] = function(a, b) return a + b end,
	["-"] = function(a, b) return a - b end,
	["×"] = function(a, b) return a * b end,
	["÷"] = function(a, b) return if b == 0 then 0 else a / b end,
	min = math.min,
	max = math.max,
}
local COMPARE = {
	["<"] = function(a, b) return a < b end,
	["≤"] = function(a, b) return a <= b end,
	["="] = function(a, b) return math.abs(a - b) < 1e-6 end,
	["≠"] = function(a, b) return math.abs(a - b) >= 1e-6 end,
	["≥"] = function(a, b) return a >= b end,
	[">"] = function(a, b) return a > b end,
}

local function compute(compiled: any, ctx: Context, id: string, port: string): any
	local rune = compiled.runes[id]
	local params = rune.params
	local kind = rune.rune
	if kind == "Caster" then
		return ctx.caster
	elseif kind == "Cursor" then
		if port == "point" then return ctx.cursorPoint end
		return if alive(ctx.cursorEntity) then ctx.cursorEntity else nil
	elseif kind == "Target" then
		-- Aim: its input, else the mouse (at cast time) / the trigger's focus.
		local point = asPoint(input(compiled, ctx, id, "point"))
		if point then return point end
		return if ctx.isCast then ctx.cursorPoint else (ctx.focus or ctx.cursorPoint)
	elseif kind == "Here" then
		return ctx.origin
	elseif kind == "Struck" then
		return if alive(ctx.struck) then ctx.struck else nil
	elseif kind == "Nearest" then
		local from = asPoint(input(compiled, ctx, id, "from")) or ctx.origin
		return nearestEntity(from, params.Radius, params.Filter, ctx.caster)
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
	elseif kind == "Number" then
		return params.Value
	elseif kind == "Math" then
		return MATH[params.Op](number(input(compiled, ctx, id, "a")), number(input(compiled, ctx, id, "b")))
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
	if not alive(target) or target == ctx.caster then
		return
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

-- Same analytic head check the projectile raycasts use (see Raycast._resolveHit).
local function hurtboxAt(entity: any, position: Vector3): string
	local head = entity:GetHeadPosition()
	if head and (position - head).Magnitude <= entity.HeadRadius then
		return "Head"
	end
	return "Body"
end

--------------------------------------------------------------------------------
-- Flow
--------------------------------------------------------------------------------

type Watch = {
	projectile: any,
	compiled: any,
	ctx: Context,
	trigger: string,
	energy: number,
	element: string,
	nextCheck: number,
}
local watches: { Watch } = {}

local runFlow: (compiled: any, ctx: Context, fromId: string, port: string, energy: number, element: string?) -> ()

local function headingOf(projectile: any, fallback: Vector3): Vector3
	local velocity = projectile.Velocity
	return if velocity.Magnitude > 1e-3 then velocity.Unit else fallback
end

-- Runs the sub-circle hanging off a trigger from eventPoint. heading is the
-- vessel's travel direction at that moment; On Impact reflects it off the
-- surface so what it fires ricochets unless aimed.
local function fireTrigger(compiled: any, parent: Context, triggerId: string, energy: number, element: string, eventPoint: Vector3, heading: Vector3, normal: Vector3?, struck: any?)
	if normal and compiled.runes[triggerId].rune == "OnImpact" then
		heading = heading - 2 * heading:Dot(normal) * normal
	end
	local ctx: Context = {
		player = parent.player,
		caster = parent.caster,
		character = parent.character,
		origin = eventPoint + (normal or Vector3.zero) * 0.5,
		cursorPoint = parent.cursorPoint,
		cursorEntity = parent.cursorEntity,
		struck = struck,
		heading = heading,
		focus = if alive(struck) then struck:GetPosition() else nil,
		isCast = false,
		spawnOffset = TRIGGER_SPAWN_OFFSET,
		memo = {},
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
			stats.quantity = params
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

-- Aim: whatever is wired into the vessel's Aim port, else the cursor (at cast
-- time) / the trigger's focus, else straight ahead.
local function aimDirection(compiled: any, ctx: Context, id: string): Vector3
	local aim = asPoint(input(compiled, ctx, id, "aim"))
	if not aim then
		aim = if ctx.isCast then ctx.cursorPoint else ctx.focus
	end
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
}

-- Orb / Bullet: one projectile with its triggers attached.
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
		Delay = 0.05,
	}
	local projectile = Projectile.new({
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
		IgnoreInstances = { ctx.character },
		Filter = function(entity)
			return entity ~= caster and not entity.IsDestroyed and entity.Health > 0
		end,
		Homing = homing,
		Visualize = true,
		VisualRange = VISUAL_RANGE,
		VisualScale = stats.scale,
		-- Built procedurally on the client -- see VisualModel's styled visuals.
		Visual = { Style = shot.vessel, Color = elementDef.Color, Core = elementDef.Core },
	})

	local lastStruck = nil
	projectile.OnHit:Connect(function(hit)
		if hit.Entity then
			lastStruck = hit.Entity
			local multiplier = projectile.DamageMultiplier
			strike(ctx, hit.Entity, projectile.Damage * multiplier, hit.Hurtbox, hit.CFrame.Position, element, shot.damageEnergy * multiplier)
		end
	end)
	local destroyTriggers = {}
	for _, triggerId in shot.info.triggers do
		local trigger = compiled.runes[triggerId]
		local watch: Watch = {
			projectile = projectile,
			compiled = compiled,
			ctx = ctx,
			trigger = triggerId,
			energy = shot.perCopy * trigger.params.Share / 100,
			element = element,
			nextCheck = 0,
		}
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
			if kind == "OnImpact" and (result.Kind == "entity" or result.Kind == "world") then
				fireTrigger(compiled, ctx, watch.trigger, watch.energy, element, result.Position, heading, result.Normal, if result.Kind == "entity" then lastStruck else nil)
			elseif kind == "OnExpire" and result.Kind == nil then
				fireTrigger(compiled, ctx, watch.trigger, watch.energy, element, result.Position, heading, nil, nil)
			end
		end
	end)
end

-- A fresh cast-time context from the caster's live hand and cursor, so each
-- Stream copy aims where you're pointing now. Values are re-evaluated too
-- (fresh memo): an Aim fed by Nearest Entity re-targets per copy.
local function liveContext(ctx: Context): Context
	if not ctx.isCast or not ctx.live then
		return ctx
	end
	local origin, cursor = ctx.live()
	local fresh = table.clone(ctx)
	fresh.origin = origin or ctx.origin
	fresh.cursorPoint = cursor or ctx.cursorPoint
	local offset = fresh.cursorPoint - fresh.origin
	fresh.heading = if offset.Magnitude > 1e-3 then offset.Unit else ctx.heading
	fresh.memo = {}
	return fresh
end

-- Explosion: damages every living entity (never the caster) in the radius,
-- full at the centre down to half at the edge, then broadcasts the blast for
-- the client-side visual. Centre: the At input, else Here -- which at cast
-- time is your hand, so a cast-time blast goes to the cursor instead
-- (clamped to MaxCastRange).
local function explode(shot: Shot)
	local ctx, compiled = shot.ctx, shot.compiled
	local base = SpellRunes.Vessels.Explosion
	local center = asPoint(input(compiled, ctx, shot.id, "aim"))
	if not center then
		center = if ctx.isCast then ctx.cursorPoint else ctx.origin
	end
	if ctx.isCast then
		local offset = center - ctx.origin
		if offset.Magnitude > base.MaxCastRange then
			center = ctx.origin + offset.Unit * base.MaxCastRange
		end
	end
	local radius = shot.stats.radius
	for _, entity in ChunkManager.GetEntitiesInRadius(center, radius) do
		if entity ~= ctx.caster and alive(entity) then
			local position = entity:GetPosition()
			local falloff = 1 - 0.5 * math.clamp((position - center).Magnitude / radius, 0, 1)
			strike(ctx, entity, shot.damageEnergy * shot.impact * falloff, "Body", position, shot.element, shot.damageEnergy * falloff)
		end
	end
	VisualOffload.Fire("SpellExplosion", {
		Position = center,
		Radius = radius,
		Color = SpellRunes.Elements[shot.element].Color,
	})
end

-- Beam: an instant spherecast trace. Entities it passes take damage (Pierce
-- lets it continue, losing 15% each time); walls stop it unless Bounce
-- reflects it. The traced path is broadcast for the client to draw.
local function fireBeam(shot: Shot, direction: Vector3)
	local ctx, stats, element, compiled = shot.ctx, shot.stats, shot.element, shot.compiled
	local elementDef = SpellRunes.Elements[element]
	if stats.homing then
		local target = stats.homing.lock
			or nearestEntity(ctx.origin, stats.homing.radius, stats.homing.filter, ctx.caster)
		if alive(target) then
			local toTarget = target:GetPosition() - ctx.origin
			-- Only snap onto targets in front of the aim, never behind the caster.
			if toTarget.Magnitude > 1e-3 and toTarget.Unit:Dot(direction) > 0.2 then
				direction = toTarget.Unit
			end
		end
	end

	local ignore = { ctx.character }
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true

	local position = ctx.origin + direction * math.min(ctx.spawnOffset, 1.5)
	local points = { position }
	local heading = direction
	local remaining = stats.range
	local bouncesLeft, piercesLeft = stats.bounces, stats.pierces
	local multiplier = 1
	local stopped, stopNormal, struck = false, nil, nil
	local struckSet = {}
	for _ = 1, BEAM_MAX_SEGMENTS do
		if remaining <= 0.05 then break end
		local result = workspace:Spherecast(position, stats.radius, heading * remaining, params)
		if not result then
			position += heading * remaining
			break
		end
		remaining -= (result.Position - position).Magnitude
		position = result.Position
		local entity = Entity.Get(result.Instance)
		if entity and (entity == ctx.caster or struckSet[entity] or not alive(entity)) then
			-- Not a valid target: let the beam pass through it.
			table.insert(ignore, entity.Instance or result.Instance)
			params.FilterDescendantsInstances = ignore
		elseif entity then
			struckSet[entity] = true
			strike(ctx, entity, shot.damageEnergy * shot.impact * multiplier, hurtboxAt(entity, result.Position), result.Position, element, shot.damageEnergy * multiplier)
			if piercesLeft > 0 then
				piercesLeft -= 1
				multiplier *= 1 - PIERCE_FALLOFF
				table.insert(ignore, entity.Instance or result.Instance)
				params.FilterDescendantsInstances = ignore
			else
				stopped, stopNormal, struck = true, result.Normal, entity
				break
			end
		elseif bouncesLeft > 0 then
			bouncesLeft -= 1
			table.insert(points, position)
			heading = heading - 2 * heading:Dot(result.Normal) * result.Normal
			position += result.Normal * 0.05
		else
			stopped, stopNormal = true, result.Normal
			break
		end
	end
	table.insert(points, position)

	VisualOffload.Fire("SpellBeam", {
		Points = points,
		Width = stats.radius * 2,
		Color = elementDef.Color,
		Core = elementDef.Core,
		Normal = stopNormal,
		Kind = if struck then "entity" elseif stopped then "world" else nil,
	})

	for _, triggerId in shot.info.triggers do
		local trigger = compiled.runes[triggerId]
		local energy = shot.perCopy * trigger.params.Share / 100
		if trigger.rune == "OnImpact" and stopped then
			fireTrigger(compiled, ctx, triggerId, energy, element, position, heading, stopNormal, struck)
		elseif trigger.rune == "OnExpire" and not stopped then
			fireTrigger(compiled, ctx, triggerId, energy, element, position, heading, nil, nil)
		end
	end
end

local function fireVessel(compiled: any, ctx: Context, id: string, energy: number, element: string)
	local info = compiled.vessels[id]
	local vessel = compiled.runes[id].rune
	local stats = vesselStats(compiled, ctx, id)
	local perCopy = energy * (1 - info.modCost) / info.count
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
	}
	if vessel == "Explosion" then
		explode(shot)
		return
	end
	local fire = if vessel == "Beam" then fireBeam else launch
	local stream = stats.quantity and stats.quantity.Pattern == "Stream"
	for index, direction in spreadDirections(aimDirection(compiled, ctx, id), stats.quantity) do
		if stream and index > 1 then
			task.delay((index - 1) * stats.quantity.Interval, function()
				-- Re-aim each later copy from where the caster is pointing now.
				local liveShot = table.clone(shot)
				liveShot.ctx = liveContext(ctx)
				fire(liveShot, aimDirection(compiled, liveShot.ctx, id))
			end)
		else
			fire(shot, direction)
		end
	end
end

runFlow = function(compiled: any, ctx: Context, fromId: string, port: string, energy: number, element: string?)
	local links = compiled.outputs[fromId][port]
	local link = links and links[1]
	if not link or energy <= 0 then
		return -- an unwired flow output fizzles
	end
	local id = link.to
	local rune = compiled.runes[id]
	local def = SpellRunes.Runes[rune.rune]
	if def.Element then
		runFlow(compiled, ctx, id, "out", energy, def.Element)
	elseif rune.rune == "If" then
		local taken = if input(compiled, ctx, id, "cond") == true then "yes" else "no"
		runFlow(compiled, ctx, id, taken, energy, element)
	elseif rune.rune == "Divide" then
		local share = rune.params.Share / 100
		runFlow(compiled, ctx, id, "a", energy * share, element)
		runFlow(compiled, ctx, id, "b", energy * (1 - share), element)
	elseif def.Vessel and element then
		fireVessel(compiled, ctx, id, energy, element)
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
}

-- Runs every Mana Well's flow. Mana is charged by the caller.
function SpellRuntime.Cast(compiled: any, request: CastRequest)
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
		isCast = true,
		spawnOffset = CAST_SPAWN_OFFSET,
		memo = {},
		live = request.live,
	}
	for _, rootId in compiled.manaRoots do
		runFlow(compiled, ctx, rootId, "out", compiled.runes[rootId].params.Amount, nil)
	end
end

-- Timer / proximity triggers. Age is the projectile's own dilated clock, so a
-- timer inside a slow zone burns slower, like everything else.
Heartbeat.Connect(function()
	local now = os.clock()
	for index = #watches, 1, -1 do
		local watch = watches[index]
		local projectile = watch.projectile
		local trigger = watch.compiled.runes[watch.trigger]
		local fired, struck = false, nil
		if projectile.Dead then
			table.remove(watches, index)
			continue
		end
		if trigger.rune == "OnTimer" then
			fired = projectile.Age >= trigger.params.Delay
		elseif trigger.rune == "OnProximity" and now >= watch.nextCheck then
			watch.nextCheck = now + PROXIMITY_CHECK_INTERVAL
			struck = nearestEntity(projectile.Position, trigger.params.Radius, trigger.params.Filter, watch.ctx.caster)
			fired = struck ~= nil
		end
		if fired then
			table.remove(watches, index)
			fireTrigger(watch.compiled, watch.ctx, watch.trigger, watch.energy, watch.element, projectile.Position, headingOf(projectile, watch.ctx.heading), nil, struck)
			if trigger.params.Detonate then
				projectile:Destroy({ Position = projectile.Position, Normal = Vector3.yAxis }, "detonate")
			end
		end
	end
end, { Name = "SpellRuntime.Triggers", Priority = 6 })

return SpellRuntime
