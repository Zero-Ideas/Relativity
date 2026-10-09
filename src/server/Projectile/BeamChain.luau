--!strict
--[[
	Projectile/BeamChain.luau
	Sustained beams: one chain per Sustain channel, made of lightweight
	samples instead of full projectiles. (The original BeamProjectileHandler,
	where every packet and joiner is a Store-backed projectile with its own
	replicated visual, stays as a backup -- see Beams.luau.)

	Same mechanics, cheaper carriers:
	 - A sample is a plain table with the fields a projectile has, so it moves
	   and collides through the very same Projectile.Step (homing, gravity,
	   dilation, pierce, penetration, bounce) and its links through the same
	   ResolveBeamSpan (body damage, world clipping). SpellRuntime binds its
	   OnHit / OnDestroy / energy hooks exactly as before.
	 - Links are planned like before (newer sample = back, older = front,
	   bounce corners from BeamPath.Plan). A link longer than BeamPath's
	   MaxStretch used to be split into joiner projectiles at once. In free
	   space those joiners only ever slide along the straight chord between
	   the link's ends (lerped position + lerped velocity stays on it), so here
	   a long link stays ONE body while nothing touches it, and is split into
	   the same joiners the moment it meets anything (ProbeBeamSpan), when its
	   front dies, or wherever that equivalence doesn't hold (homing, an
	   uneven time field along it, OnTimer / OnProximity triggers that need
	   every joiner's own position).
	 - Beamlets are only made where hit detection needs them. A packet starts
	   DORMANT: a record moving on a formula, its triggers and damage not even
	   bound. Each frame the dormant stretches of a beam are joined into one
	   line and cast; only where that line meets something are the packets
	   either side of the contact made real beamlets (which then step, clip,
	   hit and split exactly as below), and the rest of the line is cast on
	   from there. A packet that never meets anything never becomes one.
	 - Clients get one compact event stream per chain (see BeamWire): a new
	   sample, a bounce, a link change, a clipped body, a death. Samples move
	   deterministically in between, so nothing is sent per sample per frame.
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Heartbeat = require(Shared:WaitForChild("Heartbeat"))
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local VisualOffload = require(Shared:WaitForChild("VisualOffload"))
local SafeMath = require(Shared:WaitForChild("SafeMath"))
local ProjectileShared = Shared:WaitForChild("Projectile")
local Motion = require(ProjectileShared:WaitForChild("Motion"))
local Planner = require(ProjectileShared:WaitForChild("StepPlanner"))
local BeamPath = require(ProjectileShared:WaitForChild("BeamPath"))
local BeamWire = require(ProjectileShared:WaitForChild("BeamWire"))

local Projectile = require(script.Parent)
local Config = require(script.Parent.Config)
local Raycast = require(script.Parent.Raycast)
local Profile = require(script.Parent.Profile)

local Op, Section, DeathKind, Flag = BeamWire.Op, BeamWire.Section, BeamWire.Death, BeamWire.SpawnFlag
local U8, U32, F32, F64, V3 = BeamWire.U8, BeamWire.U32, BeamWire.F32, BeamWire.F64, BeamWire.V3

local Chain = {}
Chain.Interval = 1 / 30
Chain.MaxJoinersPerBeam = 512
Chain.MaxNewJoinersPerFrame = 128
-- No new joiners once BOTH real (launched, non-joiner) packets a link spans
-- are older than this many real seconds (see BeamProjectileHandler).
Chain.MaxJoinerSourceAge = 3
-- Consecutive packets sit just under one link apart (see
-- BeamProjectileHandler.GetInterval).
function Chain.GetInterval(speed: number): number
	return math.max(1 / 240, math.min(Chain.Interval, (BeamPath.MaxStretch - 2) / math.max(speed, 1)))
end

local INPUT_TIMEOUT = .75
local MAX_PACKETS_PER_CHANNEL_FRAME = 4
local MAX_CHANNELS_PER_PLAYER = 32
-- Homing / non-uniform-time / velocity-relative chains: every sample's pose
-- is re-sent about this often (clients only extrapolate between events).
local REFRESH_PERIOD = 0.2
-- A clipped body's endpoint is re-sent once it moves this far.
local CLIP_RESEND = 0.25
-- A chain lingers this long after its last packet before it ends.
local CHAIN_GRACE = 0.25
-- Dormant stretches are cast as simplified lines: a vertex is dropped when
-- it's within this many studs of the line through its neighbours (the cast
-- is widened by as much), and casts are cut at this length.
local STRAIGHT_TOLERANCE = 0.1
local MAX_CAST = 1000
-- Halving: the most times one link is halved in a frame (a link is at most
-- MaxJoinersPerLink + 1 pieces long, and 2^6 > 33).
local MAX_HALVINGS = 8
-- Emission skipping (see Channels): the longest link a skipped run of samples
-- may leave, how far the aim may turn (cosine) and the launch point move
-- since the last launched sample before the next one must launch.
local SKIP_SPACING = 4 * BeamPath.MaxStretch
local SKIP_TURN = math.cos(math.rad(1))
local SKIP_SHIFT = 2
-- A new sample links to a previous one stopped at a wall at most this many
-- real seconds ago (clients drop a dead sample nothing links to after 0.25).
local PARKED_LINK_AGE = 0.15

--------------------------------------------------------------------------------
-- Dormant packets
--------------------------------------------------------------------------------

-- Why dormant packets were made real beamlets (Stats tab), counted since
-- the last GetJoinerStats: their line met something, they're about to reach
-- a wall a packet ahead stopped at, the packet ahead expired and the gap to
-- the next one needs joiners, their body bends in a way a line can't take,
-- dilated time, or an On Expire trigger that needs every one.
local madeReal = { Hit = 0, Wall = 0, Front = 0, Bent = 0, Dilated = 0, Expire = 0 }

local function materialize(s: any, why: string)
	if not s._dormant then
		return
	end
	s._dormant = nil
	local bind = s._bind
	s._bind, s._discard = nil, nil
	if bind then
		bind(s)
	end
	madeReal[why] += 1
end

--------------------------------------------------------------------------------
-- Samples
--------------------------------------------------------------------------------

-- OnHit / OnDestroy for one sample. SpellRuntime connects one listener each,
-- so a plain list beats a Signal. Firing marks the sample: a pierce or a
-- penetration moves it, and clients must hear about that.
local Event = {}
Event.__index = Event

local function newEvent(owner: any): any
	return setmetatable({ owner = owner }, Event)
end

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
	local owner = self.owner
	owner._contact = true
	owner._lastHit = info
	for index = 1, #self do
		local fn = self[index]
		if fn then
			fn(info)
		end
	end
end

local Sample = {}
local SampleMeta = { __index = Sample }

local materializeAhead: (s: any) -> ()

-- Same contract as Projectile.Destroy: exactly once, fires OnDestroy with
-- { Position, Normal, Kind }. A world stop parks the sample one radius off the
-- wall so followers can keep linking to it.
function Sample.Destroy(self: any, result: { Position: Vector3, Normal: Vector3 }?, kind: string?)
	if self.Dead then
		return
	end
	if self._dormant then
		-- (never bound: nothing listens, only its quota slot to give back)
		local discard = self._discard
		self._dormant, self._bind, self._discard = nil, nil, nil
		if discard then
			discard()
		end
	end
	if kind ~= nil and self._lazyLink then
		-- The joiners ahead of it would have flown on past whatever stopped
		-- it. Split first, so their energy shares leave before its triggers fire.
		materializeAhead(self)
	end
	self.Dead = true
	self._diedAt = os.clock()
	self._worldStop = kind == "world" and not self._beamBodyHit
	local info = {
		Position = if result then SafeMath.vector(result.Position, self.Position) else self.Position,
		Normal = if result then SafeMath.unit(result.Normal, Vector3.yAxis) else Vector3.yAxis,
		Kind = kind,
	}
	if self._worldStop then
		self.Position = info.Position + info.Normal * self.Radius
	end
	local chain = self._chain
	if chain then
		table.insert(chain.deaths, { self, info })
	end
	self.OnDestroy:Fire(info)
	table.clear(self._ignore)
	self.HomingTarget = nil
end

function Sample.SetTimeScale(self: any, scale: number)
	self.TimeScale = SafeMath.number(scale, 1, 0)
end

local function fromSettings(chain: any, settings: any): any
	local position = settings.Origin
	local s = {
		Id = chain.nextId,
		Position = position,
		Velocity = settings.Direction * settings.Speed,
		Speed = settings.Speed,
		Acceleration = settings.Acceleration,
		AccelerationDirection = settings.AccelerationDirection,
		MinSpeed = settings.MinSpeed,
		MaxSpeed = settings.MaxSpeed,
		Gravity = settings.Gravity,
		Radius = settings.Radius,
		Lifetime = settings.Lifetime,
		Age = 0,
		MaxRealLifetime = settings.MaxRealLifetime,
		TimeScale = settings.TimeScale,
		Damage = settings.Damage,
		DamageMultiplier = 1,
		Source = settings.Source,
		IgnoreInstances = settings.IgnoreInstances,
		Filter = settings.Filter,
		BouncesLeft = settings.Bounces,
		Restitution = settings.Restitution,
		Penetration = settings.Penetration,
		PiercesLeft = settings.MaxPierces,
		PierceFalloff = settings.PierceFalloff,
		Homing = settings.Homing,
		HomingDelay = if settings.Homing then settings.Homing.Delay else 0,
		HomingTarget = if settings.Homing then settings.Homing.Target else nil,
		ReacquireTimer = 0,
		-- The chain replicates itself (BeamWire); the projectile streams stay
		-- silent for samples.
		Visualize = false,
		VisualRange = settings.VisualRange,
		Beam = settings.Beam,
		RewindSeconds = 0,
		Dead = false,
		_spawnRealTime = os.clock(),
		_acquireTimer = 0,
		_ignore = {},
		_simulationDebt = 0,
		_rayParams = settings._rayParams or Raycast.buildRayParams(settings.Source, settings.IgnoreInstances),
		_spawnStreamed = false,
		_streamedSynced = false,
		_lastStreamedTimeScale = 1,
		_beamTurns = {},
		_chain = chain,
		_origin = position,
		_tail = { position },
		_tailTurns = 0,
		_everLinked = false,
	}
	chain.nextId += 1
	s.OnHit, s.OnDestroy = newEvent(s), newEvent(s)
	return setmetatable(s, SampleMeta)
end

-- A joiner: the prototype's flight state at a point on its link, with its
-- own identity, events, pierced set and turns (cf. Projectile.CreateBeamSample).
local function joinerFrom(chain: any, prototype: any, position: Vector3, velocity: Vector3, turns: { Vector3 }): any
	local s = table.clone(prototype)
	s.Id = chain.nextId
	chain.nextId += 1
	s.Position, s.Velocity, s.Speed = position, velocity, velocity.Magnitude
	s.Dead = false
	s._beamJoiner = true
	s._beamTurns = turns
	s._ignore = table.clone(prototype._ignore)
	s._simulationDebt = 0
	s.OnHit, s.OnDestroy = newEvent(s), newEvent(s)
	s._worldStop, s._beamBodyHit, s._spanParams = nil, nil, nil
	s._beamSpan, s._beamSpanClipped, s._ahead, s._fragment = nil, nil, nil, nil
	s._lazyLink, s._incoming, s._contact, s._lastHit = nil, nil, nil, nil
	s._beamReserveChildren, s._beamBindChild, s._beamScaleEnergy = nil, nil, nil
	s._rep, s._repAhead, s._repClipN, s._repClipEnd, s._repTurns = nil, nil, nil, nil, nil
	s._dormant, s._bind, s._discard, s._prevPosition, s._behind = nil, nil, nil, nil, nil
	s._origin, s._tail, s._tailTurns, s._everLinked = position, { position }, #turns, true
	return s
end

--------------------------------------------------------------------------------
-- Chains
--------------------------------------------------------------------------------

local chains: { [number]: any } = {}
local chainOrder: { number } = {}
local frameStats = { Created = 0, BudgetSplits = 0, Lazy = 0, Samples = 0, Joiners = 0, Dormant = 0 }
local lastStats = table.clone(frameStats)
-- (Parked: a link to a sample stopped at a wall, let go once the sample
-- behind no longer heads into that spot)
local breakReasons = { Geometry = 0, ChannelBudget = 0, FrameBudget = 0, Quota = 0, SourceAge = 0, Parked = 0 }

local function colorBytes(color: Color3?, fallback: Color3): (number, number, number)
	local c = color or fallback
	return math.clamp(math.floor(c.R * 255 + .5), 0, 255), math.clamp(math.floor(c.G * 255 + .5), 0, 255),
		math.clamp(math.floor(c.B * 255 + .5), 0, 255)
end

local function newChain(id: number, config: any, settings: any): any
	local visual = settings.Visual
	local acceleration = settings.Acceleration
	local constant = typeof(acceleration) ~= "number" or acceleration == 0
	local lazy = config.Beam and config.Beam.Lazy == true
	local chain = {
		id = id,
		samples = {},
		last = nil,
		nextId = 1,
		joinerCount = 0,
		deaths = {},
		observers = {},
		lastLaunch = os.clock(),
		source = settings.Source,
		visualize = settings.Visualize,
		visualRange = settings.VisualRange,
		-- A long link may stay one body (see the module comment) only when
		-- every sample along it would move along the same straight chord.
		lazy = lazy and not settings.Homing and constant and settings.MinSpeed <= 0
			and settings.MaxSpeed == math.huge,
		-- Clients extrapolate in straight lines + constant acceleration; these
		-- chains also get periodic per-sample poses.
		refresh = settings.Homing ~= nil or not constant or settings.MinSpeed > 0 or settings.MaxSpeed ~= math.huge,
		-- every packet fires an On Expire trigger as it runs out
		expireTriggers = config.Beam and config.Beam.ExpireTriggers == true,
		refreshCursor = 1,
		refreshCarry = 0,
		scale = 1,
		header = {
			radius = settings.Radius,
			length = settings.Beam.Length,
			color = table.pack(colorBytes(visual and visual.Color, Color3.fromRGB(255, 96, 28))),
			core = table.pack(colorBytes(visual and visual.Core, Color3.new(1, 1, 1))),
			-- (constant acceleration only; see `refresh`)
			gravity = Motion.GetAcceleration(Vector3.zAxis, if constant then acceleration else 0, nil, settings.Gravity),
		},
	}
	chains[id] = chain
	table.insert(chainOrder, id)
	return chain
end

-- Is `p` still pouring into the spot its front stopped at -- heading along
-- the first leg of their link, not sliding past it?
local function feeding(p: any, corners: { Vector3 }): boolean
	local speed = p.Velocity.Magnitude
	if speed < 1e-4 then
		return true
	end
	local heading = p.Velocity / speed
	local leg = corners[2] - corners[1]
	local along = leg:Dot(heading)
	return along > 0 and (leg - heading * along).Magnitude <= BeamPath.MaxStretch
end

-- Launches: every packet of a channel is configured alike but for where
-- and which way it goes and its energy, so the chain keeps one normalized
-- config (and its RaycastParams) and each launch copies it, instead of
-- normalizing the whole config and building the cast filter per packet.
-- It's rebuilt whenever the caller's ignore list changes (SpellRuntime
-- refreshes it a few times a second). Homing packets always normalize:
-- their homing state isn't shared.
local fromTemplate: (chain: any?, config: any) -> any?

local function keepTemplate(chain: any, config: any, settings: any)
	if config.Homing ~= nil then
		chain.template = nil
		return
	end
	local template = table.clone(settings)
	template._raw = config.IgnoreInstances
	template._filter, template._source = config.Filter, config.Source
	template._speed, template._radius, template._lifetime = config.Speed, config.Radius, config.Lifetime
	template._rayParams = Raycast.buildRayParams(settings.Source, settings.IgnoreInstances)
	chain.template = template
	settings._rayParams = template._rayParams
end

function fromTemplate(chain: any?, config: any): any?
	local template = chain and chain.template
	if not template or config.Homing ~= nil or template._raw ~= config.IgnoreInstances
		or template._filter ~= config.Filter or template._source ~= config.Source or template._speed ~= config.Speed
		or template._radius ~= config.Radius or template._lifetime ~= config.Lifetime then
		return nil
	end
	local settings = table.clone(template)
	local origin = SafeMath.vector(config.Origin, Vector3.zero)
	settings.Origin = origin
	settings.Direction = Config.direction(config, origin)
	settings.Damage = SafeMath.number(config.Damage, 0)
	return settings
end

-- SpellRuntime hands over its trigger binding instead of binding at once
-- (see Launch).
Chain.DefersBinding = true

-- `deferred` (SpellRuntime): { Bind = (packet) -> (), Discard = () -> () }.
-- A packet of a chain that can run dormant keeps it until it's made real
-- (Bind) or dies without ever being (Discard); anything else binds now.
function Chain.Launch(config: any, deferred: any?): any
	local beam = config.Beam
	local id = beam and beam.ChannelId
	if not id then
		-- A single (unsustained) beam is one ordinary projectile, as before.
		local beamConfig = table.clone(config)
		beamConfig.Beam = table.clone(beam or {})
		local projectile = Projectile.new(beamConfig)
		if deferred then
			deferred.Bind(projectile)
		end
		return projectile
	end
	local started = os.clock()
	local settings = fromTemplate(chains[id], config)
	if not settings then
		settings = Config.normalize(config, Projectile.GetDefaultMaxRealLifetime())
	end
	local chain = chains[id] or newChain(id, config, settings)
	if not chain.template or chain.template._raw ~= config.IgnoreInstances then
		keepTemplate(chain, config, settings)
	end
	local s = fromSettings(chain, settings)
	local previous = chain.last
	local linked = previous ~= nil and not previous.Dead
	if previous and previous.Dead and chain.lazy and previous._worldStop
		and os.clock() - previous._diedAt < PARKED_LINK_AGE then
		-- One that just stopped at a wall: with skipped samples it can get
		-- there well before the next launch, and the beam still pours into
		-- that spot if this one heads there too. (Clients keep a stopped
		-- sample nothing links to for only DEAD_GRACE, hence recent ones.)
		local corners = BeamPath.Plan(s.Position, previous.Position, s._beamTurns, previous._beamTurns)
		linked = corners ~= nil and #corners > 1 and feeding(s, corners)
	end
	if linked then
		s._ahead = previous
		previous._behind = s
	end
	chain.last = s
	chain.lastLaunch = os.clock()
	table.insert(chain.samples, s)
	if deferred and chain.lazy then
		s._dormant, s._bind, s._discard = true, deferred.Bind, deferred.Discard
		s._accel = Motion.GetAcceleration(s.Velocity, s.Acceleration, s.AccelerationDirection, s.Gravity)
	elseif deferred then
		deferred.Bind(s)
	end
	Profile.Add("Spawn", os.clock() - started)
	Profile.Count("Spawned", 1)
	return s
end

--------------------------------------------------------------------------------
-- Links (a port of BeamProjectileHandler's span step onto samples)
--------------------------------------------------------------------------------

local function realBehind(s: any): any
	return if s._beamJoiner then s._realBehind or s else s
end
local function realAhead(s: any): any
	return if s._beamJoiner then s._realAhead or s else s
end
local function realAge(s: any): number
	return os.clock() - (s._spawnRealTime or os.clock())
end

-- Break ONLY this link; the sample keeps a finite body pointing where its
-- link went (cf. BeamProjectileHandler's unlink) -- or, `forward`, where the
-- sample itself is heading.
local function unlink(s: any, forward: boolean?)
	local path = s._beamSpan
	local offset = if forward then nil else path and path[2] and path[2] - path[1]
	if not offset or offset.Magnitude < 1e-4 then
		offset = if s.Velocity.Magnitude > 1e-4 then s.Velocity.Unit * math.min(s.Beam.Length, BeamPath.MaxStretch) else nil
	end
	if offset and offset.Magnitude > BeamPath.MaxStretch then
		offset = offset.Unit * BeamPath.MaxStretch
	end
	s._fragment = offset
	s._ahead, s._everLinked, s._lazyLink = nil, true, nil
	s._beamSpanClipped = nil
end

local function initialPath(s: any): { Vector3 }
	if s._incoming then
		return { s.Position }
	end
	if s._fragment then
		return { s.Position, s.Position + s._fragment }
	end
	if s._everLinked then
		if s.Velocity.Magnitude > 1e-4 then
			return { s.Position, s.Position + s.Velocity.Unit * math.min(s.Beam.Length, BeamPath.MaxStretch) }
		end
		return { s.Position }
	end
	local tail, turns = s._tail, s._beamTurns
	for index = s._tailTurns + 1, #turns do
		table.insert(tail, turns[index])
	end
	s._tailTurns = #turns
	if (tail[#tail] - s.Position).Magnitude > 1e-4 then
		table.insert(tail, s.Position)
	end
	local length, cap = 0, math.min(s.Beam.Length, BeamPath.MaxStretch)
	for index = #tail, 2, -1 do
		local span = (tail[index] - tail[index - 1]).Magnitude
		if length + span > cap then
			tail[index - 1] = tail[index]:Lerp(tail[index - 1], (cap - length) / span)
			for _ = 1, index - 2 do
				table.remove(tail, 1)
			end
			break
		end
		length += span
	end
	while #tail > 9 do
		table.remove(tail, 1)
	end
	local reverse = table.create(#tail)
	for index = #tail, 1, -1 do
		table.insert(reverse, tail[index])
	end
	return reverse
end

local function resolve(s: any, points: { Vector3 }, globalDt: number)
	s._beamSpan = Projectile.ResolveBeamSpan(s, points, globalDt > 0)
end

-- Would every point of this path move at the same time scale? (Only then do
-- its virtual joiners stay on the chord.)
local function uniformAlong(corners: { Vector3 }): boolean
	for leg = 1, #corners - 1 do
		local from, to = corners[leg], corners[leg + 1]
		local offset = to - from
		local length = offset.Magnitude
		if length < 1e-4 then
			continue
		end
		local scale = Planner.ChunkTimeScaleAt(from)
		if Planner.ChunkTimeScaleAt(to) ~= scale then
			return false
		end
		local heading = offset / length
		if Motion.GetTimeScaleBoundaryDt(from, heading, ChunkManager.ChunkSize, ChunkManager.UseY, scale, length,
			Planner.ChunkTimeScaleAt) < length
			or ChunkManager.GetRadialTimeScaleBoundaryDt(from, heading, length) < length then
			return false
		end
	end
	return true
end

local created = 0 -- joiners created this frame (all chains)

-- Why a link can't be subdivided right now (nil: it can, and any quota is
-- already reserved).
local function blocked(chain: any, p: any, front: any, corners: { Vector3 }?, needed: number): string?
	if not corners then
		return "Geometry"
	elseif needed > 0 and realAge(realBehind(p)) > Chain.MaxJoinerSourceAge
		and realAge(realAhead(front)) > Chain.MaxJoinerSourceAge then
		return "SourceAge"
	elseif chain.joinerCount + needed > Chain.MaxJoinersPerBeam then
		return "ChannelBudget"
	elseif created + needed > Chain.MaxNewJoinersPerFrame then
		return "FrameBudget"
	elseif needed > 0 and p._beamReserveChildren and not p._beamReserveChildren(needed) then
		return "Quota"
	end
	return nil
end

-- Inserts `needed` joiners along the planned link p -> front and resolves
-- every resulting link (cf. BeamProjectileHandler). `expiring`: the front just
-- died, and the stretch a lazy link stood for carries on as the joiners an
-- eager split would have made (ages graded along the path, so they expire in
-- turn instead of all at once).
local function split(chain: any, p: any, front: any, corners: { Vector3 }, needed: number, globalDt: number,
	expiring: boolean?, deferred: boolean?)
	local behindReal, aheadReal = realBehind(p), realAhead(front)
	local list = { p }
	local behind, ahead = p._beamTurns, front._beamTurns
	local total = 0
	for leg = 1, #corners - 1 do
		total += (corners[leg + 1] - corners[leg]).Magnitude
	end
	local along = 0
	local share = 1 / (needed + 1)
	for leg = 1, #corners - 1 do
		local from, to = corners[leg], corners[leg + 1]
		local legLength = (to - from).Magnitude
		local pieces = math.max(1, math.ceil(legLength / BeamPath.MaxStretch))
		local phase = math.min(#behind + leg - 1, #ahead)
		for piece = 1, pieces - 1 do
			local t = piece / pieces
			local prototype = if phase == #ahead then front else p
			local velocity = if #behind == #ahead then p.Velocity:Lerp(front.Velocity, t)
				elseif phase == #behind then p.Velocity
				elseif phase == #ahead then front.Velocity
				else (to - from).Unit * p.Velocity.Magnitude * p.Restitution ^ (phase - #behind)
			local turns = table.move(ahead, 1, phase, 1, {})
			local child = joinerFrom(chain, prototype, from:Lerp(to, t), velocity, turns)
			child._realBehind, child._realAhead = behindReal, aheadReal
			-- Toward a world-stopped front, never inherit its frozen age (it
			-- would keep seeding young joiners); otherwise graded along the path.
			local fraction = if total > 0 then (along + legLength * t) / total else t
			child.Age = if front.Dead and not expiring then p.Age else p.Age + (front.Age - p.Age) * fraction
			child.Damage = p.Damage * share
			if p._beamBindChild then
				p._beamBindChild(child, share)
			end
			table.insert(list, child)
			table.insert(chain.samples, child)
		end
		along += legLength
	end
	if p._beamScaleEnergy then
		p._beamScaleEnergy(share)
	else
		p.Damage *= share
	end
	table.insert(list, front)
	for link = 1, #list - 1 do
		local back, forward = list[link], list[link + 1]
		back._ahead, back._everLinked, back._lazyLink = forward, true, nil
		forward._everLinked, forward._incoming, forward._behind = true, true, back
		if deferred then
			continue -- (mid-step: the next link pass resolves these)
		end
		local path = BeamPath.Connect(back.Position, forward.Position, back._beamTurns, forward._beamTurns)
		if path then
			resolve(back, path, globalDt)
		else
			unlink(back)
			resolve(back, initialPath(back), globalDt)
		end
	end
	if not front.Dead and not front._ahead then
		front._beamSpan = { front.Position }
	end
	chain.joinerCount += needed
	created += needed
	frameStats.Created += needed
	Profile.Count("BeamCreated", needed)
end

function materializeAhead(s: any)
	local front = s._ahead
	if not front or (front.Dead and not front._worldStop) then
		return
	end
	local chain = s._chain
	local corners, needed = BeamPath.Plan(s.Position, front.Position, s._beamTurns, front._beamTurns)
	if corners and needed > 0 then
		local reason = blocked(chain, s, front, corners, needed)
		if reason then
			breakReasons[reason] += 1
		else
			split(chain, s, front, corners, needed, 0, false, true)
		end
	end
	s._lazyLink = nil
end

-- Inserts ONE joiner halfway along the planned link p -> front (by path
-- length; placed, moving, aged and given its energy share exactly as split
-- places the joiners there) and links p -> joiner -> front. Returns it.
local function halve(chain: any, p: any, front: any, corners: { Vector3 }): any
	local behind, ahead = p._beamTurns, front._beamTurns
	local total = 0
	for leg = 1, #corners - 1 do
		total += (corners[leg + 1] - corners[leg]).Magnitude
	end
	local leg, t, along = #corners - 1, .5, 0
	for index = 1, #corners - 1 do
		local length = (corners[index + 1] - corners[index]).Magnitude
		if along + length >= total * .5 then
			leg, t = index, if length > 0 then (total * .5 - along) / length else 0
			break
		end
		along += length
	end
	local from, to = corners[leg], corners[leg + 1]
	local phase = math.min(#behind + leg - 1, #ahead)
	local prototype = if phase == #ahead then front else p
	local velocity = if #behind == #ahead then p.Velocity:Lerp(front.Velocity, .5)
		elseif phase == #behind then p.Velocity
		elseif phase == #ahead then front.Velocity
		else (to - from).Unit * p.Velocity.Magnitude * p.Restitution ^ (phase - #behind)
	local child = joinerFrom(chain, prototype, from:Lerp(to, t), velocity, table.move(ahead, 1, phase, 1, {}))
	child._realBehind, child._realAhead = realBehind(p), realAhead(front)
	-- (toward a parked front, never its frozen age: see split)
	child.Age = if front.Dead and front._worldStop then p.Age else p.Age + (front.Age - p.Age) * .5
	child.Damage = p.Damage * .5
	if p._beamBindChild then
		p._beamBindChild(child, .5)
	end
	if p._beamScaleEnergy then
		p._beamScaleEnergy(.5)
	else
		p.Damage *= .5
	end
	table.insert(chain.samples, child)
	p._ahead, p._everLinked, p._lazyLink = child, true, nil
	child._ahead, child._everLinked, child._incoming, child._behind = front, true, true, p
	front._everLinked, front._incoming, front._behind = true, true, child
	chain.joinerCount += 1
	created += 1
	frameStats.Created += 1
	Profile.Count("BeamCreated", 1)
	return child
end

local halveAndSettle: (chain: any, back: any, front: any, corners: { Vector3 }, globalDt: number, depth: number) -> ()

-- Divide and repeat: a lazy chain's long link back -> front (planned:
-- `corners`, needing joiners) stays ONE body while nothing touches it. When
-- something does, it's halved, and each half gets the same treatment -- so
-- joiners appear only around the contact: about 2 * log2(length /
-- MaxStretch) of them, where splitting the whole link made length /
-- MaxStretch. Pieces short enough to need no joiners resolve as usual (hits,
-- clipping). The pieces nothing touches are exactly the bodies the eager
-- split's joiners would have had there, so no outcome changes.
local function settle(chain: any, back: any, front: any, corners: { Vector3 }, globalDt: number, depth: number)
	if Projectile.ProbeBeamSpan(back, corners, if front.Dead then 0.1 else nil) then
		back._lazyLink, back._everLinked, front._everLinked, front._incoming = true, true, true, true
		back._beamSpan, back._beamSpanClipped = corners, nil
		if not front.Dead and not front._ahead then
			front._beamSpan = { front.Position }
		end
		return
	end
	local reason = if depth >= MAX_HALVINGS then "Geometry" else blocked(chain, back, front, corners, 1)
	if reason then
		-- Out of joiners: it stays whole and takes its contact as one body
		-- (clipped at a wall) rather than tearing off a fragment that would
		-- hang in the air for the rest of its life.
		breakReasons[reason] += 1
		frameStats.BudgetSplits += 1
		back._lazyLink, back._everLinked, front._everLinked, front._incoming = nil, true, true, true
		resolve(back, corners, globalDt)
		if not front.Dead and not front._ahead then
			front._beamSpan = { front.Position }
		end
		return
	end
	halveAndSettle(chain, back, front, corners, globalDt, depth)
end

-- One of the halves: settled again if it's still long, else resolved.
local function settlePiece(chain: any, b: any, f: any, globalDt: number, depth: number)
	if b.Dead then
		return
	end
	local legs, needed = BeamPath.Plan(b.Position, f.Position, b._beamTurns, f._beamTurns)
	if not legs then
		unlink(b)
		resolve(b, initialPath(b), globalDt)
	elseif needed == 0 then
		resolve(b, legs, globalDt)
	else
		settle(chain, b, f, legs, globalDt, depth + 1)
	end
end

function halveAndSettle(chain: any, back: any, front: any, corners: { Vector3 }, globalDt: number, depth: number)
	local middle = halve(chain, back, front, corners)
	-- (front half first: the back half then ends wherever the middle did)
	settlePiece(chain, middle, front, globalDt, depth)
	settlePiece(chain, back, middle, globalDt, depth)
	if not front.Dead and not front._ahead then
		front._beamSpan = { front.Position }
	end
end

local function linkOne(chain: any, p: any, globalDt: number)
	do
		local front = p._ahead
		if front and front.Dead and not front._worldStop then
			if p._lazyLink then
				-- The stretch the lazy link stood for carries on without its
				-- front: halve it (graded ages, so it still expires in turn).
				-- The half that now ends at the dead front is halved again
				-- next frame, and so on, instead of every joiner at once.
				local corners, needed = BeamPath.Plan(p.Position, front.Position, p._beamTurns, front._beamTurns)
				if corners and needed > 0 and not blocked(chain, p, front, corners, 1) then
					halveAndSettle(chain, p, front, corners, globalDt, 0)
					return
				end
			end
			unlink(p)
			front = nil
		end
		if not front then
			resolve(p, initialPath(p), globalDt)
			return
		end
		local corners, needed = BeamPath.Plan(p.Position, front.Position, p._beamTurns, front._beamTurns)
		if corners and needed > 0 and front.Dead and not feeding(p, corners) then
			-- Its front stopped at a wall and a sweep has carried it past that
			-- spot. Holding on would stretch a string off the wall, and the
			-- joiners along it would park on the wall one by one, each
			-- anchoring another string. Let go: it carries on as a beam end.
			breakReasons.Parked += 1
			unlink(p, true)
			resolve(p, initialPath(p), globalDt)
			return
		end
		if corners and needed > 0 and chain.lazy and (ChunkManager.IsTimeUniform() or uniformAlong(corners)) then
			settle(chain, p, front, corners, globalDt, 0)
			return
		end
		local reason = blocked(chain, p, front, corners, needed)
		if reason then
			breakReasons[reason] += 1
			frameStats.BudgetSplits += 1
			unlink(p)
			resolve(p, initialPath(p), globalDt)
			return
		end
		if needed == 0 then
			p._lazyLink, p._everLinked, front._everLinked, front._incoming = nil, true, true, true
			resolve(p, corners :: { Vector3 }, globalDt)
			if not front.Dead and not front._ahead then
				front._beamSpan = { front.Position }
			end
			return
		end
		split(chain, p, front, corners :: { Vector3 }, needed, globalDt)
	end
end

local function timeScaleOf(s: any): number
	local source = s.Source
	return SafeMath.number(SafeMath.number(source and source.TimeScale, 1, 0) * SafeMath.number(s.TimeScale, 1, 0), 0, 0)
end

-- A dormant packet's frame: exactly what Projectile.Step does in empty
-- space under uniform time.
local function drift(s: any, dt: number)
	dt += s._simulationDebt
	if dt <= 0 then
		s._simulationDebt = dt
		return
	end
	s._simulationDebt = 0
	local a = s._accel
	s.Position += s.Velocity * dt + a * (.5 * dt * dt)
	s.Velocity += a * dt
	s.Age += dt
end

-- A dormant packet's body, built as linkOne would build it (nil: it can't
-- be one line and has to be made real, for `why`).
local function dormantBody(chain: any, s: any): ({ Vector3 }?, string?)
	local front = s._ahead
	if front and front.Dead and not front._worldStop then
		-- The packet ahead ran out. A long gap to it would carry on as
		-- joiners (graded ages); a short one just leaves a fragment.
		if chain.expireTriggers or (front.Position - s.Position).Magnitude > BeamPath.MaxStretch then
			s._lazyLink = (front.Position - s.Position).Magnitude > BeamPath.MaxStretch or nil
			return nil, "Front"
		end
		unlink(s)
		front = nil
	end
	if not front then
		local path = initialPath(s)
		s._beamSpan = path
		return path, nil
	end
	if front.Dead then
		return nil, "Wall" -- (stopped at a wall: this one is next)
	end
	local corners, needed = BeamPath.Plan(s.Position, front.Position, s._beamTurns, front._beamTurns)
	if not corners then
		return nil, "Bent"
	end
	s._lazyLink = needed > 0 or nil
	s._everLinked, front._everLinked, front._incoming = true, true, true
	s._beamSpan, s._beamSpanClipped = corners, nil
	if not front._ahead and not front._dormant then
		front._beamSpan = { front.Position }
	end
	return corners, nil
end

-- Drops vertices within STRAIGHT_TOLERANCE of a straight run: returns the
-- kept indices into `points`.
local function simplify(points: { Vector3 }): { number }
	local kept = { 1 }
	local count = #points
	if count < 2 then
		return kept
	end
	local anchor, heading = points[1], nil :: Vector3?
	for index = 2, count do
		local offset = points[index] - anchor
		if not heading then
			if offset.Magnitude > 1e-3 then
				heading = offset.Unit
			end
			continue
		end
		local along = offset:Dot(heading)
		if along > 0 and (offset - heading * along).Magnitude <= STRAIGHT_TOLERANCE then
			continue
		end
		local last = index - 1
		if kept[#kept] ~= last then
			table.insert(kept, last)
		end
		anchor = points[last]
		local leg = points[index] - anchor
		heading = if leg.Magnitude > 1e-3 then leg.Unit else nil
	end
	if kept[#kept] ~= count then
		table.insert(kept, count)
	end
	return kept
end

-- First contact along the polyline: (segment index, the centreline point).
local function castPolyline(proxy: any, points: { Vector3 }, kept: { number }): (number?, Vector3?)
	for k = 1, #kept - 1 do
		local from, to = points[kept[k]], points[kept[k + 1]]
		local offset = to - from
		local length = offset.Magnitude
		if length < 1e-4 then
			continue
		end
		local heading, traveled = offset / length, 0
		while traveled < length - 1e-4 do
			local distance = math.min(length - traveled, MAX_CAST)
			Profile.Count("BeamStrandCasts", 1)
			local contact = Raycast.castMovement(proxy, from + heading * traveled, heading * distance)
			if contact then
				return k, from + heading * (traveled + (contact.Distance or 0))
			end
			traveled += distance
		end
	end
	return nil, nil
end

-- One dormant stretch, back (newest) to front: cast it as one line; where it
-- meets something, make the packets either side of the contact real and cast
-- on from beyond them. Returns how many packets it made real (into `fresh`).
local function castStrand(chain: any, records: { any }, fresh: { any })
	local proxy = { Radius = records[1].Radius + STRAIGHT_TOLERANCE, _rayParams = records[1]._rayParams }
	local function promote(s: any, why: string)
		if s._dormant then
			materialize(s, why)
			table.insert(fresh, s)
		end
	end
	local first = 1
	while first <= #records do
		-- the line: every body from `first` on, end to end, and who owns each leg
		local points, owners = {}, {}
		local stop = #records
		for index = first, #records do
			local s = records[index]
			local body, why = dormantBody(chain, s)
			if not body then
				promote(s, why :: string)
				stop = index - 1
				break
			end
			if not s._ahead then
				-- the beam's front: also the ground it just covered
				local previous = s._prevPosition
				if previous and (s.Position - previous).Magnitude > 1e-4 then
					local _, hitAt = castPolyline(proxy, { previous, s.Position }, { 1, 2 })
					if hitAt then
						promote(s, "Hit")
						stop = index - 1
						break
					end
				end
			end
			if #points == 0 or (points[#points] - body[1]).Magnitude > 1e-3 then
				if #points > 0 then
					-- (not contiguous: cast what we have, start again here)
					stop = index - 1
					break
				end
				table.insert(points, body[1])
			end
			for leg = 2, #body do
				table.insert(points, body[leg])
				table.insert(owners, index)
			end
		end
		if #points >= 2 then
			local kept = simplify(points)
			local k, hitAt = castPolyline(proxy, points, kept)
			if k and hitAt then
				-- whose body: the nearest original leg inside the simplified one
				local owner, best = owners[kept[k]], math.huge
				for leg = kept[k], kept[k + 1] - 1 do
					local a, b = points[leg], points[leg + 1]
					local offset = b - a
					local t = math.clamp((hitAt - a):Dot(offset) / math.max(offset:Dot(offset), 1e-8), 0, 1)
					local d = (a + offset * t - hitAt).Magnitude
					if d < best then
						owner, best = owners[leg], d
					end
				end
				promote(records[owner], "Hit")
				local ahead = records[owner + 1]
				if ahead then
					promote(ahead, "Hit")
				end
				first = owner + 2
				continue
			end
		end
		first = math.max(stop, first) + 1
		-- (skip the one just made real, if any)
		while first <= #records and not records[first]._dormant do
			first += 1
		end
	end
end

-- Every dormant stretch of a chain (see castStrand); the packets made real
-- get their link this frame like everyone else.
local function castDormant(chain: any, globalDt: number)
	local samples = chain.samples
	local behindDormant: { [any]: boolean } = {}
	local any = false
	for _, s in samples do
		if s._dormant and not s.Dead then
			any = true
			local ahead = s._ahead
			if ahead and ahead._dormant and not ahead.Dead then
				behindDormant[ahead] = true
			end
		end
	end
	if not any then
		return
	end
	local fresh = {}
	for _, s in samples do
		if not s._dormant or s.Dead or behindDormant[s] then
			continue
		end
		local records = { s }
		local ahead = s._ahead
		while ahead and ahead._dormant and not ahead.Dead do
			table.insert(records, ahead)
			ahead = ahead._ahead
		end
		castStrand(chain, records, fresh)
	end
	for _, s in fresh do
		if not s.Dead then
			linkOne(chain, s, globalDt)
		end
	end
end

local function stepLinks(chain: any, globalDt: number)
	local samples = chain.samples
	local count = #samples
	for index = 1, count do
		local s = samples[index]
		local ahead = s._ahead
		if ahead and not s.Dead then
			ahead._behind = s
			if not ahead.Dead then
				ahead._incoming = true
			end
		end
	end
	for index = 1, count do
		local p = samples[index]
		if not p.Dead and not p._dormant then
			linkOne(chain, p, globalDt)
		end
	end
	castDormant(chain, globalDt)
	for _, p in samples do
		if p._lazyLink and not p.Dead then
			frameStats.Lazy += 1
		end
	end
end

--------------------------------------------------------------------------------
-- Replication (see BeamWire for the format)
--------------------------------------------------------------------------------

local function writeSpawn(w: BeamWire.Writer, s: any, stopped: boolean?)
	U8(w, Op.Spawn)
	U32(w, s.Id)
	V3(w, s.Position)
	V3(w, if stopped then Vector3.zero else s.Velocity)
	F32(w, math.max(s.Lifetime - s.Age, 0))
	local ahead = s._ahead
	U32(w, if ahead and not stopped then ahead.Id else 0)
	local fragment = s._fragment
	local origin = not ahead and not s._everLinked
	local flags = (if fragment then Flag.Fragment else 0) + (if origin then Flag.Origin else 0)
		+ (if s._beamJoiner then Flag.Joiner else 0) + (if s._everLinked then Flag.EverLinked else 0)
		+ (if stopped then Flag.Stopped else 0)
	U8(w, flags)
	if fragment then
		V3(w, fragment)
	end
	if origin then
		V3(w, s._origin)
	end
	local turns = s._beamTurns
	local n = math.min(#turns, 255)
	U8(w, n)
	for index = 1, n do
		V3(w, turns[index])
	end
	s._rep, s._repAhead, s._repTurns = true, if ahead and not stopped then ahead.Id else 0, #turns
end

local function writePose(w: BeamWire.Writer, s: any)
	U8(w, Op.Pose)
	U32(w, s.Id)
	V3(w, s.Position)
	V3(w, s.Velocity)
	F32(w, math.max(s.Lifetime - s.Age, 0))
end

local function clipState(s: any): ({ Vector3 }?, Vector3?)
	local span = s._beamSpan
	if s._beamSpanClipped and span and #span > 0 then
		return span, span[#span]
	end
	return nil, nil
end

local function writeClip(w: BeamWire.Writer, s: any, span: { Vector3 }?)
	U8(w, Op.Clip)
	U32(w, s.Id)
	local n = if span then math.min(#span, 255) else 0
	U8(w, n)
	for index = 1, n do
		V3(w, (span :: { Vector3 })[index])
	end
	s._repClipN = n
	s._repClipEnd = if span and n > 0 then span[n] else nil
end

-- Spawns `ahead` for a client that never saw it: a sample that stopped at a
-- wall in its first frame still anchors its followers.
local function ensureStopped(w: BeamWire.Writer, ahead: any?)
	if ahead and ahead.Dead and ahead._worldStop and not ahead._rep then
		writeSpawn(w, ahead, true)
	end
end

local function writeHeader(w: BeamWire.Writer, chain: any)
	local header = chain.header
	F32(w, header.radius)
	F32(w, header.length)
	for index = 1, 3 do
		U8(w, header.color[index])
	end
	for index = 1, 3 do
		U8(w, header.core[index])
	end
	V3(w, header.gravity)
	F32(w, chain.scale)
end

-- This frame's events for everyone already watching the chain.
local function encodeDelta(chain: any, now: number, globalDt: number): BeamWire.Writer?
	local w = BeamWire.Writer(512)
	U32(w, chain.id)
	U8(w, Section.Delta)
	F64(w, now)
	local start = w.n
	local samples = chain.samples
	if chain.scaleChanged then
		U8(w, Op.Scale)
		F32(w, chain.scale)
	end
	-- New samples first, so links in this section can name them.
	for _, s in samples do
		if not s.Dead and not s._rep then
			ensureStopped(w, s._ahead)
			writeSpawn(w, s)
			s._contact = nil
			local span = clipState(s)
			if span then
				writeClip(w, s, span)
			end
		end
	end
	-- Periodic poses for chains clients can't extrapolate exactly.
	local refreshing: { [any]: boolean }? = nil
	if chain.refresh or not ChunkManager.IsTimeUniform() then
		local live = #samples
		chain.refreshCarry += live * globalDt / REFRESH_PERIOD
		local budget = math.min(math.floor(chain.refreshCarry), live)
		chain.refreshCarry -= budget
		if budget > 0 then
			refreshing = {}
			for _ = 1, budget do
				if chain.refreshCursor > live then
					chain.refreshCursor = 1
				end
				(refreshing :: any)[samples[chain.refreshCursor]] = true
				chain.refreshCursor += 1
			end
		end
	end
	for _, s in samples do
		if not s._rep then
			continue
		end
		local ahead = s._ahead
		local aheadId = if ahead then ahead.Id else 0
		if aheadId ~= s._repAhead then
			-- (a dying sample too: its drained body ends at its new link)
			ensureStopped(w, ahead)
			U8(w, Op.Link)
			U32(w, s.Id)
			U32(w, aheadId)
			if aheadId == 0 then
				V3(w, s._fragment or Vector3.zero)
			end
			s._repAhead = aheadId
		end
		if s.Dead then
			continue
		end
		local turns = s._beamTurns
		if #turns > (s._repTurns or 0) then
			local hit = s._lastHit
			local frame = hit and hit.CFrame
			local contact = if frame then frame.Position else s.Position
			local normal = if frame then frame.LookVector else Vector3.yAxis
			U8(w, Op.Bounce)
			U32(w, s.Id)
			V3(w, s.Position)
			V3(w, s.Velocity)
			V3(w, contact)
			V3(w, normal)
			local first = s._repTurns + 1
			local n = math.min(#turns - first + 1, 255)
			U8(w, n)
			for index = first, first + n - 1 do
				V3(w, turns[index])
			end
			s._repTurns = #turns
			s._contact = nil
		elseif s._contact or (refreshing and refreshing[s]) then
			writePose(w, s)
			s._contact = nil
		end
		local span, finish = clipState(s)
		if span then
			if s._repClipN ~= #span or not s._repClipEnd or ((finish :: Vector3) - s._repClipEnd).Magnitude > CLIP_RESEND then
				writeClip(w, s, span)
			end
		elseif s._repClipN and s._repClipN > 0 then
			writeClip(w, s, nil)
		end
	end
	for _, death in chain.deaths do
		local s, info = death[1], death[2]
		if not s._rep then
			continue
		end
		U8(w, Op.Death)
		U32(w, s.Id)
		local kind = info.Kind
		if kind == nil then
			U8(w, DeathKind.Expire)
		else
			U8(w, if kind == "world" then DeathKind.World elseif kind == "entity" then DeathKind.Entity else DeathKind.Other)
			V3(w, info.Position)
			V3(w, info.Normal)
			U8(w, if s._beamBodyHit then 1 else 0)
		end
	end
	if w.n == start then
		return nil
	end
	U8(w, Op.End)
	return w
end

-- The whole chain for a client that just started watching it.
local function encodeSnapshot(chain: any, now: number): BeamWire.Writer
	local w = BeamWire.Writer(1024)
	U32(w, chain.id)
	U8(w, Section.Snapshot)
	F64(w, now)
	writeHeader(w, chain)
	local stopped: { [any]: boolean } = {}
	for _, s in chain.samples do
		if s.Dead then
			continue
		end
		local ahead = s._ahead
		if ahead and ahead.Dead and ahead._worldStop and not stopped[ahead] then
			stopped[ahead] = true
			writeSpawn(w, ahead, true)
		end
		writeSpawn(w, s)
		local span = clipState(s)
		if span then
			writeClip(w, s, span)
		end
	end
	U8(w, Op.End)
	return w
end

local function closedSection(id: number, kind: number, now: number): BeamWire.Writer
	local w = BeamWire.Writer(16)
	U32(w, id)
	U8(w, kind)
	F64(w, now)
	U8(w, Op.End)
	return w
end

local function playerRoots(): { [Player]: Vector3 }
	local roots = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character.PrimaryPart
		if root then
			roots[player] = root.Position
		end
	end
	return roots
end

local function bounds(chain: any): (Vector3?, Vector3?)
	local low, high = nil, nil
	for _, s in chain.samples do
		if s.Dead then
			continue
		end
		local position = s.Position
		low = if low then low:Min(position) else position
		high = if high then high:Max(position) else position
	end
	return low, high
end

local function distanceToBox(point: Vector3, low: Vector3, high: Vector3): number
	return (point - point:Max(low):Min(high)).Magnitude
end

-- Builds and sends this frame's per-recipient messages.
local function replicate(globalDt: number)
	local now = workspace:GetServerTimeNow()
	local roots = playerRoots()
	local outgoing: { [Player]: BeamWire.Writer } = {}
	local function send(player: Player, section: BeamWire.Writer)
		local out = outgoing[player]
		if not out then
			out = BeamWire.Writer(section.n + 64)
			outgoing[player] = out
		end
		BeamWire.Append(out, section)
	end
	for _, id in chainOrder do
		local chain = chains[id]
		if not chain then
			continue
		end
		if not chain.visualize then
			table.clear(chain.deaths)
			continue
		end
		local observers = chain.observers
		if chain.finished then
			-- Its last deaths, then the End.
			if next(observers) then
				local delta = encodeDelta(chain, now, globalDt)
				local section = closedSection(chain.id, Section.End, now)
				for player in observers do
					if player.Parent then
						if delta then
							send(player, delta)
						end
						send(player, section)
					end
				end
			end
			table.clear(chain.deaths)
			continue
		end
		local low, high = bounds(chain)
		local range = chain.visualRange
		local scale = SafeMath.number(chain.source and chain.source.TimeScale, 1, 0)
		chain.scaleChanged = scale ~= chain.scale
		chain.scale = scale
		local snapshot: BeamWire.Writer? = nil
		-- (nobody watching: a later snapshot carries everything)
		local delta = if next(observers) then encodeDelta(chain, now, globalDt) else nil
		local exit: BeamWire.Writer? = nil
		for player, position in roots do
			local watching = observers[player]
			local distance = if low and high then distanceToBox(position, low, high) else math.huge
			if watching and distance > range * 1.1 + 8 then
				observers[player] = nil
				exit = exit or closedSection(id, Section.Exit, now)
				send(player, exit :: BeamWire.Writer)
			elseif watching then
				if delta then
					send(player, delta)
				end
			elseif distance <= range then
				observers[player] = true
				snapshot = snapshot or encodeSnapshot(chain, now)
				send(player, snapshot :: BeamWire.Writer)
			end
		end
		for player in observers do
			if not roots[player] then
				observers[player] = nil
			end
		end
		table.clear(chain.deaths)
	end
	for player, out in outgoing do
		if player.Parent then
			VisualOffload.FireClient(player, BeamWire.Channel, BeamWire.Finish(out))
		end
	end
end

--------------------------------------------------------------------------------
-- Frame step: every head, then every link, then the stream
--------------------------------------------------------------------------------

Projectile.SetBeamSpanStep(function(globalDt: number)
	created = 0
	local orderCount = #chainOrder
	if orderCount == 0 then
		lastStats = table.clone(frameStats)
		return
	end
	local headStarted = os.clock()
	local uniform = ChunkManager.IsTimeUniform()
	local realNow = os.clock()
	local sampleCount, joinerCount, dormantCount = 0, 0, 0
	for offset = 1, orderCount do
		local chain = chains[chainOrder[offset]]
		if not chain then
			continue
		end
		local samples = chain.samples
		for index = 1, #samples do
			local s = samples[index]
			if s.Dead then
				continue
			end
			if s._dormant then
				local dt = globalDt * timeScaleOf(s)
				if not uniform and (Planner.ChunkTimeScaleAt(s.Position) ~= 1
					or Planner.ChunkTimeScaleAt(s.Position + s.Velocity * dt) ~= 1) then
					materialize(s, "Dilated") -- (Step handles dilation)
				elseif realNow - s._spawnRealTime >= s.MaxRealLifetime then
					s:Destroy(nil, nil)
					continue
				elseif s.Age + dt + s._simulationDebt >= s.Lifetime then
					-- runs out this frame, where it would have
					drift(s, math.max(s.Lifetime - s.Age - s._simulationDebt, 0))
					if chain.expireTriggers then
						materialize(s, "Expire")
					end
					s:Destroy(nil, nil)
					continue
				else
					s._prevPosition = s.Position
					drift(s, dt)
					dormantCount += 1
					continue
				end
			end
			if not Projectile.Step(s :: any, globalDt) and not s.Dead then
				s:Destroy(nil, nil)
			end
		end
	end
	Profile.Add("BeamHeads", os.clock() - headStarted)

	local linkStarted = os.clock()
	local now = os.clock()
	local ended = {}
	for offset = 1, orderCount do
		local id = chainOrder[offset]
		local chain = chains[id]
		if not chain then
			continue
		end
		-- Drop the dead (their deaths are already queued for the stream).
		local samples, kept, joiners = chain.samples, 0, 0
		local oldCount = #samples
		for index = 1, oldCount do
			local s = samples[index]
			s._incoming = false
			if not s.Dead then
				kept += 1
				samples[kept] = s
				if s._beamJoiner then
					joiners += 1
				end
			end
		end
		for index = kept + 1, oldCount do
			samples[index] = nil
		end
		chain.joinerCount = joiners
		if kept == 0 then
			if now - chain.lastLaunch > CHAIN_GRACE then
				-- (dropped after the stream has sent its last deaths)
				chain.finished = true
				table.insert(ended, chain)
			end
			continue
		end
		stepLinks(chain, globalDt)
		sampleCount += #chain.samples
		joinerCount += chain.joinerCount
	end
	Profile.Add("BeamLinkPass", os.clock() - linkStarted)
	Profile.Count("BeamSamples", sampleCount)

	local replicateStarted = os.clock()
	replicate(globalDt)
	if #ended > 0 then
		for _, chain in ended do
			chains[chain.id] = nil
		end
		local live = {}
		for _, id in chainOrder do
			if chains[id] then
				table.insert(live, id)
			end
		end
		chainOrder = live
	end
	Profile.Add("BeamReplicate", os.clock() - replicateStarted)
	frameStats.Samples, frameStats.Joiners, frameStats.Dormant = sampleCount, joinerCount, dormantCount
	Profile.Count("BeamDormant", dormantCount)
	lastStats = table.clone(frameStats)
	frameStats.Created, frameStats.BudgetSplits, frameStats.Lazy = 0, 0, 0
end)

function Chain.GetJoinerStats()
	return {
		Active = lastStats.Joiners,
		Samples = lastStats.Samples,
		Dormant = lastStats.Dormant,
		-- packets made real beamlets, by reason, since the last call
		MadeReal = (function()
			local copy = table.clone(madeReal)
			for key in madeReal do
				madeReal[key] = 0
			end
			return copy
		end)(),
		LazyLinks = lastStats.Lazy,
		Chains = #chainOrder,
		Created = lastStats.Created,
		Updated = lastStats.Joiners,
		BudgetSplits = lastStats.BudgetSplits,
		MaxPerBeam = Chain.MaxJoinersPerBeam,
		MaxNewPerFrame = Chain.MaxNewJoinersPerFrame,
		BreakReasons = table.clone(breakReasons),
	}
end

--------------------------------------------------------------------------------
-- Channels (as BeamProjectileHandler's, plus skipping)
--------------------------------------------------------------------------------

-- A channel ticks every Interval (consecutive samples just under one link
-- apart). Given Aim / Fire (SpellRuntime) instead of only Emit, a tick on a
-- lazy chain may skip its sample when it would add nothing: the aim and the
-- launch point are where the last launched sample left them and that sample
-- still flies. The skipped samples would all have flown along the chord of
-- the link from the next launched sample to that one -- the very joiners
-- that lazy link stands for -- so the skipped ticks' energy rides on the
-- next sample launched, whose body is where those samples would have been.
-- A steady beam is then a few long links that only gain joiners where they
-- touch something; a sweeping beam still gets a sample wherever the aim
-- turned.

local channels: { any } = {}
local lastInput: { [Player]: number } = {}
local nextChannelId = 0

local function fire(channel: any, shot: any, direction: Vector3)
	local share = channel.Carry / channel.Duration
	channel.Carry, channel.Pending = 0, nil
	channel.Fire(shot, direction, share, channel.Id)
end

-- One tick of `slice` seconds of the channel's duration.
local function tick(channel: any, slice: number, final: boolean)
	if not channel.Aim then
		channel.Emit(slice / channel.Duration, channel.Id)
		return
	end
	local shot, origin, direction = channel.Aim()
	channel.Carry += slice
	local chain = chains[channel.Id]
	local last = channel.Last
	if not final and last and chain and chain.lazy and chain.last == last.sample and not last.sample.Dead
		and (channel.Carry + channel.Interval) * channel.Speed <= SKIP_SPACING
		and direction:Dot(last.direction) >= SKIP_TURN and (origin - last.origin).Magnitude <= SKIP_SHIFT then
		channel.Pending = { shot, direction }
		return
	end
	fire(channel, shot, direction)
	chain = chains[channel.Id]
	channel.Last = { sample = chain and chain.last, origin = origin, direction = direction }
end

-- A channel ending while a skipped tick's energy waits: launch it now (from
-- that tick's aim), unless the caster can't cast any more.
local function flush(channel: any, castable: boolean)
	local pending = channel.Pending
	if pending and castable then
		fire(channel, pending[1], pending[2])
	end
	channel.Pending = nil
end

function Chain.IsActive(player: Player): boolean
	for _, channel in channels do
		if channel.Player == player then
			return true
		end
	end
	return false
end

function Chain.Stop(player: Player)
	for index = #channels, 1, -1 do
		local channel = channels[index]
		if channel.Player == player then
			table.remove(channels, index)
			local humanoid = channel.Character:FindFirstChildOfClass("Humanoid")
			flush(channel, player.Parent ~= nil and player.Character == channel.Character
				and humanoid ~= nil and humanoid.Health > 0)
		end
	end
	lastInput[player] = nil
end

-- KeepAlive cannot begin a cast or modify its duration/stats. Only the
-- server's validated SpellCast path can call Start.
function Chain.KeepAlive(player: Player)
	if lastInput[player] then
		lastInput[player] = os.clock()
	end
end

function Chain.BeginCast(player: Player)
	lastInput[player] = os.clock()
end

function Chain.Start(options: any): boolean
	if not lastInput[options.Player] or os.clock() - lastInput[options.Player] > INPUT_TIMEOUT then
		return false
	end
	local count = 0
	for _, channel in channels do
		if channel.Player == options.Player then
			count += 1
		end
	end
	if count >= MAX_CHANNELS_PER_PLAYER then
		return false
	end
	local channel = table.clone(options)
	nextChannelId += 1
	channel.Id = nextChannelId
	channel.Speed = options.Speed or 2000
	channel.Interval = Chain.GetInterval(channel.Speed)
	channel.Remaining = options.Duration
	channel.NextEmit = options.Delay or 0
	channel.Started = os.clock()
	channel.Carry = 0
	if not (options.Aim and options.Fire) then
		channel.Aim = nil
	end
	if channel.NextEmit == 0 then
		local slice = math.min(channel.Interval, channel.Remaining)
		channel.Remaining -= slice
		tick(channel, slice, channel.Remaining <= 1e-8)
		channel.NextEmit = channel.Interval
	end
	table.insert(channels, channel)
	return true
end

Heartbeat.Connect(function(globalDt: number)
	local now = os.clock()
	for index = #channels, 1, -1 do
		local channel = channels[index]
		local player, character = channel.Player, channel.Character
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		-- a channel only ends early if another weapon is taken out (same rule
		-- as SpellService.canCastSpells)
		local otherTool = false
		for _, child in character:GetChildren() do
			if child:IsA("Tool") and child.Name ~= "SpellAssembler" then
				otherTool = true
				break
			end
		end
		local castable = player.Parent ~= nil and player.Character == character and humanoid ~= nil
			and humanoid.Health > 0 and not otherTool
		if channel.Remaining <= 1e-8 or not castable
			or now - (lastInput[player] or 0) > INPUT_TIMEOUT or now - channel.Started >= 60 then
			table.remove(channels, index)
			flush(channel, castable)
			continue
		end
		local caster = channel.Caster
		if caster and (caster.IsDestroyed or caster.Health <= 0) then
			table.remove(channels, index)
			flush(channel, false)
			continue
		end
		local scale = ChunkManager.GetTimeScaleAt(channel.Origin()) * (caster and caster.TimeScale or 1)
		if scale <= 0 then
			continue
		end
		channel.NextEmit -= globalDt * scale
		local emitted = 0
		while channel.NextEmit <= 0 and channel.Remaining > 1e-8 and emitted < MAX_PACKETS_PER_CHANNEL_FRAME do
			local slice = math.min(channel.Interval, channel.Remaining)
			channel.Remaining -= slice
			tick(channel, slice, channel.Remaining <= 1e-8)
			channel.NextEmit += channel.Interval
			emitted += 1
		end
	end
end, { Name = "BeamChain.Channel", Priority = 4 })

Players.PlayerRemoving:Connect(function(player)
	Chain.Stop(player)
	for _, chain in chains do
		chain.observers[player] = nil
	end
end)

return Chain
