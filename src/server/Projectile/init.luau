--!native
--!strict
--!optimize 2
--[[
	Projectile (server)
	Server-authoritative, raycast-driven projectiles that live in dilated time.
	Every projectile steps in the local time of the chunk it currently occupies,
	so a bullet flying through a 0.2x slow zone crawls, its gravity floats, and
	its fuse burns slower — all for free. Because of that, a dilated Lifetime
	alone can't bound a projectile's real-world lifespan -- something frozen at
	0x (its own TimeScale, its Source's personal ratio, or its chunk) would
	never expire on its own. MaxRealLifetime is a separate, real-time
	(wall-clock) hard cap that always applies regardless of dilation -- see
	DEFAULT_MAX_REAL_LIFETIME / Projectile.SetDefaultMaxRealLifetime below.

	This module lives in ServerScriptService (never replicated to clients) --
	all hit-detection, lag-compensation, homing-acquisition, and damage-
	adjacent logic (raycast filters, penetration math, pierce/damage
	multipliers) stays server-only and unreadable by any client, on purpose.
	The purely cosmetic rendering half lives in ReplicatedStorage.Shared as
	ProjectileClient -- require that from client code, this module from
	server code. The two communicate only over VisualOffload's ProjSpawnBatch /
	ProjMove / ProjHitBatch / ProjSync / ProjTimeScale / ProjRay channels (see
	Projectile/Replication.luau for the sending side).

	Supported behaviours (mix and match): straight shots, ballistic gravity,
	acceleration/deceleration, bouncing (restitution), homing (explicit target or
	auto-acquire by tag(s), with optional Permalock), piercing with falloff, and
	cone bursts. Rendering can be offloaded to clients (Visualize = true): the
	server keeps only the logic. Visuals receive ProjSpawn with their current
	trajectory config and ProjHit on destruction. Finite-range observers also
	receive ProjRangeExit and a fresh authoritative spawn on re-entry; sparse
	corrections must never be lost permanently outside that range.
	On top of that there are three
	independent, orthogonal streaming mechanisms, each covering a different case
	the client can't safely reproduce on its own:
	 - Continuous sync while actively homing (self.HomingTarget ~= nil, checked
	   fresh every tick, never a static classification): the client only ever
	   sees a target's position through that target's own replication lag, which
	   differs per observer, so if it rotated toward that position locally, two
	   clients watching the same missile chase the same target could compute two
	   different flight paths. While a lock is held, the server streams
	   authoritative Position/Velocity through a persistent round-robin batch
	   capped at MAX_SYNC_UPDATES_PER_FRAME. At ordinary counts that is every
	   tick; at stress-test counts each cohort updates on alternating frames.
	   The cursor advances in real frame order and is never reset by dilation,
	   so changing GlobalTimeScale cannot merge staggered cohorts into one spike.
	   A rare ProjSync event tells clients when a visual crosses in or out of
	   continuous-sync mode.
	 - A one-shot correction on every bounce: reproducing a bounce client-side
	   requires matching the server's exact raycast resolution/timing AND
	   knowing which hits are really entities (piercable/filterable, server-only
	   knowledge -- the client has no replicated entity registry to check
	   against), neither of which the client can do reliably. So rather than
	   staying synced for the rest of its life, a bouncing projectile is only
	   ever corrected on the frame it actually bounces: that frame's ProjMove
	   batch carries one entry (Bounced = true) with the contact point and the
	   end-of-frame post-bounce Position/Velocity, which the client snaps to
	   and treats as its new local physics baseline. Between bounces (and
	   before the first one, and after the last one) the client is fully
	   unsynced and coasts on local physics, just like a non-homing,
	   non-bouncing shot.
	 - A one-shot ProjTimeScale message every time a projectile's personal/local
	   dilation actually CHANGES (Source.TimeScale * projectile.TimeScale --
	   see "Local time" below), not a continuous stream: the client can't
	   predict a ratio it's never been told, but once it knows the current
	   number it can fold it straight into the same local ChunkManager.ScaleDt
	   dead-reckoning every unsynced visual already does (see ProjectileClient's
	   render loop), exactly like it already does for chunk/world dilation
	   (which similarly replicates as sparse chunk-scale updates, not a
	   per-projectile stream).
	These three mechanisms are independent and compose freely: a homing
	projectile that also bounces stays continuously synced while locked (the
	bounce's position/velocity is folded into that same stream) and, if it
	loses its lock while bounces remain, drops to the bounce-only
	one-shot-correction mode instead of going fully local. A bounce correction
	is always applied unconditionally on receipt, whether or not the visual is
	currently in continuous-sync mode; likewise a ProjTimeScale update always
	applies unconditionally (a homing-synced visual just caches it for later,
	in case its lock later drops). All client-side simulation is purely
	cosmetic; the server always runs its own independent, authoritative Step,
	and any visual drift is corrected the instant ProjHit snaps the final
	position.

	Beams predict their linked centerline from timestamped motion seeds, with
	sparse safety/steering snapshots and immediate topology/clipping corrections.
	A body contact never teleports a distant
	back endpoint onto the leading endpoint's wall; each moving head owns its
	wall bounce/penetration timing. Client beam sections are tessellated after
	union and capped to 12 studs without limiting the beam's total reach.

	API:
	 Projectile.new(config) -> projectile
	 Projectile.Burst(config, count) -> { projectile }
	 Projectile.SetDebugRays(enabled)            -- default off; see debugRays below
	 Projectile.SetDefaultMaxRealLifetime(seconds) -- default 60; see MaxRealLifetime below
	 Projectile.SetDebugSync(enabled)            -- see Projectile/Replication.luau
	 (Rendering API -- EnableClientRendering(), SetImpactHandler(fn) -- moved to
	 ProjectileClient in ReplicatedStorage.Shared; require that from client code.)

	 Query (server-only -- projectiles only ever live in the server's `active`
	 list. Every result is the LIVE projectile object, not a copy, so an
	 ability can read OR write any field on it directly -- e.g.
	 projectile.Damage = x, or the dedicated projectile:SetTimeScale(x) below --
	 and it takes effect on the very next Step, same tick):
	 Projectile.GetAll() -> { projectile }
	 Projectile.GetBySource(source) -> { projectile }       -- e.g. "my own live shots"
	 Projectile.GetInRadius(position, radius, options?) -> { projectile }
	    options: { Filter: (projectile) -> boolean }
	    -- Linear scan, not chunk-indexed like Entity/ChunkManager's spatial
	    -- queries -- fine at this game's projectile counts (MAX_ACTIVE_
	    -- PROJECTILES_PER_PLAYER in Shooter.server.luau caps it well below
	    -- where that would matter); revisit if a future ability calls this
	    -- every frame at very high projectile counts.

	 projectile:SetTimeScale(scale)   -- clamped >= 0; see TimeScale below

	 Events (Signal.luau -- see that module for the full API; :Connect(fn) ->
	 Connection with :Disconnect()). There is no config.OnHit anymore: connect
	 on the returned projectile instead, e.g.
	   local proj = Projectile.new(config)
	   proj.OnHit:Connect(function(hit) ... end)
	 projectile.OnHit    -- fires on EVERY contact worth reporting: an entity
	                         hit (piercing or final), a world bounce, a
	                         successful wall-penetration, or a final world
	                         stop. Does NOT fire for natural Lifetime/
	                         MaxRealLifetime expiry (nothing was actually hit).
	                         Listener receives one table:
	                           { CFrame: CFrame, Part: BasePart, Entity: Entity?,
	                             Hurtbox: ("Head" | "Body")? }
	                         Entity is nil for a pure world/wall contact.
	                         Hurtbox is which of the entity's two hurtboxes
	                         (see Entity.luau's "Head + Body hurtboxes"
	                         section) was struck -- nil alongside a nil
	                         Entity. Shooter.server.luau applies the target's
	                         HeadshotMultiplier when this is "Head". The
	                         module deals no damage itself anymore -- read
	                         projectile.Damage * projectile.DamageMultiplier
	                         (the latter already reflects PierceFalloff) and
	                         apply it yourself, e.g. via hit.Entity:TakeDamage
	                         or projectile.Source:DealDamage. This is what
	                         makes per-projectile custom effects possible
	                         (status effects, chain lightning, whatever) without
	                         touching this module.
	 projectile.OnDestroy -- fires exactly ONCE, whenever the projectile is
	                         actually removed (entity kill shot, world stop,
	                         bounces/penetration exhausted, or natural
	                         expiry). Listener receives
	                           { Position: Vector3, Normal: Vector3, Kind: string? }
	                         Kind is "entity" | "world" | nil (nil covers both
	                         a fizzled/expired shot and a bare Destroy() call),
	                         or whatever a caller passes to Destroy(result,
	                         kind) -- e.g. SpellRuntime's "detonate".
	                         Use this for exactly-once bookkeeping (e.g.
	                         Shooter.server.luau's activeProjectileCount
	                         decrement) -- OnHit is NOT exactly-once, since
	                         piercing/bouncing/penetrating fire it without
	                         destroying the projectile.

	 config (all optional unless noted):
	   Origin: Vector3          (required)
	   Direction: Vector3       (required unless TargetPosition given)
	   TargetPosition: Vector3  (aim at a world point instead of a direction)
	   Speed = 100
	   Acceleration = 0         (number: studs/s² along AccelerationDirection,
	              or current velocity when no direction is supplied; negative
	              decelerates. Vector3: arbitrary world-space acceleration)
	   AccelerationDirection = nil (optional direction for numeric Acceleration)
	   MinSpeed = 0, MaxSpeed = math.huge   (clamp after acceleration + gravity)
	   Lifetime = 5             (3 for beams; dilated seconds; no upper bound is enforced)
	   MaxRealLifetime = 60     (real, undilated seconds -- a hard safety cap
	              independent of Lifetime/TimeScale/chunk dilation; see
	              DEFAULT_MAX_REAL_LIFETIME below. Fires even if this
	              projectile's effective time is completely frozen, since
	              Age itself would otherwise never advance)
	   TimeScale = 1            (this projectile's OWN dilation, independent of
	              Source -- see the "Local time" section below; live-mutable
	              via projectile:SetTimeScale() or the field directly)
	   Damage = 0               (data only -- the module never deals damage
	              itself anymore; read Damage * DamageMultiplier in your own
	              projectile.OnHit listener and apply it yourself. Kept +
	              still adjusted by PierceFalloff purely as a convenience so
	              callers don't have to reimplement pierce falloff bookkeeping)
	   Source = entity          (excluded from ever being hit; see IgnoreInstances)
	   IgnoreInstances = {Instance} (raw instances the raycast/spherecast never
	              hits, e.g. the shooter's character -- independent of Source,
	              so self-hits stay impossible even if the firing entity hasn't
	              been registered with the Entity system yet; see Raycast.buildRayParams)
	   Filter = (entity)->bool  (which entities count as targets; also applied to homing acquisition)
	   Gravity = 0              (number: studs/s² downward; Vector3: custom
	              world-space gravity. Integrated as acceleration with dilated dt)
	   Radius = 0               (>0 sweeps a capsule: cylindrical segment body
	                              plus spherical substep-joint/end caps)
	   Bounces = 0              (world bounces before it dies; no upper bound is enforced)
	   Restitution = 0.5        (velocity kept per bounce)
	   Penetration = 0          (studs of wall material this projectile can punch
	              through; see attemptPenetration in Raycast.luau. Tried BEFORE
	              bouncing on a world hit; a wall thicker than the remaining
	              Penetration blocks it, falling through to Bounces/destroy as
	              normal. Persistent, depleting state -- punching through
	              several thin walls in a row keeps consuming the same budget)
	   MaxPierces = 0           (enemies passed through)
	   PierceFalloff = 0        (damage lost per pierce, 0..1 -- see Damage above)
	   Homing = { Target?, TargetTag?, TargetTags?, AcquireRadius?, Retarget?,
	              ReacquireRate?, AcquireInterval = 0.1, Permalock?,
	              TurnRate = rad/s, Delay = 0 }
	              -- AcquireInterval: dilated seconds between searches while no
	              -- target is held (jittered 0.5x-1.5x to spread bursts).
	              -- TargetTags (plural, list of strings) matches any tag in the
	              -- list; TargetTag (singular) is still supported for a single tag.
	              -- Permalock (default off): once locked, a Retarget recheck never
	              -- drops the target due to range -- only if it's destroyed. Off by
	              -- default, a dropped-out-of-range lock is genuinely released (not
	              -- silently kept stale). The projectile's own Source is always
	              -- excluded from acquisition, and Filter (if set) is respected.
	   Visualize = false, VisualRange = math.huge
	   Model = Instance?        (cloned client-side) or Visual = {Shape,Size,Color}
	   VisualScale = 1          (0.05..20; applied once when the client clones
	                            the visual, with no per-frame scaling cost)
	   Beam = { Length = 24 }   (optional traveling cylinder path tail; defaults
	                            Speed to 2000 and Radius to 0.35 when omitted.
	                            Length clamps to 0.05..512 studs; swept-radius
	                            head collision is unchanged. The visual tail
	                            follows the already-swept path, including bends,
	                            and drains after impact instead of vanishing.
	                            Sustained spells launch through BeamProjectileHandler:
	                            ChannelId/PreviousId join moving endpoints; tilted
	                            section-body collision runs through this same resolver.)
	   DestroyDelay = 0         (client keeps the visual this long after impact)
	   WaitForParticles = true (client-side; while true, a ParticleEmitter
	              under the visual is only disabled on destroy -- already-
	              emitted particles keep fading out over their own Lifetime,
	              and the model's actual :Destroy() waits out the longest one.
	              false deletes every ParticleEmitter immediately instead,
	              contributing no wait -- see VisualModel.FadeOut)
	   WaitForTrails = true    (same as WaitForParticles, but for Trail
	              instances. If both this and WaitForParticles are false, or
	              one is false and the model has none of the other kind, the
	              visual is destroyed instantly with no grace period)
	   ActivateParticlesOnCreate = false (client-side; when true, every
	              ParticleEmitter under the visual fires once via :Emit()
	              right after spawn, per its own EmitCount/EmitDelay
	              attributes -- defaults to 5 / 0s when either is unset;
	              EmitDelay is seconds from spawn until that emitter actually
	              emits -- see VisualModel.ActivateParticles)
	   OnBounce = fn(projectile, result)   -- still config-driven, unlike OnHit (see Events above)
	   RewindSeconds = 0        (lag compensation; see below)

	 Lag compensation: when RewindSeconds > 0 (set by Shooter.server.luau from the
	 firing player's Player:GetNetworkPing() / 2), entity-hit validity while the
	 projectile is stepping through a chunk that contains entities is decided
	 against each nearby entity's Entity:GetPositionAt(now - RewindSeconds) instead
	 of its live position, LOS-checked against real geometry. This is fixed per
	 projectile at creation time (the shooter's desync at the moment they fired),
	 so simultaneous shots from different-ping players independently see hurtboxes
	 rewound by their own offset. Projectiles not created with a positive
	 RewindSeconds (anything not fired through Shooter.server.luau) are unaffected.

	 Personal time: a projectile's Source may carry its own TimeScale (see
	 Entity:SetTimeScale) independent of the world/chunk dilation the projectile
	 flies through -- a player's own personal time ratio (see TimeControlGui.luau /
	 PlayerManager.server.luau) only affects them and, via this, the bullets they
	 fire. Source.TimeScale is read LIVE every Step (not snapshotted), so a
	 shooter dragging their ratio mid-flight speeds up or slows down bullets
	 already in the air, in real time, exactly like it does their own movement.
	 A projectile with no Source, or a Source that never had its TimeScale set,
	 flies at 1x personal scale (i.e. unaffected).

	 Local time: independent of Source.TimeScale, every projectile also carries
	 its own TimeScale (config.TimeScale, default 1). This is the hook for
	 abilities that affect projectiles directly rather than through who fired
	 them -- e.g. an AoE "time bubble" that finds every projectile in a radius
	 (Projectile.GetInRadius) each tick and sets an extra multiplier on it, or
	 permanently slows/speeds a specific shot via projectile:SetTimeScale().
	 Both TimeScale sources are read live every Step and simply multiply
	 together (world/chunk dilation * Source.TimeScale * projectile.TimeScale),
	 so an ability's effect composes with the shooter's own personal ratio
	 rather than overriding it, and always reflects whatever either was most
	 recently set to -- there's no snapshotting anywhere in this chain.

	 The client can't predict a live-changing ratio it was never told about (an
	 ability's radius check, or another player's personal TimeScale, aren't
	 otherwise replicated to observers) -- but it doesn't need continuous
	 position streaming to use one once it knows it. Every Step, the server
	 diffs the combined Source.TimeScale * projectile.TimeScale against the
	 last value it streamed for that projectile and, only on an actual change,
	 sends a single small ProjTimeScale { Id, TimeScale } message (see
	 Projectile.new for the initial value and Replication.updateTimeScale for
	 the on-change check). The client stores that number per visual and
	 multiplies it straight into its local dead-reckoning (see
	 ProjectileClient's render loop), the same way it already accounts for
	 chunk/world dilation.

	 Input safety: every config value goes through Config.normalize (NaN falls
	 back to the default, +-inf and anything past SafeMath.Limit = 1e9 clamps),
	 so a hostile or broken aim can never put a NaN into the simulation.
	 Position/Velocity/TimeScale stay live-writable and are re-checked each
	 Step; a projectile that leaves the +-1e9 world bound simply expires. This is unrelated to Replication.isSynced/homing,
	 which is still the one case that genuinely needs a continuous
	 authoritative stream (see above).
]]


local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Heartbeat = require(Shared:WaitForChild("Heartbeat"))
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local Entity = require(Shared:WaitForChild("Entity"))
local ProjectileMotion = require(Shared:WaitForChild("ProjectileMotion"))
local Planner = require(Shared:WaitForChild("ProjectileStepPlanner"))
local SafeMath = require(Shared:WaitForChild("SafeMath"))
local Signal = require(Shared:WaitForChild("Signal"))
local BeamPath = require(Shared:WaitForChild("Projectile"):WaitForChild("BeamPath"))

local Config = require(script.Config)
local Homing = require(script.Homing)
local Math = require(script.Math)
local Raycast = require(script.Raycast)
local Replication = require(script.Replication)
local Occupancy = require(script.Occupancy)
local RewindHit = require(script.RewindHit)
local Types = require(script.Types)

export type Config = Types.Config
export type HitInfo = Types.HitInfo
export type DestroyInfo = Types.DestroyInfo

local Projectile = {}
Projectile.__index = Projectile

-- The live projectile: its public/internal state plus the methods below.
-- Declared as an intersection (not typeof(setmetatable(...))) so a projectile
-- is directly usable anywhere a Types.State is expected.
type Methods = {
	Step: (self: Projectile, globalDt: number) -> boolean,
	Destroy: (self: Projectile, result: { Position: Vector3, Normal: Vector3 }?, kind: string?) -> (),
	SetTimeScale: (self: Projectile, scale: number) -> (),
	ResolveBeamSpan: (self: Projectile, points: { Vector3 }, allowHits: boolean?, cornerIndices: { number }?) -> { Vector3 },
	ClearBeamPrevious: (self: Projectile) -> (),
}
export type Projectile = Types.State & Methods

local MIN_STEP_DT = ProjectileMotion.MinStepDt
local MAX_SUBSTEPS = 16
-- Homing re-aims once per substep, so cap how far one substep can turn.
local MAX_HOMING_TURN_STEP = math.rad(5)
-- Projectile.Burst never creates more than this many pellets in one call.
local MAX_BURST_COUNT = 10000

local active: { Projectile } = {} -- server-side live projectiles
-- Time spent in the step loop, for the debug panel (TakeStepTiming).
local stepTime, stepFrames, stepWorst = 0, 0, 0
local nextId = 0
local beamSpanStep: ((number) -> ())? = nil

-- Dedicated beam work runs after ALL heads are stepped, but before pose
-- replication. Never mix an old front pose with an already-stepped back.
function Projectile.SetBeamSpanStep(callback: (number) -> ())
	assert(not beamSpanStep, "Beam span handler already installed")
	beamSpanStep = callback
end

-- When on, every movement raycast is streamed to rendering clients so the hit
-- detection can be seen as lines (see ProjRay in ProjectileClient). Off by
-- default -- this is a per-substep debug stream, expensive at high projectile
-- counts. Toggle from a client via the "SetProjectileDebug" channel (see
-- example/init.server.luau).
local debugRays = false

function Projectile.SetDebugRays(enabled: boolean)
	debugRays = enabled == true
end

function Projectile.SetDebugSync(enabled: boolean)
	Replication.DebugSync = enabled == true
end

-- Hard real-time (wall-clock, undilated) cap on how long any projectile can
-- stay alive, regardless of its own dilated Lifetime/Age. A projectile whose
-- effective time is frozen (its Source's personal ratio, its own TimeScale,
-- or the chunk it's sitting in all read as 0 -- see Step) never advances Age,
-- so the normal Lifetime expiry alone would let it live in `active` forever.
-- Checked every Step via os.clock(), independent of dt. Per-shot override via
-- config.MaxRealLifetime.
local defaultMaxRealLifetime = 60 -- real seconds

function Projectile.SetDefaultMaxRealLifetime(seconds: number)
	defaultMaxRealLifetime = SafeMath.number(seconds, defaultMaxRealLifetime, 0)
end

-- The shooter's personal ratio times this projectile's own ratio -- see the
-- "Local time" section above. Both are live-writable from outside (an Entity
-- or an ability can set either to anything), so both are sanitized here.
local function combinedTimeScale(projectile: Types.State): number
	local source = projectile.Source
	local sourceScale = SafeMath.number(source and source.TimeScale, 1, 0)
	return SafeMath.number(sourceScale * SafeMath.number(projectile.TimeScale, 1, 0), 0, 0)
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function Projectile.new(config: Config): Projectile
	local settings = Config.normalize(config, defaultMaxRealLifetime)
	local homing = settings.Homing
	nextId += 1

	local state: Types.State = {
		Id = nextId,
		Position = settings.Origin,
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

		Homing = homing,
		HomingDelay = if homing then homing.Delay else 0,
		HomingTarget = if homing then homing.Target else nil,
		ReacquireTimer = 0,

		Visualize = settings.Visualize,
		VisualRange = settings.VisualRange,
		Model = settings.Model,
		Visual = settings.Visual,
		VisualScale = settings.VisualScale,
		Beam = settings.Beam,
		_beamOrigin = if settings.Beam then settings.Origin else nil,
		_beamTurns = if settings.Beam and settings.Beam.ChannelId then {} else nil,
		DestroyDelay = settings.DestroyDelay,
		WaitForParticles = settings.WaitForParticles,
		WaitForTrails = settings.WaitForTrails,
		ActivateParticlesOnCreate = settings.ActivateParticlesOnCreate,

		-- See "Events" in the module doc comment. Fresh Signal per projectile.
		OnHit = Signal.new() :: any,
		OnDestroy = Signal.new() :: any,
		OnBounce = settings.OnBounce,

		RewindSeconds = settings.RewindSeconds,
		Dead = false,

		_spawnRealTime = os.clock(),
		_acquireTimer = 0, -- throttles searches while no target is held; see Homing
		_ignore = {}, -- entities already pierced
		-- Lag-compensation working state, reset each Step (see RewindHit).
		_rewindTime = 0,
		_rewindCache = {},
		_simulationDebt = 0, -- personal/global seconds carried across frames
		_rayParams = Raycast.buildRayParams(settings.Source, settings.IgnoreInstances),
		_spawnStreamed = false,
		_streamedSynced = false,
		_lastStreamedTimeScale = 1,
	}
	state._streamedSynced = Replication.isSynced(state)
	-- Baseline for Replication.updateTimeScale; set before spawnVisual so the
	-- spawn snapshot's TimeScale matches.
	state._lastStreamedTimeScale = combinedTimeScale(state)

	local self: Projectile = setmetatable(state, Projectile) :: any
	table.insert(active, self)
	Replication.spawnVisual(self)
	return self
end

-- A real beamlet: unique identity, ordinary simulation, replication and
-- collision events. The handler binds spell energy/quota before its first step.
function Projectile.CreateBeamSample(template: Projectile, position: Vector3, velocity: Vector3, turns: { Vector3 }): Projectile
	local state = table.clone(template)
	nextId += 1
	state.Id = nextId
	state.Position, state.Velocity, state.Speed = position, velocity, velocity.Magnitude
	state.RewindSeconds = 0
	state._beamJoiner, state._beamJoinerWorldStop = true, nil
	state.Beam = template.Beam and table.clone(template.Beam)
	state.Homing = template.Homing and table.clone(template.Homing)
	state._beamTurns = table.clone(turns)
	state._beamPrevious, state._beamSpan, state._beamSpanClipped = nil, nil, nil
	state._spawnStreamed, state._streamedSynced = false, Replication.isSynced(state)
	state._ignore, state._rewindCache, state._simulationDebt = table.clone(template._ignore), {}, 0
	state._rayParams = Raycast.buildRayParams(state.Source, state.IgnoreInstances)
	state.Dead, state._beamBodyHit = false, nil
	state._beamReserveChildren, state._beamBindChild, state._beamScaleEnergy = nil, nil, nil
	state.OnHit, state.OnDestroy = Signal.new() :: any, Signal.new() :: any
	local self = setmetatable(state, Projectile) :: any
	table.insert(active, self)
	return self
end

function Projectile.PublishBeamSample(self: Projectile)
	Replication.spawnVisual(self)
end

-- Cone burst: `count` projectiles spread around the base direction.
function Projectile.Burst(config: Config, count: number): { Projectile }
	local origin = SafeMath.vector(config.Origin, Vector3.zero)
	local baseDirection = Config.direction(config, origin)
	local spread = Config.spread(config)
	local shots = {}
	for _ = 1, math.floor(SafeMath.number(count, 0, 0, MAX_BURST_COUNT)) do
		-- Each pellet gets its own normalized Homing table from Config, so
		-- siblings never share mutable state.
		local pellet = table.clone(config)
		pellet.TargetPosition = nil
		pellet.Direction = Math.coneDirection(baseDirection, spread)
		table.insert(shots, Projectile.new(pellet))
	end
	return shots
end

-- This projectile's OWN local dilation -- see the module doc comment's
-- "Local time" section. Read live every Step, so an ability can dial this up
-- or down over time (or reset it to 1) and the change is immediate. Setting
-- the .TimeScale field directly works identically.
function Projectile.SetTimeScale(self: Projectile, scale: number)
	self.TimeScale = SafeMath.number(scale, 1, 0)
end

--------------------------------------------------------------------------------
-- Query (server-only in practice -- see the module doc comment's API section)
--------------------------------------------------------------------------------

function Projectile.GetAll(): { Projectile }
	return table.clone(active)
end

function Projectile.GetStats()
	local stats = Replication.getQueueStats()
	return {
		Active = #active,
		VisualSpawnsPerFrame = stats.VisualSpawnsPerFrame,
		VisualHitsPerFrame = stats.VisualHitsPerFrame,
		PendingVisualSpawns = stats.PendingVisualSpawns,
		PendingVisualHits = stats.PendingVisualHits,
		BeamPoseCandidates = stats.BeamPoseCandidates,
		BeamPoseUpdates = stats.BeamPoseUpdates,
		BeamRefreshInterval = stats.BeamRefreshInterval,
		BeamHomingRefreshInterval = stats.BeamHomingRefreshInterval,
	}
end

-- Movement raycasts skipped through empty space since the last call (see
-- Occupancy), then resets -- DebugService's Stats tab reads this.
function Projectile.TakeOccupancyStats()
	return Occupancy.TakeStats()
end

-- Average and worst step-loop time (ms per frame) since the last call, then
-- resets -- DebugService's Stats tab reads this.
function Projectile.TakeStepTiming(): (number, number)
	local average = if stepFrames > 0 then stepTime / stepFrames * 1000 else 0
	local worst = stepWorst * 1000
	stepTime, stepFrames, stepWorst = 0, 0, 0
	return average, worst
end

function Projectile.GetBySource(source: Types.EntityLike): { Projectile }
	local result = {}
	for _, projectile in active do
		if projectile.Source == source then
			table.insert(result, projectile)
		end
	end
	return result
end

export type QueryOptions = {
	Filter: ((projectile: Projectile) -> boolean)?,
}

function Projectile.GetInRadius(position: Vector3, radius: number, options: QueryOptions?): { Projectile }
	local filter = options and options.Filter
	local result = {}
	for _, projectile in active do
		if (projectile.Position - position).Magnitude <= radius then
			if not filter or filter(projectile) then
				table.insert(result, projectile)
			end
		end
	end
	return result
end

--------------------------------------------------------------------------------
-- Per-substep movement
--------------------------------------------------------------------------------

local function integrate(projectile: Types.State, velocity: Vector3, dt: number): (Vector3, Vector3)
	return ProjectileMotion.Integrate(
		velocity,
		projectile.Acceleration,
		projectile.AccelerationDirection,
		projectile.Gravity,
		projectile.MinSpeed,
		projectile.MaxSpeed,
		dt
	)
end

-- Moves to `fraction` of this substep's chord and spends only the matching
-- share of stepDt. The time after a contact is refunded to the caller, so a
-- pierce/penetration/bounce keeps flying for the rest of the frame instead of
-- silently losing it -- the client never sees pierces or penetrations and
-- keeps coasting, so any time lost here would be pure server/client drift.
-- Returns the dilated seconds consumed.
local function advanceToContact(
	projectile: Types.State,
	from: Vector3,
	displacement: Vector3,
	fraction: number,
	startVelocity: Vector3,
	stepDt: number
): number
	local clamped = math.clamp(fraction, 0, 1)
	local contactDt = stepDt * clamped
	projectile.Velocity = if contactDt > 0 then (integrate(projectile, startVelocity, contactDt)) else startVelocity
	projectile.Position = from + displacement * clamped
	projectile.Age += contactDt
	return contactDt
end

-- A pass-through contact (pierce, penetration, or a nudge past an ignored
-- entity) teleports the projectile forward past the surface. The client
-- flies straight through the same span in real time, so charge the time it
-- would take to cover it. Returns the dilated seconds consumed.
local function chargePassThrough(projectile: Types.State, contactPosition: Vector3): number
	local speed = projectile.Velocity.Magnitude
	if not (speed >= 1e-5) then
		return 0
	end
	local skipped = (projectile.Position - contactPosition):Dot(projectile.Velocity) / speed
	if not (skipped > 0) then
		return 0
	end
	local skipDt = skipped / speed
	projectile.Velocity = (integrate(projectile, projectile.Velocity, skipDt))
	projectile.Age += skipDt
	return skipDt
end

-- Applies a resolver's verdict. Returns the total dilated seconds this
-- substep consumed, or nil once the projectile has been destroyed.
local function settle(
	projectile: Projectile,
	verdict: Types.Verdict,
	kind: string?,
	contact: Types.Contact,
	contactPosition: Vector3,
	consumed: number
): number?
	if verdict == "destroy" then
		projectile:Destroy(contact, kind)
		return nil
	elseif verdict == "pass" then
		return consumed + chargePassThrough(projectile, contactPosition)
	end
	-- "bounce": the client is re-baselined by the bounce snap instead.
	-- ("fallthrough" can't reach here: both callers resolve it first.)
	return consumed
end

-- Moves one planned substep of `stepDt` dilated seconds, resolving the first
-- contact along the way. Returns the dilated seconds actually consumed (less
-- than stepDt when a contact interrupted the chord, possibly more when a
-- pass-through skipped ahead), or nil once the projectile has been destroyed.
local function advance(projectile: Projectile, stepDt: number, highRes: boolean): number?
	Homing.update(projectile, stepDt)
	local startVelocity = projectile.Velocity
	local endVelocity, movementVelocity = integrate(projectile, startVelocity, stepDt)
	local from = projectile.Position
	local displacement = movementVelocity * stepDt
	local to = from + displacement

	-- Lag-compensated entity check, only while in an entity-containing chunk
	-- and only for shots carrying a shooter's rewind offset. RewindHit already
	-- applies Filter, so a hit here never falls through.
	if highRes and projectile.RewindSeconds > 0 then
		local entity, point, normal, hurtbox = RewindHit.check(projectile, from, to)
		if entity and point and normal then
			if debugRays then
				Replication.streamRay(projectile, from, point, false)
			end
			local contact: Types.Contact = { Position = point, Normal = normal }
			local fraction = Math.chordFraction(from, displacement, point)
			local consumed = advanceToContact(projectile, from, displacement, fraction, startVelocity, stepDt)
			local contactPosition = projectile.Position
			-- (casts: the analyzer widens literal unions returned across modules)
			local verdict = Raycast.resolveEntityHit(projectile, entity, contact, hurtbox :: Types.Hurtbox?)
			return settle(projectile, verdict :: Types.Verdict, "entity", contact, contactPosition, consumed)
		end
	end

	local contact = Raycast.castMovement(projectile, from, displacement)
	if debugRays then
		Replication.streamRay(projectile, from, if contact then contact.Position else to, not highRes)
	end
	if not contact then
		projectile.Velocity = endVelocity
		projectile.Position = to
		projectile.Age += stepDt
		return stepDt
	end

	-- Distance is how far the ray (or sphere center) travelled, which is exact
	-- for Spherecast where contact.Position is the surface instead.
	local length = displacement.Magnitude
	local fraction = if length > 1e-5 then (contact.Distance or 0) / length else 0
	local consumed = advanceToContact(projectile, from, displacement, fraction, startVelocity, stepDt)
	local contactPosition = projectile.Position

	local instance = contact.Instance
	if highRes and projectile.RewindSeconds > 0 and instance and Entity.Get(instance) then
		-- We're lag-compensating this segment and the rewound check above
		-- found no valid hit -- from the shooter's ping-adjusted view this
		-- entity wasn't actually there, so the live-position coincidence
		-- doesn't count. Nudge past and keep flying.
		Raycast.nudgePast(projectile, contact.Position)
		return settle(projectile, "pass", nil, contact, contactPosition, consumed)
	end

	local verdict, kind = Raycast.resolveHit(projectile, contact)
	return settle(projectile, verdict :: Types.Verdict, kind, contact, contactPosition, consumed)
end

--------------------------------------------------------------------------------
-- Per-projectile step
--------------------------------------------------------------------------------

-- Advances the projectile one frame; returns false when it should be
-- removed. Returning false without hitting anything (Lifetime/MaxRealLifetime
-- expiry, leaving the world limit) is a natural expiry: no OnHit fires, and
-- the step loop's Destroy() fires OnDestroy with a nil Kind.
function Projectile.Step(self: Projectile, globalDt: number): boolean
	if self.Dead then
		return false
	end

	-- Hard real-time cap, checked BEFORE anything dt-dependent -- this is the
	-- one expiry check that MUST run even while the projectile is completely
	-- frozen, since Age never advances in that state.
	if os.clock() - self._spawnRealTime >= self.MaxRealLifetime then
		return false
	end

	-- Position/Velocity are public and live-writable; a bad write from an
	-- ability must not poison the math. Out-of-world positions expire.
	self.Velocity = SafeMath.vector(self.Velocity, Vector3.zero)
	if not SafeMath.isFiniteVector(self.Position) then
		return false
	end

	-- Personal/global time is consumed below one spatial segment at a time.
	-- Chunk scale is deliberately NOT folded in here: each segment samples the
	-- chunk it is entering, so crossing a slow/frozen boundary takes effect at
	-- the boundary instead of one whole frame late.
	local combinedScale = combinedTimeScale(self)
	-- Sent BEFORE the frozen early return below, so a ratio change that
	-- freezes the projectile entirely still reaches the client.
	Replication.updateTimeScale(self, combinedScale)
	if not (globalDt > 0) or combinedScale <= 0 then
		-- Frozen: keep it alive, don't move it. A lock can still be cleared
		-- externally while frozen.
		Replication.updateSyncState(self)
		return true
	end

	-- Pin the rewind instant for every substep this frame; see RewindHit.
	if self.RewindSeconds > 0 then
		self._rewindTime = os.clock() - self.RewindSeconds
		table.clear(self._rewindCache)
	end

	local remaining = globalDt * combinedScale + self._simulationDebt
	-- With no dilated chunk or zone anywhere, every boundary search can only
	-- return "none", so skip them (they dominate substep cost at scale).
	local uniformTime = ChunkManager.IsTimeUniform()
	local homing = self.Homing
	local guard = 0
	while remaining > MIN_STEP_DT and guard < MAX_SUBSTEPS do
		guard += 1
		local lifeRemaining = self.Lifetime - self.Age
		if lifeRemaining <= MIN_STEP_DT then
			return false
		end

		local accelerationVector =
			ProjectileMotion.GetAcceleration(self.Velocity, self.Acceleration, self.AccelerationDirection, self.Gravity)
		local sample, chunkScale = Planner.Sample(self.Position, self.Velocity, accelerationVector, uniformTime)
		if chunkScale <= 0 then
			-- Real time spent in a frozen chunk is consumed without building a
			-- catch-up burst for when the chunk is unfrozen.
			remaining = 0
			break
		end

		-- Adaptive raycast resolution: fine steps where entities are (so fast
		-- bullets can't tunnel through a target), long ones in empty space. A
		-- cast is never skipped outright, only lengthened.
		local highRes = Raycast.chunkHasEntities(sample)
		local maxDt = math.huge
		if homing and self.HomingTarget and homing.TurnRate > 0 then
			maxDt = MAX_HOMING_TURN_STEP / homing.TurnRate
		end
		local stepDt = Planner.StepDt(
			self.Position,
			self.Velocity,
			accelerationVector,
			chunkScale,
			remaining,
			lifeRemaining,
			highRes,
			uniformTime,
			maxDt
		)
		if stepDt <= 0 then
			break -- too little time to integrate; carried below
		end

		local consumed = advance(self, stepDt, highRes)
		if not consumed then
			return false -- destroyed by a hit
		end
		remaining -= consumed / chunkScale

		if self.Age >= self.Lifetime - MIN_STEP_DT then
			return false
		end
	end

	-- Whatever wasn't simulated -- past this frame's substep budget, too small
	-- to integrate, or overspent by a pass-through (negative) -- carries to the
	-- next frame, so no time is ever lost or gained relative to the client.
	self._simulationDebt = remaining

	if not SafeMath.isFiniteVector(self.Position) then
		return false -- flew past SafeMath.Limit
	end
	Replication.updateSyncState(self)
	return true
end

-- Linked-body tests must never advance/reflect the distant back endpoint.
-- Movement Step owns wall bounces/penetration and their triggers. Here a world
-- obstruction clips the body; entity contacts still use the normal damage and
-- pierce pipeline once per packet. This prevents a leading ricochet from
-- instantly pulling every trailing sample onto the same wall.
function Projectile.ResolveBeamSpan(self: Projectile, points: { Vector3 }, allowHits: boolean?, cornerIndices: { number }?): { Vector3 }
	local clipped = { points[1] }
	self._beamSpanClipped = nil
	if self.Dead then return clipped end
	local ignore = self._rayParams.FilterDescendantsInstances
	for entity in self._ignore do if entity.Instance then table.insert(ignore, entity.Instance) end end
	local filtered = RaycastParams.new()
	filtered.FilterType = Enum.RaycastFilterType.Exclude
	filtered.IgnoreWater = self._rayParams.IgnoreWater
	filtered.CollisionGroup = self._rayParams.CollisionGroup
	filtered.FilterDescendantsInstances = ignore
	local contacts = 0
	for index = 1, #points - 1 do
		local from, to = points[index], points[index + 1]
		local offset = to - from
		local length = offset.Magnitude
		if length < 1e-4 then continue end
		local heading, traveled = offset / length, 0
		while traveled < length - 1e-4 do
			local distance = math.min(length - traveled, 1000)
			local contact = Raycast.castMovement(self, from + heading * traveled, heading * distance, filtered)
			if not contact then traveled += distance; continue end
			local entity = contact.Instance and Entity.Get(contact.Instance)
			if not entity then
				-- Surface contact is not the sphere center. Keep the rendered
				-- endpoint on the swept centerline, including its radius clearance.
				table.insert(clipped, from + heading * (traveled + contact.Distance))
				self._beamSpanClipped = true
				-- Each inserted beamlet owns its contact/trigger, not the whole
				-- original gap. Bounce still belongs to its moving tip; do not
				-- reflect an endpoint from a distant body contact.
				if self._beamJoiner and self.BouncesLeft <= 0 and self.Penetration <= 0
					and allowHits ~= false and combinedTimeScale(self) > 0
					and ChunkManager.GetTimeScaleAt(contact.Position) > 0 then
					self._beamSpan, self._beamBodyHit = clipped, true
					self.OnHit:Fire(Raycast.buildHitInfo(contact, nil, nil))
					self:Destroy(contact, "world")
				end
				return clipped
			end
			-- Frozen portions do not deliver repeated body-trigger hits. Still
			-- calculate clipping so geometry stays coherent across time bubbles.
			if allowHits == false or combinedTimeScale(self) <= 0 or ChunkManager.GetTimeScaleAt(contact.Position) <= 0 then
				table.insert(ignore, entity.Instance)
				filtered.FilterDescendantsInstances = ignore
			else
				local position, velocity = self.Position, self.Velocity
				self.Velocity = heading * velocity.Magnitude
				local headPosition = entity:GetHeadPosition()
				local hurtbox: Types.Hurtbox = if headPosition and (contact.Position-headPosition).Magnitude <= entity.HeadRadius then "Head" else "Body"
				local verdict = Raycast.resolveEntityHit(self, entity, contact, hurtbox)
				self.Position, self.Velocity = position, velocity
				if verdict == "destroy" then
					table.insert(clipped, from + heading * (traveled + contact.Distance))
					self._beamSpan = BeamPath.Compact(clipped, cornerIndices)
					self._beamSpanClipped = true
					self._beamBodyHit = true
					self:Destroy(contact, "entity")
					return clipped
				end
				-- A rejected entity must not fall through into world reflection.
				table.insert(ignore, entity.Instance)
				filtered.FilterDescendantsInstances = ignore
			end
			contacts += 1
			if contacts >= 16 then self._beamSpanClipped = true; return clipped end
		end
		table.insert(clipped, to)
	end
	return clipped
end
function Projectile.ClearBeamPrevious(self: Projectile)
	if not self.Beam or not self.Beam.PreviousId then return end
	self.Beam.PreviousId, self._beamPrevious = nil, nil
	self._beamSpanClipped = nil
	Replication.queueCorrection(self, self.Position, Vector3.yAxis)
end

function Projectile.Destroy(self: Projectile, result: { Position: Vector3, Normal: Vector3 }?, kind: string?)
	if self.Dead then
		return
	end
	self.Dead = true
	self._beamJoinerWorldStop = kind == "world" and not self._beamBodyHit
	local info: Types.DestroyInfo = {
		Position = if result then SafeMath.vector(result.Position, self.Position) else self.Position,
		Normal = if result then SafeMath.unit(result.Normal, Vector3.yAxis) else Vector3.yAxis,
		Kind = kind,
	}
	if self.Beam and kind == "world" and not self._beamBodyHit then
		-- Followers may finish at this stopped tip. Store its cleared center,
		-- not the pre-cast position or a point inside the wall.
		self.Position = info.Position + info.Normal * self.Radius
	end
	Replication.queueHit(self, info)

	-- Exactly-once -- see the module doc comment's "Events" section. Every
	-- removal path funnels through this one call, including natural expiry
	-- (which the step loop below Destroy()s once Step returns false).
	self.OnDestroy:Fire(info)

	-- Defensive: drop heavy references so a projectile object that somehow
	-- outlives removal from `active` (e.g. a caller retaining the returned
	-- handle) doesn't keep entities/closures alive through it.
	table.clear(self._ignore)
	self.HomingTarget = nil
	self._beamPrevious = nil
	self.OnHit:Destroy()
	self.OnDestroy:Destroy()
end

--------------------------------------------------------------------------------
-- Server step loop
--------------------------------------------------------------------------------

Heartbeat.Connect(function(globalDt: number)
	Replication.flushHitBatch()

	debug.profilebegin("Projectile.StepAll")
	local stepStarted = os.clock()
	-- Backwards with swap-removal: dead projectiles leave `active` the same
	-- frame (so GetAll/GetInRadius never return them), and anything spawned by
	-- an OnHit/OnDestroy handler mid-loop is appended past `i` and first steps
	-- next frame.
	for i = #active, 1, -1 do
		local projectile = active[i]
		if projectile:Step(globalDt) then
			-- Ordinary homing streams continuously; beams are filtered into sparse
			-- refreshes and immediate topology corrections after link refinement.
			Replication.queuePose(projectile)
		else
			local last = #active
			active[i] = active[last]
			active[last] = nil
			projectile:Destroy(nil, nil)
		end
	end
	local stepElapsed = os.clock() - stepStarted
	stepTime += stepElapsed
	stepFrames += 1
	if stepElapsed > stepWorst then stepWorst = stepElapsed end
	debug.profileend()
	if beamSpanStep then beamSpanStep(globalDt) end

	-- Publish only completed end-of-frame snapshots. Beam refinement can
	-- insert colliding children above: sending their parent before those
	-- children existed exposed an incomplete newest section for one frame.
	-- Keep spawn-before-move ordering and the existing bounded spawn queue.
	Replication.flushSpawnBatch()
	Replication.flushMoveBatch()
end, { Name = "ProjectileSystem.Step", Priority = 5 })

return Projectile
