--!strict
--!optimize 2
--[[
	ProjectileClient (client rendering, purely cosmetic)
	Receives the server-authoritative Projectile system's replication stream
	(see Shared.ProjectileProtocol for the wire format, and
	ServerScriptService.Server.Projectile/Replication.luau for the sending
	side) and renders tracers/impacts. This module never makes a gameplay
	decision -- no hit detection, no damage, no entity access -- it only draws
	what the server tells it happened. All client-side simulation between
	updates is dead-reckoning for smoothness (see Prediction.luau); the
	server's own independent Step is always authoritative, and any visual
	drift is corrected the instant ProjHit snaps the final position.

	Modules:
	 init        message handlers + the bounded per-frame render scheduler
	 Prediction  dead-reckoning physics (mirrors the server Step)
	 VisualModel building, posing, culling and retiring the rendered Instance
	 View        camera frustum test
	 Impact      hit flashes (swappable via SetImpactHandler)
	 DebugRays   ProjRay debug lines

	API:
	 ProjectileClient.EnableClientRendering()          -- call once on the client
	 ProjectileClient.SetImpactHandler(fn(position, normal, model, kind))
	     -- replaces the built-in flash/ring effect; see Impact.luau
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = script.Parent
local Heartbeat = require(Shared:WaitForChild("Heartbeat"))
local VisualOffload = require(Shared:WaitForChild("VisualOffload"))
local Protocol = require(Shared:WaitForChild("ProjectileProtocol"))

local DebugRays = require(script.DebugRays)
local Impact = require(script.Impact)
local Prediction = require(script.Prediction)
local Types = require(script.Types)
local View = require(script.View)
local VisualModel = require(script.VisualModel)

type Visual = Types.Visual

local Channels = Protocol.Channels

local ProjectileClient = {}

function ProjectileClient.SetImpactHandler(fn: (Vector3, Vector3, Instance?, string?) -> ())
	Impact.SetHandler(fn)
end

-- Matches the server's own default -- used only if a spawn payload is ever
-- missing MaxRealLifetime, which shouldn't normally happen.
local DEFAULT_MAX_REAL_LIFETIME = 60

-- Real (undilated) seconds of no ProjMove update before a SYNCED visual is
-- assumed to have left VisualRange and gets cleaned up -- see the render
-- loop below. Generous on purpose: ProjMove batches normally arrive every
-- server tick, so anything this stale really has stopped, not just lagged.
local SYNCED_VISUAL_STALE_TIMEOUT = 2
-- Hard cap on visible Transform work in one client frame. Off-screen visuals
-- still advance logically when visited but consume no transform budget. The
-- persistent round-robin cursor is independent of dilated time, so changing
-- GlobalTimeScale cannot collapse previously staggered cohorts onto one frame.
local MAX_VISUAL_UPDATES_PER_FRAME = 2500
local SMOOTH_RADIUS = 100
local MAX_SMOOTH_PROJECTILES = 500
local SMOOTH_SET_REFRESH_INTERVAL = 0.1 -- real seconds; selection is presentation-only
local DEFAULT_SMOOTH_DURATION = 1 / 60

local clientRendering = false
local visuals: { [number]: Visual } = {}
local visualCount = 0
local visualOrder: { number } = {} -- append-only between compactions; dead ids are tombstones
local visualCursor = 1
local visualTombstones = 0
-- Sum of global (dilated) dt since rendering began; a visual's
-- lastSimulationTime is a reading of this clock.
local globalSimulationClock = 0
local smoothVisuals: { Visual } = {}
local nextSmoothSetRefresh = 0

--------------------------------------------------------------------------------
-- Smooth set: the nearest visuals get per-frame interpolation
--------------------------------------------------------------------------------

local function refreshSmoothVisuals(now: number)
	if now < nextSmoothSetRefresh then
		return
	end
	nextSmoothSetRefresh = now + SMOOTH_SET_REFRESH_INTERVAL

	local player = Players.LocalPlayer
	local character = player and player.Character
	local root = character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart)
	debug.profilebegin("ProjectileClient.RefreshSmoothSet")
	-- Keep only the nearest K candidates in a max-heap, so this never sorts
	-- every nearby visual when only MAX_SMOOTH_PROJECTILES can be selected.
	local heapVisuals: { Visual } = table.create(MAX_SMOOTH_PROJECTILES)
	local heapDistances: { number } = table.create(MAX_SMOOTH_PROJECTILES)
	local heapSize = 0
	local function swap(a: number, b: number)
		heapVisuals[a], heapVisuals[b] = heapVisuals[b], heapVisuals[a]
		heapDistances[a], heapDistances[b] = heapDistances[b], heapDistances[a]
	end
	local function push(visual: Visual, distanceSq: number)
		heapSize += 1
		local index = heapSize
		heapVisuals[index] = visual
		heapDistances[index] = distanceSq
		while index > 1 do
			local parent = index // 2
			if heapDistances[parent] >= distanceSq then
				break
			end
			swap(parent, index)
			index = parent
		end
	end
	local function replaceRoot(visual: Visual, distanceSq: number)
		heapVisuals[1] = visual
		heapDistances[1] = distanceSq
		local index = 1
		while true do
			local left = index * 2
			if left > heapSize then
				break
			end
			local right = left + 1
			local largest = if right <= heapSize and heapDistances[right] > heapDistances[left] then right else left
			if heapDistances[index] >= heapDistances[largest] then
				break
			end
			swap(index, largest)
			index = largest
		end
	end
	if root and root:IsA("BasePart") then
		local rootPosition = root.Position
		local radiusSq = SMOOTH_RADIUS * SMOOTH_RADIUS
		for _, visual in visuals do
			local offset = visual.position - rootPosition
			local distanceSq = offset:Dot(offset)
			if distanceSq <= radiusSq and View.contains(visual.position) then
				if heapSize < MAX_SMOOTH_PROJECTILES then
					push(visual, distanceSq)
				elseif distanceSq < heapDistances[1] then
					replaceRoot(visual, distanceSq)
				end
			end
		end
	end

	local selected: { [Visual]: boolean } = {}
	local newSmoothVisuals: { Visual } = table.create(heapSize)
	for index = 1, heapSize do
		local visual = heapVisuals[index]
		selected[visual] = true
		table.insert(newSmoothVisuals, visual)
		if not visual.smoothTransform then
			visual.smoothTransform = true
			visual.lastSmoothStep = now
			visual.lastSmoothTarget = nil
		end
	end
	for _, visual in smoothVisuals do
		if not selected[visual] then
			visual.smoothTransform = false
			visual.lastSmoothStep = nil
			visual.lastSmoothTarget = nil
		end
	end
	smoothVisuals = newSmoothVisuals
	debug.profileend()
end

local function setSmoothTarget(visual: Visual, now: number)
	local previousTarget = visual.lastSmoothTarget
	local duration = if previousTarget
		then math.clamp(now - previousTarget, DEFAULT_SMOOTH_DURATION, 0.1)
		else DEFAULT_SMOOTH_DURATION
	visual.lastSmoothTarget = now
	VisualModel.SetTarget(visual, visual.position, visual.velocity, duration)
end

--------------------------------------------------------------------------------
-- Visual lifecycle
--------------------------------------------------------------------------------

-- Removes the flying tracer. Impact VFX is played from the ProjHit handler
-- itself, so this fires for real hits AND harmless expiry without ever
-- flashing in mid-air. The bullet DISAPPEARS instantly, but the actual
-- :Destroy() waits out the longest lifetime among the effects that were
-- emitting (or DestroyDelay, whichever is longer) -- see VisualModel.Retire.
local function destroyVisual(id: number)
	local visual = visuals[id]
	if not visual then
		return
	end
	visuals[id] = nil
	visualCount -= 1
	visualTombstones += 1
	VisualModel.Retire(visual, visual.destroyDelay)
end

-- Adopts an authoritative pose as of NOW. Every server pose (spawn, bounce,
-- sync transition) is an end-of-server-frame snapshot, so the next
-- render-loop visit must only integrate time that passes after receipt --
-- not the backlog since this visual's previous round-robin visit, which
-- already happened before the pose was taken.
local function rebaseline(visual: Visual, position: Vector3, velocity: Vector3)
	visual.position = position
	visual.velocity = velocity
	visual.simulationDebt = 0
	visual.lastSimulationTime = globalSimulationClock
end

local function onSpawn(data: Protocol.SpawnPayload)
	if visuals[data.Id] then
		return
	end
	local model, rig = VisualModel.Build(data)
	local now = os.clock()
	local inView = View.contains(data.Position)
	local visual: Visual = {
		id = data.Id,
		model = model,
		rig = rig,
		destroyDelay = data.DestroyDelay or 0,
		-- See VisualModel.FadeOut -- both default true.
		waitForParticles = data.WaitForParticles ~= false,
		waitForTrails = data.WaitForTrails ~= false,

		position = data.Position,
		velocity = data.Velocity,
		gravity = data.Gravity or 0,
		acceleration = data.Acceleration or 0,
		accelerationDirection = data.AccelerationDirection,
		minSpeed = data.MinSpeed or 0,
		maxSpeed = data.MaxSpeed or math.huge,
		life = data.Lifetime,
		simulationDebt = 0,
		-- Combined Source.TimeScale * projectile.TimeScale; updated live via
		-- ProjTimeScale -- see the "Local time" section of the server module.
		timeScale = data.TimeScale or 1,
		lastSimulationTime = globalSimulationClock,
		synced = data.Synced == true,

		-- Real (undilated) safety-net cap. spawnRealTime is THIS client's own
		-- os.clock() at spawn -- fine, since this only needs to be a generous
		-- backstop, not an exact match to the server's own cap.
		spawnRealTime = now,
		maxRealLifetime = data.MaxRealLifetime or DEFAULT_MAX_REAL_LIFETIME,
		lastUpdate = now,

		lastRenderStep = now,
		inView = inView,
		offscreenSince = if inView then nil else now,
		culled = false,
		effectCullDelay = VisualModel.GetLongestEffectLifetime(model),
		smoothTransform = false,
		transformElapsed = 0,
		transformDuration = 0,
	}
	if data.ActivateParticlesOnCreate then
		VisualModel.ActivateParticles(model)
	end
	visuals[data.Id] = visual
	visualCount += 1
	table.insert(visualOrder, data.Id)
end

--------------------------------------------------------------------------------
-- Message handlers
--------------------------------------------------------------------------------

-- Fires only when the combined personal/local TimeScale actually changes --
-- not a per-frame stream. The client just needs the number; from here it
-- predicts locally exactly like it already does for chunk/world dilation.
local function onTimeScale(data: Protocol.TimeScalePayload)
	local visual = visuals[data.Id]
	if not visual then
		return
	end
	if not visual.synced then
		-- Settle time already elapsed at the OLD scale first; otherwise the
		-- new scale would be applied retroactively to the whole backlog
		-- since this visual's last round-robin visit.
		local elapsed = globalSimulationClock - visual.lastSimulationTime
		if elapsed > 0 then
			Prediction.simulate(visual, elapsed * visual.timeScale)
		end
		visual.lastSimulationTime = globalSimulationClock
	end
	visual.timeScale = data.TimeScale
end

-- Homing lock acquired/dropped -- rare, only on an actual transition, never
-- per-frame. Synced switches the visual into "trust the streamed ProjMove"
-- mode; unsynced switches it back to local physics. Either way the message
-- carries the server's pose at the transition, which is the only correct
-- starting point for local physics after a lock drops.
local function onSync(data: Protocol.SyncPayload)
	local visual = visuals[data.Id]
	if not visual then
		return
	end
	visual.synced = data.Synced
	rebaseline(visual, data.Position, data.Velocity)
	if visual.synced then
		-- Reset the staleness clock right at the transition, so a lastUpdate
		-- left over from before it can't immediately read as stale before the
		-- first real ProjMove arrives.
		visual.lastUpdate = os.clock()
	end
end

-- Batched authoritative pose updates. Two kinds of entries:
--  - Bounced = true: a one-shot bounce correction, applied whether or not
--    the visual is synced (for a non-homing bouncer it is the ONLY update
--    between spawn and impact). Snaps instead of tweening -- a straight
--    tween from the old position would cut through the surface it bounced
--    off -- plays the ricochet flash, and re-baselines local physics.
--  - Otherwise: a continuous homing pose, only sent while the visual is
--    synced (see Replication.isSynced on the server for why).
local function onMove(batch: { Protocol.MovePayload })
	local now = os.clock()
	for _, data in batch do
		local visual = visuals[data.Id]
		if not visual then
			continue
		end
		if data.Bounced then
			visual.lastUpdate = now
			rebaseline(visual, data.Position, data.Velocity)
			VisualModel.Place(visual, data.Position, data.Velocity)
			Impact.Play(data.Point or data.Position, data.Normal, "bounce")
		elseif visual.synced then
			local duration = math.clamp(now - visual.lastUpdate, 0.03, 0.2)
			visual.lastUpdate = now
			visual.position = data.Position
			visual.velocity = data.Velocity
			VisualModel.SetTarget(visual, data.Position, data.Velocity, duration)
		end
	end
end

local function onHit(data: Protocol.HitPayload)
	local visual = visuals[data.Id]
	if visual then
		-- Snap to the server's exact position before destroying, so any
		-- imperceptible mid-flight drift from local simulation never shows at
		-- the one moment it would be visible.
		VisualModel.Place(visual, data.Position, visual.velocity)
		if data.Kind then
			Impact.Play(data.Position, data.Normal, data.Kind)
		end
	end
	destroyVisual(data.Id)
end

--------------------------------------------------------------------------------
-- Render scheduler
--------------------------------------------------------------------------------

-- Visual came back on screen: place it without drawing a trail across the
-- jump, restore it if it had been fully culled, and resume effects on a
-- later update.
local function reenterView(visual: Visual, now: number)
	VisualModel.SuspendTrails(visual)
	VisualModel.Place(visual, visual.position, visual.velocity)
	if visual.culled then
		VisualModel.SetCulled(visual, false)
		visual.culled = false
	end
	visual.resumeEffectsOnNextUpdate = now
	visual.offscreenSince = nil
end

-- Visual is off screen: once it has been gone longer than its effects take
-- to fade, stop them and unparent it.
local function updateOffscreen(visual: Visual, now: number)
	local since: number = if visual.inView then now else visual.offscreenSince or now
	visual.offscreenSince = since
	if not visual.culled and now - since >= visual.effectCullDelay then
		VisualModel.SuspendEffects(visual)
		VisualModel.SetCulled(visual, true)
		visual.culled = true
	end
end

local function resumeEffectsIfDue(visual: Visual)
	if visual.resumeEffectsOnNextUpdate then
		VisualModel.ResumeEffects(visual)
		visual.resumeEffectsOnNextUpdate = nil
	end
end

-- A SYNCED visual (actively homing) is posed entirely by ProjMove; this only
-- advances its tween and handles visibility. Returns whether it used
-- transform budget, or nil if it was destroyed.
local function updateSynced(visual: Visual, now: number): boolean?
	local inView = View.contains(visual.position)
	if inView then
		if not visual.inView then
			reenterView(visual, now)
		elseif not visual.smoothTransform then
			resumeEffectsIfDue(visual)
			VisualModel.Step(visual, math.max(now - visual.lastRenderStep, 0))
		end
		visual.lastRenderStep = now
	else
		updateOffscreen(visual, now)
	end
	visual.inView = inView
	-- Left-VisualRange safety net. Deliberately wall-clock, NOT a dilated
	-- countdown: a synced visual can belong to a shooter at ANY personal time
	-- ratio, including exactly 0, so there's no dilated schedule the client
	-- could reconstruct. The server streams every synced projectile's pose
	-- regardless of dt, so lastUpdate keeps refreshing while this client is
	-- in range; once it stops, a real-time timeout cleans the visual up.
	if now - visual.lastUpdate > SYNCED_VISUAL_STALE_TIMEOUT then
		destroyVisual(visual.id)
		return nil
	end
	return inView
end

-- An UNSYNCED visual (the common case -- including a bouncer between
-- bounces) is dead-reckoned by Prediction over all global time accumulated
-- since its previous visit. Returns whether it used transform budget, or nil
-- if it was destroyed.
local function updatePredicted(visual: Visual, elapsedGlobalDt: number, now: number): boolean?
	local alive, moved = Prediction.simulate(visual, elapsedGlobalDt * visual.timeScale)
	local inView = View.contains(visual.position)
	if inView then
		if not visual.inView then
			reenterView(visual, now)
		else
			if moved and visual.smoothTransform then
				setSmoothTarget(visual, now)
			elseif moved then
				VisualModel.Place(visual, visual.position, visual.velocity)
			end
			resumeEffectsIfDue(visual)
		end
		visual.lastRenderStep = now
	else
		updateOffscreen(visual, now)
	end
	visual.inView = inView
	if not alive then
		-- Safety net: normally ProjHit arrives first and removes this entry.
		-- This only fires if it never does (e.g. the projectile left this
		-- client's VisualRange).
		destroyVisual(visual.id)
		return nil
	end
	return inView
end

local function compactVisualOrder()
	local oldOrder = visualOrder
	local oldCount = #oldOrder
	local compacted: { number } = table.create(math.max(oldCount - visualTombstones, 0))
	-- Begin at the next due slot so compaction preserves round-robin fairness.
	for offset = 0, oldCount - 1 do
		local id = oldOrder[(visualCursor + offset - 1) % oldCount + 1]
		if visuals[id] then
			table.insert(compacted, id)
		end
	end
	visualOrder = compacted
	visualCursor = 1
	visualTombstones = 0
end

-- Visits visuals round-robin until MAX_VISUAL_UPDATES_PER_FRAME on-screen
-- transforms have been spent (or every visual was visited once).
local function renderStep(globalDt: number)
	globalSimulationClock += globalDt
	local now = os.clock()
	View.refresh()
	refreshSmoothVisuals(now)

	local slotCount = #visualOrder
	local inspected = 0
	local transformed = 0
	while inspected < slotCount and transformed < MAX_VISUAL_UPDATES_PER_FRAME do
		if visualCursor > slotCount then
			visualCursor = 1
		end
		local id = visualOrder[visualCursor]
		visualCursor += 1
		inspected += 1
		local visual = visuals[id]
		if not visual then
			continue
		end
		local elapsedGlobalDt = math.max(globalSimulationClock - visual.lastSimulationTime, 0)
		visual.lastSimulationTime = globalSimulationClock

		-- Real (undilated) backstop mirroring the server's MaxRealLifetime.
		-- Normally ProjHit removes the visual first; this only matters if that
		-- message is missed (e.g. the visual drifted outside VisualRange).
		if now - visual.spawnRealTime >= visual.maxRealLifetime then
			destroyVisual(id)
			continue
		end

		local usedBudget = if visual.synced
			then updateSynced(visual, now)
			else updatePredicted(visual, elapsedGlobalDt, now)
		if usedBudget then
			transformed += 1
		end
	end

	-- Nearby visuals receive presentation-only interpolation every real frame.
	-- Their logical simulation and network snapshots remain in the bounded
	-- scheduler above, so this adds at most MAX_SMOOTH_PROJECTILES transforms.
	for _, visual in smoothVisuals do
		if visual.inView and visuals[visual.id] == visual then
			local resumeAt = visual.resumeEffectsOnNextUpdate
			if resumeAt and resumeAt < now then
				resumeEffectsIfDue(visual)
			end
			VisualModel.Step(visual, math.max(now - (visual.lastSmoothStep or now), 0))
			visual.lastSmoothStep = now
		end
	end

	-- Avoid an ever-growing sparse order array without changing which live
	-- visual is next. This is metadata work only; it performs no transforms.
	if visualTombstones >= 256 and visualTombstones * 4 >= #visualOrder then
		compactVisualOrder()
	end
end

function ProjectileClient.EnableClientRendering()
	if clientRendering or RunService:IsServer() then
		return
	end
	clientRendering = true

	VisualOffload.On(Channels.SpawnBatch, function(batch: { Protocol.SpawnPayload })
		debug.profilebegin("ProjectileClient.BuildSpawnBatch")
		for _, data in batch do
			onSpawn(data)
		end
		debug.profileend()
	end)
	VisualOffload.On(Channels.TimeScale, onTimeScale)
	VisualOffload.On(Channels.Sync, onSync)
	VisualOffload.On(Channels.Move, onMove)
	VisualOffload.On(Channels.HitBatch, function(batch: { Protocol.HitPayload })
		for _, data in batch do
			onHit(data)
		end
	end)
	VisualOffload.On(Channels.Ray, function(data: Protocol.RayPayload)
		DebugRays.Draw(data.From, data.To, data.LowRes)
	end)

	View.refresh()
	Heartbeat.Connect(renderStep, { Name = "ProjectileSystem.ClientSimulate", Priority = 5 })
end

function ProjectileClient.GetStats()
	return {
		Visuals = visualCount,
		VisualUpdatesPerFrame = MAX_VISUAL_UPDATES_PER_FRAME,
		SmoothLimit = MAX_SMOOTH_PROJECTILES,
	}
end

return ProjectileClient
