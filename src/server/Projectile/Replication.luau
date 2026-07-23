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

function Replication.spawnVisual(projectile)
	if Replication.DebugSync then
		print(`[Relativity][sync] ProjSpawn Id={projectile.Id} Synced={Replication.isSynced(projectile)}`)
	end
	Replication.streamTo(projectile, "ProjSpawn", {
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
		-- server's step loop will include it in the very next ProjMove batch.
		Synced = Replication.isSynced(projectile),
		-- Initial combined Source.TimeScale * projectile.TimeScale, so the
		-- client's local dead-reckoning is correct from frame one even if
		-- this shot was fired while the shooter's ratio was already off 1x --
		-- see ProjTimeScale / the module doc comment's "Local time" section.
		TimeScale = projectile._lastStreamedTimeScale,
		-- Real (undilated) safety cap -- see MaxRealLifetime / the module doc
		-- comment. Lets the client independently self-destroy the visual as a
		-- backstop even if it never receives this projectile's ProjHit (e.g.
		-- it drifted outside VisualRange), rather than being able to leak a
		-- frozen visual forever -- see ProjectileClient's render loop.
		MaxRealLifetime = projectile.MaxRealLifetime,
		Model = projectile.Model,
		Visual = projectile.Visual,
		DestroyDelay = projectile.DestroyDelay,
		-- Client-side effect-cleanup/activation options -- see
		-- VisualModel.FadeOut / VisualModel.ActivateParticles and the module
		-- doc comment's config section.
		WaitForParticles = projectile.WaitForParticles,
		WaitForTrails = projectile.WaitForTrails,
		ActivateParticlesOnCreate = projectile.ActivateParticlesOnCreate,
	})
end

-- Flushes one frame's worth of ProjMove updates for projectiles the client
-- can't currently predict on its own (checked fresh every tick -- see
-- init.luau's server step loop, not a static per-projectile classification)
-- as a single batched event per recipient instead of one event per
-- projectile. Everything else never appears here at all -- see the module
-- doc comment.
function Replication.flushMoveBatch(moveBatch)
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
