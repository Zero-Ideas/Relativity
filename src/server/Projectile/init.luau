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
	 Projectile.Compile(config) -> compiled   -- do the config work once...
	 Projectile.Fire(compiled, origin, direction) -> projectile  -- ...then fire it cheaply
	 Projectile.FireBurst(compiled, origin, direction, count) -> { projectile }
	 Projectile.SetDebugRays(enabled)            -- default off; see debugRays below
	 Projectile.SetDefaultMaxRealLifetime(seconds) -- default 60; see MaxRealLifetime below
	 Projectile.SetDebugSync(enabled)            -- see Projectile/Replication.luau
	 (Rendering API -- EnableClientRendering(), SetImpactHandler(fn) -- moved to
	 ProjectileClient (ReplicatedStorage.Shared.Projectile.Client); require that from client code.)

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
	   Radius = 0               (>0 sweeps a capsule near entity-occupied chunks;
	                              entity-free spans use a cheaper centerline ray.
	                              Broad/ambiguous boundary spans retain the radius.)
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
	              -- An explicit Target is always a lock: Retarget only re-checks
	              -- targets the projectile acquired itself, so a passed-in Target
	              -- is kept (whatever its range or Filter) until it's gone.
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


local RunService = game:GetService("RunService")
local FrameProfiler = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("FrameProfiler"))
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Heartbeat = require(Shared:WaitForChild("Heartbeat"))
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local Entity = require(Shared:WaitForChild("Entity"))
local ProjectileMotion = require(Shared:WaitForChild("Projectile"):WaitForChild("Motion"))
local Planner = require(Shared:WaitForChild("Projectile"):WaitForChild("StepPlanner"))
local SafeMath = require(Shared:WaitForChild("SafeMath"))
local Signal = require(Shared:WaitForChild("Signal"))
local BeamPath = require(Shared:WaitForChild("Projectile"):WaitForChild("BeamPath"))

local Config = require(script.Config)
local Homing = require(script.Homing)
local Math = require(script.Math)
local Raycast = require(script.Raycast)
local Replication = require(script.Replication)
local Occupancy = require(script.Occupancy)
local Sweep = require(script.Sweep)
local Parallel = require(script.Parallel)
local Store = require(script.Store)
local Spec = require(script.Spec)
local Profile = require(script.Profile)
local RewindHit = require(script.RewindHit)
local Types = require(script.Types)

export type Config = Types.Config
export type HitInfo = Types.HitInfo
export type DestroyInfo = Types.DestroyInfo

local Projectile = {}
Projectile.__index = Projectile
-- Live projectiles keep their per-frame fields in Store's buffer behind this
-- metatable (fields read and write as usual); released ones get Projectile.
local Live = Store.Metatable(Projectile)
-- Per-projectile values an efficient handle only makes when first read.
local LAZY: { [string]: () -> any } = {
	OnHit = Signal.new,
	OnDestroy = Signal.new,
	_ignore = function()
		return {}
	end,
	_rewindCache = function()
		return {}
	end,
}

-- The live projectile: its public/internal state plus the methods below.
-- Declared as an intersection (not typeof(setmetatable(...))) so a projectile
-- is directly usable anywhere a Types.State is expected.
type Methods = {
	Step: (self: Projectile, globalDt: number) -> boolean,
	Destroy: (self: Projectile, result: { Position: Vector3, Normal: Vector3 }?, kind: string?) -> (),
	SetTimeScale: (self: Projectile, scale: number) -> (),
	ResolveBeamSpan: (self: Projectile, points: { Vector3 }, allowHits: boolean?, cornerIndices: { number }?) -> { Vector3 },
	ProbeBeamSpan: (self: Projectile, points: { Vector3 }, trimEnd: number?) -> boolean,
	ClearBeamPrevious: (self: Projectile) -> (),
}
export type Projectile = Types.State & Methods

