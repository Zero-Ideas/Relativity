--!optimize 2
--[[
	Projectile.luau
	Server-authoritative, raycast-driven projectiles that live in dilated time.
	Every projectile steps in the local time of the chunk it currently occupies,
	so a bullet flying through a 0.2x slow zone crawls, its gravity floats, and
	its fuse burns slower — all for free.

	Supported behaviours (mix and match): straight shots, ballistic gravity,
	acceleration/deceleration, bouncing (restitution), homing (explicit target or
	auto-acquire by tag(s), with optional Permalock), piercing with falloff, and
	cone bursts. Rendering can be offloaded to clients (Visualize = true): the
	server keeps only the logic. Every projectile gets exactly two replication
	events over its life -- ProjSpawn (once, with its full trajectory-determining
	config) and ProjHit (once, on destroy) -- UNLESS it's currently doing
	something the client can't safely reproduce on its own, in which case the
	server also streams authoritative Position/Velocity every tick (batched,
	one ProjMove per frame covering everyone who currently needs it, not one
	event each) for as long as that's true. There are exactly two such cases,
	both driven by a single per-tick check (self.HomingTarget ~= nil or
	self.BouncesLeft > 0), and a rare ProjSync event tells clients when a visual
	crosses in or out of that state:
	 - Homing while actually locked onto a target: the client only ever sees a
	   target's position through that target's own replication lag, which
	   differs per observer, so if it rotated toward that position locally, two
	   clients watching the same missile chase the same target could compute
	   two different flight paths.
	 - Bouncing while bounces remain: reproducing a bounce client-side requires
	   matching the server's exact raycast resolution/timing AND knowing which
	   hits are really entities (piercable/filterable, server-only knowledge --
	   the client has no replicated entity registry to check against), neither
	   of which the client can do reliably. Guessing wrong doesn't just look
	   slightly off, it visibly bounces off things that should have been pierced.
	The moment neither condition holds -- no lock, no bounces left -- streaming
	stops and the client coasts on local physics (gravity/acceleration only, no
	raycasting), which is driftless because it depends on nothing but universal
	constants every client agrees on. All client-side simulation is purely
	cosmetic; the server always runs its own independent, authoritative Step,
	and any visual drift is corrected the instant ProjHit snaps the final
	position.

	API:
	 Projectile.new(config) -> projectile
	 Projectile.Burst(config, count) -> { projectile }
	 Projectile.EnableClientRendering()          -- call once on the client
	 Projectile.SetImpactHandler(fn(position, normal, model))  -- client VFX hook
	 Projectile.SetDebugRays(enabled)            -- default off; see debugRays below

	 config (all optional unless noted):
	   Origin: Vector3          (required)
	   Direction: Vector3       (required unless TargetPosition given)
	   TargetPosition: Vector3  (aim at a world point instead of a direction)
	   Speed = 100
	   Acceleration = 0         (studs/s² along current velocity direction; negative decelerates)
	   MinSpeed = 0, MaxSpeed = math.huge   (clamp for Acceleration)
	   Lifetime = 5             (dilated seconds; no upper bound is enforced)
	   Damage = 0
	   Source = entity          (deals the damage; never hits itself)
	   Filter = (entity)->bool  (which entities count as targets; also applied to homing acquisition)
	   Gravity = 0              (studs/s² downward, integrated with dilated dt)
	   Radius = 0               (>0 uses a spherecast)
	   Bounces = 0              (world bounces before it dies; no upper bound is enforced)
	   Restitution = 0.5        (velocity kept per bounce)
	   MaxPierces = 0           (enemies passed through)
	   PierceFalloff = 0        (damage lost per pierce, 0..1)
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
	   OnHit = fn(projectile, result, hitEntity?)
	   OnBounce = fn(projectile, result)
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
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Heartbeat = require(script.Parent.Heartbeat)
local ChunkManager = require(script.Parent.ChunkManager)
local Entity = require(script.Parent.Entity)
local VisualOffload = require(script.Parent.VisualOffload)

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

-- Whether the client can't safely predict this projectile's motion on its own
-- right now -- see the module doc comment. Checked fresh every tick (Step's
-- end-of-tick transition check, and here for the initial spawn state), never a
-- static per-projectile classification. Note this is NOT just "BouncesLeft >
-- 0": once a projectile has bounced at all, its remaining trajectory is a
-- post-reflection path the client never predicted and may still take a long
-- time to actually resolve (a heavily-restituted bounce can leave it coasting
-- for seconds before its real terminal hit) -- staying synced for the rest of
-- its life, not just while bounces remain, is what keeps that whole remaining
-- flight pinned to the server's real position instead of going fully blind
-- the instant the last bounce is spent.
local function isSynced(projectile): boolean
	return projectile.HomingTarget ~= nil or projectile.BouncesLeft > 0 or projectile._hasBounced == true
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
		-- Whether it starts out synced (an explicit Homing.Target given at
		-- construction, or Bounces > 0) -- if so, the client starts in "trust
		-- the stream" mode immediately; the server's step loop below will
		-- include it in the very next ProjMove batch.
		Synced = isSynced(projectile),
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

		Damage = config.Damage or 0,
		DamageMultiplier = 1,
		Source = config.Source,
		Filter = config.Filter,

		BouncesLeft = bounces,
		Restitution = config.Restitution or 0.5,

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

		OnHit = config.OnHit,
		OnBounce = config.OnBounce,

		RewindSeconds = config.RewindSeconds or 0,

		_ignore = {}, -- entities already pierced
		_hasBounced = false, -- once true, stays synced for the rest of its life -- see isSynced
		_bouncedThisTick = false,
		_bouncedNormal = Vector3.yAxis,
		Dead = false,
	}, Projectile)

	self._rayParams = buildRayParams(self)
	self._streamedSynced = isSynced(self)

	table.insert(active, self)
	spawnVisual(self)
	return self
