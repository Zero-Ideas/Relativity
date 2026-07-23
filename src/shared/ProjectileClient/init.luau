--!optimize 2
--[[
	ProjectileClient (client rendering, purely cosmetic)
	Receives the server-authoritative Projectile system's replication stream
	(ProjSpawn/ProjMove/ProjHit/ProjSync/ProjTimeScale/ProjRay, over
	VisualOffload -- see ServerScriptService.Server.Projectile/Replication.luau
	for the sending side and its module doc comment for the full sync
	protocol) and renders tracers/impacts. This module never makes a gameplay
	decision -- no hit detection, no damage, no entity access -- it only draws
	what the server tells it happened. All client-side simulation between
	updates is dead-reckoning for smoothness; the server's own independent Step
	is always authoritative, and any visual drift is corrected the instant
	ProjHit snaps the final position.

	API:
	 ProjectileClient.EnableClientRendering()          -- call once on the client
	 ProjectileClient.SetImpactHandler(fn(position, normal, model, kind))
	     -- replaces the built-in flash/ring effect; see Impact.luau
]]

local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Heartbeat = require(Shared.Heartbeat)
local ChunkManager = require(Shared.ChunkManager)
local VisualOffload = require(Shared.VisualOffload)

local VisualModel = require(script.VisualModel)
local Impact = require(script.Impact)
local DebugRays = require(script.DebugRays)

local ProjectileClient = {}

local function safeUnit(v: Vector3, fallback: Vector3): Vector3
	local magnitude = v.Magnitude
	if magnitude < 1e-5 then
		return fallback
	end
	return v / magnitude
end

function ProjectileClient.SetImpactHandler(fn)
	Impact.SetHandler(fn)
end

-- Matches ServerScriptService.Server.Projectile's own default -- used only as
-- a fallback if a ProjSpawn payload is ever missing MaxRealLifetime, which
-- shouldn't normally happen (the server always includes it).
local DEFAULT_MAX_REAL_LIFETIME = 60

-- Real (undilated) seconds of no ProjMove update before a SYNCED visual is
-- assumed to have left VisualRange and gets cleaned up -- see the render
-- loop below. Generous on purpose: ProjMove batches normally arrive every
-- server tick, so anything this stale really has stopped, not just lagged.
local SYNCED_VISUAL_STALE_TIMEOUT = 2

local clientRendering = false
local visuals = {} -- [id] = { model, position, velocity, gravity, homing/bounce state, ... }

-- Removes the flying tracer. Impact VFX is played from the ProjHit handler
-- itself (see EnableClientRendering), so this fires for real hits AND harmless
-- expiry without ever flashing in mid-air. The bullet DISAPPEARS instantly
-- (VisualModel.FadeOut hides every part and disables every
-- trail/particle/beam), but the actual :Destroy() waits out the longest
-- lifetime among the effects that were emitting -- already-spawned trail
-- segments and particles keep fading naturally during that grace window
-- instead of being cut off mid-air (or the spawn-configured DestroyDelay,
-- whichever is longer).
local function destroyVisual(id)
	local visual = visuals[id]
	if not visual then
		return
	end
	visuals[id] = nil
	if visual.tween then
		visual.tween:Cancel()
		visual.tween = nil
	end
	local delay =
		math.max(visual.destroyDelay or 0, VisualModel.FadeOut(visual.model, visual.waitForParticles, visual.waitForTrails))
	if delay > 0 then
		task.delay(delay, function()
			visual.model:Destroy()
		end)
	else
		visual.model:Destroy()
	end
end

function ProjectileClient.EnableClientRendering()
	if clientRendering or RunService:IsServer() then
		return
	end
	clientRendering = true

	VisualOffload.On("ProjSpawn", function(data)
		local model = VisualModel.Build(data)
		VisualModel.Place(model, data.Position, data.Velocity)
		if data.ActivateParticlesOnCreate then
			VisualModel.ActivateParticles(model)
		end
		visuals[data.Id] = {
			model = model,
			destroyDelay = data.DestroyDelay or 0,
			-- See VisualModel.FadeOut -- both default true.
			waitForParticles = data.WaitForParticles ~= false,
			waitForTrails = data.WaitForTrails ~= false,
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
	--    non-homing bouncer is normally fully unsynced -- see the module doc
	--    comment -- so this is the ONLY update it ever gets between spawn and
	--    impact). Always applied unconditionally: snap instead of tweening,
	--    since tweening a straight line from the old position would cut
	--    through whatever surface sits between them (exactly where the
	--    bounce occurred), play the ricochet flash, and re-baseline
	--    position/velocity so local physics (see the per-frame loop below)
	--    picks up from the correct post-reflection state.
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
				VisualModel.Place(visual.model, data.Position, data.Velocity)
				Impact.Play(data.Position, data.Normal, "bounce")
			elseif visual and visual.synced then
				local duration = math.clamp(now - visual.lastUpdate, 0.03, 0.2)
				visual.lastUpdate = now
				visual.position = data.Position
				visual.velocity = data.Velocity
				VisualModel.Tween(visual, data.Position, data.Velocity, duration)
			end
		end
	end)

	VisualOffload.On("ProjHit", function(data)
		local visual = visuals[data.Id]
		if visual then
			-- Snap to the server's exact position before destroying, so any
			-- imperceptible mid-flight drift from local simulation never shows
			-- at the one moment it would be visible.
			VisualModel.Place(visual.model, data.Position, visual.velocity)
			if data.Kind then
				Impact.Play(data.Position, data.Normal, data.Kind)
			end
		end
		destroyVisual(data.Id)
	end)

	VisualOffload.On("ProjRay", function(data)
		DebugRays.Draw(data.From, data.To, data.LowRes)
	end)

	-- Every projectile visual gets exactly one ProjSpawn and, eventually, one
	-- ProjHit. For an UNSYNCED visual (the common case: no active homing lock
	-- -- this includes a bouncer between bounces, since bouncing no longer
	-- keeps a visual continuously synced, see the module doc comment), this
	-- loop is the entire simulation in between -- it integrates
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
				-- regardless of dt (see the server step loop), so as long as
				-- this client is in VisualRange, lastUpdate keeps getting
				-- refreshed; once it stops (genuinely left range, or the
				-- projectile is gone), a real-time timeout cleans it up.
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
				VisualModel.Place(visual.model, visual.position, visual.velocity)
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

return ProjectileClient