-- A config prepared once by Projectile.Compile, fired with Projectile.Fire.
export type Compiled = {
	Config: Config, -- (a private copy; the fallback for shots that can't be efficient)
	Efficient: boolean,
	Settings: any,
	Metatable: any,
	Spread: number,
	InitialScale: number,
	RayParams: RaycastParams?,
}

local MIN_STEP_DT = ProjectileMotion.MinStepDt
local MAX_SUBSTEPS = Sweep.MaxSubsteps -- shared with the parallel workers' copy of the loop
-- Homing re-aims once per substep, so cap how far one substep can turn.
local MAX_HOMING_TURN_STEP = Sweep.MaxHomingTurnStep -- (shared with the workers)
-- Projectile.Burst never creates more than this many pellets in one call.
local MAX_BURST_COUNT = 10000

local active: { Projectile } = {} -- server-side live projectiles
local activeSlot: { number } = {} -- active[i]'s Store record (kept in step with active)
-- Time per frame spent in each phase of the server loop, for the debug
-- panel (TakeStepTiming): projectile movement, beam body refinement, and
-- replication flushing.
local PHASES = { "Step", "Beam", "Replication" }
local phaseTotal: { [string]: number } = { Step = 0, Beam = 0, Replication = 0 }
local phaseWorst: { [string]: number } = { Step = 0, Beam = 0, Replication = 0 }
local phaseFrames = 0
local dispatchElapsed = 0 -- this frame's parallel dispatch, counted into its Step time
local function recordPhase(name: string, elapsed: number)
	phaseTotal[name] += elapsed
	if elapsed > phaseWorst[name] then
		phaseWorst[name] = elapsed
	end
end
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

local createProjectile: (config: Config) -> Projectile

-- (timed for the Stats tab's frame split: spawning runs wherever the caller
-- does, usually between frames)
function Projectile.new(config: Config): Projectile
	local started = os.clock()
	local self = createProjectile(config)
	Profile.Add("Spawn", os.clock() - started)
	Profile.Count("Spawned", 1)
	return self
end

function createProjectile(config: Config): Projectile
	local settings = Config.normalize(config, defaultMaxRealLifetime)
	local homing = settings.Homing
	nextId += 1

	-- EFFICIENT (the default for plain shots): no table of its own, just a
	-- handle on a Store record and a shared spec -- see Store.luau / Spec.luau.
	-- Homing, beams and lag-compensated shots carry lots of per-projectile
	-- state and step serially anyway, so they keep a full table, as does
	-- anything with config.Efficient = false.
	if config.Efficient ~= false and not homing and not settings.Beam and settings.RewindSeconds <= 0 then
		local rayParams = Raycast.buildRayParams(settings.Source, settings.IgnoreInstances)
		local _, metatable = Spec.Get(settings, rayParams, Projectile, LAZY)
		local initial = {
			Source = settings.Source,
			TimeScale = settings.TimeScale,
			Visualize = settings.Visualize,
		}
		local values = {
			Id = nextId,
			Position = settings.Origin,
			Velocity = settings.Direction * settings.Speed,
			Age = 0,
			_simulationDebt = 0,
			TimeScale = settings.TimeScale,
			Dead = false,
			_spawnRealTime = os.clock(),
			_spawnStreamed = false,
			_streamedSynced = false, -- (no homing target, no beam)
			-- baseline for Replication.updateTimeScale, as below
			_lastStreamedTimeScale = combinedTimeScale(initial :: any),
			Visualize = settings.Visualize,
			Source = settings.Source,
		}
		local self: Projectile = Store.Adopt({ _slot = 0 }, metatable, values)
		table.insert(active, self)
		table.insert(activeSlot, (self :: any)._slot)
		Replication.spawnVisual(self)
		Parallel.Offer(self)
		return self
	end

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

	local self: Projectile = Store.Adopt(state, Live)
	table.insert(active, self)
	table.insert(activeSlot, (self :: any)._slot)
	Replication.spawnVisual(self)
	Parallel.Offer(self)
	return self
end

-- A real beamlet: unique identity, ordinary simulation, replication and
-- collision events. The handler binds spell energy/quota before its first step.
function Projectile.CreateBeamSample(template: Projectile, position: Vector3, velocity: Vector3, turns: { Vector3 }): Projectile
	local state = Store.CloneRaw(template) -- (plain fields, no record yet)
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
	-- never inherit the parent's slot or applied-this-frame mark
	state._parallelState, state._sweepMark = nil, nil
	state._beamReserveChildren, state._beamBindChild, state._beamScaleEnergy = nil, nil, nil
	state.OnHit, state.OnDestroy = Signal.new() :: any, Signal.new() :: any
	local self = Store.Adopt(state, Live)
	table.insert(active, self)
	table.insert(activeSlot, self._slot)
	Parallel.Offer(self)
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

--------------------------------------------------------------------------------
-- Compiled configs
--------------------------------------------------------------------------------

-- Does everything Projectile.new does with a config ONCE -- normalizing it,
-- its raycast params, finding its shared spec (Spec.luau) -- so firing it is
-- just a buffer record and a handle (Projectile.Fire). For anything fired
-- repeatedly with the same settings: a weapon, a spell cast's copies, a
-- stress test. Origin / Direction / TargetPosition in `config` are ignored
-- (each Fire gives its own). Source is baked in, so compile per shooter.
-- Configs that can't be efficient (homing, beams, lag compensation,
-- Efficient = false) still work: Fire falls back to Projectile.new.
function Projectile.Compile(config: Config): Compiled
	local copy = table.clone(config)
	copy.Origin, copy.Direction, copy.TargetPosition = nil, nil, nil
	local settings = Config.normalize(copy, defaultMaxRealLifetime)
	local efficient = copy.Efficient ~= false and not settings.Homing and not settings.Beam
		and settings.RewindSeconds <= 0
	local metatable, rayParams = nil, nil
	if efficient then
		rayParams = Raycast.buildRayParams(settings.Source, settings.IgnoreInstances)
		local _, found = Spec.Get(settings, rayParams, Projectile, LAZY)
		metatable = found
	end
	return table.freeze({
		Config = copy, -- (never mutated: Fire clones it)
		Efficient = efficient,
		Settings = settings,
		Metatable = metatable,
		Spread = Config.spread(copy),
		-- the combined scale a shot starts with, unless Source's changes
		InitialScale = SafeMath.number(settings.TimeScale, 1, 0),
		RayParams = rayParams,
	}) :: any
