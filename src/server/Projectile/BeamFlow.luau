--!strict
--[[
	Projectile/BeamFlow.luau
	Sustained beams as continuous material. No beamlets.

	A beam is an ordered list of points, oldest (the front) to newest (the
	caster's end). Material joins each point to the next older one unless
	the newer point says Gap. Every bit of material left the caster at some
	moment tau and flies at the beam's speed; a point carries the tau of the
	material at it.

	 - Free points move with the material (velocity + constant
	   acceleration, chunk dilation). The caster emits one wherever the aim
	   turned (BeamChain's channel skips the rest), so a steady beam is two
	   points however long it is, and a sweep keeps its curve.
	 - The Source point is the caster's end while the channel runs; when it
	   stops, it becomes the free back end of the beam.
	 - Pinned points sit on surfaces. Each frame the beam is cast from the
	   point behind toward where its material would be had nothing stopped
	   it -- a cut or a pass-through keeps a ghost of the material it took
	   in flying on past the surface; a corner mirrors the reflected side
	   back through it -- so a pinned point slides wherever that line meets
	   the surface, and lets go (becomes free, where the material then is)
	   once it doesn't:
	     Cut     the beam runs into something that stops it. Material
	             reaching it is absorbed; the next older point is the free
	             back end of whatever got through before (Gap between them).
	     Corner  it bounces: material reaching it turns (the points past it
	             are mirrored), so it bends the beam without making another.
	     In/Out  it passes through (pierce, penetration): material between
	             them is inside the thing.
	   Each frame the beam is cast from the caster's end toward its front,
	   one cast per straight leg. Where a leg enters something, one more
	   cast from the far side against only that thing finds where it comes
	   out, and casting carries on from there -- so sweeping across two
	   objects leaves a middle piece between them.

	Damage and triggers: every packet the channel fires is a ticket -- its
	energy and SpellRuntime's trigger binding (bound only when needed) --
	at the tau in the middle of the material it was emitted with. A ticket
	fires exactly as its packet would have: when its material is absorbed
	(OnHit + OnDestroy entity/world: damage, On Impact), passes through
	something (OnHit, pierce falloff), bounces (OnHit), or runs out
	(OnDestroy, On Expire; or just gives its quota back).

	Homing beams and positional triggers (On Timer / On Proximity) need
	every bit of material's own path: those stay on BeamChain's packets.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local VisualOffload = require(Shared:WaitForChild("VisualOffload"))
local SafeMath = require(Shared:WaitForChild("SafeMath"))
local Entity = require(Shared:WaitForChild("Entity"))
local ProjectileShared = Shared:WaitForChild("Projectile")
local Planner = require(ProjectileShared:WaitForChild("StepPlanner"))
local BeamWire = require(ProjectileShared:WaitForChild("BeamWire"))

local Raycast = require(script.Parent.Raycast)
local Profile = require(script.Parent.Profile)

local Kind, FlowOp, FlowFlag, Section, DeathKind =
	BeamWire.AnchorKind, BeamWire.FlowOp, BeamWire.FlowFlag, BeamWire.Section, BeamWire.Death
local FREE, SOURCE, CUT, CORNER, IN, OUT = Kind.Free, Kind.Source, Kind.Cut, Kind.Corner, Kind.In, Kind.Out
local U8, U32, F32, F64, V3 = BeamWire.U8, BeamWire.U32, BeamWire.F32, BeamWire.F64, BeamWire.V3

local Flow = {}

-- How far past a pinned point its recast looks (a surface sliding away from
-- the beam is followed this far before the point lets go).
local PIN_REACH = 2
-- A pinned point's position is re-sent once it moves this far.
local PIN_RESEND = 0.1
-- Casts are cut at this length (shape casts stop at 1024).
local MAX_CAST = 1000
-- Where a cast resumes past an exit (so it doesn't find the same surface).
local EXIT_STEP = 0.05
-- Cuts at most this many points into a beam per frame (a pathological
-- crowd of thin things).
local MAX_CONTACTS = 64

local function pinned(kind: number): boolean
	return kind == CUT or kind == CORNER or kind == IN or kind == OUT
end

local function reflect(v: Vector3, normal: Vector3): Vector3
	return v - 2 * v:Dot(normal) * normal
end

--------------------------------------------------------------------------------
-- Beams
--------------------------------------------------------------------------------

local flows: { any } = {}
local stats = { Beams = 0, Points = 0, Tickets = 0, Casts = 0, Contacts = 0 }

local function newPoint(flow: any, kind: number, pos: Vector3, vel: Vector3, tau: number, age: number): any
	local id = flow.nextId
	flow.nextId += 1
	return { id = id, kind = kind, pos = pos, vel = vel, tau = tau, age = age, gap = false, Dead = false }
end

local function insertAt(flow: any, index: number, point: any)
	table.insert(flow.points, index, point)
end

local function removeAt(flow: any, index: number)
	local point = table.remove(flow.points, index)
	if point then
		point.Dead = true
		if point._rep then
			table.insert(flow.removed, point.id)
		end
	end
end

local function dirty(point: any)
	point._dirty = true
end

-- Material at `position` on the leg from `newer` to `older`.
local function materialAt(newer: any, older: any, position: Vector3): (number, Vector3, number)
	local offset = older.pos - newer.pos
	local lengthSq = offset:Dot(offset)
	local t = if lengthSq > 1e-8 then math.clamp((position - newer.pos):Dot(offset) / lengthSq, 0, 1) else 0
	return newer.tau + (older.tau - newer.tau) * t, newer.vel:Lerp(older.vel, t), newer.age + (older.age - newer.age) * t
end

local function sourceScale(flow: any): number
	local source = flow.sourceEntity
	return SafeMath.number(source and source.TimeScale, 1, 0)
end

function Flow.New(chain: any, settings: any): any
	local header = chain.header
	local flow = {
		chain = chain,
		id = chain.id,
		points = {},
		tickets = {},
		removed = {},
		events = {},
		impacts = {},
		observers = {},
		nextId = 1,
		clock = 0,
		lastLaunchTau = nil :: number?,
		radius = settings.Radius,
		speed = settings.Speed,
		lifetime = settings.Lifetime,
		accel = header.gravity,
		bounces = settings.Bounces or 0,
		restitution = settings.Restitution or 1,
		penetration = settings.Penetration or 0,
		pierces = settings.MaxPierces or 0,
		falloff = settings.PierceFalloff or 0,
		filter = settings.Filter,
		sourceEntity = settings.Source,
		rayParams = settings._rayParams or Raycast.buildRayParams(settings.Source, settings.IgnoreInstances),
		visualize = settings.Visualize,
		visualRange = settings.VisualRange or 800,
		scale = 1,
		header = header,
		source = nil :: any,
		finished = false,
	}
	flow.proxy = { Radius = flow.radius, _rayParams = flow.rayParams }
	table.insert(flows, flow)
	return flow
end

--------------------------------------------------------------------------------
-- Tickets (a packet's energy and triggers)
--------------------------------------------------------------------------------

local Event = {}
Event.__index = Event

function Event.Connect(self: any, fn: (any) -> ())
	table.insert(self, fn)
	return {
		Connected = true,
		Disconnect = function(connection)
			connection.Connected = false
			local index = table.find(self, fn)
			if index then
				table.remove(self, index)
			end
		end,
	}
end

function Event.Fire(self: any, info: any)
	for index = 1, #self do
		local fn = self[index]
		if fn then
			fn(info)
		end
	end
end

local Packet = {}
Packet.__index = Packet
function Packet.Destroy(_self: any) end
function Packet.SetTimeScale(_self: any) end

-- The projectile-shaped stand-in SpellRuntime's binding expects, made the
-- first time the ticket's material does something.
local function bound(flow: any, ticket: any, position: Vector3): any
	local packet = ticket.packet
	if not packet then
		packet = setmetatable({
			Damage = ticket.damage,
			DamageMultiplier = 1,
			Age = 0,
			Velocity = ticket.velocity,
			Position = position,
			Dead = false,
			Source = flow.sourceEntity,
		}, Packet)
		packet.OnHit = setmetatable({}, Event)
		packet.OnDestroy = setmetatable({}, Event)
		ticket.packet = packet
		local bind = ticket.bind
		ticket.bind, ticket.discard = nil, nil
		if bind then
			bind(packet)
		end
	end
	packet.Position = position
	packet.Age = math.max(flow.clock - ticket.tau, 0)
	return packet
end

local function hitInfo(position: Vector3, normal: Vector3, part: Instance?, entity: any?): any
	local hurtbox = nil
	if entity then
		hurtbox = "Body"
		local head = entity:GetHeadPosition()
		if head and (position - head).Magnitude <= entity.HeadRadius then
			hurtbox = "Head"
		end
	end
	return Raycast.buildHitInfo({ Position = position, Normal = normal, Instance = part, Distance = 0 } :: any, entity,
		hurtbox)
end

-- The ticket is spent: its packet "died" with `kind` (nil: ran out).
local function finish(flow: any, ticket: any, position: Vector3, normal: Vector3, kind: string?)
	ticket.done = true
	if not ticket.packet and kind == nil and not flow.chain.expireTriggers then
		local discard = ticket.discard
		ticket.bind, ticket.discard = nil, nil
		if discard then
			discard() -- (nothing to fire: just its quota slot back)
		end
		return
	end
	local packet = bound(flow, ticket, position)
	packet.Dead = true
	packet.OnDestroy:Fire({ Position = position, Normal = normal, Kind = kind })
end

-- Applies this frame's events to the tickets whose tau they cover.
local function settleTickets(flow: any)
	local tickets = flow.tickets
	if #tickets == 0 then
		table.clear(flow.events)
		return
	end
	for _, event in flow.events do
		local lo, hi = event.lo, event.hi
		if not (hi > lo) then
			continue
		end
		for _, ticket in tickets do
			local tau = ticket.tau
			if ticket.done or tau <= lo or tau > hi then
				continue
			end
			local position, normal = event.pos, event.normal
			if event.kind == "absorb" then
				local packet = bound(flow, ticket, position)
				packet.OnHit:Fire(hitInfo(position, normal, event.part, event.entity))
				finish(flow, ticket, position, normal, if event.entity then "entity" else "world")
			elseif event.kind == "pierce" then
				local seen = ticket.passed
				if not seen then
					seen = {}
					ticket.passed = seen
				end
				if not seen[event.entity] then
					seen[event.entity] = true
					local packet = bound(flow, ticket, position)
					packet.OnHit:Fire(hitInfo(position, normal, event.part, event.entity))
					packet.DamageMultiplier *= 1 - flow.falloff
				end
			elseif event.kind == "pass" or event.kind == "bounce" then
				local packet = bound(flow, ticket, position)
				packet.OnHit:Fire(hitInfo(position, normal, event.part, nil))
			end
		end
	end
	table.clear(flow.events)
	-- spent tickets out
	local kept = 0
	for index = 1, #tickets do
		local ticket = tickets[index]
		if not ticket.done then
			kept += 1
			tickets[kept] = ticket
		end
	end
	for index = kept + 1, #tickets do
		tickets[index] = nil
	end
end

-- Tickets whose material is older than the beam's front ran out.
local function expireTickets(flow: any, frontTau: number?, position: Vector3?)
	for _, ticket in flow.tickets do
		if not ticket.done and (frontTau == nil or ticket.tau < frontTau) then
			finish(flow, ticket, position or ticket.origin, Vector3.yAxis, nil)
		end
	end
end

--------------------------------------------------------------------------------
-- Launch (one per packet the channel fires)
--------------------------------------------------------------------------------

-- `settings`: the packet's normalized config; `deferred`: SpellRuntime's
-- binding { Bind, Discard }. Adds a free point where the aim turned and a
-- ticket for the material emitted since the last launch.
function Flow.Launch(flow: any, settings: any, deferred: any): any
	local clock = flow.clock
	local origin = settings.Origin
	local velocity = settings.Direction * settings.Speed
	local points = flow.points
	local source = flow.source
	if not source then
		source = newPoint(flow, SOURCE, origin, velocity, clock, 0)
		table.insert(points, source)
		flow.source = source
	end
	-- the knot sits just older than the source (the source stays newest)
	local knot = newPoint(flow, FREE, origin, velocity, clock, 0)
	local index = table.find(points, source) or (#points + 1)
	insertAt(flow, index, knot)
	source.pos, source.vel, source.tau, source.age = origin, velocity, clock, 0
	dirty(source)
	local from = flow.lastLaunchTau or clock
	flow.lastLaunchTau = clock
	table.insert(flow.tickets, {
		tau = (from + clock) * .5,
		damage = settings.Damage or 0,
		velocity = velocity,
		origin = origin,
		bind = deferred and deferred.Bind,
		discard = deferred and deferred.Discard,
	})
	return knot
end

-- The caster's end follows the live aim between launches.
function Flow.Aim(flow: any, origin: Vector3, direction: Vector3)
	local source = flow.source
	if source and source.kind == SOURCE then
		source.pos, source.vel = origin, direction * flow.speed
	end
end

-- The channel stopped: its end becomes the free back of the beam.
function Flow.Close(flow: any)
	local source = flow.source
	if source and source.kind == SOURCE then
		source.kind = FREE
		dirty(source)
	end
	flow.source = nil
	flow.closed = true
end

--------------------------------------------------------------------------------
-- Casting
--------------------------------------------------------------------------------

local includeParams: { [Instance]: RaycastParams } = setmetatable({}, { __mode = "k" }) :: any

local function only(target: Instance): RaycastParams
	local params = includeParams[target]
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { target }
		includeParams[target] = params
	end
	return params
end

-- First thing the beam's body meets from `from` along `direction` within
-- `length`: (distance, contact) or nil.
local function cast(flow: any, from: Vector3, direction: Vector3, length: number): (number?, any?)
	local traveled = 0
	while traveled < length - 1e-4 do
		local distance = math.min(length - traveled, MAX_CAST)
		stats.Casts += 1
		local contact = Raycast.castMovement(flow.proxy, from + direction * traveled, direction * distance)
		if contact then
			return traveled + (contact.Distance or 0), contact
		end
		traveled += distance
	end
	return nil, nil
end

-- What a contact belongs to for "is it the same thing": its entity's
-- model, else the part.
local function targetOf(part: Instance): (Instance, any?)
	local entity = Entity.Get(part)
	if entity and entity.Instance then
		return entity.Instance, entity
	end
	return part, nil
end

-- Where the run of points older than `index` (from `entry` on) comes back out
-- of `target`: (index of the older point of the leg it's on, point), or nil
-- when it never does before the run ends.
local function exitOf(flow: any, index: number, entry: Vector3, target: Instance): (number?, Vector3?)
	local points = flow.points
	local params = only(target)
	local newer = entry
	local k = index
	while k >= 1 do
		local older = points[k].pos
		local offset = newer - older
		local length = offset.Magnitude
		if length > 1e-4 then
			stats.Casts += 1
			local result = workspace:Raycast(older, offset.Unit * math.min(length, MAX_CAST), params)
			if result then
				return k, older + offset.Unit * result.Distance
			end
		end
		if k == 1 or points[k].gap then
			return nil, nil
		end
		newer = older
		k -= 1
	end
	return nil, nil
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function event(flow: any, kind: string, lo: number, hi: number, pos: Vector3, normal: Vector3, part: Instance?,
	entity: any?)
	table.insert(flow.events, { kind = kind, lo = lo, hi = hi, pos = pos, normal = normal, part = part, entity = entity })
end

-- Material that flowed through a pinned point since last frame.
local function flowedThrough(flow: any, point: any)
	local previous = point.prevTau or point.tau
	if point.tau > previous then
		local kind = if point.kind == CUT then "absorb"
			elseif point.kind == CORNER then "bounce"
			elseif point.passKind == "pierce" then "pierce"
			elseif point.passKind == "penetrate" then "pass"
			else nil
		if kind then
			event(flow, kind, previous, point.tau, point.pos, point.normal or Vector3.yAxis, point.part, point.entity)
		end
	end
	point.prevTau = point.tau
end

local function mirror(position: Vector3, planePoint: Vector3, normal: Vector3): Vector3
	return position - 2 * (position - planePoint):Dot(normal) * normal
end

-- The material just past pinned point `b` as if nothing had stopped it:
-- (position, velocity, tau), or nil.
local function beyond(flow: any, b: any, older: any?): (Vector3?, Vector3?, number?)
	if older and not b.gap then
		if b.kind == CORNER then
			return mirror(older.pos, b.pos, b.normal), reflect(older.vel, b.normal), older.tau
		elseif b.kind == IN and older.kind == FREE then
			return older.pos, older.vel, older.tau -- (the material inside)
		end
	end
	local ghost = b.ghost
	if ghost then
		return ghost.pos, ghost.vel, ghost.tau
	end
	return nil, nil, nil
end

-- A frozen copy of material state that keeps flying (see `beyond`).
local function ghostOf(pos: Vector3, vel: Vector3, tau: number): any
	return { pos = pos, vel = vel, tau = tau }
end

-- A free point that flowed past the pinned point ahead of it this frame:
-- absorbed (cut), turned (corner), or now on the other side (in / out).
local function flowPast(flow: any)
	local points = flow.points
	local index = 2
	local guard = 0
	while index <= #points and guard < 4096 do
		guard += 1
		local x, y = points[index], points[index - 1]
		if x.kind == FREE and not x.gap and pinned(y.kind) then
			local speed = x.vel.Magnitude
			if speed > 1e-4 and (x.pos - y.pos):Dot(x.vel / speed) > 0 then
				if y.kind == CUT then
					-- absorbed; it's now the material the cut aims along
					y.ghost = ghostOf(x.pos, x.vel, x.tau)
					removeAt(flow, index)
					continue
				end
				if y.kind == CORNER then
					local normal = y.normal
					x.pos = x.pos - 2 * (x.pos - y.pos):Dot(normal) * normal
					x.vel = reflect(x.vel, normal) * flow.restitution
				elseif y.kind == OUT and y.entry then
					-- out the far side: the entry now aims along it
					y.entry.ghost = ghostOf(x.pos, x.vel, x.tau)
				end
				points[index], points[index - 1] = y, x
				x._reordered, y._reordered = true, true
				dirty(x)
				index = math.max(index - 1, 2)
				continue
			end
		end
		index += 1
	end
end

-- Lets go of pinned point `index` (its surface is gone from the beam).
local function release(flow: any, index: number)
	local points = flow.points
	local point = points[index]
	local newer = points[index + 1]
	local incoming = if newer then newer.vel else point.vel
	-- Where its material is now: along the line from the point behind to
	-- the material beyond, at its tau (not stuck where it last touched).
	local farPos, farVel, farTau = beyond(flow, point, points[index - 1])
	if newer and farPos and farVel and farTau and newer.tau ~= farTau then
		local t = math.clamp((newer.tau - point.tau) / (newer.tau - farTau), 0, 1)
		point.pos = newer.pos:Lerp(farPos, t)
		incoming = newer.vel:Lerp(farVel, t)
	end
	point.ghost = nil
	if point.kind == CUT then
		point.kind, point.vel = FREE, incoming
	elseif point.kind == CORNER then
		-- the reflected material's back end, and the incoming beam's new front
		-- (nothing between them: they part ways)
		point.kind, point.vel = FREE, reflect(incoming, point.normal) * flow.restitution
		point.marker = "bounce"
		local front = newPoint(flow, FREE, point.pos, incoming, point.tau + 1e-6, point.age)
		front.gap = true
		insertAt(flow, index + 1, front)
	elseif point.kind == IN then
		local out = point.pair
		removeAt(flow, index)
		if out and not out.Dead then
			out.kind = FREE
			out.vel = incoming
			dirty(out)
		end
		return
	elseif point.kind == OUT then
		point.kind, point.vel = FREE, incoming
	end
	point.age = math.max(flow.clock - point.tau, 0)
	dirty(point)
end

-- Material state just older than point `point`: what it has passed.
local function note(state: any, point: any, frame: number)
	if point._noted == frame then
		return
	end
	point._noted = frame
	local marker = point.marker
	if marker == "pierce" then
		state.pierces += 1
		if point.entity then
			state.passed[point.entity] = true
		end
	elseif marker == "penetrate" then
		state.penetration += point.thickness or 0
	elseif marker == "bounce" or point.kind == CORNER then
		state.bounces += 1
	end
end

-- The lowest tau in the run of points from `index` down to its front.
local function runFront(points: { any }, index: number): (number, number)
	local lowest, k = math.huge, index
	while k >= 1 do
		lowest = math.min(lowest, points[k].tau)
		if k == 1 or points[k].gap then
			break
		end
		k -= 1
	end
	return lowest, k
end

-- The beam met something on the leg from points[index] to points[index - 1]
-- at `distance` along `direction`. Cuts / bends / passes it there; returns
-- the index to carry on from.
local function contactAt(flow: any, index: number, distance: number, direction: Vector3, contact: any, state: any): number
	local points = flow.points
	local a, b = points[index], points[index - 1]
	stats.Contacts += 1
	local position = a.pos + direction * distance
	local tau, vel, age = materialAt(a, b, position)
	local part = contact.Instance
	local target, entity = targetOf(part)
	local normal = SafeMath.unit(contact.Normal, -direction)
	local impactKind = if entity then DeathKind.Entity else DeathKind.World

	-- Where it comes back out, and the material there (on the leg the exit
	-- is on: from `position` itself, or from the point that leg starts at).
	local exitIndex, exitPoint = exitOf(flow, index - 1, position, target)
	local exitTau, exitVel, exitAge, exitDirection = 0, vel, age, direction
	if exitIndex and exitPoint then
		local older = points[exitIndex]
		local newer = if exitIndex == index - 1 then { pos = position, tau = tau, vel = vel, age = age } else points[exitIndex + 1]
		exitTau, exitVel, exitAge = materialAt(newer, older, exitPoint)
		local leg = older.pos - newer.pos
		if leg.Magnitude > 1e-4 then
			exitDirection = leg.Unit
		end
	end

	local reaction
	if entity then
		local wanted = entity ~= flow.sourceEntity and (not flow.filter or flow.filter(entity))
		reaction = if not wanted or state.passed[entity] then "ghost"
			elseif state.pierces < flow.pierces then "pierce"
			else "cut"
	else
		local thickness = if exitPoint then (exitPoint - position).Magnitude else math.huge
		reaction = if flow.penetration - state.penetration >= thickness then "penetrate"
			elseif state.bounces < flow.bounces then "bounce"
			else "cut"
	end

	-- What keeps flying past the surface, for re-aiming the pinned point:
	-- the material at the exit, else the far end of this leg. (A cut's ghost
	-- then moves on to each point the surface takes in: see flowPast.)
	local ghost = if exitPoint then ghostOf(exitPoint, exitVel, exitTau) else ghostOf(b.pos, b.vel, b.tau)

	if reaction == "bounce" then
		local corner = newPoint(flow, CORNER, position, vel, tau, age)
		corner.normal, corner.part, corner.prevTau, corner.plane = normal, part, tau, position
		insertAt(flow, index, corner)
		-- material already past the surface turns back out of it
		local lowest = tau
		local k = index - 1
		while k >= 1 do
			local p = points[k]
			if (p.pos - position):Dot(normal) < 0 then
				p.pos = p.pos - 2 * (p.pos - position):Dot(normal) * normal
				p.vel = reflect(p.vel, normal) * flow.restitution
				lowest = math.min(lowest, p.tau)
				dirty(p)
			end
			if k == 1 or p.gap then
				break
			end
			k -= 1
		end
		event(flow, "bounce", lowest - 1e-6, tau, position, normal, part, nil)
		table.insert(flow.impacts, { position, normal, DeathKind.World })
		return index -- (next: the corner's leg)
	end

	if reaction == "cut" then
		local cut = newPoint(flow, CUT, position, vel, tau, age)
		cut.normal, cut.part, cut.entity, cut.prevTau, cut.ghost = normal, part, entity, tau, ghost
		table.insert(flow.impacts, { position, normal, impactKind })
		if exitIndex and exitPoint then
			-- the points between the entry and the exit's leg are inside it
			for k = index - 1, exitIndex + 1, -1 do
				removeAt(flow, k)
			end
			local back = newPoint(flow, FREE, exitPoint + exitDirection * EXIT_STEP, exitVel, exitTau, exitAge)
			insertAt(flow, exitIndex + 1, back) -- (the older piece's new back end)
			insertAt(flow, exitIndex + 2, cut)
			cut.gap = true
			event(flow, "absorb", exitTau, tau, position, normal, part, entity)
			return exitIndex + 1
		end
		-- never comes out: everything older in this run is inside
		local lowest, front = runFront(points, index - 1)
		for k = index - 1, front, -1 do
			removeAt(flow, k)
		end
		insertAt(flow, front, cut)
		cut.gap = front > 1
		event(flow, "absorb", lowest - 1e-6, tau, position, normal, part, entity)
		return front
	end

	-- passes through (pierce / penetrate / ghost: something it ignores)
	local entry = newPoint(flow, IN, position, vel, tau, age)
	entry.normal, entry.part, entry.entity, entry.prevTau, entry.passKind = normal, part, entity, tau, reaction
	entry.ghost = ghost
	local eventKind = if reaction == "pierce" then "pierce" elseif reaction == "penetrate" then "pass" else nil
	insertAt(flow, index, entry)
	if not (exitIndex and exitPoint) then
		-- its front is still inside: the exit appears once material leaves
		if eventKind then
			local lowest = runFront(points, index - 1)
			event(flow, eventKind, lowest - 1e-6, tau, position, normal, part, entity)
		end
		return index - 1
	end
	local out = newPoint(flow, OUT, exitPoint, exitVel, exitTau, exitAge)
	out.part, out.entity, out.marker, out.normal = part, entity, reaction, -exitDirection
	out.thickness = (exitPoint - position).Magnitude
	insertAt(flow, exitIndex + 1, out)
	entry.pair, out.entry = out, entry
	if eventKind then
		event(flow, eventKind, exitTau, tau, position, normal, part, entity)
	end
	return exitIndex + 1
end

-- Re-finds a pass-through's exit: back along the line from its ghost
-- (the material beyond) toward `from`, against only what it passes through.
local function reexit(flow: any, entry: any, from: Vector3)
	local out = entry.pair
	if not out or out.Dead then
		return
	end
	local points = flow.points
	local outIndex = table.find(points, out)
	local past = outIndex and outIndex > 1 and not out.gap and points[outIndex - 1] or nil
	local start = if past then past.pos elseif entry.ghost then entry.ghost.pos else nil
	if not start then
		return
	end
	local offset = from - start
	local length = offset.Magnitude
	if length < 1e-4 then
		return
	end
	stats.Casts += 1
	local result = workspace:Raycast(start, offset.Unit * math.min(length, MAX_CAST), only(targetOf(entry.part)))
	if result then
		local point = start + offset.Unit * result.Distance
		out.pos = point
		out.thickness = (point - entry.pos).Magnitude
	end
end

local frameNumber = 0

local function collide(flow: any)
	frameNumber += 1
	local points = flow.points
	local state = { pierces = 0, penetration = 0, bounces = 0, passed = {} }
	local index = #points
	local contacts = 0
	local guard = 0
	while index >= 2 and guard < 8192 do
		guard += 1
		local a = points[index]
		note(state, a, frameNumber)
		local b = points[index - 1]
		if a.gap then
			index -= 1
			continue
		end
		if a.kind == IN then
			-- inside what it passes through: no casts until its exit
			local out = a.pair
			local k = index - 1
			while k >= 1 and points[k] ~= out do
				if points[k].gap then
					break
				end
				k -= 1
			end
			index = if k >= 1 and points[k] == out then k else index - 1
			continue
		end
		local offset = b.pos - a.pos
		local length = offset.Magnitude
		local direction = if length > 1e-4 then offset / length
			elseif a.vel.Magnitude > 1e-4 then a.vel.Unit
			else nil
		if not direction then
			index -= 1
			continue
		end
		if b.kind == CUT or b.kind == CORNER or b.kind == IN then
			-- Cast toward where the material would be without the surface
			-- (never toward the pinned spot itself: that always hits, and
			-- the beam would stay strung to it).
			local farPos, _, farTau = beyond(flow, b, points[index - 2])
			local aim = if farPos then farPos - a.pos else direction * (length + PIN_REACH)
			local reach = aim.Magnitude
			if reach < 1e-4 then
				index -= 1
				continue
			end
			local heading = aim / reach
			local distance, contact = cast(flow, a.pos, heading, reach + (if farPos then 0 else PIN_REACH))
			if contact and distance then
				local target = targetOf(contact.Instance)
				local same = target == targetOf(b.part)
				local before = (b.pos - a.pos).Magnitude
				if same or distance >= before - 1e-3 then
					local point = a.pos + heading * distance
					b.pos = point
					b.normal = SafeMath.unit(contact.Normal, b.normal or -heading)
					b.part = if same then b.part else contact.Instance
					local tau = if farTau then a.tau + (farTau - a.tau) * math.clamp(distance / reach, 0, 1)
						else a.tau - distance / math.max(a.vel.Magnitude, 1e-3)
					b.tau = math.max(tau, b.tau)
					b.age = math.max(flow.clock - b.tau, 0)
					if b.kind == IN then
						reexit(flow, b, a.pos)
					end
					flowedThrough(flow, b)
					index -= 1
					continue
				elseif contacts < MAX_CONTACTS then
					-- something new came between
					contacts += 1
					index = contactAt(flow, index, distance, heading, contact, state)
					continue
				end
			end
			release(flow, index - 1)
			continue -- (same leg again, now to a free point)
		end
		-- a leg of plain material
		local distance, contact = cast(flow, a.pos, direction, length)
		if contact and distance and contacts < MAX_CONTACTS then
			contacts += 1
			index = contactAt(flow, index, distance, direction, contact, state)
			continue
		end
		index -= 1
	end
end

local function unpin(flow: any)
	local points = flow.points
	local clock = flow.clock
	-- Pinned points nothing flows into any more (the beam's back end went
	-- in, bounced or passed through): a cut is just a spot on a wall, gone;
	-- a corner becomes the free back end of the reflected beam, which flies
	-- off at its full length instead of staying strung to the wall; a
	-- pass-through's entry goes and its exit flies on with the material.
	local index = 1
	while index <= #points do
		local point = points[index]
		local newer = points[index + 1]
		local fed = newer ~= nil and not newer.gap
		if not fed and point.kind == CUT then
			removeAt(flow, index)
			if newer then
				newer.gap = index > 1 and newer.gap
				dirty(newer)
			end
			continue
		elseif not fed and point.kind == CORNER then
			local older = points[index - 1]
			point.kind = FREE
			point.vel = if older and not point.gap then older.vel
				else reflect(point.vel, point.normal) * flow.restitution
			point.marker, point.ghost = "bounce", nil
			point.age = math.max(clock - point.tau, 0)
			dirty(point)
		elseif not fed and point.kind == IN then
			local out = point.pair
			removeAt(flow, index)
			if out and not out.Dead then
				local outIndex = table.find(points, out)
				local past = outIndex and outIndex > 1 and points[outIndex - 1]
				out.kind = FREE
				out.vel = if past and not out.gap then past.vel else out.vel
				out.age = math.max(clock - out.tau, 0)
				dirty(out)
			end
			continue
		end
		index += 1
	end
end

-- Moves every free point, follows the source, trims the front.
local function advance(flow: any, dt: number)
	local points = flow.points
	local accel = flow.accel
	local uniform = ChunkManager.IsTimeUniform()
	local clock = flow.clock
	for _, point in points do
		local kind = point.kind
		if kind == FREE then
			local step = if uniform then dt else dt * Planner.ChunkTimeScaleAt(point.pos)
			point.pos += point.vel * step + accel * (.5 * step * step)
			point.vel += accel * step
			point.age += step
		elseif kind == SOURCE then
			point.tau, point.age = clock, 0
		else
			point.age = math.max(clock - point.tau, 0)
			local ghost = point.ghost
			if ghost then
				local step = if uniform then dt else dt * Planner.ChunkTimeScaleAt(ghost.pos)
				ghost.pos += ghost.vel * step + accel * (.5 * step * step)
				ghost.vel += accel * step
			end
		end
	end
	-- The front: material older than the lifetime is gone. The front point
	-- slides back along its leg to where the material is exactly that old.
	local lifetime = flow.lifetime
	while #points > 0 do
		local front = points[1]
		if front.age < lifetime then
			break
		end
		local nextPoint = points[2]
		if not nextPoint or nextPoint.gap or nextPoint.age >= lifetime then
			removeAt(flow, 1)
			if points[1] then
				points[1].gap = false
			end
			continue
		end
		local t = math.clamp((front.age - lifetime) / math.max(front.age - nextPoint.age, 1e-6), 0, 1)
		front.pos = front.pos:Lerp(nextPoint.pos, t)
		front.vel = front.vel:Lerp(nextPoint.vel, t)
		front.tau = front.tau + (nextPoint.tau - front.tau) * t
		front.age = lifetime
		if front.kind ~= FREE then
			front.kind = FREE
			dirty(front)
		end
		break
	end
end

function Flow.Step(flow: any, globalDt: number)
	local scale = sourceScale(flow)
	if scale ~= flow.scale then
		flow.scale = scale
		flow.scaleChanged = true
	end
	local dt = globalDt * scale
	if dt > 0 then
		flow.clock += dt
		advance(flow, dt)
		flowPast(flow)
		unpin(flow) -- (right after: a back end that just bounced lets its corner go now)
		collide(flow)
	end
	local points = flow.points
	local front = points[1]
	-- (this frame's absorptions first: material that stopped at a wall
	-- this frame mustn't read as having run out)
	settleTickets(flow)
	expireTickets(flow, if front then front.tau else (if flow.closed then nil else -math.huge), front and front.pos)
	if flow.closed and #points <= 1 then
		if points[1] then
			removeAt(flow, 1)
		end
		expireTickets(flow, nil, nil)
		flow.finished = true
	end
end

function Flow.Finished(flow: any): boolean
	return flow.finished
end

--------------------------------------------------------------------------------
-- Stream (BeamWire.FlowChannel)
--------------------------------------------------------------------------------

local function writeAdd(w: BeamWire.Writer, points: { any }, index: number)
	local point = points[index]
	U8(w, FlowOp.Add)
	U32(w, point.id)
	U32(w, if index > 1 then points[index - 1].id else 0)
	U8(w, point.kind)
	U8(w, if point.gap then FlowFlag.Gap else 0)
	V3(w, point.pos)
	V3(w, point.vel)
	F32(w, point.age)
	F32(w, point.tau)
	point._rep, point._repKind, point._repGap, point._repPos = true, point.kind, point.gap, point.pos
	point._dirty, point._reordered = nil, nil
end

local function writeHeader(w: BeamWire.Writer, flow: any)
	local header = flow.header
	F32(w, flow.radius)
	F32(w, flow.lifetime)
	for index = 1, 3 do
		U8(w, header.color[index])
	end
	for index = 1, 3 do
		U8(w, header.core[index])
	end
	V3(w, flow.accel)
	F32(w, flow.scale)
end

local function sectionStart(w: BeamWire.Writer, flow: any, kind: number, now: number)
	U32(w, flow.id)
	U8(w, kind)
	F64(w, now)
	F32(w, flow.clock)
end

local function encodeDelta(flow: any, now: number): BeamWire.Writer?
	local w = BeamWire.Writer(256)
	sectionStart(w, flow, Section.Delta, now)
	local start = w.n
	if flow.scaleChanged then
		U8(w, FlowOp.Scale)
		F32(w, flow.scale)
	end
	for _, id in flow.removed do
		U8(w, FlowOp.Remove)
		U32(w, id)
	end
	local points = flow.points
	for index, point in points do
		if not point._rep then
			writeAdd(w, points, index)
			continue
		end
		if point._reordered then
			point._reordered = nil
			U8(w, FlowOp.Order)
			U32(w, point.id)
			U32(w, if index > 1 then points[index - 1].id else 0)
		end
		if point._dirty or point._repKind ~= point.kind or point._repGap ~= point.gap then
			U8(w, FlowOp.State)
			U32(w, point.id)
			U8(w, point.kind)
			U8(w, if point.gap then FlowFlag.Gap else 0)
			V3(w, point.pos)
			V3(w, point.vel)
			F32(w, point.age)
			F32(w, point.tau)
			point._dirty, point._repKind, point._repGap, point._repPos = nil, point.kind, point.gap, point.pos
		elseif (point.kind ~= FREE) and (point.pos - point._repPos).Magnitude > PIN_RESEND then
			U8(w, FlowOp.Pin)
			U32(w, point.id)
			V3(w, point.pos)
			F32(w, point.tau)
			point._repPos = point.pos
		end
	end
	for _, impact in flow.impacts do
		U8(w, FlowOp.Impact)
		V3(w, impact[1])
		V3(w, impact[2])
		U8(w, impact[3])
	end
	if w.n == start then
		return nil
	end
	U8(w, FlowOp.End)
	return w
end

local function encodeSnapshot(flow: any, now: number): BeamWire.Writer
	local w = BeamWire.Writer(512)
	sectionStart(w, flow, Section.Snapshot, now)
	writeHeader(w, flow)
	local points = flow.points
	for index = 1, #points do
		writeAdd(w, points, index)
	end
	U8(w, FlowOp.End)
	return w
end

local function closed(flow: any, kind: number, now: number): BeamWire.Writer
	local w = BeamWire.Writer(24)
	sectionStart(w, flow, kind, now)
	U8(w, FlowOp.End)
	return w
end

local function bounds(flow: any): (Vector3?, Vector3?)
	local low, high = nil, nil
	for _, point in flow.points do
		low = if low then low:Min(point.pos) else point.pos
		high = if high then high:Max(point.pos) else point.pos
	end
	return low, high
end

-- Every beam's messages this frame, one buffer per player.
function Flow.Replicate()
	local now = workspace:GetServerTimeNow()
	local roots: { [Player]: Vector3 } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character.PrimaryPart
		if root then
			roots[player] = root.Position
		end
	end
	local outgoing: { [Player]: BeamWire.Writer } = {}
	local function send(player: Player, section: BeamWire.Writer)
		local out = outgoing[player]
		if not out then
			out = BeamWire.Writer(section.n + 64)
			outgoing[player] = out
		end
		BeamWire.Append(out, section)
	end
	for _, flow in flows do
		if not flow.visualize then
			table.clear(flow.removed)
			table.clear(flow.impacts)
			continue
		end
		local observers = flow.observers
		if flow.finished then
			if next(observers) then
				local delta = encodeDelta(flow, now)
				local section = closed(flow, Section.End, now)
				for player in observers do
					if player.Parent then
						if delta then
							send(player, delta)
						end
						send(player, section)
					end
				end
			end
		else
			local low, high = bounds(flow)
			local range = flow.visualRange
			local delta = if next(observers) then encodeDelta(flow, now) else nil
			local snapshot, exit = nil, nil
			for player, position in roots do
				local watching = observers[player]
				local distance = if low and high then (position - position:Max(low):Min(high)).Magnitude else math.huge
				if watching and distance > range * 1.1 + 8 then
					observers[player] = nil
					exit = exit or closed(flow, Section.Exit, now)
					send(player, exit)
				elseif watching then
					if delta then
						send(player, delta)
					end
				elseif distance <= range then
					observers[player] = true
					snapshot = snapshot or encodeSnapshot(flow, now)
					send(player, snapshot)
				end
			end
			for player in observers do
				if not roots[player] then
					observers[player] = nil
				end
			end
			if not next(observers) then
				-- (nobody watching: the next snapshot carries everything)
				for _, point in flow.points do
					point._rep = nil
				end
			end
		end
		flow.scaleChanged = nil
		table.clear(flow.removed)
		table.clear(flow.impacts)
	end
	for player, out in outgoing do
		if player.Parent then
			VisualOffload.FireClient(player, BeamWire.FlowChannel, BeamWire.Finish(out))
		end
	end
	-- drop finished beams
	local live = {}
	for _, flow in flows do
		if not flow.finished then
			table.insert(live, flow)
		end
	end
	flows = live
end

-- Every beam's points, front to back, as "<kind><gap?>" (F free, S source,
-- C cut, B corner, I in, O out; "|" marks a gap toward the front) -- for
-- debugging from a Script / the command bar.
function Flow.Describe(): { string }
	local letters = { [FREE] = "F", [SOURCE] = "S", [CUT] = "C", [CORNER] = "B", [IN] = "I", [OUT] = "O" }
	local lines = {}
	for _, flow in flows do
		local parts = {}
		for _, point in flow.points do
			table.insert(parts, (if point.gap then "|" else "") .. (letters[point.kind] or "?"))
		end
		table.insert(lines, string.format("beam %d (%s): %s", flow.id, if flow.closed then "closed" else "open",
			table.concat(parts, " ")))
	end
	return lines
end

function Flow.TakeStats(): { [string]: number }
	local points, tickets = 0, 0
	for _, flow in flows do
		points += #flow.points
		tickets += #flow.tickets
	end
	local snapshot = { Beams = #flows, Points = points, Tickets = tickets, Casts = stats.Casts, Contacts = stats.Contacts }
	stats.Casts, stats.Contacts = 0, 0
	return snapshot
end

Players.PlayerRemoving:Connect(function(player)
	for _, flow in flows do
		flow.observers[player] = nil
	end
end)

return Flow
