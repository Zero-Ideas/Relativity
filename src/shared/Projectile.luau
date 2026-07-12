--!optimize 2
--[[
	Projectile.luau
	Server-authoritative, raycast-driven projectiles that live in dilated time.
	Every projectile steps in the local time of the chunk it currently occupies,
	so a bullet flying through a 0.2x slow zone crawls, its gravity floats, and
	its fuse burns slower — all for free. Because of that, a dilated Lifetime
	alone can't bound a projectile's real-world lifespan -- something frozen at
	0x (its own TimeScale, its Source's personal ratio, or its chunk) would
	never expire on its own. MaxRealLifetime is a separate, real-time
	(wall-clock) hard cap that always applies regardless of dilation -- see
	DEFAULT_MAX_REAL_LIFETIME / Projectile.SetDefaultMaxRealLifetime below.

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
	   dead-reckoning every unsynced visual already does (see the render loop),
	   exactly like it already does for chunk/world dilation (which similarly
	   replicates as sparse chunk-scale updates, not a per-projectile stream).
	   This used to be handled by forcing the projectile fully "synced" (see
	   isSynced) for as long as either ratio held at non-1x, which meant a
	   60/sec authoritative Position/Velocity stream PER slowed/sped-up
	   projectile for its entire flight -- needlessly expensive, since the only
	   thing the client was actually missing was the number itself, which
	   almost never changes mid-flight.
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
	 Projectile.EnableClientRendering()          -- call once on the client
	 Projectile.SetImpactHandler(fn(position, normal, model))  -- client VFX hook
	 Projectile.SetDebugRays(enabled)            -- default off; see debugRays below
	 Projectile.SetDefaultMaxRealLifetime(seconds) -- default 60; see MaxRealLifetime below

	 Query (server-only -- projectiles only ever live in the server's `active`
	 list; see the module doc comment above. Every result is the LIVE
	 projectile object, not a copy, so an ability can read OR write any field
	 on it directly -- e.g. projectile.Damage = x, or the dedicated
	 projectile:SetTimeScale(x) below -- and it takes effect on the very next
	 Step, same tick):
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
	              been registered with the Entity system yet; see buildRayParams)
	   Filter = (entity)->bool  (which entities count as targets; also applied to homing acquisition)
	   Gravity = 0              (studs/s² downward, integrated with dilated dt)
	   Radius = 0               (>0 uses a spherecast)
	   Bounces = 0              (world bounces before it dies; no upper bound is enforced)
	   Restitution = 0.5        (velocity kept per bounce)
	   Penetration = 0          (studs of wall material this projectile can punch
	              through; see _attemptPenetration below. Tried BEFORE bouncing
	              on a world hit; a wall thicker than the remaining Penetration
	              blocks it, falling through to Bounces/destroy as normal.
	              Persistent, depleting state -- punching through several thin
	              walls in a row keeps consuming the same budget)
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
	 spawnVisual for the initial value and Step for the on-change check). The
	 client stores that number per visual and multiplies it straight into its
	 existing local ChunkManager.ScaleDt dead-reckoning (see the render loop),
	 the same way it already accounts for chunk/world dilation. This is
	 unrelated to isSynced/homing, which is still the one case that genuinely
	 needs a continuous authoritative stream (see above).
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Heartbeat = require(script.Parent.Heartbeat)
local ChunkManager = require(script.Parent.ChunkManager)
local Entity = require(script.Parent.Entity)
local VisualOffload = require(script.Parent.VisualOffload)
local Signal = require(script.Parent.Signal)

local Projectile = {}
Projectile.__index = Projectile

local active = {} -- server-side live projectiles
local nextId = 0

-- When on, every movement raycast is streamed to rendering clients so the hit
-- detection can be seen as lines (see ProjRay in the client renderer). Off by
-- default -- this is a per-substep debug stream, expensive at high projectile
-- counts. Toggle from a client via the "SetProjectileDebug" channel.
local debugRays = false

function Projectile.SetDebugRays(enabled: boolean)
	debugRays = enabled and true or false
end

-- When on, prints every ProjSpawn/ProjSync/ProjHit as they're streamed
-- (individually rare enough to log one line each), plus a once-a-second rate
-- summary for ProjMove (logging every individual batch would be 60/sec and
-- unreadable -- the summary answers "how often is this actually being sent"
-- directly instead). Server-side only; toggle with Projectile.SetDebugSync.
local debugSync = false

function Projectile.SetDebugSync(enabled: boolean)
	debugSync = enabled and true or false
end

-- Accumulated since the last once-a-second report -- see the ProjMove rate
-- summary in the server step loop below.
local _syncMoveStats = { batches = 0, entries = 0 }

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
-- Geometry helpers
--------------------------------------------------------------------------------

local function safeUnit(v: Vector3, fallback: Vector3): Vector3
	local magnitude = v.Magnitude
	if magnitude < 1e-5 then
		return fallback
	end
	return v / magnitude
end

-- Rotate `from` toward `to` by at most `maxAngle` radians, preserving length.
local function rotateTowards(from: Vector3, to: Vector3, maxAngle: number): Vector3
	local fromDir = safeUnit(from, Vector3.zAxis)
	local toDir = safeUnit(to, fromDir)
	local dot = math.clamp(fromDir:Dot(toDir), -1, 1)
	local angle = math.acos(dot)
	if angle <= maxAngle or angle < 1e-4 then
		return toDir
	end
	local axis = fromDir:Cross(toDir)
	if axis.Magnitude < 1e-4 then
		-- opposite directions: pick an arbitrary perpendicular axis
		axis = math.abs(fromDir.Y) < 0.99 and fromDir:Cross(Vector3.yAxis) or fromDir:Cross(Vector3.xAxis)
	end
	axis = axis.Unit
	return CFrame.fromAxisAngle(axis, maxAngle):VectorToWorldSpace(fromDir)
end

-- Closest point on segment [a,b] to point p, and the distance to it. Used by
-- lag-compensated hit detection to test a rewound entity position against a
-- substep's movement segment.
local function closestPointOnSegment(p: Vector3, a: Vector3, b: Vector3): (Vector3, number)
	local ab = b - a
	local lengthSq = ab:Dot(ab)
	local t = lengthSq > 1e-8 and math.clamp((p - a):Dot(ab) / lengthSq, 0, 1) or 0
	local closest = a + ab * t
	return closest, (p - closest).Magnitude
end

local function coneDirection(dir: Vector3, spreadDeg: number): Vector3
	if spreadDeg <= 0 then
		return dir
	end
	local spread = math.rad(spreadDeg)
	-- sqrt for an even areal distribution across the cone
	local theta = math.sqrt(math.random()) * spread
	local roll = math.random() * 2 * math.pi
	local up = math.abs(dir.Y) < 0.99 and Vector3.yAxis or Vector3.xAxis
	local right = dir:Cross(up).Unit
	local realUp = right:Cross(dir).Unit
	local radial = (right * math.cos(roll) + realUp * math.sin(roll)) * math.tan(theta)
	return safeUnit(dir + radial, dir)
end

--------------------------------------------------------------------------------
-- Homing target resolution
--------------------------------------------------------------------------------

local function targetPosition(target): Vector3?
	if target == nil then
		return nil
	end
	if typeof(target) == "Vector3" then
		return target
	end
	if typeof(target) == "Instance" then
		if target:IsA("BasePart") then
			return target.Position
		elseif target:IsA("Model") then
			return target:GetPivot().Position
		end
		return nil
	end
	-- assume an Entity
	if target.IsDestroyed then
		return nil
	end
	if target.GetPosition then
		return target:GetPosition()
	end
	return nil
end

-- Finds the nearest valid homing target: entities matching TargetTag/TargetTags
-- (or ALL entities if neither given), excluding the projectile's own Source and
-- anything its Filter rejects. Uses ChunkManager's spatial index when
-- AcquireRadius is set (the normal case -- every real spawn site sets one), so
-- cost scales with local entity density, not total entity/projectile count; the
-- unbounded case (rare) falls back to a full scan.
local function acquireTarget(projectile, homing, position: Vector3)
	local source = projectile.Source
	local filter = projectile.Filter

	local function isEligible(entity): boolean
		if entity == source or entity.IsDestroyed then
			return false
		end
		if filter and not filter(entity) then
			return false
		end
		if homing.TargetTags then
			for _, tag in homing.TargetTags do
				if entity:HasTag(tag) then
					return true
				end
			end
			return false
		elseif homing.TargetTag then
			return entity:HasTag(homing.TargetTag)
		end
		return true
	end

	if homing.AcquireRadius then
		local best, bestDist = nil, homing.AcquireRadius
		local candidates = ChunkManager.GetEntitiesInRadius(position, homing.AcquireRadius, { Filter = isEligible })
		for _, entity in candidates do
			local distance = (entity:GetPosition() - position).Magnitude
			if distance <= bestDist then
				best, bestDist = entity, distance
			end
		end
		return best
	end

	local best, bestDist = nil, math.huge
	local candidates = homing.TargetTag and Entity.GetTagged(homing.TargetTag) or Entity.GetAll()
	for _, entity in candidates do
		if isEligible(entity) then
			local distance = (entity:GetPosition() - position).Magnitude
			if distance <= bestDist then
				best, bestDist = entity, distance
			end
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Raycasting
--------------------------------------------------------------------------------

-- Built once per projectile and cached on it (Source never changes after
-- construction), reused for every raycast that projectile makes -- Roblox
-- re-evaluates FilterDescendantsInstances against the live scene at cast time, so
-- one instance is safe to reuse across many casts/frames; this only removes the
-- allocation churn of rebuilding it every substep, not a correctness change.
-- NOTE: if a future feature needs to grow the exclude list dynamically (e.g.
-- adding pierced entities instead of the current position-nudge approach),
-- mutating `ignore` in place won't take effect -- FilterDescendantsInstances
-- would need reassigning.
local function buildRayParams(projectile)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	local source = projectile.Source
	if source and source.Instance then
		table.insert(ignore, source.Instance)
	end
	-- Excluded independently of Source: Source only exists once the firing
	-- entity is registered with the Entity system (see PlayerManager.server.luau),
	-- so a shot fired in the window before that registration lands would
	-- otherwise have nothing excluding the shooter's own character from this
	-- raycast -- IgnoreInstances closes that gap without depending on timing.
	if projectile.IgnoreInstances then
		for _, instance in projectile.IgnoreInstances do
			table.insert(ignore, instance)
		end
	end
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	return params
end

local function castMovement(projectile, origin: Vector3, displacement: Vector3)
	local params = projectile._rayParams
	if projectile.Radius > 0 then
		return workspace:Spherecast(origin, projectile.Radius, displacement, params)
	end
	return workspace:Raycast(origin, displacement, params)
end

-- Does the chunk containing `position` currently hold any entities? Drives the
-- high/low resolution decision each frame.
local function chunkHasEntities(position: Vector3): boolean
	local chunk = ChunkManager.GetChunk(position)
	return chunk ~= nil and chunk.EntityCount > 0
end

--------------------------------------------------------------------------------
-- Visual replication (server -> clients)
--------------------------------------------------------------------------------

local function streamTo(projectile, channel: string, payload: any)
	if not projectile.Visualize then
		return
	end
	if projectile.VisualRange >= math.huge then
		VisualOffload.Fire(channel, payload)
		return
	end
	local origin = projectile.Position
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character.PrimaryPart
		if root and (root.Position - origin).Magnitude <= projectile.VisualRange then
			VisualOffload.FireClient(player, channel, payload)
		end
	end
end

-- Whether the client can't safely predict this projectile's CONTINUOUS motion
-- on its own right now -- see the module doc comment. Checked fresh every
-- tick (Step's end-of-tick transition check, and here for the initial spawn
-- state), never a static per-projectile classification. This governs only the
-- per-tick ProjMove stream; it deliberately excludes bouncing -- a bounce is
-- corrected with its own one-shot ProjMove entry (Bounced = true) sent the
-- instant it happens (see _resolveHit), not by holding the projectile synced
-- for its whole remaining life. A projectile with bounces remaining (or that
-- has already bounced) but no active homing lock is therefore NOT
-- continuously synced -- it coasts on local physics between bounces like any
-- other unsynced shot, and only gets snapped at the moment each bounce
-- occurs. It also deliberately excludes Source.TimeScale/projectile.TimeScale
-- -- those no longer force a continuous stream (see ProjTimeScale / the
-- module doc comment's "Local time" section): the client just needs to KNOW
-- the current ratio, not be streamed a live position because of it.
local function isSynced(projectile): boolean
	return projectile.HomingTarget ~= nil
end

-- world/chunk dilation is applied separately (ChunkManager.ScaleDt, replicated
-- to clients on its own); this is just the shooter's personal ratio times
-- this specific projectile's own local ratio -- see the module doc comment's
-- "Local time" section. Read live, never snapshotted.
local function combinedTimeScale(projectile): number
	local source = projectile.Source
	local sourceScale = (source and source.TimeScale) or 1
	return sourceScale * projectile.TimeScale
end

local function spawnVisual(projectile)
	if debugSync then
		print(`[Relativity][sync] ProjSpawn Id={projectile.Id} Synced={isSynced(projectile)}`)
	end
	streamTo(projectile, "ProjSpawn", {
		Id = projectile.Id,
		Position = projectile.Position,
		Velocity = projectile.Velocity,
		Gravity = projectile.Gravity,
		Acceleration = projectile.Acceleration,
		MinSpeed = projectile.MinSpeed,
		MaxSpeed = projectile.MaxSpeed,
		Lifetime = projectile.Lifetime,
		-- Whether it starts out continuously synced -- true only for an
		-- explicit Homing.Target given at construction (auto-acquire homing
		-- starts unsynced until it actually locks onto something). If true,
		-- the client starts in "trust the stream" mode immediately; the
		-- server's step loop below will include it in the very next ProjMove
		-- batch.
		Synced = isSynced(projectile),
		-- Initial combined Source.TimeScale * projectile.TimeScale, so the
		-- client's local dead-reckoning is correct from frame one even if
		-- this shot was fired while the shooter's ratio was already off 1x --
		-- see ProjTimeScale / the module doc comment's "Local time" section.
		TimeScale = projectile._lastStreamedTimeScale,
		-- Real (undilated) safety cap -- see MaxRealLifetime / the module doc
		-- comment. Lets the client independently self-destroy the visual as a
		-- backstop even if it never receives this projectile's ProjHit (e.g.
		-- it drifted outside VisualRange), rather than being able to leak a
		-- frozen visual forever -- see the render loop below.
		MaxRealLifetime = projectile.MaxRealLifetime,
		Model = projectile.Model,
		Visual = projectile.Visual,
		DestroyDelay = projectile.DestroyDelay,
	})
end

-- Flushes one frame's worth of ProjMove updates for projectiles the client
-- can't currently predict on its own (checked fresh every tick -- see the
-- server step loop below, not a static per-projectile classification) as a
-- single batched event per recipient instead of one event per projectile.
-- Everything else never appears here at all -- see the module doc comment.
local function flushMoveBatch(moveBatch)
	if #moveBatch == 0 then
		return
	end

	if debugSync then
		_syncMoveStats.batches += 1
		_syncMoveStats.entries += #moveBatch
	end

	local broadcastBatch = {}
	local perPlayerBatches: { [Player]: { any } }? = nil
	local players = Players:GetPlayers()
	local playerRoots = {}
	for _, player in players do
		local character = player.Character
		playerRoots[player] = character and character.PrimaryPart
	end

	for _, entry in moveBatch do
		if entry.VisualRange >= math.huge then
			table.insert(broadcastBatch, entry.Payload)
		else
			for _, player in players do
				local root = playerRoots[player]
				if root and (root.Position - entry.Position).Magnitude <= entry.VisualRange then
					perPlayerBatches = perPlayerBatches or {}
					local list = perPlayerBatches[player]
					if not list then
						list = {}
						perPlayerBatches[player] = list
					end
					table.insert(list, entry.Payload)
				end
			end
		end
	end

	if #broadcastBatch > 0 then
		VisualOffload.Fire("ProjMove", broadcastBatch)
	end
	if perPlayerBatches then
		for player, list in perPlayerBatches do
			VisualOffload.FireClient(player, "ProjMove", list)
		end
	end
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function Projectile.new(config)
	nextId += 1

	local origin = config.Origin or Vector3.zero
	local direction
	if config.TargetPosition then
		direction = safeUnit(config.TargetPosition - origin, Vector3.zAxis)
	else
		direction = safeUnit(config.Direction or Vector3.zAxis, Vector3.zAxis)
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
		-- through -- see _attemptPenetration / the module doc comment's
		-- config section. Tried before bouncing on a world hit.
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
	self._rayParams = buildRayParams(self)
	self._streamedSynced = isSynced(self)
	-- Baseline for the ProjTimeScale on-change check in Step -- see
	-- combinedTimeScale / the module doc comment's "Local time" section.
	-- Computed before spawnVisual so ProjSpawn's TimeScale field matches.
	self._lastStreamedTimeScale = combinedTimeScale(self)

	table.insert(active, self)
	spawnVisual(self)
	return self
