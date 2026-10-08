--!strict
--!optimize 2
--[[
	Projectile/Replication.luau
	Everything that pushes projectile state from the server to rendering
	clients (see ProjectileClient (ReplicatedStorage.Shared.Projectile.Client) for the
	receiving side, and Shared.Projectile.Protocol for the wire format). The
	server stays authoritative; this module only ever sends -- see the
	top-level Projectile doc comment (init.luau) for the protocol's design.

	Per frame, init.luau's step loop calls, in order:
	 flushHitBatch                   (start of frame, bounded)
	 Step -> updateTimeScale / updateSyncState / queueBounce / queueHit
	 queuePose -> refine/collide beam links
	 flushSpawnBatch                 (completed snapshots, bounded)
	 flushMoveBatch                   (end of frame, bounded round-robin)
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local VisualOffload = require(Shared:WaitForChild("VisualOffload"))
local Protocol = require(Shared:WaitForChild("Projectile"):WaitForChild("Protocol"))
local Codec = require(Shared:WaitForChild("Projectile"):WaitForChild("Codec"))
local Heartbeat = require(Shared:WaitForChild("Heartbeat"))

local Types = require(script.Parent.Types)

type State = Types.State

local Channels = Protocol.Channels

local Replication = {}

-- Bounded per-frame work so one client event never grows without bound.
local MAX_SPAWNS_PER_FRAME = 1000
local MAX_HITS_PER_FRAME = 1000
-- Homing poses are round-robined past this; the cursor advances in real frame
-- order and is never reset by dilation, so changing GlobalTimeScale cannot
-- merge staggered cohorts into one spike.
local MAX_POSES_PER_FRAME = 2500
-- Beam geometry is reconstructed locally. Ballistic safety snapshots are
-- sparse; homing and topology/clipping/time changes are never rate-throttled.
local BEAM_REFRESH = 0.5
local beamSnapshots: { [number]: any } = {}

local function rememberBeam(projectile: State, now: number)
	if not projectile.Beam then return end
	beamSnapshots[projectile.Id] = {
		Time = now, PreviousId = projectile.Beam.PreviousId or 0,
		Clipped = projectile._beamSpanClipped == true,
		Path = table.clone(projectile._beamSpan or {}),
		Scale = Heartbeat.GetGlobalTimeScale(), PersonalScale = projectile._lastStreamedTimeScale,
	}
end

local function beamDue(projectile: State, now: number): boolean
	if projectile.HomingTarget then return true end
	local previous = beamSnapshots[projectile.Id]
	if not previous then return true end
	if previous.PreviousId ~= (projectile.Beam.PreviousId or 0)
		or previous.Clipped ~= (projectile._beamSpanClipped == true)
		or previous.Scale ~= Heartbeat.GetGlobalTimeScale()
		or previous.PersonalScale ~= projectile._lastStreamedTimeScale then return true end
	local path = projectile._beamSpan or {}
	if #path ~= #previous.Path then return true end
	-- Bend vertices and clipped endpoints are world anchors, not predictions.
	for index = 2, #path - (if projectile._beamSpanClipped then 0 else 1) do
		if (path[index] - previous.Path[index]).Magnitude > 0.05 then return true end
	end
	return now - previous.Time >= BEAM_REFRESH
end

-- When on, prints every ProjSpawn/ProjSync/ProjTimeScale/ProjHit as it is
-- streamed (individually rare enough to log one line each), plus a
-- once-a-second rate summary for ProjMove. Toggled via Projectile.SetDebugSync.
Replication.DebugSync = false

-- One queued, range-limited message payload.
type Entry = {
	Range: number,
	Position: Vector3,
	Payload: any,
	Recipients: { [Player]: boolean }?,
	Chunk: buffer?, -- Payload encoded once (binary channels), shared by every recipient
}

type BounceSnap = {
	Projectile: State,
	Point: Vector3,
	Normal: Vector3,
	Corrected: boolean?,
}

local spawnQueue: { State } = {}
local spawnQueueHead = 1
local hitQueue: { Entry } = {}
local hitQueueHead = 1
local pendingBounces: { BounceSnap } = {} -- flushed with this frame's ProjMove
local pendingBounceHead = 1
local poseCandidates: { State } = {} -- homing and beam correction candidates
local poseCursor = 1
local moveStats = { batches = 0, entries = 0 }
local beamStats = { Candidates = 0, Updates = 0 }

-- Only finite-range visuals need interest bookkeeping. Unlimited-range
-- stress tests retain the broadcast fast path. The persistent cursor limits
-- re-entry checks independently of simulation/dilation and spawn cohorts.
local interests: { [number]: { Projectile: State, Observers: { [Player]: boolean } } } = {}
local interestOrder: { number } = {}
local interestCursor = 1
local interestCount = 0
local frameRoots: { [Player]: BasePart }? = nil

local function playerRoots(): { [Player]: BasePart }
	local roots: { [Player]: BasePart } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character.PrimaryPart
		if root then
			roots[player] = root
		end
	end
	return roots
end

-- Sends each entry to every player within its Range (everyone when the range
-- is unlimited), as ONE event per recipient no matter how many entries.
-- With `encode` (ProjMove / ProjHitBatch -- see Projectile.Codec) each entry is
-- encoded once and every recipient's message is one packed buffer of them.
local function fanOut(channel: string, entries: { Entry }, encode: ((any) -> buffer)?)
	if #entries == 0 then
		return
	end
	local function item(entry: Entry): any
		if not encode then
			return entry.Payload
		end
		local chunk = entry.Chunk
		if not chunk then
			chunk = encode(entry.Payload)
			entry.Chunk = chunk
		end
		return chunk
	end
	local function message(list: { any }): any
		return if encode then Codec.Join(list) else list
	end
	local broadcast: { any } = {}
	local perPlayer: { [Player]: { any } } = {}
	local roots: { [Player]: BasePart }? = nil
	for _, entry in entries do
		if entry.Recipients then
			for player in entry.Recipients do
				if not player.Parent then continue end
				local list = perPlayer[player] or {}
				perPlayer[player] = list
				table.insert(list, item(entry))
			end
		elseif entry.Range >= math.huge then
			table.insert(broadcast, item(entry))
		else
			roots = roots or playerRoots()
			for player, root in roots :: { [Player]: BasePart } do
				if (root.Position - entry.Position).Magnitude <= entry.Range then
					local list = perPlayer[player]
					if not list then
						list = {}
						perPlayer[player] = list
					end
					table.insert(list, item(entry))
				end
			end
		end
	end
	if #broadcast > 0 then
		VisualOffload.Fire(channel, message(broadcast))
	end
	for player, list in perPlayer do
		VisualOffload.FireClient(player, channel, message(list))
	end
end

-- Sends one immediate (unbatched) message about `projectile`.
local function streamTo(projectile: State, channel: string, payload: any)
	if not projectile.Visualize then
		return
	end
	-- State changes that happen while a visual is still waiting in the bounded
	-- spawn queue are folded into its eventual spawn snapshot. Sending them
	-- first would create out-of-order client state for visuals not built yet.
	if not projectile._spawnStreamed then
		return
	end
	if projectile.VisualRange >= math.huge then
		VisualOffload.Fire(channel, payload)
		return
	end
	local interest = interests[projectile.Id]
	for player in interest and interest.Observers or {} do
		if player.Parent then
			VisualOffload.FireClient(player, channel, payload)
		end
	end
end

-- Ordinary homing retains its pose stream. Beam endpoints are predicted at
-- one common client epoch, with sparse ballistic snapshots and immediate
-- authoritative steering/topology/clipping/bounce corrections.
function Replication.isSynced(projectile: State): boolean
	return projectile.HomingTarget ~= nil and projectile.Beam == nil
end

-- Fields equal to ProjectileClient's defaults are omitted: remote events
-- serialize every key name per entry, so at batch sizes the defaults were most
-- of the spawn bandwidth.
local function spawnPayload(projectile: State): Protocol.SpawnPayload
	local payload: Protocol.SpawnPayload = {
		Id = projectile.Id,
		Position = projectile.Position,
		Velocity = projectile.Velocity,
		Lifetime = math.max(projectile.Lifetime - projectile.Age, 0),
		MaxRealLifetime = math.max(projectile.MaxRealLifetime - (os.clock() - projectile._spawnRealTime), 0),
		AccelerationDirection = projectile.AccelerationDirection,
		Model = projectile.Model,
		Visual = projectile.Visual,
	}
	if projectile.Gravity ~= 0 then payload.Gravity = projectile.Gravity end
	if projectile.Acceleration ~= 0 then payload.Acceleration = projectile.Acceleration end
	if projectile.MinSpeed ~= 0 then payload.MinSpeed = projectile.MinSpeed end
	if projectile.MaxSpeed ~= math.huge then payload.MaxSpeed = projectile.MaxSpeed end
	if Replication.isSynced(projectile) then payload.Synced = true end
	if projectile._lastStreamedTimeScale ~= 1 then payload.TimeScale = projectile._lastStreamedTimeScale end
	if projectile.VisualScale ~= 1 then payload.VisualScale = projectile.VisualScale end
	if projectile.Beam then
		payload.ServerTime = workspace:GetServerTimeNow()
		payload.GlobalScale = Heartbeat.GetGlobalTimeScale()
		payload.Beam = { Length = projectile.Beam.Length, Radius = projectile.Radius,
			Origin = if projectile.Beam.ChannelId then projectile.Position else projectile._beamOrigin or projectile.Position,
			ChannelId = projectile.Beam.ChannelId, PreviousId = projectile.Beam.PreviousId,
			Path = projectile._beamSpan, Clipped = projectile._beamSpanClipped }
	end
	if projectile.DestroyDelay ~= 0 then payload.DestroyDelay = projectile.DestroyDelay end
	if not projectile.WaitForParticles then payload.WaitForParticles = false end
	if not projectile.WaitForTrails then payload.WaitForTrails = false end
	if projectile.ActivateParticlesOnCreate then payload.ActivateParticlesOnCreate = true end
	return payload
end

--------------------------------------------------------------------------------
-- Lifecycle messages
--------------------------------------------------------------------------------

-- Queues the visual's creation; it spawns from its latest pose when flushed.
function Replication.spawnVisual(projectile: State)
	if not projectile.Visualize then
		return
	end
	if Replication.DebugSync then
		print(`[Relativity][sync] queued ProjSpawn Id={projectile.Id} Synced={Replication.isSynced(projectile)}`)
	end
	table.insert(spawnQueue, projectile)
end

-- Destruction is queued for the same reason creation is: a mass expiry must
-- become a few bounded batch messages, not thousands of individual remote
-- invocations in one frame. A projectile that dies before its queued spawn
-- was streamed needs no hit message because no client visual exists yet.
function Replication.queueHit(projectile: State, info: Types.DestroyInfo)
	beamSnapshots[projectile.Id] = nil
	if Replication.DebugSync then
		print(`[Relativity][sync] ProjHit Id={projectile.Id} Kind={info.Kind or "fizzle"}`)
	end
	if not projectile.Visualize or not projectile._spawnStreamed then
		return
	end
	local payload: Protocol.HitPayload = {
		Id = projectile.Id,
		Position = info.Position,
		Normal = info.Normal,
		Kind = info.Kind,
		BeamBody = projectile._beamBodyHit,
		BeamPath = projectile._beamSpan,
		BeamClipped = projectile._beamSpanClipped,
	}
	local interest = interests[projectile.Id]
	table.insert(hitQueue, { Range = projectile.VisualRange, Position = info.Position, Payload = payload,
		Recipients = interest and table.clone(interest.Observers) })
	interests[projectile.Id] = nil
	if interest then interestCount -= 1 end
end

-- Compacts a head-indexed queue once its consumed prefix dominates it.
local function compact<T>(queue: { T }, head: number): ({ T }, number)
	if head > #queue then
		table.clear(queue)
		return queue, 1
	elseif head > 4096 and head > #queue / 2 then
		return table.move(queue, head, #queue, 1, {}), 1
	end
	return queue, head
end

function Replication.flushHitBatch()
	local batch: { Entry } = {}
	local last = math.min(#hitQueue, hitQueueHead + MAX_HITS_PER_FRAME - 1)
	for index = hitQueueHead, last do
		table.insert(batch, hitQueue[index])
	end
	hitQueue, hitQueueHead = compact(hitQueue, last + 1)
	fanOut(Channels.HitBatch, batch, Codec.EncodeHit)
end

-- Sends at most MAX_SPAWNS_PER_FRAME new visuals per frame, combined into one
-- RemoteEvent per recipient. Simulation starts immediately on the server;
-- queued visuals spawn from their latest authoritative pose, so batching never
-- rewinds or slows gameplay.
function Replication.flushSpawnBatch()
	frameRoots = playerRoots()
	local batch: { Entry } = {}
	local exits: { [Player]: { number } } = {}
	local remaining = MAX_SPAWNS_PER_FRAME
	local last = math.min(#spawnQueue, spawnQueueHead + remaining - 1)
	for index = spawnQueueHead, last do
		local projectile = spawnQueue[index]
		if projectile.Dead then continue end
		projectile._spawnStreamed = true
		local payload = spawnPayload(projectile)
		projectile._streamedSynced = payload.Synced == true
		rememberBeam(projectile, workspace:GetServerTimeNow())
		local recipients
		if projectile.VisualRange < math.huge then
			recipients = {}
			for player, root in frameRoots :: { [Player]: BasePart } do
				if (root.Position-projectile.Position).Magnitude <= projectile.VisualRange then recipients[player] = true end
			end
			interests[projectile.Id] = { Projectile = projectile, Observers = recipients }
			interestCount += 1
			table.insert(interestOrder, projectile.Id)
		end
		table.insert(batch, { Range = projectile.VisualRange, Position = projectile.Position, Payload = payload, Recipients = recipients })
		remaining -= 1
	end
	spawnQueue, spawnQueueHead = compact(spawnQueue, last + 1)
	-- At most 2500 checks and 1000 creation/re-entry snapshots in a frame.
	-- Hysteresis prevents churn when the player sits on the range boundary.
	for _ = 1, math.min(#interestOrder, MAX_POSES_PER_FRAME) do
		if interestCursor > #interestOrder then interestCursor = 1 end
		local id = interestOrder[interestCursor]
		interestCursor += 1
		local interest = interests[id]
		if not interest then continue end
		local projectile, observers = interest.Projectile, interest.Observers
		local entering: { [Player]: boolean } = {}
		for player in observers do
			local root = (frameRoots :: { [Player]: BasePart })[player]
			if not root or (root.Position-projectile.Position).Magnitude > projectile.VisualRange*1.1+8 then
				observers[player] = nil
				if player.Parent then
					local list = exits[player] or {}; exits[player] = list
					table.insert(list, id)
				end
			end
		end
		for player, root in frameRoots :: { [Player]: BasePart } do
			if not observers[player] and remaining > 0 and (root.Position-projectile.Position).Magnitude <= projectile.VisualRange then
				entering[player], observers[player] = true, true
			end
		end
		if next(entering) then
			table.insert(batch, { Range = projectile.VisualRange, Position = projectile.Position,
				Payload = spawnPayload(projectile), Recipients = entering })
			remaining -= 1
		end
	end
	for player, ids in exits do VisualOffload.FireClient(player, Channels.RangeExit, ids) end
	fanOut(Channels.SpawnBatch, batch)
	if #interestOrder > 4096 and #interestOrder > 2*interestCount then
		local ordered = {}
		for offset = 0, #interestOrder-1 do
			local id = interestOrder[(interestCursor+offset-1)%#interestOrder+1]
			if interests[id] then table.insert(ordered,id) end
		end
		interestOrder, interestCursor = ordered, 1
	end
end
function Replication.getQueueStats()
	return {
		VisualSpawnsPerFrame = MAX_SPAWNS_PER_FRAME,
		VisualHitsPerFrame = MAX_HITS_PER_FRAME,
		PendingVisualSpawns = math.max(#spawnQueue - spawnQueueHead + 1, 0),
		PendingVisualHits = math.max(#hitQueue - hitQueueHead + 1, 0),
		BeamPoseCandidates = beamStats.Candidates,
		BeamPoseUpdates = beamStats.Updates,
		BeamRefreshInterval = BEAM_REFRESH,
		BeamHomingRefreshInterval = 0,
	}
end

--------------------------------------------------------------------------------
-- State changes (sent immediately, only when something actually changed)
--------------------------------------------------------------------------------

-- Tells clients the combined Source.TimeScale * projectile.TimeScale only
-- when it CHANGES -- see the "Local time" section in init.luau. In the common
-- case (nobody touches it after firing) this never fires after spawn.
function Replication.updateTimeScale(projectile: State, combinedScale: number)
	if combinedScale == projectile._lastStreamedTimeScale then
		return
	end
	projectile._lastStreamedTimeScale = combinedScale
	if Replication.DebugSync then
		print(`[Relativity][sync] ProjTimeScale Id={projectile.Id} TimeScale={combinedScale}`)
	end
	local payload: Protocol.TimeScalePayload = { Id = projectile.Id, TimeScale = combinedScale }
	streamTo(projectile, Channels.TimeScale, payload)
end

-- Tells clients only when the homing-sync state actually changed. True
-- switches the client into "trust the continuous ProjMove stream" mode; false
-- switches it back to local physics. The authoritative pose rides on this
-- message: it is sent immediately (mid-step) over the same ordered remote as
-- ProjMove, so a separate end-of-frame pose would arrive after the client had
-- already left synced mode and be discarded -- and the round-robin cap could
-- skip it entirely.
function Replication.updateSyncState(projectile: State)
	local synced = Replication.isSynced(projectile)
	if synced == projectile._streamedSynced then
		return
	end
	projectile._streamedSynced = synced
	if Replication.DebugSync then
		print(`[Relativity][sync] ProjSync Id={projectile.Id} Synced={synced}`)
	end
	local payload: Protocol.SyncPayload = {
		Id = projectile.Id,
		Synced = synced,
		Position = projectile.Position,
		Velocity = projectile.Velocity,
	}
	streamTo(projectile, Channels.Sync, payload)
end

-- Debug visualization of one movement cast (see Projectile.SetDebugRays).
function Replication.streamRay(projectile: State, from: Vector3, to: Vector3, lowRes: boolean)
	local payload: Protocol.RayPayload = { From = from, To = to, LowRes = lowRes }
	streamTo(projectile, Channels.Ray, payload)
end

--------------------------------------------------------------------------------
-- Pose stream (ProjMove)
--------------------------------------------------------------------------------

-- One-shot bounce snap (see Raycast.resolveHit). Queued rather than fired so
-- a volley bouncing off one floor costs one event per recipient, not one per
-- projectile. Ordering still holds: this frame's flushMoveBatch sends it, and
-- any ProjHit for the same projectile is flushed at the start of a LATER frame.
-- Only the contact point/normal are captured now; the snapped pose is read at
-- flush time, i.e. the end-of-frame pose, the same time base as ProjSpawn and
-- the homing stream. A mid-frame pose would leave the client behind by the
-- rest of the frame the server kept simulating after the bounce.
function Replication.queueBounce(projectile: State, point: Vector3, normal: Vector3)
	if not projectile.Visualize or not projectile._spawnStreamed then
		return
	end
	table.insert(pendingBounces, { Projectile = projectile, Point = point, Normal = normal })
end

function Replication.queueCorrection(projectile: State, point: Vector3, normal: Vector3)
	if not projectile.Visualize or not projectile._spawnStreamed then return end
	table.insert(pendingBounces, { Projectile = projectile, Point = point, Normal = normal, Corrected = true })
end

-- Collects homing/beam candidates. Beam cadence and topology are checked AFTER
-- link refinement; payloads are built only for the bounded slice actually sent.
function Replication.queuePose(projectile: State)
	if projectile.Visualize and projectile._spawnStreamed and (projectile._streamedSynced or projectile.Beam ~= nil) then
		table.insert(poseCandidates, projectile)
	end
end

local function poseEntry(projectile: State): Entry
	local payload: Protocol.MovePayload = {
		Id = projectile.Id,
		Position = projectile.Position,
		Velocity = projectile.Velocity,
		BeamPath = projectile._beamSpan,
		BeamClipped = projectile._beamSpanClipped,
		BeamPreviousId = if projectile.Beam then projectile.Beam.PreviousId or 0 else nil,
		ServerTime = if projectile.Beam then workspace:GetServerTimeNow() else nil,
		GlobalScale = if projectile.Beam then Heartbeat.GetGlobalTimeScale() else nil,
		TimeScale = if projectile.Beam then projectile._lastStreamedTimeScale else nil,
		Lifetime = if projectile.Beam then math.max(projectile.Lifetime-projectile.Age, 0) else nil,
	}
	local interest = interests[projectile.Id]
	return { Range = projectile.VisualRange, Position = projectile.Position, Payload = payload,
		Recipients = if projectile.VisualRange < math.huge then interest and interest.Observers or {} else nil }
end

-- Sends this frame's bounce snaps plus a bounded round-robin slice of the
-- queued homing poses, as one ProjMove event per recipient.
function Replication.flushMoveBatch()
	local batch: { Entry } = {}
	local now = workspace:GetServerTimeNow()
	local sent: { [number]: boolean } = {}
	local lastBounce = math.min(#pendingBounces, pendingBounceHead+MAX_POSES_PER_FRAME-1)
	for index = pendingBounceHead, lastBounce do
		local bounce = pendingBounces[index]
		local projectile = bounce.Projectile
		local payload: Protocol.MovePayload = {
			Id = projectile.Id,
			Position = projectile.Position,
			Velocity = projectile.Velocity,
			Bounced = if bounce.Corrected then nil else true,
			Corrected = bounce.Corrected,
			BeamPreviousId = if projectile.Beam then projectile.Beam.PreviousId or 0 else nil,
			ServerTime = if projectile.Beam then now else nil,
			GlobalScale = if projectile.Beam then Heartbeat.GetGlobalTimeScale() else nil,
			TimeScale = if projectile.Beam then projectile._lastStreamedTimeScale else nil,
			BeamPath = projectile._beamSpan,
			BeamClipped = projectile._beamSpanClipped,
			Lifetime = if projectile.Beam then math.max(projectile.Lifetime-projectile.Age, 0) else nil,
			Point = bounce.Point,
			Normal = bounce.Normal,
		}
		local interest = interests[projectile.Id]
		sent[projectile.Id] = true
		if projectile.Beam then beamStats.Updates += 1 end
		if not projectile.Dead then rememberBeam(projectile, now) end
		table.insert(batch, { Range = projectile.VisualRange, Position = projectile.Position, Payload = payload,
			Recipients = if projectile.VisualRange < math.huge then interest and interest.Observers or {} else nil })
	end
	pendingBounces, pendingBounceHead = compact(pendingBounces, lastBounce+1)

	local due = {}
	for _, projectile in poseCandidates do
		if projectile.Beam then beamStats.Candidates += 1 end
		if not projectile.Dead and not sent[projectile.Id]
			and (not projectile.Beam or beamDue(projectile, now)) then table.insert(due, projectile) end
	end
	table.clear(poseCandidates)
	local candidateCount = #due
	if candidateCount > 0 then
		local updateCount = math.min(candidateCount, math.max(MAX_POSES_PER_FRAME-#batch, 0))
		if poseCursor > candidateCount then
			poseCursor = (poseCursor - 1) % candidateCount + 1
		end
		for offset = 0, updateCount - 1 do
			local projectile = due[(poseCursor + offset - 1) % candidateCount + 1]
			table.insert(batch, poseEntry(projectile))
			if projectile.Beam then beamStats.Updates += 1 end
			rememberBeam(projectile, now)
		end
		poseCursor = (poseCursor + updateCount - 1) % candidateCount + 1
	else
		poseCursor = 1
	end

	if Replication.DebugSync and #batch > 0 then
		moveStats.batches += 1
		moveStats.entries += #batch
	end
	fanOut(Channels.Move, batch, Codec.EncodeMove)
end

-- Once-a-second ProjMove rate summary (see DebugSync) -- real time, not
-- dilated, so the reporting cadence stays steady even mid-freeze.
task.spawn(function()
	while true do
		task.wait(1)
		if Replication.DebugSync and moveStats.batches > 0 then
			print(`[Relativity][sync] ProjMove rate: {moveStats.batches} batches/s, {moveStats.entries} projectile-updates/s`)
		end
		moveStats.batches = 0
		moveStats.entries = 0
	end
end)

return Replication
