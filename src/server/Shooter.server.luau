--[[
	Shooter (server authority)
	Generic weapon dispatcher: receives fire/reload requests from clients
	(VisualOffload "FireBullet"/"ReloadWeapon"/"WeaponEquip") and spawns
	bullets through the Projectile system on behalf of whichever weapon
	module (see Weapons/init.luau) matches the firing player's equipped
	Tool. This file owns ZERO weapon-specific numbers -- every stat, the
	fire rate, the magazine size, and any custom hit/destroy behavior come
	from that weapon's own Weapons/<Name>.luau module. Adding a new weapon
	never means editing this file.

	Because Projectile steps on the dilated Heartbeat, these bullets slow down with
	the global time ratio and inside slow chunks for free -- and, per-shooter, live
	with that player's own personal time ratio (Projectile.luau reads Source.
	TimeScale every tick, so a shooter dragging their ratio mid-flight speeds up
	or slows down bullets already in the air).

	Anti-exploit, defense in depth (VisualOffload's remote is reachable directly by
	any client, bypassing ShooterController's own throttling entirely):
	 - MIN_FIRE_INTERVAL is a hard per-(player, tool) rate limit floor enforced
	   here regardless of how fast (or how directly) the remote is fired, no
	   matter what FireRate a weapon module claims -- a misconfigured weapon
	   can never fire faster than this.
	 - MAX_ACTIVE_PROJECTILES_PER_PLAYER caps how many of a player's bullets can be
	   alive at once, so even max-rate firing with a huge Lifetime can't build an
	   unbounded swarm.
	 - A shot is only accepted while the firing player's character has one of the
	   Weapons registry's tools equipped (see Weapons/init.luau).
	 - The bullet's Model and every gameplay stat are looked up server-side from
	   the equipped tool's weapon module, NEVER taken from client-sent data -- a
	   client-supplied Model Instance or stat table would be an easy exploit
	   vector (clone-and-broadcast via ProjSpawn, or simply lying about damage).
	 - A weapon with a Magazine can't be fired while empty or mid-reload.
	 - The spawn Origin is resolved entirely server-side too (see
	   resolveMuzzleOrigin below): the equipped Tool's "Tip" Attachment if one
	   exists, else the character's Head -- never taken from the client at
	   all, so there's no origin-spoofing surface to clamp/sanity-check in the
	   first place. Only the aim TargetPoint comes from the client (needed --
	   only it knows where the player is aiming), which just steers direction,
	   not where the bullet spawns.
	 - data.Config (from the client's ShooterConfigGui debug panel) is only
	   ever read inside Studio (see applyStudioDebugOverrides/RunService:
	   IsStudio() below) -- a live client's Config table is completely
	   ignored, so this is a Studio iteration convenience, not a trust hole.

	Lag compensation: each shot carries RewindSeconds, half the firing player's
	current network ping, clamped to MAX_REWIND. Projectile.luau uses this to check
	nearby entities against their position as of (now - RewindSeconds) instead of
	their live position while the bullet is near entities -- see Projectile.luau's
	top-of-file doc comment for the full behavior.

	Also handles "StressTestFire": a dev/benchmarking request that spawns many
	projectiles in one go, bypassing the per-shot rate limit (which throttles
	per-click requests, not a single "spawn N" request) -- see the client's N
	keybind in ShooterController.luau. Restricted to Studio (see the
	RunService:IsStudio() guard below) since spawning thousands of projectiles
	per request is itself an exploit vector if left reachable in a live game. Use
	Heartbeat.GetStats().AvgFrameTime to read the actual per-frame cost while a
	batch is in flight.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Heartbeat = require(Shared.Heartbeat)
local Entity = require(Shared.Entity)
local Projectile = require(script.Parent.Projectile)
local VisualOffload = require(Shared.VisualOffload)
local Weapons = require(script.Parent.Weapons)
local WeaponsShared = require(script.Parent.Weapons.Shared)

-- Server-owned mapping of weapon name -> the Model clients render for that
-- weapon's bullets, resolved once at startup from each WeaponDef.Model.
-- NEVER trust a client-sent Model reference (a remote can carry an Instance
-- argument, and a client could point it at literally anything replicated to
-- them -- another player's rig, a chunk of terrain, a LocalScript buried
-- somewhere else in the game -- which the server would then clone and
-- broadcast onto every observer via ProjSpawn). A weapon with no asset found
-- just falls back to the default Visual ball.
local Effects = ReplicatedStorage:FindFirstChild("Effects")
local PROJECTILE_MODELS: { [string]: Instance } = {}
for toolName, weapon in Weapons do
	PROJECTILE_MODELS[toolName] = Effects and Effects:FindFirstChild(weapon.Model)
end

local MIN_FIRE_INTERVAL = 0.1 -- absolute floor (seconds, real time), regardless of a weapon's own FireRate -- 10/sec hard cap
local MAX_ACTIVE_PROJECTILES_PER_PLAYER = 150 -- concurrently-alive cap per player
local MAX_REWIND = 0.4 -- seconds; stays safely under Entity.HistoryWindow (0.5s)
local MUZZLE_SPAWN_OFFSET = 3 -- studs spawned ahead of the resolved origin, along the aim direction, so a bullet never immediately hits its own shooter
local TIP_ATTACHMENT_NAME = "Tip"
local DEFAULT_VISUAL = { Shape = "Ball", Size = Vector3.one * 0.4, Color = Color3.fromRGB(120, 220, 255) }

local lastFire: { [Tool]: number } = {}
local activeProjectileCount: { [Player]: number } = {}

type WeaponState = {
	Magazine: number,
	Reserve: number,
	Reloading: boolean,
}

-- Ammo/reload state, keyed by Tool INSTANCE (not player or weapon name).
-- Every weapon Tool is a private per-player copy cloned from StarterPack --
-- never shared/contested between players -- and Roblox destroys/reclones it
-- fresh on every respawn, so keying by instance means ammo naturally resets
-- on death for free; the only bookkeeping needed is clearing the entry when
-- THIS instance goes away (see tool.Destroying below), not on any
-- per-player respawn hook.
local weaponState: { [Tool]: WeaponState } = {}

-- Clamp a client-supplied number into a trusted range (anti-cheat + sanity).
local function num(value: any, default: number, min: number, max: number): number
	if typeof(value) ~= "number" or value ~= value then
		return default
	end
	return math.clamp(value, min, max)
end

-- Studio-only debug override (see ShooterConfigGui.luau on the client): the
-- fields a dev can live-tune from that panel while testing, each clamped to
-- a sane range and only applied if actually present -- unset fields keep
-- whatever the equipped weapon's own Stats/Homing already say. NEVER read
-- outside Studio (see the IsStudio guard at the call site below), so a live
-- client's Config table is never touched at all -- this doesn't reopen the
-- client-trust gap the per-weapon schema was built to close, it's purely a
-- Studio iteration convenience layered on top of it.
local STUDIO_DEBUG_STAT_FIELDS = {
	{ key = "Speed", min = 10, max = math.huge },
	{ key = "Acceleration", min = -math.huge, max = math.huge },
	{ key = "MinSpeed", min = 0, max = math.huge },
	{ key = "MaxSpeed", min = 0, max = math.huge },
	{ key = "Damage", min = 0, max = math.huge },
	{ key = "Lifetime", min = 0.1, max = math.huge },
	{ key = "Gravity", min = 0, max = math.huge },
	{ key = "Radius", min = 0, max = math.huge },
	{ key = "Bounces", min = 0, max = math.huge, integer = true },
	{ key = "Restitution", min = 0, max = math.huge },
	{ key = "Penetration", min = 0, max = math.huge },
	{ key = "PierceFalloff", min = 0, max = math.huge },
}

local function applyStudioDebugOverrides(projectileConfig: { [string]: any }, cfg: { [string]: any })
	for _, field in STUDIO_DEBUG_STAT_FIELDS do
		local raw = cfg[field.key]
		if typeof(raw) == "number" and raw == raw then
			local value = math.clamp(raw, field.min, field.max)
			projectileConfig[field.key] = if field.integer then math.floor(value) else value
		end
	end
	if typeof(cfg.Pierces) == "number" then
		projectileConfig.MaxPierces = math.floor(num(cfg.Pierces, 0, 0, math.huge))
	end
	if cfg.Homing == true then
		-- Replaces the weapon's own static Homing (if any) for this shot --
		-- lets a dev toggle homing on/off live regardless of what the
		-- weapon module declares.
		projectileConfig.Homing = {
			AcquireRadius = num(cfg.AcquireRadius, 60, 0, math.huge),
			TargetTags = { "Enemy", "Player" },
			Retarget = true,
			ReacquireRate = 0.3,
			Permalock = cfg.Permalock == true,
			TurnRate = math.rad(num(cfg.TurnRate, 140, 0, math.huge)),
			Delay = 0.05,
		}
	end
end

-- Finds which registered weapon (if any) the player's character has
-- equipped right now. Returns the Tool instance and its WeaponDef, or nil,
-- nil if none is equipped -- closes the gap where an exploiter fires a
-- weapon remote directly without ever equipping anything.
local function findEquippedWeapon(character: Model): (Tool?, Weapons.WeaponDef?)
	for toolName, weapon in Weapons do
		local candidate = character:FindFirstChild(toolName)
		if candidate and candidate:IsA("Tool") then
			return candidate, weapon
		end
	end
	return nil, nil
end

-- Where a shot spawns from: the equipped weapon's own "Tip" Attachment if
-- it has one (searched recursively, so it can live under a muzzle model
-- nested inside the Tool), else the character's Head, else the root part
-- (only reachable if a character somehow has no Head at all). Entirely
-- server-resolved from the server's own scene graph -- never trusts
-- anything client-sent, unlike the old client-supplied Origin this replaces.
local function resolveMuzzleOrigin(tool: Tool, character: Model, root: BasePart): Vector3
	local tip = tool:FindFirstChild(TIP_ATTACHMENT_NAME, true)
	if tip and tip:IsA("Attachment") then
		return tip.WorldPosition
	end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position
	end
	return root.Position
end

-- Lazily creates (full magazine) or returns this tool's ammo state. Only
-- called for weapons that actually have a Magazine (callers check first).
local function getWeaponState(tool: Tool, weapon: Weapons.WeaponDef): WeaponState
	local state = weaponState[tool]
	if state then
		return state
	end
	local magazine = assert(weapon.Magazine, "getWeaponState called on a weapon with no Magazine")
	state = { Magazine = magazine.Size, Reserve = magazine.Reserve, Reloading = false }
	weaponState[tool] = state
	tool.Destroying:Once(function()
		weaponState[tool] = nil
	end)
	return state
end

local function pushAmmoSync(player: Player, tool: Tool, state: WeaponState)
	VisualOffload.FireClient(player, "AmmoSync", {
		ToolName = tool.Name,
		Magazine = state.Magazine,
		Reserve = state.Reserve,
		Reloading = state.Reloading,
	})
end

VisualOffload.On("FireBullet", function(data, player)
	if not player or typeof(data) ~= "table" then
		return
	end

	local targetPoint = data.TargetPoint
	if typeof(targetPoint) ~= "Vector3" then
		return
	end

	local character = player.Character
	local root = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
	if not root then
		return
	end

	local tool, weapon = findEquippedWeapon(character)
	if not tool or not weapon then
		return
	end

	-- Origin is entirely server-resolved (see the module doc comment and
	-- resolveMuzzleOrigin above); direction is derived from it toward the
	-- client's aimed TargetPoint, so shots still converge exactly where the
	-- player clicked regardless of which origin was used. Resolved before
	-- any state changes below so a degenerate aim (target on top of the
	-- origin) bails out without consuming ammo/cooldown or playing OnFire.
	local origin = resolveMuzzleOrigin(tool, character, root)
	local toTarget = targetPoint - origin
	if toTarget.Magnitude < 1e-3 then
		return
	end
	local direction = toTarget.Unit

	-- rate limit: a hard per-(player, tool) cap independent of client input
	-- (the remote is reachable directly -- see the module doc comment
	-- above), floored regardless of what the weapon's own FireRate claims.
	local cooldown = math.max(1 / weapon.FireRate, MIN_FIRE_INTERVAL)
	local now = os.clock()
	if lastFire[tool] and now - lastFire[tool] < cooldown then
		return
	end

	-- concurrent-projectile cap: stops max-rate firing + a huge Lifetime from
	-- building an unbounded swarm
	if (activeProjectileCount[player] or 0) >= MAX_ACTIVE_PROJECTILES_PER_PLAYER then
		return
	end

	-- ammo: reject (without consuming the fire-rate cooldown above) while
	-- empty or mid-reload; otherwise consume one round and sync the client.
	local state: WeaponState? = nil
	if weapon.Magazine then
		state = getWeaponState(tool, weapon)
		if state.Reloading or state.Magazine <= 0 then
			return
		end
	end
	if lastFire[tool] == nil then
		-- lastFire is keyed by Tool instance, same as weaponState -- clean
		-- it up on the same signal so a long session doesn't accumulate an
		-- entry per (now-destroyed) Tool instance across every respawn.
		tool.Destroying:Once(function()
			lastFire[tool] = nil
		end)
	end
	lastFire[tool] = now
	if state then
		state.Magazine -= 1
		pushAmmoSync(player, tool, state)
	end

	-- Shot is fully accepted at this point -- fire the weapon's cosmetic
	-- hook (muzzle flash, fire sound, etc.) now, before the projectile
	-- itself spawns. See the OnFire doc comment in Weapons/init.luau.
	if weapon.OnFire then
		weapon.OnFire(tool)
	end

	local shooter = Entity.Get(character) -- may be nil if the character isn't registered

	-- lag compensation: how far back (real seconds) this shooter's view was
	-- desynced when they fired, half their round-trip ping, clamped.
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	local rewindSeconds = (ok and typeof(ping) == "number" and ping == ping) and math.clamp(ping / 2, 0, MAX_REWIND) or 0

	-- Seed the projectile config from the weapon's own stat sheet (cloned so
	-- Projectile can never mutate the module's canonical table), then layer
	-- the fields only the server ever controls on top.
	local projectileConfig = table.clone(weapon.Stats)
	projectileConfig.Origin = origin + direction * MUZZLE_SPAWN_OFFSET
	projectileConfig.Direction = direction
	projectileConfig.Source = shooter
	-- Belt-and-suspenders against self-hits: shooter (the Entity) may still
	-- be nil for a shot fired in the brief window before
	-- PlayerManager.server.luau registers this character on CharacterAdded
	-- -- IgnoreInstances excludes the raw character model from the raycast
	-- regardless, so a self-hit can't happen even during that race.
	projectileConfig.IgnoreInstances = { character }
	projectileConfig.RewindSeconds = rewindSeconds
	projectileConfig.Visualize = true -- server = logic only; clients render
	projectileConfig.VisualRange = 800
	projectileConfig.Visual = DEFAULT_VISUAL -- fallback ball, only used if Model resolution above failed
	-- Chosen server-side from the validated equipped tool, never from client
	-- data (see PROJECTILE_MODELS above) -- a client-supplied Model
	-- reference would be an easy exploit vector.
	projectileConfig.Model = PROJECTILE_MODELS[tool.Name]
	if weapon.Homing then
		-- Fresh clone per shot -- handing Projectile the module's own
		-- canonical Homing table would let it become shared/mutated state
		-- across every shot this weapon ever fires (the exact footgun
		-- Projectile.Burst has with a shallow table.clone(config)).
		projectileConfig.Homing = table.clone(weapon.Homing)
	end
	if RunService:IsStudio() and typeof(data.Config) == "table" then
		applyStudioDebugOverrides(projectileConfig, data.Config)
	end

	local ctx: WeaponsShared.FireContext = {
		Player = player,
		Shooter = shooter,
		Tool = tool,
		Projectile = nil :: any, -- filled in immediately below
	}

	-- counted against MAX_ACTIVE_PROJECTILES_PER_PLAYER above; OnDestroy fires
	-- exactly once per projectile on every removal path (entity hit, world
	-- hit, dilated lifetime expiry, or the real-time MaxRealLifetime safety
	-- cap -- see Projectile.luau's Step/Destroy), so this always balances the
	-- increment below. OnHit is NOT exactly-once (piercing/bouncing/
	-- penetrating fire it without removing the projectile), which is exactly
	-- why this uses OnDestroy instead. The real-time cap matters here
	-- specifically: a shooter who freezes their own personal time with shots
	-- in flight would otherwise have those shots sit in activeProjectileCount
	-- forever, silently eating into their MAX_ACTIVE_PROJECTILES_PER_PLAYER
	-- budget.
	activeProjectileCount[player] = (activeProjectileCount[player] or 0) + 1
	local proj = Projectile.new(projectileConfig)
	ctx.Projectile = proj

	proj.OnDestroy:Connect(function(destroyInfo)
		-- Unconditional bookkeeping -- never skippable by a weapon's own
		-- OnDestroyFunction, or the concurrency cap silently breaks.
		activeProjectileCount[player] = math.max((activeProjectileCount[player] or 1) - 1, 0)
		if weapon.OnDestroyFunction then
			weapon.OnDestroyFunction(ctx, destroyInfo)
		end
	end)

	-- If the weapon defines its own OnHitFunction it FULLY REPLACES default
	-- damage-dealing for this weapon's hits (see the WeaponDef schema in
	-- Weapons/init.luau) -- it can call WeaponsShared.DealDefaultDamage
	-- itself to opt back into standard damage before adding custom effects.
	proj.OnHit:Connect(function(hit)
		if weapon.OnHitFunction then
			weapon.OnHitFunction(ctx, hit)
		else
			WeaponsShared.DealDefaultDamage(ctx, hit)
		end
	end)
end)

VisualOffload.On("ReloadWeapon", function(_data, player)
	if not player then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local tool, weapon = findEquippedWeapon(character)
	if not tool or not weapon or not weapon.Magazine then
		return
	end
	local magazine = weapon.Magazine
	local state = getWeaponState(tool, weapon)
	if state.Reloading or state.Reserve <= 0 or state.Magazine >= magazine.Size then
		return
	end

	state.Reloading = true
	pushAmmoSync(player, tool, state)

	task.delay(magazine.ReloadTime, function()
		-- The tool (or its state entry) may be gone by the time this fires
		-- (unequipped/respawned/left) -- weaponState[tool] would already be
		-- nil via tool.Destroying in that case, `state` here is still the
		-- same table reference so writes are harmless even if orphaned.
		local reload = math.min(magazine.Size - state.Magazine, state.Reserve)
		state.Magazine += reload
		state.Reserve -= reload
		state.Reloading = false
		if player.Parent and weaponState[tool] == state then
			pushAmmoSync(player, tool, state)
		end
	end)
end)

VisualOffload.On("WeaponEquip", function(data, player)
	if not player or typeof(data) ~= "table" or typeof(data.ToolName) ~= "string" then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local weapon = Weapons[data.ToolName]
	local tool = character:FindFirstChild(data.ToolName)
	if not weapon or not weapon.Magazine or not tool or not tool:IsA("Tool") then
		return
	end
	-- Lets the client learn correct starting ammo the instant a weapon is
	-- equipped, instead of waiting for the first shot (a future HUD's entry
	-- point -- see AmmoState.luau on the client).
	pushAmmoSync(player, tool, getWeaponState(tool, weapon))
end)

-- Dev/benchmarking only: spawns Count projectiles immediately in one request,
-- bypassing the per-shot rate limit above (that throttles per-click requests;
-- this is a single request asking for N spawns, not N separate clicks). Damage is forced to
-- 0 so a stress test never kills the Dummy or otherwise interferes with real
-- gameplay mid-benchmark. Has its own, longer cooldown so repeated presses don't
-- compound into an ever-growing pile. Restricted to Studio (see the IsStudio
-- guard below): spawning up to MAX_STRESS_COUNT projectiles per request is
-- itself an "ungodly amounts of projectiles" vector if any client could reach
-- it in a live game, so this never runs outside of testing.
local MAX_STRESS_COUNT = 5000
local STRESS_COOLDOWN = 2
local lastStressTest: { [Player]: number } = {}

local function randomDirection(): Vector3
	local theta = math.random() * 2 * math.pi
	local z = math.random() * 2 - 1
	local r = math.sqrt(1 - z * z)
	return Vector3.new(r * math.cos(theta), z, r * math.sin(theta))
end

VisualOffload.On("StressTestFire", function(data, player)
	if not player or not RunService:IsStudio() then
		return
	end

	local now = os.clock()
	if lastStressTest[player] and now - lastStressTest[player] < STRESS_COOLDOWN then
		return
	end
	lastStressTest[player] = now

	local character = player.Character
	local root = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
	if not root then
		return
	end

	local requestedCount = typeof(data) == "table" and data.Count or nil
	local count = math.floor(num(requestedCount, 500, 1, MAX_STRESS_COUNT))
	local shooter = Entity.Get(character)

	for _ = 1, count do
		local direction = randomDirection()
		Projectile.new({
			Origin = root.Position + direction * 3,
			Direction = direction,
			Speed = 220,
			Lifetime = 4,
			Damage = 0, -- pure load test; never affects real gameplay/entities
			Source = shooter,
			IgnoreInstances = { character },
			Visualize = true,
			VisualRange = 8000,
			Visual = { Shape = "Ball", Size = Vector3.one * 0.4, Color = Color3.fromRGB(255, 140, 60) },
			Homing = {
				AcquireRadius = num(60, 60, 0, 300),
				TargetTags = { "Enemy", "Player" },
				Retarget = true,
				ReacquireRate = 0.3,
				Permalock = true,
				TurnRate = math.rad(num(140, 140, 0, 360)),
				Delay = 0.05,
			},
		})
	end

	print(`[Relativity] stress test: spawned {count} projectiles for {player.Name}`)

	-- Real frame-cost data while the batch is in flight (Heartbeat.GetStats() is
	-- shared module state, so this reads the actual live loop -- not a
	-- disconnected/isolated snapshot).
	task.spawn(function()
		for _ = 1, 6 do
			task.wait(0.5)
			local stats = Heartbeat.GetStats()
			print(
				`[Relativity] stress test stats: {stats.ConnectionCount} connections, avg frame cost {string.format("%.3f", stats.AvgFrameTime * 1000)} ms`
			)
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	lastStressTest[player] = nil
	activeProjectileCount[player] = nil
	-- lastFire/weaponState are keyed by Tool instance, not Player -- they
	-- self-clean via tool.Destroying when the character/backpack is torn
	-- down, so nothing to do here for those.
end)

print("[Relativity] shooter online")