end

-- Tells rendering clients only when the sync state actually changed -- not
-- every frame (see isSynced / the module doc comment). True switches the
-- client into "trust the streamed ProjMove" mode; false switches it back to
-- local physics from wherever the last authoritative Position/Velocity left
-- it. Checked once at the end of each Step, after both homing and any bounce
-- resolution have run for that tick, so it correctly reflects both
-- contributing conditions with one flag and one event.
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

--------------------------------------------------------------------------------
-- Per-projectile step
--------------------------------------------------------------------------------

function Projectile:_dealDamage(entity, result)
	local damage = self.Damage * self.DamageMultiplier
	if damage <= 0 then
		return
	end
	local info = { Type = "Projectile", Source = self.Source, Position = result.Position }
	if self.Source and self.Source.DealDamage then
		self.Source:DealDamage(entity, damage, info)
	else
		entity:TakeDamage(damage, info)
	end
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
function Projectile:_resolveEntityHit(entity, result): string?
	if entity == self.Source or self._ignore[entity] then
		-- can't collide with ourselves or an already-pierced target;
		-- nudge past the surface and keep going
		self.Position = result.Position + safeUnit(self.Velocity, Vector3.zAxis) * (self.Radius + 0.1)
		return "continue"
	end
	if self.Filter and not self.Filter(entity) then
		return nil -- fallthrough: filtered out, treat like world geometry
	end

	self:_dealDamage(entity, result)
	if self.OnHit then
		task.spawn(self.OnHit, self, result, entity)
	end
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
-- bounce marks _bouncedThisTick so the streamed ProjMove for this tick tells
-- rendering clients to snap instead of tween (see EnableClientRendering).
function Projectile:_resolveHit(result)
	local instance = result.Instance
	local entity = instance and Entity.Get(instance)

	if entity then
		local verdict = self:_resolveEntityHit(entity, result)
		if verdict then
			return verdict
		end
		-- fallthrough (filtered out): treat like world geometry below
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
		self._hasBounced = true
		self._bouncedThisTick = true
		self._bouncedNormal = normal
		if self.OnBounce then
			task.spawn(self.OnBounce, self, result)
		end
		return "continue"
	end

	if self.OnHit then
		task.spawn(self.OnHit, self, result, entity)
	end
	self:Destroy(result, "world")
	return "destroy"
end

-- Lag-compensated entity check for one movement substep. Only meaningful while
-- passing through a chunk that contains entities (see `highRes` in Step) and
-- only for shots that carry a positive RewindSeconds. Builds its hurtbox
-- whitelist directly from the (loaded) chunk(s) the segment touches -- not a
-- radius sweep -- so a projectile only ever considers entities actually in a
-- loaded chunk it's in, per-shooter-desync.
function Projectile:_checkRewoundHit(from: Vector3, to: Vector3)
	local rewindTime = os.clock() - self.RewindSeconds

	local whitelist = {}
	for _, position in { from, to } do
		local chunk = ChunkManager.GetChunk(position)
		if chunk and ChunkManager.IsChunkActive(chunk) then
			for entity in chunk.Entities do
				whitelist[entity] = true
			end
		end
	end

	local bestEntity, bestPoint, bestDistAlong = nil, nil, math.huge
	for entity in whitelist do
		if entity ~= self.Source and not self._ignore[entity] and (not self.Filter or self.Filter(entity)) then
			local rewoundPos = entity:GetPositionAt(rewindTime)
			local closest, distance = closestPointOnSegment(rewoundPos, from, to)
			if distance <= entity.HitboxRadius + self.Radius then
				local distAlong = (closest - from).Magnitude
				if distAlong < bestDistAlong then
					-- line-of-sight: real geometry must not block the shot before
					-- it would reach this point, so stale rewound data can never
					-- be used to hit someone through a wall.
					local los = workspace:Raycast(from, closest - from, self._rayParams)
					local blocked = los ~= nil
						and (los.Position - from).Magnitude < distAlong - 0.5
						and Entity.Get(los.Instance) ~= entity
					if not blocked then
						bestEntity, bestPoint, bestDistAlong = entity, closest, distAlong
					end
				end
			end
		end
	end

	if bestEntity then
		return bestEntity, bestPoint, safeUnit(from - bestPoint, Vector3.yAxis)
	end
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