end

-- Tells rendering clients only when the homing-sync state actually changed --
-- not every frame (see isSynced / the module doc comment). True switches the
-- client into "trust the continuous ProjMove stream" mode; false switches it
-- back to local physics from wherever the last authoritative Position/
-- Velocity left it. Bounce corrections are separate (see _resolveHit) and
-- never touch this flag or fire ProjSync -- they're one-shot regardless of
-- sync state.
function Projectile:_checkSyncTransition()
	local synced = isSynced(self)
	if synced ~= self._streamedSynced then
		self._streamedSynced = synced
		if debugSync then
			print(`[Relativity][sync] ProjSync Id={self.Id} Synced={synced} (BouncesLeft={self.BouncesLeft} Homing={self.HomingTarget ~= nil})`)
		end
		streamTo(self, "ProjSync", { Id = self.Id, Synced = synced })
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
		if debugSync then
			print(`[Relativity][sync] ProjTimeScale Id={self.Id} TimeScale={combinedScale}`)
		end
		streamTo(self, "ProjTimeScale", { Id = self.Id, TimeScale = combinedScale })
	end
end

-- Cone burst: `count` projectiles spread around the base direction.
function Projectile.Burst(config, count: number)
	local origin = config.Origin or Vector3.zero
	local baseDir
	if config.TargetPosition then
		baseDir = safeUnit(config.TargetPosition - origin, Vector3.zAxis)
	else
		baseDir = safeUnit(config.Direction or Vector3.zAxis, Vector3.zAxis)
	end

	local spread = config.Spread or 0
	local shots = {}
	for _ = 1, count do
		local pelletConfig = table.clone(config)
		pelletConfig.TargetPosition = nil
		pelletConfig.Direction = coneDirection(baseDir, spread)
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

