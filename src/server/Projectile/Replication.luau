--!optimize 2
--[[
	Projectile/Replication.luau
	Everything that pushes projectile state from the server to rendering
	clients (see ProjectileClient in ReplicatedStorage.Shared for the
	receiving side). The server stays authoritative; this module only ever
	sends -- see the top-level Projectile doc comment (init.luau) for the full
	ProjSpawn/ProjMove/ProjHit/ProjSync/ProjTimeScale/ProjRay protocol.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)

local Replication = {}
local spawnQueue = {}
local spawnQueueHead = 1
local hitQueue = {}
local hitQueueHead = 1
local pendingBounces = {} -- flushed with this frame's ProjMove; see queueBounce

-- When on, prints every ProjSpawn/ProjSync/ProjHit as they're streamed
-- (individually rare enough to log one line each), plus a once-a-second rate
-- summary for ProjMove (logging every individual batch would be 60/sec and
-- unreadable -- the summary answers "how often is this actually being sent"
-- directly instead). Toggled via Projectile.SetDebugSync (init.luau).
Replication.DebugSync = false

-- Accumulated since the last once-a-second report -- read + reset by
-- init.luau's rate-summary loop.
Replication.SyncMoveStats = { batches = 0, entries = 0 }

function Replication.streamTo(projectile, channel: string, payload: any)
	if not projectile.Visualize then
		return
	end
	-- State changes that happen while a visual is still waiting in the bounded
	-- spawn queue are folded into its eventual spawn snapshot. Sending them
	-- first would create out-of-order client state for visuals not built yet.
	if channel ~= "ProjSpawn" and not projectile._spawnStreamed then
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
-- instant it happens (see Raycast._resolveHit), not by holding the projectile
-- synced for its whole remaining life. A projectile with bounces remaining
-- (or that has already bounced) but no active homing lock is therefore NOT
-- continuously synced -- it coasts on local physics between bounces like any
-- other unsynced shot, and only gets snapped at the moment each bounce
-- occurs. It also deliberately excludes Source.TimeScale/projectile.TimeScale
-- -- those no longer force a continuous stream (see ProjTimeScale / the
-- module doc comment's "Local time" section): the client just needs to KNOW
-- the current ratio, not be streamed a live position because of it.
function Replication.isSynced(projectile): boolean
	return projectile.HomingTarget ~= nil
end

-- world/chunk dilation is applied separately (ChunkManager.ScaleDt, replicated
-- to clients on its own); this is just the shooter's personal ratio times
-- this specific projectile's own local ratio -- see the module doc comment's
-- "Local time" section. Read live, never snapshotted.
function Replication.combinedTimeScale(projectile): number
	local source = projectile.Source
	local sourceScale = (source and source.TimeScale) or 1
	return sourceScale * projectile.TimeScale
end

-- Fields equal to ProjectileClient's defaults are omitted: remote events
-- serialize every key name per entry, so at batch sizes the defaults were most
-- of the spawn bandwidth.
local function spawnPayload(projectile)
	local payload = {
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
	if projectile.DestroyDelay ~= 0 then payload.DestroyDelay = projectile.DestroyDelay end
	if not projectile.WaitForParticles then payload.WaitForParticles = false end
	if not projectile.WaitForTrails then payload.WaitForTrails = false end
	if projectile.ActivateParticlesOnCreate then payload.ActivateParticlesOnCreate = true end
	return payload
end

function Replication.spawnVisual(projectile)
	if not projectile.Visualize then return end
	if Replication.DebugSync then
		print(`[Relativity][sync] queued ProjSpawn Id={projectile.Id} Synced={Replication.isSynced(projectile)}`)
	end
	table.insert(spawnQueue, projectile)
end

-- Destruction is queued for the same reason creation is: a mass expiry must
-- become a few bounded batch messages, not thousands of individual remote
-- invocations in one frame. A projectile that dies before its queued spawn
-- was streamed needs no hit message because no client visual exists yet.
function Replication.queueHit(projectile, payload)
	if not projectile.Visualize or not projectile._spawnStreamed then return end
	table.insert(hitQueue, {
		VisualRange = projectile.VisualRange,
		Position = payload.Position,
		Payload = payload,
	})
end

local function flushRangedBatch(queue, head: number, limit: number, channel: string): number
	local broadcast = {}
	local perPlayer: { [Player]: { any } } = {}
	local players = Players:GetPlayers()
	local roots = {}
	for _, player in players do
		local character = player.Character
		roots[player] = character and character.PrimaryPart
	end

	local processed = 0
	while head <= #queue and processed < limit do
		local entry = queue[head]
		queue[head] = false
		head += 1
		processed += 1
		if entry.VisualRange >= math.huge then
			table.insert(broadcast, entry.Payload)
		else
			for _, player in players do
				local root = roots[player]
				if root and (root.Position - entry.Position).Magnitude <= entry.VisualRange then
					local list = perPlayer[player]
					if not list then list = {}; perPlayer[player] = list end
					table.insert(list, entry.Payload)
				end
			end
		end
	end

	if #broadcast > 0 then VisualOffload.Fire(channel, broadcast) end
	for player, list in perPlayer do
		if #list > 0 then VisualOffload.FireClient(player, channel, list) end
	end
	return head
end

function Replication.flushHitBatch(limit: number)
	hitQueueHead = flushRangedBatch(hitQueue, hitQueueHead, limit, "ProjHitBatch")
	if hitQueueHead > #hitQueue then
		table.clear(hitQueue)
		hitQueueHead = 1
	elseif hitQueueHead > 4096 and hitQueueHead > #hitQueue / 2 then
		local compacted = {}
		for index = hitQueueHead, #hitQueue do table.insert(compacted, hitQueue[index]) end
		hitQueue = compacted
		hitQueueHead = 1
	end
end

function Replication.getQueueStats()
	return {
		PendingSpawns = math.max(#spawnQueue - spawnQueueHead + 1, 0),
		PendingHits = math.max(#hitQueue - hitQueueHead + 1, 0),
	}
end

-- Sends at most `limit` new visuals in one frame and combines them into one
-- RemoteEvent per recipient. Simulation starts immediately on the server;
-- queued visuals spawn from their latest authoritative pose, so batching never
-- rewinds or slows gameplay.
function Replication.flushSpawnBatch(limit: number)
	local broadcast = {}
	local perPlayer: { [Player]: { any } } = {}
	local players = Players:GetPlayers()
	local roots = {}
	for _, player in players do
		local character = player.Character
		roots[player] = character and character.PrimaryPart
	end
	local processed = 0
	while spawnQueueHead <= #spawnQueue and processed < limit do
		local projectile = spawnQueue[spawnQueueHead]
		spawnQueue[spawnQueueHead] = false
		spawnQueueHead += 1
		processed += 1
		if projectile.Dead then continue end
		projectile._spawnStreamed = true
		local payload = spawnPayload(projectile)
		if projectile.VisualRange >= math.huge then
			table.insert(broadcast, payload)
		else
			for _, player in players do
				local root = roots[player]
				if root and (root.Position - projectile.Position).Magnitude <= projectile.VisualRange then
					local list = perPlayer[player]
					if not list then list = {}; perPlayer[player] = list end
					table.insert(list, payload)
				end
			end
		end
	end
	if #broadcast > 0 then VisualOffload.Fire("ProjSpawnBatch", broadcast) end
	for player, list in perPlayer do
		if #list > 0 then VisualOffload.FireClient(player, "ProjSpawnBatch", list) end
	end
	if spawnQueueHead > #spawnQueue then
		table.clear(spawnQueue)
		spawnQueueHead = 1
	elseif spawnQueueHead > 4096 and spawnQueueHead > #spawnQueue / 2 then
		local compacted = {}
		for index = spawnQueueHead, #spawnQueue do table.insert(compacted, spawnQueue[index]) end
		spawnQueue = compacted
		spawnQueueHead = 1
	end
end

-- One-shot bounce snap (see Raycast._resolveHit). Queued rather than fired so
-- a volley bouncing off one floor costs one event per recipient, not one per
-- projectile. Ordering still holds: this frame's flushMoveBatch sends it, and
-- any ProjHit for the same projectile is flushed at the start of a LATER frame.
function Replication.queueBounce(projectile, normal: Vector3)
	if not projectile.Visualize or not projectile._spawnStreamed then
		return
	end
	table.insert(pendingBounces, {
		VisualRange = projectile.VisualRange,
		Position = projectile.Position,
		Payload = {
			Id = projectile.Id,
			Position = projectile.Position,
			Velocity = projectile.Velocity,
			Bounced = true,
			Normal = normal,
		},
	})
end

-- Flushes the bounded round-robin slice selected by init.luau's server step
-- loop, plus this frame's queued bounce snaps, as one event per recipient
-- instead of one event per projectile.
function Replication.flushMoveBatch(moveBatch)
	if #pendingBounces > 0 then
		table.move(pendingBounces, 1, #pendingBounces, #moveBatch + 1, moveBatch)
		table.clear(pendingBounces)
	end
	if #moveBatch == 0 then
		return
	end

	if Replication.DebugSync then
		Replication.SyncMoveStats.batches += 1
		Replication.SyncMoveStats.entries += #moveBatch
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

return Replication
