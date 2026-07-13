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
	server code. The two communicate only over VisualOffload's ProjSpawn /
	ProjMove / ProjHit / ProjSync / ProjTimeScale / ProjRay channels (see
	Projectile/Replication.luau for the sending side).

	Supported behaviours (mix and match): straight shots, ballistic gravity,
	acceleration/deceleration, bouncing (restitution), homing (explicit target or
	auto-acquire by tag(s), with optional Permalock), piercing with falloff, and
	cone bursts. Rendering can be offloaded to clients (Visualize = true): the
	server keeps only the logic. Every projectile gets exactly two replication
	events over its life -- ProjSpawn (once, with its full trajectory-determining
	config) and ProjHit (once, on destroy). On top of that there are three
	independent, orthogonal streaming mechanisms, each covering a different case
	the client can't safely reproduce on its own:
	 - Continuous sync while actively homing (self.HomingTarget ~= nil, checked
	   fresh every tick, never a static classification): the client only ever
	   sees a target's position through that target's own replication lag, which
	   differs per observer, so if it rotated toward that position locally, two
	   clients watching the same missile chase the same target could compute two
	   different flight paths. While a lock is held, the server streams
	   authoritative Position/Velocity every tick (batched, one ProjMove per
	   frame covering everyone who currently needs it, not one event each), and
	   a rare ProjSync event tells clients when a visual crosses in or out of
	   that state. The instant the lock drops -- lost, out of range, or the
	   target destroyed -- streaming stops immediately; the final synced
	   ProjMove for that tick carries the exact Velocity the server was using at
	   the moment the lock was dropped, so the client's subsequent local physics
	   (gravity/acceleration only) continues in exactly the direction the server
	   itself would have flown, keeping it aligned with the server's own hit
	   detection even though nothing streams after that point.
	 - A one-shot correction on every bounce: reproducing a bounce client-side
	   requires matching the server's exact raycast resolution/timing AND
	   knowing which hits are really entities (piercable/filterable, server-only
	   knowledge -- the client has no replicated entity registry to check
	   against), neither of which the client can do reliably. So rather than
	   staying synced for the rest of its life, a bouncing projectile is only
	   ever corrected at the instant it actually bounces: the server sends one
	   immediate ProjMove entry (Bounced = true) with the exact post-reflection
	   Position/Velocity, which the client snaps to and treats as its new local
	   physics baseline. Between bounces (and before the first one, and after
	   the last one) the client is fully unsynced and coasts on local physics,
	   just like a non-homing, non-bouncing shot.
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
	                         a fizzled/expired shot and a bare Destroy() call).
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
	   Acceleration = 0         (studs/s² along current velocity direction; negative decelerates)
	   MinSpeed = 0, MaxSpeed = math.huge   (clamp for Acceleration)
	   Lifetime = 5             (dilated seconds; no upper bound is enforced)
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
	   Gravity = 0              (studs/s² downward, integrated with dilated dt)
	   Radius = 0               (>0 uses a spherecast)
	   Bounces = 0              (world bounces before it dies; no upper bound is enforced)
	   Restitution = 0.5        (velocity kept per bounce)
	   Penetration = 0          (studs of wall material this projectile can punch
	              through; see Raycast._attemptPenetration below. Tried BEFORE
	              bouncing on a world hit; a wall thicker than the remaining
	              Penetration blocks it, falling through to Bounces/destroy as
	              normal. Persistent, depleting state -- punching through
	              several thin walls in a row keeps consuming the same budget)
	   MaxPierces = 0           (enemies passed through)
	   PierceFalloff = 0        (damage lost per pierce, 0..1 -- see Damage above)
	   Homing = { Target?, TargetTag?, TargetTags?, AcquireRadius?, Retarget?,
	              ReacquireRate?, Permalock?, TurnRate = rad/s, Delay = 0 }
	              -- TargetTags (plural, list of strings) matches any tag in the
	              -- list; TargetTag (singular) is still supported for a single tag.
	              -- Permalock (default off): once locked, a Retarget recheck never
	              -- drops the target due to range -- only if it's destroyed. Off by
	              -- default, a dropped-out-of-range lock is genuinely released (not
	              -- silently kept stale). The projectile's own Source is always
	              -- excluded from acquisition, and Filter (if set) is respected.
	   Visualize = false, VisualRange = math.huge
	   Model = Instance?        (cloned client-side) or Visual = {Shape,Size,Color}
	   DestroyDelay = 0         (client keeps the visual this long after impact)
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
	 Replication.spawnVisual for the initial value and Step for the on-change
	 check). The client stores that number per visual and multiplies it
	 straight into its existing local ChunkManager.ScaleDt dead-reckoning (see
	 ProjectileClient's render loop), the same way it already accounts for
	 chunk/world dilation. This is unrelated to Replication.isSynced/homing,
	 which is still the one case that genuinely needs a continuous
	 authoritative stream (see above).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Heartbeat = require(Shared.Heartbeat)
local ChunkManager = require(Shared.ChunkManager)
local Entity = require(Shared.Entity)
local Signal = require(Shared.Signal)

local Math = require(script.Math)
local Homing = require(script.Homing)
local Raycast = require(script.Raycast)
local RewindHit = require(script.RewindHit)
local Replication = require(script.Replication)

local Projectile = {}
Projectile.__index = Projectile

-- Mix each sub-module's instance methods onto the class so self:_resolveHit(),
-- self:_updateHoming(), self:_checkRewoundHit(), etc. keep working exactly as
-- if this were still one file.
for _, mixin in { Homing.Methods, Raycast.Methods, RewindHit.Methods } do
	for name, fn in mixin do
		Projectile[name] = fn
	end
end

local active = {} -- server-side live projectiles
local nextId = 0

-- When on, every movement raycast is streamed to rendering clients so the hit
-- detection can be seen as lines (see ProjRay in ProjectileClient). Off by
-- default -- this is a per-substep debug stream, expensive at high projectile
-- counts. Toggle from a client via the "SetProjectileDebug" channel (see
-- example/init.server.luau).
local debugRays = false

function Projectile.SetDebugRays(enabled: boolean)
	debugRays = enabled and true or false
end

function Projectile.SetDebugSync(enabled: boolean)
	Replication.DebugSync = enabled and true or false
end

-- Adaptive raycast resolution. In chunks that contain entities we step finely so
-- fast bullets can't tunnel through a target; in empty chunks we take one long
-- cast per frame (walls still register, but we skip the wasted fine checks). A
-- raycast is NEVER skipped outright -- only its resolution (step size) adapts --
-- so nothing can pass through world geometry unchecked.
local HIGH_RES_STEP = 4 -- studs per raycast near entities
local LOW_RES_STEP = 64 -- studs per raycast in empty space
local MAX_SUBSTEPS = 16

-- Hard real-time (wall-clock, undilated) cap on how long any projectile can
-- stay alive, regardless of its own dilated Lifetime/Age. A projectile whose
-- effective time is frozen (its Source's personal ratio, its own TimeScale,
-- or the chunk it's sitting in all read as 0 -- see Step) never advances Age,
-- so the normal Lifetime expiry alone would let it live in `active` forever.
-- Checked every Step via os.clock(), independent of dt. Per-shot override via
-- config.MaxRealLifetime; change the default for every future shot with
-- Projectile.SetDefaultMaxRealLifetime.
local DEFAULT_MAX_REAL_LIFETIME = 60 -- real seconds

function Projectile.SetDefaultMaxRealLifetime(seconds: number)
	DEFAULT_MAX_REAL_LIFETIME = math.max(seconds, 0)
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function Projectile.new(config)
	nextId += 1

	local origin = config.Origin or Vector3.zero
	local direction
	if config.TargetPosition then
		direction = Math.safeUnit(config.TargetPosition - origin, Vector3.zAxis)
	else
		direction = Math.safeUnit(config.Direction or Vector3.zAxis, Vector3.zAxis)
	end
	local speed = config.Speed or 100

	local bounces = config.Bounces or 0

	local self = setmetatable({
		Id = nextId,
		Position = origin,
		Velocity = direction * speed,
		Speed = speed,
		Acceleration = config.Acceleration or 0,
		MinSpeed = config.MinSpeed or 0,
		MaxSpeed = config.MaxSpeed or math.huge,
		Gravity = config.Gravity or 0,
		Radius = config.Radius or 0,

		Lifetime = config.Lifetime or 5,
		Age = 0,
		-- Hard real-time (wall-clock) safety cap -- see
		-- DEFAULT_MAX_REAL_LIFETIME above. _spawnRealTime is os.clock() at
		-- construction, checked every Step regardless of dt/freeze state.
		MaxRealLifetime = math.max(config.MaxRealLifetime or DEFAULT_MAX_REAL_LIFETIME, 0),
		_spawnRealTime = os.clock(),
		-- This projectile's OWN dilation, independent of Source -- see the
		-- module doc comment's "Local time" section. Live-mutable directly or
		-- via :SetTimeScale(); read live every Step, never snapshotted.
		TimeScale = math.max(config.TimeScale or 1, 0),

		Damage = config.Damage or 0,
		DamageMultiplier = 1,
		Source = config.Source,
		IgnoreInstances = config.IgnoreInstances,
		Filter = config.Filter,

		BouncesLeft = bounces,
		Restitution = config.Restitution or 0.5,
		-- Depleting budget of wall material this projectile can still punch
		-- through -- see Raycast._attemptPenetration / the module doc
		-- comment's config section. Tried before bouncing on a world hit.
		Penetration = math.max(config.Penetration or 0, 0),

		PiercesLeft = config.MaxPierces or 0,
		PierceFalloff = config.PierceFalloff or 0,

		Homing = config.Homing,
		HomingDelay = config.Homing and (config.Homing.Delay or 0) or 0,
		HomingTarget = config.Homing and config.Homing.Target,
		ReacquireTimer = 0,

		Visualize = config.Visualize == true,
		VisualRange = config.VisualRange or math.huge,
		Model = config.Model,
		Visual = config.Visual,
		DestroyDelay = config.DestroyDelay or 0,

		-- See "Events" in the module doc comment's API section. Fresh Signal
		-- per projectile -- connect on the returned instance, not via config.
		OnHit = Signal.new(),
		OnDestroy = Signal.new(),
		OnBounce = config.OnBounce,

		RewindSeconds = config.RewindSeconds or 0,

		_ignore = {}, -- entities already pierced
		_bouncedThisTick = false,
		_bouncedNormal = Vector3.yAxis,
		-- Lag-compensation working state, repopulated each Step before
		-- _checkRewoundHit runs (see Step). rewoundPos is memoized per frame
		-- since RewindSeconds is fixed and os.clock() is stable across one
		-- frame's substeps; the candidate buffer is reused across substeps to
		-- avoid per-substep allocation churn under high projectile counts.
		_rewindTime = 0,
		_rewindCache = {},
		_candidateBuf = {},
		Dead = false,
	}, Projectile)
	self._rayParams = Raycast.buildRayParams(self)
	self._streamedSynced = Replication.isSynced(self)
	-- Baseline for the ProjTimeScale on-change check in Step -- see
	-- Replication.combinedTimeScale / the module doc comment's "Local time"
	-- section. Computed before spawnVisual so ProjSpawn's TimeScale field
	-- matches.
	self._lastStreamedTimeScale = Replication.combinedTimeScale(self)

	table.insert(active, self)
	Replication.spawnVisual(self)
	return self
end

-- Tells rendering clients only when the homing-sync state actually changed --
-- not every frame (see Replication.isSynced / the module doc comment). True
-- switches the client into "trust the continuous ProjMove stream" mode; false
-- switches it back to local physics from wherever the last authoritative
-- Position/Velocity left it. Bounce corrections are separate (see
-- Raycast._resolveHit) and never touch this flag or fire ProjSync -- they're
-- one-shot regardless of sync state.
function Projectile:_checkSyncTransition()
	local synced = Replication.isSynced(self)
	if synced ~= self._streamedSynced then
		self._streamedSynced = synced
		if Replication.DebugSync then
			print(`[Relativity][sync] ProjSync Id={self.Id} Synced={synced} (BouncesLeft={self.BouncesLeft} Homing={self.HomingTarget ~= nil})`)
		end
		Replication.streamTo(self, "ProjSync", { Id = self.Id, Synced = synced })
	end
end

-- Tells rendering clients only when the combined Source.TimeScale *
-- projectile.TimeScale actually CHANGES -- not every frame. This is what
-- replaced continuously streaming Position/Velocity for the whole flight of
-- any personal/local-time-affected projectile (see the module doc comment's
-- "Local time" section): the client just needs the number, which in the
-- common case (nobody touched it after firing) never changes again after
-- ProjSpawn, so this fires zero extra times per shot instead of 60/sec.
function Projectile:_checkTimeScaleChange(combinedScale: number)
	if combinedScale ~= self._lastStreamedTimeScale then
		self._lastStreamedTimeScale = combinedScale
		if Replication.DebugSync then
			print(`[Relativity][sync] ProjTimeScale Id={self.Id} TimeScale={combinedScale}`)
		end
		Replication.streamTo(self, "ProjTimeScale", { Id = self.Id, TimeScale = combinedScale })
	end
end

-- Cone burst: `count` projectiles spread around the base direction.
function Projectile.Burst(config, count: number)
	local origin = config.Origin or Vector3.zero
	local baseDir
	if config.TargetPosition then
		baseDir = Math.safeUnit(config.TargetPosition - origin, Vector3.zAxis)
	else
		baseDir = Math.safeUnit(config.Direction or Vector3.zAxis, Vector3.zAxis)
	end

	local spread = config.Spread or 0
	local shots = {}
	for _ = 1, count do
		local pelletConfig = table.clone(config)
		pelletConfig.TargetPosition = nil
		pelletConfig.Direction = Math.coneDirection(baseDir, spread)
		table.insert(shots, Projectile.new(pelletConfig))
	end
	return shots
end

-- This projectile's OWN local dilation -- see the module doc comment's
-- "Local time" section. Read live every Step, so an ability can dial this up
-- or down over time (or reset it to 1) and the change is immediate. Setting
-- the .TimeScale field directly works identically; this just adds the same
-- clamping Entity:SetTimeScale uses.
function Projectile:SetTimeScale(scale: number)
	self.TimeScale = math.max(scale, 0)
end

--------------------------------------------------------------------------------
-- Query (server-only in practice -- see the module doc comment's API section)
--------------------------------------------------------------------------------

function Projectile.GetAll()
	return table.clone(active)
end

function Projectile.GetBySource(source: any)
	local result = {}
	for _, projectile in active do
		if projectile.Source == source then
			table.insert(result, projectile)
		end
	end
	return result
end

export type QueryOptions = {
	Filter: ((projectile: any) -> boolean)?,
}

function Projectile.GetInRadius(position: Vector3, radius: number, options: QueryOptions?)
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
-- Per-projectile step
--------------------------------------------------------------------------------

-- Shared "died of natural causes, nothing was actually hit" path -- dilated
-- Lifetime expiry and the real-time MaxRealLifetime cap below both fizzle out
-- the same way. Deliberately does NOT fire OnHit (there was no contact to
-- report -- see the module doc comment's "Events" section); OnDestroy still
-- fires exactly once, from Destroy(), which the outer server step loop calls
-- once Step() returns false here, same as any other removal.
function Projectile:_expire(): boolean
	return false
end

-- Advances the projectile; returns false when it should be removed.
function Projectile:Step(globalDt: number): boolean
	if self.Dead then
		return false
	end

	-- Hard real-time cap, checked unconditionally every tick via os.clock()
	-- BEFORE anything dt-dependent -- this is the one expiry check that MUST
	-- run even while the projectile is completely frozen (combinedScale/chunk
	-- dt at 0 below), since Age itself never advances in that state and the
	-- dilated Lifetime check further down would otherwise never fire. See
	-- MaxRealLifetime / DEFAULT_MAX_REAL_LIFETIME above.
	if os.clock() - self._spawnRealTime >= self.MaxRealLifetime then
		return self:_expire()
	end

	-- Reset every tick so a stale true from a previous bounce never leaks into
	-- a later, non-bouncing tick's streamed payload -- see Raycast._resolveHit.
	self._bouncedThisTick = false

	-- world/chunk dilation at the projectile's own position, times the
	-- shooter's CURRENT personal ratio, times this projectile's OWN current
	-- ratio -- both read live every tick (never snapshotted), so dragging a
	-- personal-time slider or an ability tweaking this specific projectile's
	-- TimeScale mid-flight takes effect immediately -- see the module doc
	-- comment's "Local time" section.
	local combinedScale = Replication.combinedTimeScale(self)
	-- Checked BEFORE the dt<=0 early return below, so a ratio change that
	-- freezes the projectile entirely (combinedScale hits 0) still reaches
	-- the client -- otherwise a frozen shot would silently keep whatever
	-- stale TimeScale it last streamed. See ProjTimeScale / the module doc
	-- comment's "Local time" section.
	self:_checkTimeScaleChange(combinedScale)
	local dt = ChunkManager.ScaleDt(globalDt, self.Position) * combinedScale
	if dt <= 0 then
		return true -- frozen chunk / paused / shooter or projectile frozen: keep it alive, don't move it
	end

	self.Age += dt
	if self.Age >= self.Lifetime then
		return self:_expire()
	end

	self:_updateHoming(dt)

	if self.Acceleration ~= 0 then
		local speed = self.Velocity.Magnitude
		local newSpeed = math.clamp(speed + self.Acceleration * dt, self.MinSpeed, self.MaxSpeed)
		self.Velocity = Math.safeUnit(self.Velocity, Vector3.zAxis) * newSpeed
	end

	if self.Gravity > 0 then
		self.Velocity -= Vector3.new(0, self.Gravity * dt, 0)
	end

	-- Adaptive stepping: fine casts near entities (accurate hit detection),
	-- one coarse cast per frame in empty chunks (skip the wasted checks). The
	-- step size is chosen from whether the chunk we're in / moving into holds
	-- entities. A raycast is never skipped -- only its resolution adapts.
	local highRes = Raycast.chunkHasEntities(self.Position)
		or Raycast.chunkHasEntities(self.Position + self.Velocity * dt)
	local maxStep = highRes and HIGH_RES_STEP or LOW_RES_STEP

	-- Lag-compensation working state for this frame: pin rewindTime and a fresh
	-- rewound-position cache so every substep rewinds to the SAME instant
	-- (RewindSeconds is fixed per projectile and os.clock() is stable across
	-- substeps; previously each substep recomputed both, doing up to N redundant
	-- GetPositionAt lookups where one would do). The candidate buffer is
	-- reused, never reallocated -- see RewindHit._checkRewoundHit.
	local useRewind = highRes and self.RewindSeconds > 0
	if useRewind then
		self._rewindTime = os.clock() - self.RewindSeconds
		table.clear(self._rewindCache)
		table.clear(self._candidateBuf)
	end

	local remaining = dt
	local guard = 0
	while remaining > 1e-4 and guard < MAX_SUBSTEPS do
		guard += 1
		local speed = self.Velocity.Magnitude
		local stepDt = remaining
		if speed * stepDt > maxStep then
			stepDt = maxStep / math.max(speed, 1e-3)
		end

		local from = self.Position
		local displacement = self.Velocity * stepDt
		local to = from + displacement

		-- Lag-compensated entity check, only while in an entity-containing chunk
		-- and only for shots carrying a shooter's rewind offset.
		if highRes and self.RewindSeconds > 0 then
			local lagEntity, lagPoint, lagNormal, lagHurtbox = self:_checkRewoundHit(from, to)
			if lagEntity then
				if debugRays then
					self:_streamRay(from, lagPoint, false)
				end
				local verdict = self:_resolveEntityHit(lagEntity, { Position = lagPoint, Normal = lagNormal }, lagHurtbox)
				if verdict == "destroy" then
					return false
				end
				remaining -= stepDt
				continue
			end
		end

		local result = Raycast.castMovement(self, from, displacement)
		if debugRays then
			self:_streamRay(from, result and result.Position or to, not highRes)
		end

		if not result then
			self.Position = to
			remaining -= stepDt
		else
			local instance = result.Instance
			local liveEntity = instance and Entity.Get(instance)
			if liveEntity and highRes and self.RewindSeconds > 0 then
				-- We're lag-compensating this segment and the rewound check above
				-- found no valid hit -- from the shooter's ping-adjusted view this
				-- entity wasn't actually there, so the live-position coincidence
				-- doesn't count. Nudge past and keep flying.
				self.Position = result.Position + Math.safeUnit(self.Velocity, Vector3.zAxis) * (self.Radius + 0.1)
				remaining -= stepDt
			else
				local verdict = self:_resolveHit(result)
				if verdict == "destroy" then
					return false
				end
				-- pierce/bounce/penetrate/ignore already advanced self.Position past the surface
				remaining -= stepDt
			end
		end
	end

	self:_checkSyncTransition()
	return true
end

function Projectile:Destroy(result, kind: string?)
	if self.Dead then
		return
	end
	self.Dead = true
	local hitResult = result or { Position = self.Position, Normal = Vector3.yAxis }
	if Replication.DebugSync then
		print(`[Relativity][sync] ProjHit Id={self.Id} Kind={kind or "fizzle"}`)
	end
	Replication.streamTo(self, "ProjHit", { Id = self.Id, Position = hitResult.Position, Normal = hitResult.Normal, Kind = kind })

	-- Exactly-once -- see the module doc comment's "Events" section. Fired
	-- here (not in Raycast._resolveEntityHit/_resolveHit/_expire) so EVERY
	-- removal path funnels through the same single call, including natural
	-- Lifetime/MaxRealLifetime expiry (which calls Destroy() from the outer
	-- server step loop, not from here).
	self.OnDestroy:Fire({ Position = hitResult.Position, Normal = hitResult.Normal, Kind = kind })

	-- Defensive: drop heavy references so a projectile object that somehow
	-- outlives removal from `active` (e.g. a future caller retaining the
	-- returned handle) doesn't keep entities/closures alive through it.
	table.clear(self._ignore)
	self.HomingTarget = nil
	self.OnHit:Destroy()
	self.OnDestroy:Destroy()
end

--------------------------------------------------------------------------------
-- Server step loop
--------------------------------------------------------------------------------

Heartbeat.Connect(function(globalDt)
	local moveBatch = {}
	for i = #active, 1, -1 do
		local projectile = active[i]
		-- Captured BEFORE Step() so a projectile whose homing lock drops
		-- DURING this exact tick still gets this tick's corrected
		-- post-drop Position/Velocity streamed -- otherwise the client is
		-- left holding a stale pre-transition pose and resumes local
		-- physics from the wrong place. Bounce corrections are handled
		-- separately and immediately inside Raycast._resolveHit -- they
		-- don't depend on isSynced at all, so a non-homing bouncer never
		-- reaches this batch outside the tick it actually bounces on.
		local wasSynced = Replication.isSynced(projectile)
		local alive = projectile:Step(globalDt)
		if not alive then
			local last = #active
			active[i] = active[last]
			active[last] = nil
			projectile:Destroy({ Position = projectile.Position, Normal = Vector3.yAxis })
		elseif projectile.Visualize and (wasSynced or Replication.isSynced(projectile)) then
			-- Currently (or just-formerly, see above) locked onto a homing
			-- target (checked fresh every tick, not a static
			-- classification) -- see the module doc comment for why this
			-- is the one case that stays continuously streamed rather
			-- than left to the client.
			table.insert(moveBatch, {
				VisualRange = projectile.VisualRange,
				Position = projectile.Position,
				Payload = {
					Id = projectile.Id,
					Position = projectile.Position,
					Velocity = projectile.Velocity,
					-- Set only on the tick a bounce actually happened -- tells
					-- the client to snap instead of tweening a straight line
					-- from its last position, which would cut through
					-- whatever surface sits between the two (see Raycast._resolveHit).
					Bounced = projectile._bouncedThisTick,
					Normal = projectile._bouncedThisTick and projectile._bouncedNormal or nil,
				},
			})
		end
	end
	Replication.flushMoveBatch(moveBatch)
end, { Name = "ProjectileSystem.Step", Priority = 5 })

-- Once-a-second ProjMove rate summary (see Replication.DebugSync above) --
-- real time, not dilated, so the reporting cadence stays steady even
-- mid-freeze.
task.spawn(function()
	while true do
		task.wait(1)
		local stats = Replication.SyncMoveStats
		if Replication.DebugSync and (stats.batches > 0 or stats.entries > 0) then
			print(`[Relativity][sync] ProjMove rate: {stats.batches} batches/s, {stats.entries} projectile-updates/s`)
		end
		stats.batches = 0
		stats.entries = 0
	end
end)

return Projectile