-- Builds the { CFrame, Part, Entity?, Hurtbox? } table passed to every
-- projectile.OnHit listener -- see the module doc comment's "Events"
-- section. `result` is a RaycastResult (or an equivalent plain table shape
-- for a bounce/penetration point); entity is nil for a pure world/wall
-- contact. hurtboxName is "Head" | "Body" | nil -- see _resolveHit /
-- _checkRewoundHit, which resolve it analytically against
-- entity:GetHeadPosition()/GetBodyPosition() (see Entity.luau's "Head +
-- Body hurtboxes" section).
local function buildHitInfo(result, entity, hurtboxName: string?)
	local normal = result.Normal and safeUnit(result.Normal, Vector3.zAxis) or Vector3.zAxis
	return {
		CFrame = CFrame.lookAt(result.Position, result.Position + normal),
		Part = result.Instance,
		Entity = entity,
		Hurtbox = hurtboxName,
	}
end

-- Broadcasts a single movement raycast segment for debug visualization.
-- lowRes marks the coarse casts taken through empty (entity-free) chunks.
function Projectile:_streamRay(from: Vector3, to: Vector3, lowRes: boolean)
	streamTo(self, "ProjRay", { From = from, To = to, LowRes = lowRes })
end

-- Handles the case where a raycast (or a lag-compensated rewind check, see
-- _checkRewoundHit) resolved to hitting `entity` at `result`. Returns
-- "continue" if the projectile keeps flying (pierced, or a self/ignored hit),
-- "destroy" if it called Destroy() itself, or nil if the entity should be
-- treated as a fallthrough (filtered out) -- the caller decides what happens
-- next (bounce/world resolution).
function Projectile:_resolveEntityHit(entity, result, hurtboxName: string?): string?
	if entity == self.Source or self._ignore[entity] then
		-- can't collide with ourselves or an already-pierced target;
		-- nudge past the surface and keep going
		self.Position = result.Position + safeUnit(self.Velocity, Vector3.zAxis) * (self.Radius + 0.1)
		return "continue"
	end
	if self.Filter and not self.Filter(entity) then
		return nil -- fallthrough: filtered out, treat like world geometry
	end

	self.OnHit:Fire(buildHitInfo(result, entity, hurtboxName))
	if self.PiercesLeft > 0 then
		self.PiercesLeft -= 1
		self.DamageMultiplier *= (1 - self.PierceFalloff)
		self._ignore[entity] = true
		self.Position = result.Position + safeUnit(self.Velocity, Vector3.zAxis) * (self.Radius + 0.1)
		return "continue"
	end
	self:Destroy(result, "entity")
	return "destroy"
end

-- Returns "continue" | "destroy" after resolving a physical raycast hit. A
-- bounce marks _bouncedThisTick and immediately flushes a one-shot ProjMove
-- correction (Bounced = true) below -- this is now the ONLY streaming a
-- non-homing bouncing projectile ever gets; it tells rendering clients to
-- snap instead of tween (see EnableClientRendering) and re-baseline their
-- local physics from this post-reflection Position/Velocity.
function Projectile:_resolveHit(result)
	local instance = result.Instance
	local entity = instance and Entity.Get(instance)

	if entity then
		-- Head/Body classification is purely analytic here (no synthetic
		-- hurtbox Parts, no CanQuery/CollisionGroup tricks -- see the module
		-- doc comment's "Head + Body hurtboxes" section): the raycast hits
		-- whatever real rig geometry is physically in the way, exactly as
		-- before this feature existed; we just check whether that hit POINT
		-- happens to fall within HeadRadius of the entity's Head center.
		local hurtboxName = "Body"
		local headPosition = entity:GetHeadPosition()
		if headPosition and (result.Position - headPosition).Magnitude <= entity.HeadRadius then
			hurtboxName = "Head"
		end

		local verdict = self:_resolveEntityHit(entity, result, hurtboxName)
		if verdict then
			return verdict
		end
		-- fallthrough (filtered out): treat like world geometry below
	end

	-- world geometry (or a filtered-out entity): try to punch straight through
	-- before considering a bounce -- see _attemptPenetration / the module doc
	-- comment's config section.
	if self.Penetration > 0 then
		local exitPosition = self:_attemptPenetration(result)
		if exitPosition then
			self.OnHit:Fire(buildHitInfo(result, entity))
			self.Position = exitPosition
			return "continue"
		end
		-- Blocked (wall thicker than remaining Penetration): fall through to
		-- the normal bounce/destroy resolution below, same as if Penetration
		-- had been 0 all along.
	end

	-- world geometry (or a filtered-out entity): bounce if we can
	if self.BouncesLeft > 0 then
		self.BouncesLeft -= 1
		local normal = result.Normal
		local reflected = self.Velocity - 2 * self.Velocity:Dot(normal) * normal
		self.Velocity = reflected * self.Restitution
		self.Position = result.Position + normal * (self.Radius + 0.05)
		-- Flags this tick's streamed position as a bounce (see the module doc
		-- comment / _checkSyncTransition's Step-level reset): the client must
		-- SNAP to it instead of tweening a straight line from its pre-bounce
		-- position, which would visibly cut through whatever surface sits
		-- between the two -- exactly where the bounce happened.
		self._bouncedThisTick = true
		self._bouncedNormal = normal
		-- Flush this bounce's snap-to-position immediately instead of waiting
		-- for the end-of-frame batch in the server step loop. If this is the
		-- last bounce (BouncesLeft just hit 0) and the reflected path clips
		-- more geometry later in this SAME tick's substep loop, that next hit
		-- destroys the projectile and fires ProjHit synchronously -- before
		-- Step() even returns -- so the outer loop's batching never gets a
		-- chance to queue this update at all (its "not alive" branch queues
		-- nothing). Without this, the client would never learn a bounce
		-- happened here and would keep coasting its stale pre-bounce
		-- trajectory straight through the surface until ProjHit teleports it
		-- to the real final position. Sending here guarantees the snap
		-- always reaches the client before any same-tick Destroy's ProjHit.
		-- This fires unconditionally on every bounce regardless of homing
		-- state -- it is the sole sync mechanism for a non-homing bouncer
		-- (see isSynced): the client is otherwise fully unsynced and coasts
		-- on local physics between bounces.
		if self.Visualize then
			flushMoveBatch({ {
				VisualRange = self.VisualRange,
				Position = self.Position,
				Payload = {
					Id = self.Id,
					Position = self.Position,
					Velocity = self.Velocity,
					Bounced = true,
					Normal = normal,
				},
			} })
		end
		-- Consumed for this tick already -- clear it so the outer loop's
		-- end-of-frame batch (only reachable while actively homing; see
		-- isSynced) doesn't re-snap/re-flash a second time at wherever the
		-- projectile ends up after further substeps this same tick.
		self._bouncedThisTick = false
		if self.OnBounce then
			task.spawn(self.OnBounce, self, result)
		end
		self.OnHit:Fire(buildHitInfo(result, entity))
		return "continue"
	end

	self.OnHit:Fire(buildHitInfo(result, entity))
	self:Destroy(result, "world")
	return "destroy"
end

-- Attempts to punch this projectile through the wall it just hit. Probes a
-- point Penetration studs further along the ray past the entry point, then
-- raycasts BACKWARD from that probe to the entry point, whitelisted to ONLY
-- the part that was just hit:
--  - Hit (not nil): the probe already crossed back into the SAME part from
--    outside it, meaning the wall's far/exit surface is somewhere between the
--    probe and the entry point -- i.e. the wall is thinner than the current
--    Penetration budget. The distance from the entry point to that exit
--    surface is the wall's actual thickness; that amount (not the probe
--    distance) is subtracted from Penetration, since a thin wall should
--    barely dent the budget and a thick one should nearly exhaust it.
--  - Nil: the probe point is still INSIDE the wall's solid (Roblox raycasts
--    never register a hit against a part the ray starts inside of), meaning
--    the wall is thicker than the entire Penetration budget -- can't punch
--    through at all.
-- Returns the position just past the exit surface on success, or nil if
-- blocked (caller falls through to bounce/destroy as normal).
function Projectile:_attemptPenetration(result): Vector3?
	local instance = result.Instance
	if not instance then
		return nil
	end

	local direction = safeUnit(self.Velocity, Vector3.zAxis)
	local probeOrigin = result.Position + direction * self.Penetration

	local probeParams = RaycastParams.new()
	probeParams.FilterType = Enum.RaycastFilterType.Include
	probeParams.FilterDescendantsInstances = { instance }

	local probeResult = workspace:Raycast(probeOrigin, result.Position - probeOrigin, probeParams)
	if not probeResult then
		return nil
	end

	local thickness = (probeResult.Position - result.Position).Magnitude
	self.Penetration -= thickness
	if self.Penetration < 0 then
		-- Ran out of power exactly on this wall -- treat as blocked, same as
		-- the nil case above.
		return nil
	end

	return probeResult.Position + direction * (self.Radius + 0.1)
