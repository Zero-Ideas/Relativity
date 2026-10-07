--!optimize 2
--[[
	DebugService (server, Studio only)
	Backs the client DebugPanel (src/client/DebugPanel.luau):
	 - tool list + give/clear, sourced from Tools under StarterPack,
	   ReplicatedStorage and ServerStorage (direct children, or inside a
	   Folder named "Tools");
	 - server stats, pushed at STATS_INTERVAL only to players whose Stats tab
	   is open;
	 - entity control: list every Entity, act on one by Id (HP, status
	   effects, tools), and push the watched entity's state at STATS_INTERVAL
	   to players whose Entities tab is open;
	 - chunk control: chunk/zone snapshots at STATS_INTERVAL to players whose
	   Chunks tab is open, plus per-chunk / radius / global time scale and
	   load-state actions.
	With no subscribers/watchers nothing runs: no frame counter, no sends.

	Channels (VisualOffload):
	 client -> server  DebugRequestTools, DebugGiveTool(name), DebugClearTools,
	                   DebugStats(subscribed: boolean),
	                   DebugRequestEntities, DebugEntityWatch(id?),
	                   DebugEntityAction({ Id, Action, ... }),
	                   DebugRequestChunks, DebugChunkWatch(boolean),
	                   DebugChunkAction({ Action, ... })
	 server -> client  DebugTools({ string }), DebugServerStats(table),
	                   DebugEntities({ Entities, Effects }), DebugEntityState(table),
	                   DebugChunks(table)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPack = game:GetService("StarterPack")
local Stats = game:GetService("Stats")

-- Gated per player (see DebugAccess), not per environment: Team Test's
-- cloud server isn't "Studio", but its testers still need the panel.
local DebugAccess = require(script.Parent.DebugAccess)
local PlayerDefaults = require(script.Parent.PlayerDefaults)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)

-- Every request is dropped unless the sender may use one of the panel tabs
-- that sends it (DebugAccess.CanUseTab: listed players any tab, everyone else
-- only the tabs made public while the panel is open to all).
local function onAllowed(tabs: { string }, channel: string, handler: (any, Player) -> ())
	VisualOffload.On(channel, function(data, player)
		if not player then
			return
		end
		for _, tab in tabs do
			if DebugAccess.CanUseTab(player, tab) then
				handler(data, player)
				return
			end
		end
	end)
end

-- Opening the panel to everyone is for listed players only (DebugAccess
-- checks); the result reaches every client as ReplicatedStorage's
-- "DebugPublic" attribute.
VisualOffload.On("DebugSetPublic", function(enabled, player)
	if player and typeof(enabled) == "boolean" then
		DebugAccess.SetPublic(player, enabled)
	end
end)

-- Defaults tab: the stats every character spawns with (listed players only).
VisualOffload.On("DebugSetDefaults", function(data, player)
	if not player or not DebugAccess.CanUseTab(player, "Defaults") or typeof(data) ~= "table" then
		return
	end
	if typeof(data.Enabled) == "boolean" then
		PlayerDefaults.SetEnabled(data.Enabled)
	elseif data.Reset == true then
		PlayerDefaults.Reset()
	else
		PlayerDefaults.Set(data)
	end
end)

-- Admin tab: take a tab from (or give it back to) one player you outrank.
VisualOffload.On("DebugSetPlayerTab", function(data, player)
	if not player or typeof(data) ~= "table" or typeof(data.Tab) ~= "string" or typeof(data.Allowed) ~= "boolean" then
		return
	end
	local target = data.Player
	if typeof(target) == "Instance" and target:IsA("Player") and target.Parent == Players then
		DebugAccess.SetPlayerTab(player, target, data.Tab, data.Allowed)
	end
end)

-- Admin tab: which tabs non-listed players see (listed players only).
VisualOffload.On("DebugSetTabPublic", function(data, player)
	if player and typeof(data) == "table" and typeof(data.Tab) == "string" and typeof(data.Enabled) == "boolean" then
		DebugAccess.SetTabPublic(player, data.Tab, data.Enabled)
	end
end)
local ChunkManager = require(Shared.ChunkManager)
local Heartbeat = require(Shared.Heartbeat)
local Entity = require(Shared.Entity)
local StatusEffectSys = require(Shared.StatusEffectSys)
local Projectile = require(script.Parent.Projectile)

local STATS_INTERVAL = 0.5

--------------------------------------------------------------------------------
-- Tools
--------------------------------------------------------------------------------

-- First match per name wins, so StarterPack copies take priority.
local TOOL_CONTAINERS = { StarterPack, ReplicatedStorage, ServerStorage }

local function collectTools(): { [string]: Tool }
	local found: { [string]: Tool } = {}
	local function consider(instance: Instance)
		if instance:IsA("Tool") and not found[instance.Name] then
			found[instance.Name] = instance
		end
	end
	for _, container in TOOL_CONTAINERS do
		for _, child in container:GetChildren() do
			consider(child)
			if child:IsA("Folder") and child.Name == "Tools" then
				for _, nested in child:GetChildren() do
					consider(nested)
				end
			end
		end
	end
	return found
end

local function sendToolList(player: Player)
	local names = {}
	for name in collectTools() do
		table.insert(names, name)
	end
	table.sort(names)
	VisualOffload.FireClient(player, "DebugTools", names)
end

local function ownsTool(player: Player, name: string): boolean
	local backpack = player:FindFirstChildOfClass("Backpack")
	local held = player.Character and player.Character:FindFirstChild(name)
	return (backpack ~= nil and backpack:FindFirstChild(name) ~= nil) or (held ~= nil and held:IsA("Tool"))
end

onAllowed({ "Tools", "Entities" }, "DebugRequestTools", function(_, player)
	if player then
		sendToolList(player)
	end
end)

local function giveToPlayer(player: Player, name: string)
	local source = collectTools()[name]
	local backpack = player:FindFirstChildOfClass("Backpack")
	if source and backpack and not ownsTool(player, name) then
		source:Clone().Parent = backpack
	end
end

local function clearTools(containers: { Instance? })
	for _, container in containers do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool") then
					child:Destroy()
				end
			end
		end
	end
end

onAllowed({ "Tools" }, "DebugGiveTool", function(name, player)
	if player and typeof(name) == "string" then
		giveToPlayer(player, name)
	end
end)

onAllowed({ "Tools" }, "DebugClearTools", function(_, player)
	if player then
		clearTools({ player:FindFirstChildOfClass("Backpack"), player.Character })
	end
end)

--------------------------------------------------------------------------------
-- Entities
--------------------------------------------------------------------------------

local function findEntity(id: any): any?
	if typeof(id) ~= "number" then
		return nil
	end
	for _, entity in Entity.GetAll() do
		if entity.Id == id and not entity.IsDestroyed then
			return entity
		end
	end
	return nil
end

local function entityName(entity): string
	local instance = entity.Instance
	if not instance then
		return "Entity"
	end
	local player = Players:GetPlayerFromCharacter(instance)
	return if player then `{player.Name} (player)` else instance.Name
end

-- Only instances clients can actually see are sent as references.
local function visibleInstance(entity): Instance?
	local instance = entity.Instance
	return if instance and instance:IsDescendantOf(workspace) then instance else nil
end

local function entityTools(entity): { string }
	local names = {}
	local instance = entity.Instance
	local player = instance and Players:GetPlayerFromCharacter(instance)
	for _, container in { instance, player and player:FindFirstChildOfClass("Backpack") } do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool") then
					table.insert(names, child.Name)
				end
			end
		end
	end
	table.sort(names)
	return names
end

local function entityState(id: number)
	local entity = findEntity(id)
	if not entity then
		return { Id = id, Gone = true }
	end
	local effects = {}
	for _, effect in StatusEffectSys:GetEffects(entity) do
		table.insert(effects, { Name = effect.Name, Duration = effect.Duration, Potency = effect.Potency })
	end
	return {
		Id = id,
		Name = entityName(entity),
		Instance = visibleInstance(entity),
		Health = entity.Health,
		MaxHealth = entity.MaxHealth,
		Dead = entity._dead == true,
		Position = entity:GetPosition(),
		TimeScale = entity:GetEffectiveTimeScale(),
		Team = entity.Team,
		Effects = effects,
		Tools = entityTools(entity),
	}
end

local function sendEntityList(player: Player)
	local list = {}
	for _, entity in Entity.GetAll() do
		if not entity.IsDestroyed then
			table.insert(list, { Id = entity.Id, Name = entityName(entity), Instance = visibleInstance(entity) })
		end
	end
	table.sort(list, function(a, b)
		return a.Id < b.Id
	end)
	VisualOffload.FireClient(player, "DebugEntities", {
		Entities = list,
		Effects = StatusEffectSys.GetRegisteredNames(),
	})
end

local function setHealth(entity, value: number)
	local humanoid = entity.Humanoid
	value = math.clamp(value, 0, entity.MaxHealth)
	if humanoid and humanoid.Parent then
		humanoid.Health = value -- HealthChanged/Died keep the entity in sync
		entity.Health = humanoid.Health
	else
		entity.Health = value
		if value <= 0 then
			entity:_handleDeath({ Type = "Debug" })
		else
			entity._dead = false -- data-only entities can be revived
		end
	end
end

local function setMaxHealth(entity, value: number)
	value = math.max(value, 1)
	local humanoid = entity.Humanoid
	if humanoid and humanoid.Parent then
		humanoid.MaxHealth = value
	end
	entity.MaxHealth = value
	if entity.Health > value then
		setHealth(entity, value)
	end
end

local function giveToEntity(entity, name: string)
	local instance = entity.Instance
	if not instance then
		return
	end
	local player = Players:GetPlayerFromCharacter(instance)
	if player then
		giveToPlayer(player, name)
		return
	end
	local humanoid = entity.Humanoid
	local source = collectTools()[name]
	if source and humanoid and humanoid.Parent and not instance:FindFirstChild(name) then
		humanoid:EquipTool(source:Clone())
	end
end

local function finite(value: any): number?
	return if typeof(value) == "number" and value == value and math.abs(value) < 1e9 then value else nil
end

-- The player whose character `entity` is, if any.
local function playerOf(entity: any): Player?
	local instance = entity and entity.Instance
	return if instance then Players:GetPlayerFromCharacter(instance) else nil
end

local actions = {
	SetHealth = function(entity, data)
		local value = finite(data.Value)
		if value then
			setHealth(entity, value)
		end
	end,
	SetMaxHealth = function(entity, data)
		local value = finite(data.Value)
		if value then
			setMaxHealth(entity, value)
		end
	end,
	Heal = function(entity)
		setHealth(entity, entity.MaxHealth)
	end,
	Kill = function(entity)
		-- the allowlist is immune to the panel's Kill button
		if not DebugAccess.IsListed(playerOf(entity)) then
			setHealth(entity, 0)
		end
	end,
	ApplyEffect = function(entity, data)
		local duration, potency = finite(data.Duration), finite(data.Potency)
		if
			typeof(data.Name) == "string"
			and table.find(StatusEffectSys.GetRegisteredNames(), data.Name)
			and duration
			and duration > 0
		then
			StatusEffectSys:ApplyEffect(entity, data.Name, duration, potency)
		end
	end,
	RemoveEffect = function(entity, data)
		if typeof(data.Name) == "string" then
			StatusEffectSys:RemoveEffect(entity, data.Name)
		end
	end,
	GiveTool = function(entity, data)
		if typeof(data.Name) == "string" then
			giveToEntity(entity, data.Name)
		end
	end,
	ClearTools = function(entity)
		local instance = entity.Instance
		local player = instance and Players:GetPlayerFromCharacter(instance)
		clearTools({ instance, player and player:FindFirstChildOfClass("Backpack") })
	end,
}

-- Summary of live projectiles, for chasing leaks (who's alive past their
-- lifetime, which channels they belong to).
onAllowed({ "Stats" }, "DebugProjectileReport", function(_, player)
	if not player then
		return
	end
	local rows = {}
	for _, p in Projectile.GetAll() do
		if not p.Dead and #rows < 40 then
			table.insert(rows, {
				Id = p.Id,
				Age = p.Age,
				Lifetime = p.Lifetime,
				Real = os.clock() - (p._spawnRealTime or os.clock()),
				Joiner = p._beamJoiner == true,
				Channel = p.Beam and p.Beam.ChannelId,
				Previous = p.Beam and p.Beam.PreviousId,
				Speed = p.Velocity.Magnitude,
				TimeScale = p.TimeScale,
				SourceScale = p.Source and p.Source.TimeScale,
				Debt = p._simulationDebt,
				Position = p.Position,
			})
		end
	end
	VisualOffload.FireClient(player, "DebugProjectileReport", { Total = #Projectile.GetAll(), Rows = rows })
end)

onAllowed({ "Entities" }, "DebugRequestEntities", function(_, player)
	if player then
		sendEntityList(player)
	end
end)

onAllowed({ "Entities" }, "DebugEntityAction", function(data, player)
	if not player or typeof(data) ~= "table" then
		return
	end
	local action = actions[data.Action]
	local entity = findEntity(data.Id)
	-- ranks: a player's character can only be changed by someone who
	-- outranks them (or themselves) -- the master by no one else
	if entity and not DebugAccess.CanAffect(player, playerOf(entity)) then
		return
	end
	if action and entity then
		action(entity, data)
		-- reply right away instead of waiting for the next tick
		VisualOffload.FireClient(player, "DebugEntityState", entityState(data.Id))
	end
end)

--------------------------------------------------------------------------------
-- Chunks
--------------------------------------------------------------------------------

local MAX_CHUNKS_SENT = 4096
local MAX_TIME_SCALE = 10

local function chunkSnapshot()
	local list = {}
	for _, chunk in ChunkManager.GetAllChunks() do
		if #list >= MAX_CHUNKS_SENT then
			break
		end
		table.insert(list, {
			Key = chunk.Key,
			TimeScale = chunk.TimeScale,
			Loaded = chunk.Loaded,
			Persistent = chunk.Persistent,
			Entities = chunk.EntityCount,
		})
	end
	local zones = {}
	for _, zone in ChunkManager.GetTimeScaleZones() do
		table.insert(zones, { Id = tostring(zone.Id), Position = zone.Position, Radius = zone.Radius, Scale = zone.Scale })
	end
	return {
		ChunkSize = ChunkManager.ChunkSize,
		UseY = ChunkManager.UseY,
		FreezeUnloaded = ChunkManager.FreezeUnloaded,
		GlobalScale = Heartbeat.GetGlobalTimeScale(),
		Chunks = list,
		Zones = zones,
	}
end

local function chunkKey(value: any): Vector3?
	if typeof(value) ~= "Vector3" then
		return nil
	end
	local key = Vector3.new(math.floor(value.X), if ChunkManager.UseY then math.floor(value.Y) else 0, math.floor(value.Z))
	return if key.Magnitude < 1e6 then key else nil
end

-- Keys from data.Keys (a mass selection, capped) or a single data.Key.
local function chunkKeys(data): { Vector3 }
	local keys = {}
	local source = if typeof(data.Keys) == "table" then data.Keys else { data.Key }
	for index, value in source do
		if index > MAX_CHUNKS_SENT then
			break
		end
		local key = chunkKey(value)
		if key then
			table.insert(keys, key)
		end
	end
	return keys
end

local function timeScale(value: any): number?
	local scale = finite(value)
	return if scale then math.clamp(scale, 0, MAX_TIME_SCALE) else nil
end

local function chunkCenter(key: Vector3): Vector3
	local size = ChunkManager.ChunkSize
	return key * size + Vector3.new(size, if ChunkManager.UseY then size else 0, size) / 2
end

local chunkActions = {
	SetScale = function(data)
		local scale = timeScale(data.Scale)
		if scale then
			for _, key in chunkKeys(data) do
				ChunkManager.SetTimeScaleForKey(key, scale, scale ~= 1)
			end
		end
	end,
	SetScaleRadius = function(data)
		local key, scale, radius = chunkKey(data.Key), timeScale(data.Scale), finite(data.Radius)
		if key and scale and radius then
			for _, nearby in ChunkManager.GetChunkKeysInRadius(chunkCenter(key), math.clamp(radius, 0, 4096)) do
				ChunkManager.SetTimeScaleForKey(nearby, scale, scale ~= 1)
			end
		end
	end,
	SetLoaded = function(data)
		if typeof(data.Loaded) == "boolean" then
			for _, key in chunkKeys(data) do
				ChunkManager.SetLoadedAt(chunkCenter(key), data.Loaded)
			end
		end
	end,
	ResetAll = function()
		for _, chunk in ChunkManager.GetAllChunks() do
			if chunk.TimeScale ~= 1 or not chunk.Loaded then
				chunk.Loaded = true
				ChunkManager.SetTimeScaleForKey(chunk.Key, 1, false)
			end
		end
	end,
	ClearZones = function()
		for _, zone in ChunkManager.GetTimeScaleZones() do
			ChunkManager.RemoveTimeScaleZone(zone.Id)
		end
	end,
	SetGlobalScale = function(data)
		local scale = timeScale(data.Scale)
		if scale then
			Heartbeat.SetGlobalTimeScale(scale) -- ChunkManager replication mirrors it
		end
	end,
}

onAllowed({ "Chunks" }, "DebugRequestChunks", function(_, player)
	if player then
		VisualOffload.FireClient(player, "DebugChunks", chunkSnapshot())
	end
end)

onAllowed({ "Chunks" }, "DebugChunkAction", function(data, player)
	if not player or typeof(data) ~= "table" then
		return
	end
	local action = chunkActions[data.Action]
	if action then
		action(data)
		VisualOffload.FireClient(player, "DebugChunks", chunkSnapshot())
	end
end)

--------------------------------------------------------------------------------
-- Stats / entity / chunk watch ticker
--------------------------------------------------------------------------------

local subscribers: { [Player]: true } = {}
local watchers: { [Player]: number } = {}
local chunkWatchers: { [Player]: true } = {}
local frameConnection: RBXScriptConnection? = nil
local frames, frameTime, worstFrame = 0, 0, 0
local sinceSend = 0

local function readStat(name: string): number?
	local ok, value = pcall(function()
		return (Stats :: any)[name]
	end)
	return if ok and typeof(value) == "number" then value else nil
end

-- In a Studio playtest DataReceiveKbps reads 0 (the Stats.Network items that
-- do report it are not readable from game scripts). Each subscribed client
-- reports its own outbound -- this server's inbound -- so a 0 is filled with
-- their sum and flagged ReceiveApprox.
local clientOut: { [Player]: number } = {}

local function inboundRate(): (number?, boolean)
	local measured = readStat("DataReceiveKbps")
	if measured and measured > 0 then
		return measured, false
	end
	local total, any = 0, false
	for _, rate in clientOut do
		total += rate
		any = true
	end
	return if any then total else measured, any
end

local function buildStats()
	local projectiles = Projectile.GetStats()
	local timing = Projectile.TakeStepTiming()
	local occupancy = Projectile.TakeOccupancyStats()
	local parallel = Projectile.TakeParallelStats()
	local chunks = ChunkManager.GetStats()
	local averageFrame = if frames > 0 then frameTime / frames else 0
	return {
		Fps = if frameTime > 0 then frames / frameTime else 0,
		FrameMs = averageFrame * 1000,
		WorstFrameMs = worstFrame * 1000,
		HeartbeatMs = readStat("HeartbeatTimeMs"),
		PhysicsMs = readStat("PhysicsStepTimeMs"),
		SendKbps = readStat("DataSendKbps"),
		MemoryMb = Stats:GetTotalMemoryUsageMb(),
		Instances = readStat("InstanceCount"),
		Players = #Players:GetPlayers(),
		GlobalTimeScale = Heartbeat.GetGlobalTimeScale(),
		Projectiles = projectiles.Active,
		StepMs = timing.StepMs,
		StepWorstMs = timing.StepWorstMs,
		BeamMs = timing.BeamMs,
		BeamWorstMs = timing.BeamWorstMs,
		ReplicationMs = timing.ReplicationMs,
		ReplicationWorstMs = timing.ReplicationWorstMs,
		RaycastChecks = occupancy.Checks,
		RaycastsSkipped = occupancy.Skipped,
		OccupancyReady = occupancy.Ready,
		OccupancyCells = occupancy.StaticCells,
		OccupancyDynamic = occupancy.DynamicParts,
		ParallelSteps = parallel.Parallel,
		SerialSteps = parallel.Serial,
		FallbackSteps = parallel.Fallback,
		LateSteps = parallel.Late,
		ParallelWorkers = parallel.Workers,
		PendingSpawns = projectiles.PendingVisualSpawns,
		PendingHits = projectiles.PendingVisualHits,
		BeamPoseUpdates = projectiles.BeamPoseUpdates,
		Entities = chunks.TrackedEntityCount,
		Chunks = chunks.ChunkCount,
		LoadedChunks = chunks.LoadedChunkCount,
	}
end

local function onFrame(dt: number)
	frames += 1
	frameTime += dt
	if dt > worstFrame then
		worstFrame = dt
	end
	sinceSend += dt
	if sinceSend < STATS_INTERVAL then
		return
	end
	sinceSend = 0
	if next(subscribers) then
		local payload = buildStats()
		payload.ReceiveKbps, payload.ReceiveApprox = inboundRate()
		for player in subscribers do
			-- each recipient gets its own server-measured ping
			payload.PingMs = player:GetNetworkPing() * 1000
			VisualOffload.FireClient(player, "DebugServerStats", payload)
		end
	end
	frames, frameTime, worstFrame = 0, 0, 0
	for player, id in watchers do
		VisualOffload.FireClient(player, "DebugEntityState", entityState(id))
	end
	if next(chunkWatchers) then
		local snapshot = chunkSnapshot()
		for player in chunkWatchers do
			VisualOffload.FireClient(player, "DebugChunks", snapshot)
		end
	end
end

-- The frame counter runs only while someone is subscribed or watching.
local function refreshTicker()
	local needed = next(subscribers) ~= nil or next(watchers) ~= nil or next(chunkWatchers) ~= nil
	if needed and not frameConnection then
		frames, frameTime, worstFrame, sinceSend = 0, 0, 0, 0
		frameConnection = RunService.Heartbeat:Connect(onFrame)
	elseif not needed and frameConnection then
		frameConnection:Disconnect()
		frameConnection = nil
	end
end

onAllowed({ "Stats" }, "DebugClientNet", function(sent, player)
	if player and subscribers[player] and typeof(sent) == "number" and sent == sent and sent >= 0 and sent < 1e6 then
		clientOut[player] = sent
	end
end)

onAllowed({ "Stats" }, "DebugStats", function(subscribed, player)
	if player then
		subscribers[player] = if subscribed == true then true else nil
		if not subscribers[player] then
			clientOut[player] = nil
		end
		refreshTicker()
	end
end)

onAllowed({ "Entities" }, "DebugEntityWatch", function(id, player)
	if player then
		watchers[player] = if typeof(id) == "number" then id else nil
		refreshTicker()
		if watchers[player] then
			VisualOffload.FireClient(player, "DebugEntityState", entityState(id))
		end
	end
end)

onAllowed({ "Chunks" }, "DebugChunkWatch", function(watching, player)
	if player then
		chunkWatchers[player] = if watching == true then true else nil
		refreshTicker()
	end
end)

Players.PlayerRemoving:Connect(function(player)
	subscribers[player] = nil
	clientOut[player] = nil
	watchers[player] = nil
	chunkWatchers[player] = nil
	refreshTicker()
end)