end

-- One projectile from a compiled config, from `origin` along `direction`.
function Projectile.Fire(compiled: Compiled, origin: Vector3, direction: Vector3): Projectile
	local started = os.clock()
	local self: Projectile
	if compiled.Efficient then
		local settings = compiled.Settings
		origin = SafeMath.vector(origin, Vector3.zero)
		direction = SafeMath.unit(direction, Vector3.zAxis)
		nextId += 1
		local source = settings.Source
		local ownScale = compiled.InitialScale
		-- (combinedTimeScale, inline: the Source's scale is read live)
		local sourceScale = SafeMath.number(source and source.TimeScale, 1, 0)
		local lastScale = SafeMath.number(sourceScale * ownScale, 0, 0)
		local velocity = direction * settings.Speed
		local spawnTime = os.clock()
		self = Store.AdoptFast({ _slot = 0 }, compiled.Metatable, origin, velocity, ownScale,
			nextId, spawnTime, lastScale, settings.Visualize, source)
		table.insert(active, self)
		table.insert(activeSlot, (self :: any)._slot)
		Replication.spawnVisual(self)
		-- straight into a worker slot when it can be (else queued as usual)
		if debugRays or not Parallel.PackNew(self, origin, velocity, lastScale, compiled.RayParams :: RaycastParams,
			spawnTime + settings.MaxRealLifetime) then
			Parallel.Offer(self)
		end
	else
		local config = table.clone(compiled.Config) :: any
		config.Origin, config.Direction = origin, direction
		self = createProjectile(config)
	end
	Profile.Add("Spawn", os.clock() - started)
	Profile.Count("Spawned", 1)
	return self
end

-- `count` projectiles from a compiled config, spread around `direction` by
-- its Spread (like Projectile.Burst).
function Projectile.FireBurst(compiled: Compiled, origin: Vector3, direction: Vector3, count: number): { Projectile }
	local base = SafeMath.unit(direction, Vector3.zAxis)
	local shots = {}
	for _ = 1, math.floor(SafeMath.number(count, 0, 0, MAX_BURST_COUNT)) do
		table.insert(shots, Projectile.Fire(compiled, origin, Math.coneDirection(base, compiled.Spread)))
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

-- Projectile-steps done by parallel workers vs serially since the last call
-- (see Parallel), then resets -- DebugService's Stats tab reads this.
function Projectile.TakeParallelStats()
	return Parallel.TakeStats()
end

-- Average ms per frame of each part of the main thread's movement work (see
-- Profile.luau), then resets -- DebugService's Stats tab reads this.
function Projectile.TakeProfile(): { [string]: number }
	return Profile.Take()
end