end

-- Lag-compensated entity check for one movement substep. Only meaningful while
-- passing through a chunk that contains entities (see `highRes` in Step) and
-- only for shots that carry a positive RewindSeconds. Builds its hurtbox
-- whitelist directly from the (loaded) chunk(s) the segment touches -- not a
-- radius sweep -- so a projectile only ever considers entities actually in a
-- loaded chunk it's in, per-shooter-desync.
--
-- Two memoization/deferral choices preserve the exact "nearest in-range entity
-- with a clear LOS to `from`" semantics while cutting redundant work:
--  - The rewind instant (os.clock() - RewindSeconds) is pinned for the whole
--    Step (see Step's useRewind setup), and each entity's rewound position is
--    memoized in self._rewindCache. Within a frame RewindSeconds is constant
--    and os.clock() is stable, so an entity rewinds to the same place on every
--    substep -- previously this recomputed GetPositionAt per entity per
--    substep.
--  - LOS verification is deferred: in-range candidates are collected into a
--    reusable buffer, sorted ascending by distance-along-segment, then
--    LOS-checked nearest-first, returning the first whose LOS to `from` is
--    unobstructed. The survivor is exactly the nearest clear entity the old
--    hash-order loop would also have produced, but the raycast count is now the
--    rank of the nearest clear candidate (or N if all blocked) rather than up
--    to N regardless of order -- deterministically O(rank), not O(N) worst-case.
function Projectile:_checkRewoundHit(from: Vector3, to: Vector3)
	local whitelist = {}
	for _, position in { from, to } do
		local chunk = ChunkManager.GetChunk(position)
		if chunk and ChunkManager.IsChunkActive(chunk) then
			for entity in chunk.Entities do
				whitelist[entity] = true
			end
		end
	end

	-- Collect in-range candidates (no raycasts yet) into the reusable buffer.
	-- Each entity is tested against BOTH its rewound Head and Body spheres
	-- (see the module doc comment's "Head + Body hurtboxes" section) --
	-- Head is checked first and wins outright if in range (the two spheres
	-- are independent, not required to nest -- see Entity.luau).
	local candidates = self._candidateBuf
	for entity in whitelist do
		if entity ~= self.Source and not self._ignore[entity] and (not self.Filter or self.Filter(entity)) then
			local cache = self._rewindCache[entity]
			if not cache then
				cache = {
					Body = entity:GetBodyPositionAt(self._rewindTime),
					Head = entity:GetHeadPositionAt(self._rewindTime),
				}
				self._rewindCache[entity] = cache
			end

			local matchedHead = false
			if cache.Head then
				local closest, distance = closestPointOnSegment(cache.Head, from, to)
				if distance <= entity.HeadRadius + self.Radius then
					table.insert(candidates, {
						entity = entity,
						point = closest,
						distAlong = (closest - from).Magnitude,
						hurtbox = "Head",
					})
					matchedHead = true
				end
			end
			if not matchedHead then
				local closest, distance = closestPointOnSegment(cache.Body, from, to)
				if distance <= entity.HitboxRadius + self.Radius then
					table.insert(candidates, {
						entity = entity,
						point = closest,
						distAlong = (closest - from).Magnitude,
						hurtbox = "Body",
					})
				end
			end
		end
	end

	-- Nearest-first: sort ascending by distance along the segment, then
	-- LOS-check in order, returning the first unobstructed one. This matches
	-- the old "bestDistAlong, clear only" survivor exactly.
	table.sort(candidates, function(a, b)
		return a.distAlong < b.distAlong
	end)

	for _, c in candidates do
		-- line-of-sight: real geometry must not block the shot before it would
		-- reach this point, so stale rewound data can never be used to hit
		-- someone through a wall. The hit instance must not belong to the
		-- candidate itself, so a target's own body can't block hitting it.
		local los = workspace:Raycast(from, c.point - from, self._rayParams)
		local blocked = los ~= nil
			and (los.Position - from).Magnitude < c.distAlong - 0.5
			and Entity.Get(los.Instance) ~= c.entity
		if not blocked then
			-- drain the buffer for this frame so the next substep starts clean
			-- (Step already clears it, but this keeps the function honest if
			-- ever called from elsewhere).
			table.clear(candidates)
			return c.entity, c.point, safeUnit(from - c.point, Vector3.yAxis), c.hurtbox
		end
	end

	table.clear(candidates)
	return nil
end

function Projectile:_updateHoming(dt: number)
	local homing = self.Homing
	if not homing then
		return
	end

	if self.HomingDelay > 0 then
		self.HomingDelay -= dt
		return
	end

	-- (re)acquire a target when none / auto-targeting
	local target = self.HomingTarget
	local targetGone = target == nil or targetPosition(target) == nil

	if targetGone then
		if homing.AcquireRadius or homing.TargetTag or homing.TargetTags then
			self.HomingTarget = acquireTarget(self, homing, self.Position)
			target = self.HomingTarget
		end
	elseif not homing.Permalock and homing.Retarget then
		self.ReacquireTimer -= dt
		if self.ReacquireTimer <= 0 then
			self.ReacquireTimer = homing.ReacquireRate or 0.3
			-- No `or target` fallback: if nothing is in range anymore, the lock
			-- is genuinely dropped, matching "re-acquire if the target ...
			-- leaves" above. Homing.Permalock (checked above) is the explicit
			-- opt-in for "never drop a lock due to range."
			self.HomingTarget = acquireTarget(self, homing, self.Position)
			target = self.HomingTarget
		end
	end

	local goal = target and targetPosition(target)
	if not goal then
		return
	end
	local desired = goal - self.Position
	local turn = (homing.TurnRate or math.rad(120)) * dt
	local speed = self.Velocity.Magnitude
	local newDir = rotateTowards(self.Velocity, desired, turn)
	self.Velocity = newDir * speed
end

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
	-- a later, non-bouncing tick's streamed payload -- see _resolveHit.
	self._bouncedThisTick = false

	-- world/chunk dilation at the projectile's own position, times the
	-- shooter's CURRENT personal ratio, times this projectile's OWN current
	-- ratio -- both read live every tick (never snapshotted), so dragging a
	-- personal-time slider or an ability tweaking this specific projectile's
	-- TimeScale mid-flight takes effect immediately -- see the module doc
	-- comment's "Local time" section.
	local combinedScale = combinedTimeScale(self)
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
		self.Velocity = safeUnit(self.Velocity, Vector3.zAxis) * newSpeed
	end

	if self.Gravity > 0 then
		self.Velocity -= Vector3.new(0, self.Gravity * dt, 0)
	end

	-- Adaptive stepping: fine casts near entities (accurate hit detection),
	-- one coarse cast per frame in empty chunks (skip the wasted checks). The
	-- step size is chosen from whether the chunk we're in / moving into holds
	-- entities. A raycast is never skipped -- only its resolution adapts.
	local highRes = chunkHasEntities(self.Position)
		or chunkHasEntities(self.Position + self.Velocity * dt)
	local maxStep = highRes and HIGH_RES_STEP or LOW_RES_STEP

	-- Lag-compensation working state for this frame: pin rewindTime and a fresh
	-- rewound-position cache so every substep rewinds to the SAME instant
	-- (RewindSeconds is fixed per projectile and os.clock() is stable across
	-- substeps; previously each substep recomputed both, doing up to N redundant
	-- GetPositionAt lookups where one would do). The candidate buffer is
	-- reused, never reallocated -- see _checkRewoundHit.
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

		local result = castMovement(self, from, displacement)
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
				self.Position = result.Position + safeUnit(self.Velocity, Vector3.zAxis) * (self.Radius + 0.1)
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
	if debugSync then
		print(`[Relativity][sync] ProjHit Id={self.Id} Kind={kind or "fizzle"}`)
	end
	streamTo(self, "ProjHit", { Id = self.Id, Position = hitResult.Position, Normal = hitResult.Normal, Kind = kind })

	-- Exactly-once -- see the module doc comment's "Events" section. Fired
	-- here (not in _resolveEntityHit/_resolveHit/_expire) so EVERY removal
	-- path funnels through the same single call, including natural Lifetime/
	-- MaxRealLifetime expiry (which calls Destroy() from the outer server
	-- step loop, not from here).
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

if RunService:IsServer() then
	Heartbeat.Connect(function(globalDt)
		local moveBatch = {}
		for i = #active, 1, -1 do
			local projectile = active[i]
			-- Captured BEFORE Step() so a projectile whose homing lock drops
			-- DURING this exact tick still gets this tick's corrected
			-- post-drop Position/Velocity streamed -- otherwise the client is
			-- left holding a stale pre-transition pose and resumes local
			-- physics from the wrong place. Bounce corrections are handled
			-- separately and immediately inside _resolveHit -- they don't
			-- depend on isSynced at all, so a non-homing bouncer never
			-- reaches this batch outside the tick it actually bounces on.
			local wasSynced = isSynced(projectile)
			local alive = projectile:Step(globalDt)
			if not alive then
				local last = #active
				active[i] = active[last]
				active[last] = nil
				projectile:Destroy({ Position = projectile.Position, Normal = Vector3.yAxis })
			elseif projectile.Visualize and (wasSynced or isSynced(projectile)) then
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
						-- whatever surface sits between the two (see _resolveHit).
						Bounced = projectile._bouncedThisTick,
						Normal = projectile._bouncedThisTick and projectile._bouncedNormal or nil,
					},
				})
			end
		end
		flushMoveBatch(moveBatch)
	end, { Name = "ProjectileSystem.Step", Priority = 5 })

	-- Once-a-second ProjMove rate summary (see debugSync above) -- real time,
	-- not dilated, so the reporting cadence stays steady even mid-freeze.
	task.spawn(function()
		while true do
			task.wait(1)
			if debugSync and (_syncMoveStats.batches > 0 or _syncMoveStats.entries > 0) then
				print(`[Relativity][sync] ProjMove rate: {_syncMoveStats.batches} batches/s, {_syncMoveStats.entries} projectile-updates/s`)
			end
			_syncMoveStats.batches = 0
			_syncMoveStats.entries = 0
		end
	end)