-- Advances the projectile; returns false when it should be removed.
function Projectile:Step(globalDt: number): boolean
	if self.Dead then
		return false
	end

	-- Reset every tick so a stale true from a previous bounce never leaks into
	-- a later, non-bouncing tick's streamed payload -- see _resolveHit.
	self._bouncedThisTick = false

	local dt = ChunkManager.ScaleDt(globalDt, self.Position)
	if dt <= 0 then
		return true -- frozen chunk / paused: keep it alive, don't move it
	end

	self.Age += dt
	if self.Age >= self.Lifetime then
		local result = { Position = self.Position, Normal = Vector3.yAxis, Instance = nil }
		if self.OnHit then
			task.spawn(self.OnHit, self, result, nil)
		end
		return false
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
			local lagEntity, lagPoint, lagNormal = self:_checkRewoundHit(from, to)
			if lagEntity then
				if debugRays then
					self:_streamRay(from, lagPoint, false)
				end
				local verdict = self:_resolveEntityHit(lagEntity, { Position = lagPoint, Normal = lagNormal })
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
				-- pierce/bounce/ignore already advanced self.Position past the surface
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

	-- Defensive: drop heavy references so a projectile object that somehow
	-- outlives removal from `active` (e.g. a future caller retaining the
	-- returned handle) doesn't keep entities/closures alive through it.
	table.clear(self._ignore)
	self.HomingTarget = nil
end

--------------------------------------------------------------------------------
-- Server step loop
--------------------------------------------------------------------------------

if RunService:IsServer() then
	Heartbeat.Connect(function(globalDt)
		local moveBatch = {}
		for i = #active, 1, -1 do
			local projectile = active[i]
			-- Captured BEFORE Step() so a projectile that transitions out of
			-- sync DURING this exact tick (its last bounce charge just spent,
			-- or its homing lock just dropped) still gets this tick's
			-- corrected post-bounce/post-drop Position/Velocity streamed --
			-- otherwise the client is left holding a stale pre-transition pose
			-- and resumes local physics from the wrong place (e.g. coasting
			-- on the old pre-bounce velocity, straight through the floor).
			local wasSynced = isSynced(projectile)
			local alive = projectile:Step(globalDt)
			if not alive then
				local last = #active
				active[i] = active[last]
				active[last] = nil
				projectile:Destroy({ Position = projectile.Position, Normal = Vector3.yAxis })
			elseif projectile.Visualize and (wasSynced or isSynced(projectile)) then
				-- Currently (or just-formerly, see above) locked onto a target
				-- and/or has bounces left (checked fresh every tick, not a
				-- static classification) -- see the module doc comment for why
				-- these are the cases that must stay streamed rather than left
				-- to the client.
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

	for _, part in { model, table.unpack(model:GetDescendants()) } do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
		end
	end
	model.Parent = workspace
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
		}
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
		end
	end)

	-- Synced visuals only: authoritative pose arrives batched (an array
	-- covering every currently-synced projectile this frame, not one event
	-- each) -> tween each toward its latest position. See the module doc
	-- comment for why this can't be safely predicted client-side.
	VisualOffload.On("ProjMove", function(batch)
		local now = os.clock()
		for _, data in batch do
			local visual = visuals[data.Id]
			if visual and visual.synced then
				local duration = math.clamp(now - visual.lastUpdate, 0.03, 0.2)
				visual.lastUpdate = now
				visual.position = data.Position
				visual.velocity = data.Velocity
				if data.Bounced then
					-- A bounce happened on the server between this update and
					-- the last one -- tweening a straight line from the old
					-- position to this one would cut through whatever surface
					-- sits between them (exactly where the bounce occurred), so
					-- snap instead and play the ricochet flash at the new pose.
					placeVisual(visual.model, data.Position, data.Velocity)
					playImpact(data.Position, data.Normal, "bounce")
				else
					tweenVisual(visual, data.Position, data.Velocity, duration)
				end
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
	-- ProjHit. For an UNSYNCED visual (the common case: no homing lock, no
	-- bounces remaining), this loop is the entire simulation in between -- it
	-- integrates acceleration/gravity/position every frame using the same
	-- chunk/global dt pipeline the server's Step uses (ChunkManager.ScaleDt).
	-- No raycasting ever happens here -- a SYNCED visual (actively homing onto
	-- a target and/or still able to bounce) skips all of that -- its
	-- Position/Velocity/pose are driven entirely by the streamed ProjMove
	-- handler above; see the module doc comment for why that case can't be
	-- safely predicted client-side. All of this is purely cosmetic; the server
	-- always runs its own independent, authoritative Step, and any drift is
	-- corrected the instant ProjHit snaps the final position.
	Heartbeat.Connect(function(globalDt)
		for id, visual in visuals do
			local dt = ChunkManager.ScaleDt(globalDt, visual.position)
			if dt > 0 then
				if visual.synced then
					-- Position/velocity/pose come from ProjMove; only the
					-- left-VisualRange safety net runs here.
					visual.life -= dt
					if visual.life <= 0 then
						destroyVisual(id)
					end
					continue
				end

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