-- Average and worst ms per frame of each phase (Step / Beam / Replication)
-- since the last call, then resets -- DebugService's Stats tab reads this.
-- e.g. { StepMs = 12.1, StepWorstMs = 18.0, BeamMs = ..., ReplicationMs = ... }
function Projectile.TakeStepTiming(): { [string]: number }
	local result = {}
	for _, name in PHASES do
		result[name .. "Ms"] = if phaseFrames > 0 then phaseTotal[name] / phaseFrames * 1000 else 0
		result[name .. "WorstMs"] = phaseWorst[name] * 1000
		phaseTotal[name], phaseWorst[name] = 0, 0
	end
	phaseFrames = 0
	return result
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

-- The motion constants of the projectile runSubsteps is stepping, read once
-- instead of on every integrate (each read of an efficient projectile goes
-- through its metatable). Dropped whenever a contact is settled -- the only
-- point mid-step where user code (OnHit, OnBounce, Destroy handlers) can run
-- and change them -- so the next substep re-reads.
local cached: any = nil
local cAcceleration: any, cDirection: Vector3?, cGravity: any = 0, nil, 0
local cMinSpeed, cMaxSpeed, cLifetime = 0, math.huge, 0

local function cacheMotion(projectile: any)
	cached = projectile
	cAcceleration, cDirection, cGravity = projectile.Acceleration, projectile.AccelerationDirection, projectile.Gravity
	cMinSpeed, cMaxSpeed, cLifetime = projectile.MinSpeed, projectile.MaxSpeed, projectile.Lifetime
end

-- A worker's contact for the projectile about to resume serially from it
-- (applySweep), consumed by its first substep's cast (advance).
local pendingFor: any = nil
local pendingContact: any = nil