end

--------------------------------------------------------------------------------
-- Client-side visual rendering (opt-in)
--------------------------------------------------------------------------------

local clientRendering = false
local visuals = {} -- [id] = { model, position, velocity, gravity, homing/bounce state, ... }

-- Real (undilated) seconds of no ProjMove update before a SYNCED visual is
-- assumed to have left VisualRange and gets cleaned up -- see the render
-- loop below. Generous on purpose: ProjMove batches normally arrive every
-- server tick, so anything this stale really has stopped, not just lagged.
local SYNCED_VISUAL_STALE_TIMEOUT = 2

-- Custom impact hook: fn(position, normal, model?, kind). When set, it replaces
-- the built-in effect below. (model is nil for impacts; kind is
-- "entity" | "world" | "bounce".)
local impactHandler: ((Vector3, Vector3, Instance?, string?) -> ())? = nil

function Projectile.SetImpactHandler(fn)
	impactHandler = fn
end

-- Built-in hit visualization: a short, real-time neon flash at the impact point
-- plus a ring spreading along the surface, color-coded by what was struck.
local IMPACT_COLORS = {
	entity = Color3.fromRGB(255, 80, 80), -- hit a damageable target
	world = Color3.fromRGB(255, 225, 150), -- hit geometry
	bounce = Color3.fromRGB(120, 220, 255), -- ricochet
}

