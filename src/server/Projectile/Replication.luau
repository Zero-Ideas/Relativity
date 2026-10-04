--!strict
--!optimize 2
--[[
	Projectile/Replication.luau
	Everything that pushes projectile state from the server to rendering
	clients (see ProjectileClient in ReplicatedStorage.Shared for the
	receiving side, and Shared.ProjectileProtocol for the wire format). The
	server stays authoritative; this module only ever sends -- see the
	top-level Projectile doc comment (init.luau) for the protocol's design.

	Per frame, init.luau's step loop calls, in order:
	 flushHitBatch / flushSpawnBatch  (start of frame, bounded)
	 Step -> updateTimeScale / updateSyncState / queueBounce / queueHit
	 queuePose for every projectile that is homing-synced
	 flushMoveBatch                   (end of frame, bounded round-robin)
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local VisualOffload = require(Shared:WaitForChild("VisualOffload"))
local Protocol = require(Shared:WaitForChild("ProjectileProtocol"))

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

-- When on, prints every ProjSpawn/ProjSync/ProjTimeScale/ProjHit as it is
-- streamed (individually rare enough to log one line each), plus a
-- once-a-second rate summary for ProjMove. Toggled via Projectile.SetDebugSync.
Replication.DebugSync = false

-- One queued, range-limited message payload.
type Entry = {
	Range: number,
	Position: Vector3,
	Payload: any,
}

type BounceSnap = {
	Projectile: State,
	Point: Vector3,
	Normal: Vector3,
}

local spawnQueue: { State } = {}
local spawnQueueHead = 1
local hitQueue: { Entry } = {}
local hitQueueHead = 1
local pendingBounces: { BounceSnap } = {} -- flushed with this frame's ProjMove
local poseCandidates: { State } = {} -- homing-synced this frame
local poseCursor = 1
local moveStats = { batches = 0, entries = 0 }

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
local function fanOut(channel: string, entries: { Entry })
	if #entries == 0 then
		return
	end
	local broadcast: { any } = {}
	local perPlayer: { [Player]: { any } } = {}
	local roots: { [Player]: BasePart }? = nil
	for _, entry in entries do
		if entry.Range >= math.huge then
			table.insert(broadcast, entry.Payload)
		else
			roots = roots or playerRoots()
			for player, root in roots :: { [Player]: BasePart } do
				if (root.Position - entry.Position).Magnitude <= entry.Range then
					local list = perPlayer[player]
					if not list then
						list = {}
						perPlayer[player] = list
					end
					table.insert(list, entry.Payload)
				end
			end
		end
	end
	if #broadcast > 0 then
		VisualOffload.Fire(channel, broadcast)
	end
	for player, list in perPlayer do
		VisualOffload.FireClient(player, channel, list)
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
	for player, root in playerRoots() do
		if (root.Position - projectile.Position).Magnitude <= projectile.VisualRange then
			VisualOffload.FireClient(player, channel, payload)
		end
	end
end

-- Whether the client can't safely predict this projectile's CONTINUOUS motion
-- on its own right now -- see the module doc comment in init.luau. Only an
-- active homing lock qualifies: a target's position is seen through each
-- observer's own replication lag, so local steering would diverge per client.
-- Bounces are corrected one-shot (queueBounce) and personal/local time scales
-- are replicated as a number (updateTimeScale), so neither forces a stream.
function Replication.isSynced(projectile: State): boolean
	return projectile.HomingTarget ~= nil
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
		payload.Beam = { Length = projectile.Beam.Length, Radius = projectile.Radius, Origin = projectile._beamOrigin or projectile.Position }
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
	}
	table.insert(hitQueue, { Range = projectile.VisualRange, Position = info.Position, Payload = payload })
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
	fanOut(Channels.HitBatch, batch)
end

-- Sends at most MAX_SPAWNS_PER_FRAME new visuals per frame, combined into one
-- RemoteEvent per recipient. Simulation starts immediately on the server;
-- queued visuals spawn from their latest authoritative pose, so batching never
-- rewinds or slows gameplay.
function Replication.flushSpawnBatch()
	local batch: { Entry } = {}
	local last = math.min(#spawnQueue, spawnQueueHead + MAX_SPAWNS_PER_FRAME - 1)
	for index = spawnQueueHead, last do
		local projectile = spawnQueue[index]
		if not projectile.Dead then
			projectile._spawnStreamed = true
			local payload = spawnPayload(projectile)
			-- The snapshot is the client's sync baseline; keep the transition
			-- check diffing against exactly what was sent.
			projectile._streamedSynced = payload.Synced == true
			table.insert(batch, { Range = projectile.VisualRange, Position = projectile.Position, Payload = payload })
		end
	end
	spawnQueue, spawnQueueHead = compact(spawnQueue, last + 1)
	fanOut(Channels.SpawnBatch, batch)
end

function Replication.getQueueStats()
	return {
		VisualSpawnsPerFrame = MAX_SPAWNS_PER_FRAME,
		VisualHitsPerFrame = MAX_HITS_PER_FRAME,
		PendingVisualSpawns = math.max(#spawnQueue - spawnQueueHead + 1, 0),
		PendingVisualHits = math.max(#hitQueue - hitQueueHead + 1, 0),
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

-- Marks a homing-synced projectile as due a pose this frame (see isSynced).
-- Payloads are only built for the round-robin slice actually sent.
function Replication.queuePose(projectile: State)
	if projectile.Visualize and projectile._spawnStreamed and projectile._streamedSynced then
		table.insert(poseCandidates, projectile)
	end
end

local function poseEntry(projectile: State): Entry
	local payload: Protocol.MovePayload = {
		Id = projectile.Id,
		Position = projectile.Position,
		Velocity = projectile.Velocity,
	}
	return { Range = projectile.VisualRange, Position = projectile.Position, Payload = payload }
end

-- Sends this frame's bounce snaps plus a bounded round-robin slice of the
-- queued homing poses, as one ProjMove event per recipient.
function Replication.flushMoveBatch()
	local batch: { Entry } = {}
	for _, bounce in pendingBounces do
		local projectile = bounce.Projectile
		local payload: Protocol.MovePayload = {
			Id = projectile.Id,
			Position = projectile.Position,
			Velocity = projectile.Velocity,
			Bounced = true,
			Point = bounce.Point,
			Normal = bounce.Normal,
		}
		table.insert(batch, { Range = projectile.VisualRange, Position = projectile.Position, Payload = payload })
	end
	table.clear(pendingBounces)

	local candidateCount = #poseCandidates
	if candidateCount > 0 then
		local updateCount = math.min(candidateCount, MAX_POSES_PER_FRAME)
		if poseCursor > candidateCount then
			poseCursor = (poseCursor - 1) % candidateCount + 1
		end
		for offset = 0, updateCount - 1 do
			table.insert(batch, poseEntry(poseCandidates[(poseCursor + offset - 1) % candidateCount + 1]))
		end
		poseCursor = (poseCursor + updateCount - 1) % candidateCount + 1
		table.clear(poseCandidates)
	else
		poseCursor = 1
	end

	if Replication.DebugSync and #batch > 0 then
		moveStats.batches += 1
		moveStats.entries += #batch
	end
	fanOut(Channels.Move, batch)
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