local function integrate(projectile: Types.State, velocity: Vector3, dt: number): (Vector3, Vector3)
	if projectile == cached then
		return ProjectileMotion.Integrate(velocity, cAcceleration, cDirection, cGravity, cMinSpeed, cMaxSpeed, dt)
	end
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
	cached = nil -- (handlers may have changed its motion constants)
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

	-- A worker that stopped at this very segment already cast it: use its hit
	-- (when it's exactly this segment and what it hit still exists).
	local contact: Types.Contact? = nil
	local reused = false
	if pendingFor == projectile then
		local pending = pendingContact
		pendingFor, pendingContact = nil, nil
		if pending and pending.From == from and pending.Displacement == displacement and pending.Instance.Parent then
			contact = { Position = pending.Position, Normal = pending.Normal, Instance = pending.Instance,
				Distance = pending.Distance }
			reused = true
		end
	end
	if not reused then
		contact = Raycast.castMovement(projectile, from, displacement, nil, highRes)
	end
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

local runSubsteps: (self: Projectile, remaining: number, guard: number, uniformTime: boolean) -> boolean
local finishStep: (self: Projectile, remaining: number) -> boolean

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
	return runSubsteps(self, remaining, 0, ChunkManager.IsTimeUniform())
end

-- The rest of a frame's substeps, from `remaining` personal/global seconds
-- with `guard` substeps already spent -- Step's own loop, and where a parallel
-- worker's result resumes when it stopped at a contact (see applySweep).
function runSubsteps(self: Projectile, remaining: number, guard: number, uniformTime: boolean): boolean
	local homing = self.Homing
	while remaining > MIN_STEP_DT and guard < MAX_SUBSTEPS do
		guard += 1
		if cached ~= self then
			cacheMotion(self)
		end
		local age = self.Age
		local lifeRemaining = cLifetime - age
		if lifeRemaining <= MIN_STEP_DT then
			cached = nil
			return false
		end

		local position, velocity = self.Position, self.Velocity
		local accelerationVector = ProjectileMotion.GetAcceleration(velocity, cAcceleration, cDirection, cGravity)
		local sample, chunkScale = Planner.Sample(position, velocity, accelerationVector, uniformTime)
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
			position,
			velocity,
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
			cached = nil
			return false -- destroyed by a hit
		end
		remaining -= consumed / chunkScale

		if self.Age >= self.Lifetime - MIN_STEP_DT then
			cached = nil
			return false
		end
	end

	cached = nil
	return finishStep(self, remaining)
end

-- Whatever wasn't simulated -- past this frame's substep budget, too small to
-- integrate, or overspent by a pass-through (negative) -- carries to the next
-- frame, so no time is ever lost or gained relative to the client.
function finishStep(self: Projectile, remaining: number): boolean
	self._simulationDebt = remaining
	if not SafeMath.isFiniteVector(self.Position) then
		return false -- flew past SafeMath.Limit
	end
	Replication.updateSyncState(self)
	return true
end

--------------------------------------------------------------------------------
-- Parallel movement (see Parallel.luau / Sweep.luau)
--------------------------------------------------------------------------------

-- May this projectile be swept by a worker this frame? Its combined time
-- scale if so. Homing (target choice runs Filter callbacks) and lag-
-- compensated shots (need entity history) stay serial, as does anything the
-- prologue of Step would stop.
--
-- Everything below runs once per projectile per frame on the main thread
-- (tens of thousands of times under load), so the common case avoids calls:
-- SafeMath checks and combinedTimeScale are inlined, os.clock() is read once
-- per frame, and replication helpers are only called when their state would
-- actually change.
local LIMIT = SafeMath.Limit
local abs = math.abs
local dispatchNow = 0 -- os.clock() at this frame's dispatch
-- step outcomes this frame, flushed to Parallel's stats once per frame
local counted = { Parallel = 0, Resumed = 0, Serial = 0, Fallback = 0 }

local function finiteVector(v: Vector3): boolean
	return abs(v.X) <= LIMIT and abs(v.Y) <= LIMIT and abs(v.Z) <= LIMIT
end

-- combinedTimeScale for ordinary values (falls back to it for anything else),
-- with identical results.
local function fastScale(projectile: Projectile): number
	local source = projectile.Source
	local sourceScale = if source then source.TimeScale else 1
	local ownScale = projectile.TimeScale
	if type(sourceScale) == "number" and type(ownScale) == "number" and sourceScale >= 0 and ownScale >= 0
		and sourceScale < LIMIT and ownScale < LIMIT then
		local scale = sourceScale * ownScale
		if scale < LIMIT then
			return scale
		end
	end
	return combinedTimeScale(projectile)
end

local function parallelScale(projectile: Projectile): number?
	if projectile.Dead or projectile.RewindSeconds > 0 or debugRays then
		return nil
	end
	if dispatchNow - projectile._spawnRealTime >= projectile.MaxRealLifetime then
		return nil
	end
	if not finiteVector(projectile.Position) or not finiteVector(projectile.Velocity) then
		return nil
	end
	local scale = fastScale(projectile)
	if not (scale > 0) then
		return nil
	end
	-- Neither can change while it keeps its slot (a new scale or homing sends
	-- it back through here), so its applier doesn't re-check them per frame.
	Replication.updateTimeScale(projectile, scale)
	Replication.updateSyncState(projectile)
	return scale
end
Parallel.SetEligibility(parallelScale)

-- Applies a worker's result in place of Step, or falls back to Step when the
-- projectile changed after it was dispatched (`dirty`: an ability moved it;
-- or it gained homing, time scales changed...). Same return as Step. Plain
-- values (see Parallel.Apply), so a result costs no tables.
local function applySweep(self: Projectile, globalDt: number, status: number, position: Vector3,
	velocity: Vector3, age: number, remaining: number, guard: number, dirty: boolean, fromScale: number,
	timeVersion: number, uniform: boolean, contact: Parallel.WorkerContact?, homingTimers: { number }?): boolean
	if self.Dead then
		return false
	end
	if os.clock() - self._spawnRealTime >= self.MaxRealLifetime then
		return false
	end
	if dirty or self.RewindSeconds > 0
		or combinedTimeScale(self) ~= fromScale or ChunkManager.GetTimeVersion() ~= timeVersion then
		counted.Fallback += 1
		local started = os.clock()
		local alive = self:Step(globalDt)
		Profile.Add("SerialFallback", os.clock() - started)
		return alive
	end
	if status == Sweep.Contact then
		counted.Resumed += 1
	else
		counted.Parallel += 1
	end
	Replication.updateTimeScale(self, fromScale)
	self.Position, self.Velocity, self.Age = position, velocity, age
	if homingTimers and self.Homing then
		-- (the worker steered it: its homing timers as of where it stopped)
		self.HomingDelay, self._acquireTimer, self.ReacquireTimer = homingTimers[1], homingTimers[2], homingTimers[3]
	end
	if status == Sweep.Expired then
		return false
	elseif status == Sweep.Contact then
		-- (timed for the Stats tab: finishing a frame at a contact -- the cast,
		-- hit resolution, and Destroy when it dies there)
		local started = os.clock()
		pendingFor, pendingContact = self, contact
		local alive = runSubsteps(self, remaining, guard, uniform)
		pendingFor, pendingContact = nil, nil
		Profile.Add("SerialContact", os.clock() - started)
		Profile.Count("SerialContacts", 1)
		return alive
	end
	return finishStep(self, remaining)
end

-- Results are applied in one pass before the step loop; each projectile is
-- marked with this frame's stepMark (negated when it died), and the loop only
-- reads the mark (see the server step loop below). Parallel.Apply writes the
-- plain "moved, hit nothing" results straight into Store; this applier gets
-- the rest and finishes them serially.
local stepMark = 0
local applyDt = 0
local PARALLEL_DROP, PARALLEL_REFRESH = Parallel.Drop, Parallel.Refresh

local function applySwept(self: Projectile, status: number, position: Vector3, velocity: Vector3,
	age: number, remaining: number, guard: number, dirty: boolean, fromScale: number, timeVersion: number,
	uniform: boolean, contact: Parallel.WorkerContact?, homingTimers: { number }?): number
	if applySweep(self, applyDt, status, position, velocity, age, remaining, guard, dirty, fromScale,
		timeVersion, uniform, contact, homingTimers) then
		self._sweepMark = stepMark
		return PARALLEL_REFRESH
	end
	self._sweepMark = -stepMark
	return PARALLEL_DROP
end

-- Linked-body tests must never advance/reflect the distant back endpoint.
-- Movement Step owns wall bounces/penetration and their triggers. Here a world
-- obstruction clips the body; entity contacts still use the normal damage and
-- pierce pipeline once per packet. This prevents a leading ricochet from
-- instantly pulling every trailing sample onto the same wall.
-- Body-cast params for this packet: its movement filter plus every entity it
-- already pierced. Built once and reused across frames; rebuilt only when the
-- pierced set grows (ResolveBeamSpan runs for every beam packet every frame,
-- and rebuilding them each call was thousands of allocations per frame).
local function spanParams(self: Projectile): RaycastParams
	local cached = self._spanParams
	if cached then
		return cached
	end
	-- Nothing pierced yet: exactly its movement filter, which is already
	-- shared (Raycast.buildRayParams). ResolveBeamSpan copies before excluding.
	if next(self._ignore) == nil then
		return self._rayParams
	end
	local ignore = self._rayParams.FilterDescendantsInstances
	for entity in self._ignore do if entity.Instance then table.insert(ignore, entity.Instance) end end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = self._rayParams.IgnoreWater
	params.CollisionGroup = self._rayParams.CollisionGroup
	params.FilterDescendantsInstances = ignore
	self._spanParams = params
	return params
end

local function clipBeamPath(points: { Vector3 }, index: number, endpoint: Vector3?): { Vector3 }
	local clipped = table.create(index + (if endpoint then 1 else 0))
	table.move(points, 1, index, 1, clipped)
	if endpoint then clipped[index+1] = endpoint end
	return clipped
end

function Projectile.ResolveBeamSpan(self: Projectile, points: { Vector3 }, allowHits: boolean?, cornerIndices: { number }?): { Vector3 }
	self._beamSpanClipped = nil
	if self.Dead then return { points[1] } end
	-- Paths are immutable snapshots. An unobstructed span can retain its input
	-- rather than allocate/copy a second identical array every frame.
	if #points < 2 then return points end
	local filtered = spanParams(self)
	-- Entities skipped for the rest of THIS call only (frozen portions,
	-- rejected targets) go on a private copy, never the cached params.
	local ignore: { Instance }? = nil
	local function exclude(instance: Instance)
		if not ignore then
			ignore = filtered.FilterDescendantsInstances
			local private = RaycastParams.new()
			private.FilterType = filtered.FilterType
			private.IgnoreWater = filtered.IgnoreWater
			private.CollisionGroup = filtered.CollisionGroup
			filtered = private
		end
		local list = ignore :: { Instance }
		table.insert(list, instance)
		filtered.FilterDescendantsInstances = list
	end
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
				local clipped = clipBeamPath(points, index, from + heading * (traveled + contact.Distance))
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
				exclude(entity.Instance)
			else
				local headPosition = entity:GetHeadPosition()
				local hurtbox: Types.Hurtbox = if headPosition and (contact.Position-headPosition).Magnitude <= entity.HeadRadius then "Head" else "Body"
				local verdict = Raycast.resolveEntityHit(self, entity, contact, hurtbox, true)
				if verdict == "destroy" then
					local clipped = clipBeamPath(points, index, from + heading * (traveled + contact.Distance))
					self._beamSpan = BeamPath.Compact(clipped, cornerIndices)
					self._beamSpanClipped = true
					self._beamBodyHit = true
					self:Destroy(contact, "entity")
					return clipped
				end
				-- A rejected entity must not fall through into world reflection.
				exclude(entity.Instance)
			end
			contacts += 1
			if contacts >= 16 then self._beamSpanClipped = true; return clipBeamPath(points, index) end
		end
	end
	return points
end
-- True when nothing touches the body along `points` at all. No hits, no
-- clipping, no side effects: BeamChain keeps a long link in one piece while
-- this holds, and only subdivides it where the body actually meets something.
-- `trimEnd` stops that far short of the last point (a world-stopped front sits
-- exactly one radius off its wall).
function Projectile.ProbeBeamSpan(self: Projectile, points: { Vector3 }, trimEnd: number?): boolean
	local last = #points - 1
	if last < 1 then
		return true
	end
	local params = spanParams(self)
	for index = 1, last do
		local from = points[index]
		local offset = points[index + 1] - from
		local full = offset.Magnitude
		local length = if index == last and trimEnd then full - trimEnd else full
		if length < 1e-4 then
			continue
		end
		local heading, traveled = offset / full, 0
		while traveled < length - 1e-4 do
			local distance = math.min(length - traveled, 1000)
			if Raycast.castMovement(self, from + heading * traveled, heading * distance, params) then
				return false
			end
			traveled += distance
		end
	end
	return true
end

function Projectile.GetDefaultMaxRealLifetime(): number
	return defaultMaxRealLifetime
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
	if self.Beam then
		self._beamJoinerWorldStop = kind == "world" and not self._beamBodyHit
	end
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
	-- (peeked: an efficient projectile only has the signal if someone connected)
	local onDestroy = Store.Peek(self, "OnDestroy")
	if onDestroy then
		onDestroy:Fire(info)
	end

	-- Defensive: drop heavy references so a projectile object that somehow
	-- outlives removal from `active` (e.g. a caller retaining the returned
	-- handle) doesn't keep entities/closures alive through it.
	local ignore = Store.Peek(self, "_ignore")
	if ignore then
		table.clear(ignore)
	end
	self.HomingTarget = nil
	self._beamPrevious = nil
	local onHit = Store.Peek(self, "OnHit")
	if onHit then
		onHit:Destroy()
	end
	if onDestroy then
		onDestroy:Destroy()
	end
end

--------------------------------------------------------------------------------
-- Server step loop
--------------------------------------------------------------------------------

local readu8, band = buffer.readu8, bit32.band
local STORE_MARK_STRIDE, STORE_DEAD = Store.MarkStride, Store.Dead
local readi32 = buffer.readi32
local POSE_NEEDS = bit32.bor(Store.Visualize, Store.SpawnStreamed)
local POSE_EITHER = bit32.bor(Store.Synced, Store.Beam)

-- Frame split for the Stats tab: the wall time between our own handlers,
-- i.e. what the rest of the frame costs (see the Heartbeat/PreSimulation
-- handlers below).
local dispatchEndedAt = 0
local stepEndedAt = 0

Heartbeat.Connect(function(globalDt: number)
	phaseFrames += 1
	local stepStartedAt = os.clock()
	if dispatchEndedAt > 0 and stepEndedAt < dispatchEndedAt then
		-- our dispatch -> this step: the parallel phase (workers), physics, and
		-- every other script's simulation / Heartbeat handlers that ran first
		Profile.Add("FrameSimulation", stepStartedAt - dispatchEndedAt)
	end
	local replicationStarted = os.clock()
	Replication.flushHitBatch()
	local replicationElapsed = os.clock() - replicationStarted

	debug.profilebegin("Projectile.StepAll")
	local stepStarted = os.clock()
	-- Projectiles spawned by hits while applying results are appended past
	-- this count and first step next frame, as with spawns during the loop.
	local stepCount = #active
	stepMark += 1
	applyDt = globalDt
	Parallel.Apply(applySwept, stepMark, os.clock(), ChunkManager.GetTimeVersion())
	local loopStarted = os.clock()
	local destroyTime = 0
	-- Backwards with swap-removal: dead projectiles leave `active` the same
	-- frame (so GetAll/GetInRadius never return them), and anything spawned by
	-- an OnHit/OnDestroy handler mid-loop is appended past `i` and first steps
	-- next frame.
	-- Reads each projectile's Store record, not its table (see Store.luau).
	for i = stepCount, 1, -1 do
		local projectile = active[i]
		local slot = activeSlot[i]
		local alive
		local mark = readi32(Store.Marks, slot * STORE_MARK_STRIDE)
		if mark == stepMark then
			-- (something earlier in this loop may have destroyed it since)
			alive = band(readu8(Store.Flags, slot), STORE_DEAD) == 0
		elseif mark == -stepMark then
			alive = false
		else
			counted.Serial += 1
			alive = projectile:Step(globalDt)
			if alive then
				Parallel.Offer(projectile)
			end
		end
		if alive then
			-- Ordinary homing streams continuously; beams are filtered into sparse
			-- refreshes and immediate topology corrections after link refinement.
			-- (queuePose's own condition -- Visualize and _spawnStreamed and
			-- (_streamedSynced or Beam ~= nil) -- checked here to skip the call)
			local flags = readu8(Store.Flags, slot)
			if band(flags, POSE_NEEDS) == POSE_NEEDS and band(flags, POSE_EITHER) ~= 0 then
				Replication.queuePose(projectile)
			end
		else
			local last = #active
			active[i] = active[last]
			active[last] = nil
			activeSlot[i] = activeSlot[last]
			activeSlot[last] = nil
			local destroyStarted = os.clock()
			projectile:Destroy(nil, nil)
			-- (a full projectile goes back to a plain table; a handle keeps its metatable)
			Store.Release(projectile, if getmetatable(projectile) == Live then Projectile else nil)
			destroyTime += os.clock() - destroyStarted
		end
	end
	Profile.Add("StepLoop", os.clock() - loopStarted - destroyTime)
	Profile.Add("StepDestroy", destroyTime)
	Profile.Frame()
	Parallel.AddCounts(counted.Parallel, counted.Resumed, counted.Serial, counted.Fallback)
	counted.Parallel, counted.Resumed, counted.Serial, counted.Fallback = 0, 0, 0, 0
	recordPhase("Step", dispatchElapsed + os.clock() - stepStarted)
	dispatchElapsed = 0
	debug.profileend()
	if beamSpanStep then
		debug.profilebegin("Projectile.BeamSpans")
		local beamStarted = os.clock()
		beamSpanStep(globalDt)
		recordPhase("Beam", os.clock() - beamStarted)
		debug.profileend()
	end

	-- Publish only completed end-of-frame snapshots. Beam refinement can
	-- insert colliding children above: sending their parent before those
	-- children existed exposed an incomplete newest section for one frame.
	-- Keep spawn-before-move ordering and the existing bounded spawn queue.
	local flushStarted = os.clock()
	Replication.flushSpawnBatch()
	Replication.flushMoveBatch()
	recordPhase("Replication", replicationElapsed + os.clock() - flushStarted)
	stepEndedAt = os.clock()
	Profile.Add("FrameOurs", stepEndedAt - stepStartedAt)
end, { Name = "ProjectileSystem.Step", Priority = 5 })

-- Parallel movement dispatch: before physics, so the workers' parallel phase
-- finishes before the Heartbeat loop above collects it (dt is this frame's,
-- dilated the same way Heartbeat.Connect callbacks receive it).
FrameProfiler.Connect(RunService.PreSimulation, "Projectile.PreSimulation", function(dt: number)
	local started = os.clock()
	if stepEndedAt > 0 and stepEndedAt > dispatchEndedAt then
		-- our last step -> this dispatch: replication, other scripts' callbacks,
		-- and everything else the engine does between frames
		Profile.Add("FrameBetween", started - stepEndedAt)
	end
	dispatchNow = started
	Parallel.Dispatch(#active, dt * Heartbeat.GetGlobalTimeScale(), not debugRays)
	dispatchEndedAt = os.clock()
	dispatchElapsed = dispatchEndedAt - started
	Profile.Add("FrameOurs", dispatchElapsed)
end)

return Projectile