local function defaultImpact(position: Vector3, normal: Vector3, kind: string?)
	local color = IMPACT_COLORS[kind or "world"] or IMPACT_COLORS.world
	local big = kind ~= "bounce"
	local info = TweenInfo.new(big and 0.28 or 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	-- expanding core flash
	local burst = Instance.new("Part")
	burst.Shape = Enum.PartType.Ball
	burst.Size = Vector3.one * (big and 0.6 or 0.3)
	burst.CFrame = CFrame.new(position)
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanQuery = false
	burst.CanTouch = false
	burst.CastShadow = false
	burst.Material = Enum.Material.Neon
	burst.Color = color
	burst.Transparency = 0.1
	burst.Parent = workspace
	TweenService:Create(burst, info, { Size = Vector3.one * (big and 3.5 or 1.5), Transparency = 1 }):Play()

	-- flat ring spreading along the surface (Cylinder's length runs along local X,
	-- so aim X down the normal and keep it thin there)
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.12, 0.5, 0.5)
	local n = normal.Magnitude > 1e-3 and normal.Unit or Vector3.yAxis
	ring.CFrame = CFrame.new(position, position + n) * CFrame.Angles(0, math.rad(90), 0)
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.2
	ring.Parent = workspace
	local ringSpan = big and 4 or 2
	TweenService:Create(ring, info, { Size = Vector3.new(0.12, ringSpan, ringSpan), Transparency = 1 }):Play()

	task.delay(info.Time, function()
		burst:Destroy()
		ring:Destroy()
	end)
end

local function playImpact(position: Vector3, normal: Vector3?, kind: string?)
	local n = normal or Vector3.yAxis
	if impactHandler then
		task.spawn(impactHandler, position, n, nil, kind)
	else
		defaultImpact(position, n, kind)
	end
end

-- Debug: draw one raycast segment as a thin fading line, colored by resolution.
-- Red = coarse cast through an empty chunk; green = fine cast near entities.
local RAY_LOWRES_COLOR = Color3.fromRGB(255, 70, 70)
local RAY_HIGHRES_COLOR = Color3.fromRGB(90, 255, 140)

local function drawRay(from: Vector3, to: Vector3, lowRes: boolean?)
	local delta = to - from
	local dist = delta.Magnitude
	if dist < 1e-3 then
		return
	end
	local line = Instance.new("Part")
	line.Anchored = true
	line.CanCollide = false
	line.CanQuery = false
	line.CanTouch = false
	line.CastShadow = false
	line.Material = Enum.Material.Neon
	line.Color = lowRes and RAY_LOWRES_COLOR or RAY_HIGHRES_COLOR
	line.Size = Vector3.new(0.08, 0.08, dist)
	line.CFrame = CFrame.lookAt((from + to) * 0.5, to)
	line.Transparency = 0.15
	line.Parent = workspace
	TweenService:Create(line, TweenInfo.new(0.3, Enum.EasingStyle.Linear), { Transparency = 1 }):Play()
	task.delay(0.3, function()
		line:Destroy()
	end)
end

local function buildVisualModel(data): Instance
	local model

	if data.Model then
		model = data.Model:Clone()
	else
		local part = Instance.new("Part")
		local spec = data.Visual
		if spec then
			if spec.Shape == "Ball" then
				part.Shape = Enum.PartType.Ball
			elseif spec.Shape == "Cylinder" then
				part.Shape = Enum.PartType.Cylinder
			end
			part.Size = spec.Size or Vector3.one * 0.5
			part.Color = spec.Color or Color3.new(1, 1, 1)
		else
			part.Size = Vector3.one * 0.4
			part.Color = Color3.fromRGB(255, 220, 120)
		end
		part.Material = Enum.Material.Neon
		model = part
	end
	if model:IsA("Model") then
		for _, part in { model, table.unpack(model:GetDescendants()) } do

			if part:IsA("BasePart") then
				--if part == model.PrimaryPart then
				--	part.Anchored = true
				--else
				--	part.Anchored = false
--
				--end
				part.Anchored = part == model.PrimaryPart --<-- clever? might try later but this works 4 now
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.CastShadow = false
			end
		end
	else
		model.Anchored = true
		model.CanCollide = false
		model.CanQuery = false
		model.CanTouch = false
		model.CastShadow = false
	end
	model.Parent = workspace
	RunService.RenderStepped:Wait()
	return model
end

local function placeVisual(model: Instance, position: Vector3, velocity: Vector3)
	local look = position + safeUnit(velocity, Vector3.zAxis)
	local cframe = CFrame.new(position, look)
	if model:IsA("Model") then
		model:PivotTo(cframe)
	elseif model:IsA("BasePart") then
		model.CFrame = cframe
	end
end

-- Removes the flying tracer. Impact VFX is played from the ProjHit handler
-- itself (see EnableClientRendering), so this fires for real hits AND harmless
-- expiry without ever flashing in mid-air.
local function destroyVisual(id)
	local visual = visuals[id]
	if not visual then
		return
	end
	visuals[id] = nil
	local delay = visual.destroyDelay or 0
	if delay > 0 then
		task.delay(delay, function()
			visual.model:Destroy()
		end)
	else
		visual.model:Destroy()
	end
end

-- Client-side shadow simulation helpers -----------------------------------

-- Smoothly moves a SYNCED bullet visual toward the latest authoritative pose
-- via a tween. Duration adapts to how often updates arrive, so motion stays
-- continuous whether the server is stepping fast or coarsely, and it naturally
-- slows when the world's time ratio drops. Unsynced visuals never call this --
-- see the per-frame local-physics loop below.
local function tweenVisual(visual, position: Vector3, velocity: Vector3, duration: number)
	local look = position + safeUnit(velocity, Vector3.zAxis)
	local goal = CFrame.new(position, look)
	local info = TweenInfo.new(duration, Enum.EasingStyle.Linear)

	if visual.tween then
		visual.tween:Cancel()
		visual.tween = nil
	end

	local model = visual.model
	local target = model
	if model:IsA("Model") then
		target = model.PrimaryPart
	end
	if target and target:IsA("BasePart") then
		visual.tween = TweenService:Create(target, info, { CFrame = goal })
		visual.tween:Play()
	elseif model:IsA("Model") then
		model:PivotTo(goal) -- no primary part to tween; snap
	end
end

function Projectile.EnableClientRendering()
	if clientRendering or RunService:IsServer() then
		return
	end
	clientRendering = true

	VisualOffload.On("ProjSpawn", function(data)
		local model = buildVisualModel(data)
		placeVisual(model, data.Position, data.Velocity)
		visuals[data.Id] = {
			model = model,
			destroyDelay = data.DestroyDelay or 0,
			lastUpdate = os.clock(),
			tween = nil,

			position = data.Position,
			velocity = data.Velocity,
			gravity = data.Gravity or 0,
			acceleration = data.Acceleration or 0,
			minSpeed = data.MinSpeed or 0,
			maxSpeed = data.MaxSpeed or math.huge,
			life = data.Lifetime or 5,

			synced = data.Synced == true,
			-- Combined Source.TimeScale * projectile.TimeScale at spawn time;
			-- updated live via ProjTimeScale below, folded into the unsynced
			-- render loop's local dead-reckoning -- see the module doc
			-- comment's "Local time" section.
			timeScale = data.TimeScale or 1,
			-- Real (undilated) safety-net cap -- see MaxRealLifetime / the
			-- render loop below. spawnRealTime is THIS client's own os.clock()
			-- at spawn, not the server's -- fine, since this only needs to be
			-- a generous backstop, not an exact match to the server's own cap.
			spawnRealTime = os.clock(),
			maxRealLifetime = data.MaxRealLifetime or DEFAULT_MAX_REAL_LIFETIME,
		}
	end)

	-- Fires only when the combined personal/local TimeScale actually changes
	-- (see Projectile:_checkTimeScaleChange) -- not a per-frame stream. The
	-- client just needed to know the number; from here it predicts locally
	-- exactly like it already does for chunk/world dilation.
	VisualOffload.On("ProjTimeScale", function(data)
		local visual = visuals[data.Id]
		if visual then
			visual.timeScale = data.TimeScale
		end
	end)

	-- Sync state changed (homing lock acquired/dropped, or bounces just ran
	-- out) -- rare, only on an actual transition, never per-frame. Synced
	-- switches the visual into "trust the streamed ProjMove" mode; unsynced
	-- switches it back to local physics from wherever the last authoritative
	-- Position/Velocity left it.
	VisualOffload.On("ProjSync", function(data)
		local visual = visuals[data.Id]
		if visual then
			visual.synced = data.Synced == true
			if visual.synced then
				-- reset the staleness clock right at the transition -- see the
				-- synced branch of the render loop below -- so a lastUpdate
				-- left over from before this transition (however old) can't
				-- immediately read as stale before the first real ProjMove
				-- arrives.
				visual.lastUpdate = os.clock()
			end
		end
	end)

	-- Batched authoritative pose updates (an array covering every entry that
	-- needs one this frame, not one event each). Two kinds of entries arrive
	-- here, handled differently:
	--  - Bounced = true: a one-shot bounce correction, sent regardless of
	--    whether the visual is currently in continuous-sync mode (a
	--    non-homing bouncer is normally fully unsynced -- see isSynced /
	--    the module doc comment -- so this is the ONLY update it ever gets
	--    between spawn and impact). Always applied unconditionally: snap
	--    instead of tweening, since tweening a straight line from the old
	--    position would cut through whatever surface sits between them
	--    (exactly where the bounce occurred), play the ricochet flash, and
	--    re-baseline position/velocity so local physics (see the per-frame
	--    loop below) picks up from the correct post-reflection state.
	--  - Otherwise: a continuous homing-sync update, only meaningful (and
	--    only sent by the server) while visual.synced is true -- see the
	--    module doc comment for why homing can't be predicted client-side.
	VisualOffload.On("ProjMove", function(batch)
		local now = os.clock()
		for _, data in batch do
			local visual = visuals[data.Id]
			if visual and data.Bounced then
				visual.lastUpdate = now
				visual.position = data.Position
				visual.velocity = data.Velocity
				placeVisual(visual.model, data.Position, data.Velocity)
				playImpact(data.Position, data.Normal, "bounce")
			elseif visual and visual.synced then
				local duration = math.clamp(now - visual.lastUpdate, 0.03, 0.2)
				visual.lastUpdate = now
				visual.position = data.Position
				visual.velocity = data.Velocity
				tweenVisual(visual, data.Position, data.Velocity, duration)
			end
		end
	end)

	VisualOffload.On("ProjHit", function(data)
		local visual = visuals[data.Id]
		if visual then
			-- Snap to the server's exact position before destroying, so any
			-- imperceptible mid-flight drift from local simulation never shows
			-- at the one moment it would be visible.
			placeVisual(visual.model, data.Position, visual.velocity)
			if data.Kind then
				playImpact(data.Position, data.Normal, data.Kind)
			end
		end
		destroyVisual(data.Id)
	end)

	VisualOffload.On("ProjRay", function(data)
		drawRay(data.From, data.To, data.LowRes)
	end)

	-- Every projectile visual gets exactly one ProjSpawn and, eventually, one
	-- ProjHit. For an UNSYNCED visual (the common case: no active homing lock
	-- -- this includes a bouncer between bounces, since bouncing no longer
	-- keeps a visual continuously synced, see isSynced / the module doc
	-- comment), this loop is the entire simulation in between -- it integrates
	-- acceleration/gravity/position every frame using the same chunk/global dt
	-- pipeline the server's Step uses (ChunkManager.ScaleDt). No raycasting
	-- ever happens here -- a SYNCED visual (actively homing onto a target)
	-- skips all of that -- its Position/Velocity/pose are driven entirely by
	-- the streamed ProjMove handler above; see the module doc comment for why
	-- that case can't be safely predicted client-side. A bouncing visual's
	-- position/velocity get corrected in-place by the one-shot Bounced
	-- ProjMove entry each time it bounces (handled above, independent of
	-- visual.synced), and this loop just keeps integrating forward from
	-- whatever that correction left behind. All of this is purely cosmetic;
	-- the server always runs its own independent, authoritative Step, and any
	-- drift is corrected the instant ProjHit snaps the final position.
	Heartbeat.Connect(function(globalDt)
		for id, visual in visuals do
			-- Real (undilated) backstop, checked unconditionally before the
			-- synced/unsynced split below -- mirrors the server's own
			-- MaxRealLifetime check (see Step). Primarily this is redundant
			-- with ProjHit already destroying the visual the instant the
			-- server actually expires it; this exists purely as a client-only
			-- fallback in case that message is ever missed (e.g. the visual
			-- drifted outside VisualRange), so a visual can never linger
			-- forever regardless of dt/freeze state -- same reasoning as the
			-- server-side fix this mirrors.
			if os.clock() - visual.spawnRealTime >= visual.maxRealLifetime then
				destroyVisual(id)
				continue
			end

			if visual.synced then
				-- Position/velocity/pose come from ProjMove; the only thing
				-- that runs here is a left-VisualRange safety net. This is
				-- deliberately wall-clock (os.clock()), NOT a dilated-dt
				-- countdown: a synced visual can belong to a shooter at ANY
				-- personal time ratio, including exactly 0 (a legitimate
				-- indefinite freeze the player chose), so there's no dilated
				-- "Lifetime elapsed" schedule the client could reconstruct on
				-- its own without knowing that live ratio (which isn't
				-- replicated to observers -- see the module doc comment's
				-- "Personal time" section). Instead: the server includes every
				-- synced projectile in its ProjMove batch every tick
				-- regardless of dt (see the server step loop below), so as
				-- long as this client is in VisualRange, lastUpdate keeps
				-- getting refreshed; once it stops (genuinely left range, or
				-- the projectile is gone), a real-time timeout cleans it up.
				if os.clock() - visual.lastUpdate > SYNCED_VISUAL_STALE_TIMEOUT then
					destroyVisual(id)
				end
				continue
			end

			-- visual.timeScale is the combined Source.TimeScale *
			-- projectile.TimeScale, kept current via the (rare, on-change
			-- only) ProjTimeScale handler above -- see the module doc
			-- comment's "Local time" section. This mirrors the server's own
			-- Step exactly: ChunkManager.ScaleDt(globalDt, pos) * combinedScale.
			local dt = ChunkManager.ScaleDt(globalDt, visual.position) * visual.timeScale
			if dt > 0 then
				if visual.acceleration ~= 0 then
					local speed = visual.velocity.Magnitude
					local newSpeed = math.clamp(speed + visual.acceleration * dt, visual.minSpeed, visual.maxSpeed)
					visual.velocity = safeUnit(visual.velocity, Vector3.zAxis) * newSpeed
				end
				if visual.gravity > 0 then
					visual.velocity -= Vector3.new(0, visual.gravity * dt, 0)
				end

				visual.position += visual.velocity * dt

				visual.life -= dt
				placeVisual(visual.model, visual.position, visual.velocity)
				if visual.life <= 0 then
					-- Safety net: normally ProjHit arrives first and removes this
					-- entry. This only fires if it never does (e.g. the
					-- projectile left this client's VisualRange).
					destroyVisual(id)
				end
			end
		end
	end, { Name = "ProjectileSystem.ClientSimulate", Priority = 5 })
end

return Projectile
