--!native
--!optimize 2
--[[
	ChunkManager.luau
	Spatial chunking system. Divides the world into a grid of chunks and tracks
	which entities are inside each one. Every chunk owns a local TimeScale that
	multiplies with the Heartbeat's global time scale, so time inside one chunk
	can run slower or faster than the rest of the world (1 = global speed,
	0.5 = half speed, 0 = frozen).

	Chunks also carry a Loaded flag. When ChunkManager.FreezeUnloaded is true
	(default), entities inside unloaded chunks are skipped by the entity update
	loop and excluded from hitbox/projectile queries — this is the "don't hitbox
	check chunks nobody is using" optimization.

	Chunking is on the XZ plane by default (Y ignored); set ChunkManager.UseY
	= true before creating any chunks for full 3D chunking.

	API summary:
	 ChunkManager.GetChunk(worldPos) -> Chunk?
	 ChunkManager.GetOrCreateChunk(worldPos) -> Chunk
	 ChunkManager.GetTimeScaleAt(worldPos) -> number
	 ChunkManager.SetTimeScaleAt(worldPos, scale)
	 ChunkManager.SetTimeScaleInRadius(worldPos, radius, scale)
	 ChunkManager.GetChunkKeysInRadius(worldPos, radius) -> { Vector3 }
	 ChunkManager.SetTimeScaleForKey(key, scale, persistent?)
	 ChunkManager.AddTimeScaleZone(id, position, radius, scale)
	 ChunkManager.RemoveTimeScaleZone(id)
	 ChunkManager.SetLoadedAt(worldPos, loaded)
	 ChunkManager.IsActiveAt(worldPos) -> boolean
	 ChunkManager.GetEntitiesInChunk(worldPos) -> {Entity}
	 ChunkManager.GetEntitiesInRadius(worldPos, radius, options?) -> {Entity}
	 ChunkManager.GetEntitiesInBox(cframe, size, options?) -> {Entity}
	 ChunkManager.ConfigureAutoLoad({Enabled, Radius?, Interval?})
	 ChunkManager.EnableReplication(options?)  -- server: broadcast, client: receive
	 ChunkManager.GetAllChunks() / GetStats()

	 Chunk fields: Key (chunk coords), TimeScale, Loaded, Persistent,
	   Entities (set), EntityCount, Origin (world min corner)
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Heartbeat = require(script.Parent.Heartbeat)
local Signal = require(script.Parent.Signal)

local ChunkManager = {}
-- Observers settle deferred uniform motion before the time field changes.
-- Handlers must not yield.
ChunkManager.BeforeTimeScaleChange = Signal.new()
ChunkManager.ChunkSize = 64 -- studs per chunk edge
ChunkManager.FreezeUnloaded = true -- skip updates/queries in unloaded chunks
ChunkManager.UseY = false -- 2D (XZ) chunking by default

local chunks: { [Vector3]: any } = {} -- keyed by chunk-coordinate Vector3
local chunkCount = 0
local dilatedChunkCount = 0 -- chunks whose TimeScale ~= 1; see IsTimeUniform
local timeVersion = 0 -- bumped on every chunk scale / zone change; see GetTimeVersion
local autoLoadConnection = nil
local timeZones = {} -- ordered oldest -> newest; newest containing zone wins
local timeZonesById = {}
local replicationEnabled = false

--------------------------------------------------------------------------------
-- Chunk lookup
--------------------------------------------------------------------------------

local function toChunkKey(worldPos: Vector3): Vector3
	local size = ChunkManager.ChunkSize
	return Vector3.new(
		math.floor(worldPos.X / size),
		ChunkManager.UseY and math.floor(worldPos.Y / size) or 0,
		math.floor(worldPos.Z / size)
	)
end

local function newChunk(key: Vector3)
	local size = ChunkManager.ChunkSize
	local chunk = {
		Key = key,
		Origin = key * size,
		TimeScale = 1,
		Loaded = true,
		Persistent = false, -- persistent chunks survive becoming empty
		Entities = {}, -- set: [entity] = true
		EntityCount = 0,
	}
	chunks[key] = chunk
	chunkCount += 1
	return chunk
end

local function maybeCollect(chunk)
	-- Drop empty, non-persistent, default-state chunks to keep the grid sparse.
	if chunk.EntityCount == 0 and not chunk.Persistent and chunk.TimeScale == 1 then
		chunks[chunk.Key] = nil
		chunkCount -= 1
	end
end

-- Every chunk TimeScale write goes through here so dilatedChunkCount stays exact.
local function setChunkScale(chunk, scale: number)
	if chunk.TimeScale ~= scale then
		timeVersion += 1
		ChunkManager.BeforeTimeScaleChange:Fire()
	end
	if (chunk.TimeScale ~= 1) ~= (scale ~= 1) then
		dilatedChunkCount += if scale ~= 1 then 1 else -1
	end
	chunk.TimeScale = scale
end

function ChunkManager.ToChunkKey(worldPos: Vector3): Vector3
	return toChunkKey(worldPos)
end

function ChunkManager.GetChunk(worldPos: Vector3)
	return chunks[toChunkKey(worldPos)]
end

function ChunkManager.GetChunkByKey(key: Vector3)
	return chunks[key]
end

function ChunkManager.GetOrCreateChunk(worldPos: Vector3)
	local key = toChunkKey(worldPos)
	return chunks[key] or newChunk(key)
end

--------------------------------------------------------------------------------
-- Time scale & load state
--------------------------------------------------------------------------------

-- Chunk-local time scale at a position (1 when no chunk exists there).
function ChunkManager.GetTimeScaleAt(worldPos: Vector3): number
	for i = #timeZones, 1, -1 do
		local zone = timeZones[i]
		local offset = worldPos - zone.Position
		if offset:Dot(offset) <= zone.Radius * zone.Radius then
			return zone.Scale
		end
	end
	local chunk = chunks[toChunkKey(worldPos)]
	return chunk and chunk.TimeScale or 1
end

-- True when GetTimeScaleAt is 1 everywhere (no dilated chunk, no zone), so
-- per-step boundary searches can be skipped entirely.
-- Changes whenever any chunk time scale or zone changes -- lets mirrors (the
-- parallel projectile workers) resync only when something actually changed.
function ChunkManager.GetTimeVersion(): number
	return timeVersion
end

function ChunkManager.IsTimeUniform(): boolean
	return dilatedChunkCount == 0 and #timeZones == 0
end

function ChunkManager.GetTimeScaleZones()
	return table.clone(timeZones)
end

local function replicateZone(channel: string, payload)
	if not replicationEnabled or not RunService:IsServer() then
		return
	end
	local VisualOffload = require(script.Parent.VisualOffload)
	VisualOffload.Fire(channel, payload)
end

function ChunkManager.AddTimeScaleZone(id: any, position: Vector3, radius: number, scale: number)
	timeVersion += 1
	ChunkManager.BeforeTimeScaleChange:Fire()
	local existing = timeZonesById[id]
	if existing then
		local index = table.find(timeZones, existing)
		if index then
			table.remove(timeZones, index)
		end
	end
	local zone = {
		Id = id,
		Position = position,
		Radius = math.max(radius, 0),
		Scale = math.max(scale, 0),
	}
	timeZonesById[id] = zone
	table.insert(timeZones, zone)
	replicateZone("TimeZoneUpsert", zone)
	return zone
end

function ChunkManager.RemoveTimeScaleZone(id: any)
	local zone = timeZonesById[id]
	if not zone then
		return
	end
	timeVersion += 1
	ChunkManager.BeforeTimeScaleChange:Fire()
	timeZonesById[id] = nil
	local index = table.find(timeZones, zone)
	if index then
		table.remove(timeZones, index)
	end
	replicateZone("TimeZoneRemove", { Id = id })
end

-- Earliest entry/exit of a radial zone that changes the effective scale along
-- this straight segment. Projectile curvature limits keep the chord error
-- bounded before this function is consulted.
function ChunkManager.GetRadialTimeScaleBoundaryDt(position: Vector3, velocity: Vector3, maxDt: number): number
	local speedSq = velocity:Dot(velocity)
	if speedSq < 1e-8 or #timeZones == 0 then
		return math.huge
	end

	local speed = math.sqrt(speedSq)
	local direction = velocity / speed
	local initialScale = ChunkManager.GetTimeScaleAt(position + direction * 1e-3)
	local candidates = {}
	for _, zone in timeZones do
		local offset = position - zone.Position
		local b = 2 * offset:Dot(velocity)
		local c = offset:Dot(offset) - zone.Radius * zone.Radius
		local discriminant = b * b - 4 * speedSq * c
		if discriminant >= 0 then
			local root = math.sqrt(discriminant)
			local denominator = 2 * speedSq
			local first = (-b - root) / denominator
			local second = (-b + root) / denominator
			if first > 1e-6 and first < maxDt then
				table.insert(candidates, first)
			end
			if second > 1e-6 and second < maxDt then
				table.insert(candidates, second)
			end
		end
	end
	table.sort(candidates)
	local sampleDt = 1e-3 / speed
	for _, candidate in candidates do
		if ChunkManager.GetTimeScaleAt(position + velocity * (candidate + sampleDt)) ~= initialScale then
			return candidate
		end
	end
	return math.huge
end

-- Full effective scale at a position: global * chunk.
function ChunkManager.GetEffectiveTimeScaleAt(worldPos: Vector3): number
	return Heartbeat.GetGlobalTimeScale() * ChunkManager.GetTimeScaleAt(worldPos)
end

-- Scales an already global-dilated dt by the chunk-local rate at a position.
-- Use this in batched per-frame loops (Projectile, Hitbox) that receive dt
-- already multiplied by Heartbeat.GetGlobalTimeScale() and only need the
-- chunk-local factor folded in on top.
function ChunkManager.ScaleDt(dt: number, worldPos: Vector3): number
	return dt * ChunkManager.GetTimeScaleAt(worldPos)
end

function ChunkManager.SetTimeScaleAt(worldPos: Vector3, scale: number)
	return ChunkManager.SetTimeScaleForKey(toChunkKey(worldPos), scale, true)
end

-- Key-based variant used by temporary zone systems that must restore both the
-- previous scale and persistence state without leaking empty default chunks.
function ChunkManager.SetTimeScaleForKey(key: Vector3, scale: number, persistent: boolean?)
	local chunk = chunks[key] or newChunk(key)
	setChunkScale(chunk, math.max(scale, 0))
	if persistent ~= nil then
		chunk.Persistent = persistent
	end
	ChunkManager._replicateScale(chunk)
	maybeCollect(chunk)
	return chunk
end

-- Chunk keys whose axis-aligned cells intersect a circular (2D mode) or
-- spherical (3D mode) radius. Public so debug/test visuals can show the exact
-- same discretized zone that simulation uses.
function ChunkManager.GetChunkKeysInRadius(worldPos: Vector3, radius: number): { Vector3 }
	local size = ChunkManager.ChunkSize
	radius = math.max(radius, 0)
	local minY, maxY = 0, 0
	if ChunkManager.UseY then
		minY = math.floor((worldPos.Y - radius) / size)
		maxY = math.floor((worldPos.Y + radius) / size)
	end
	local radiusSq = radius * radius
	local keys = {}
	for x = math.floor((worldPos.X - radius) / size), math.floor((worldPos.X + radius) / size) do
		for z = math.floor((worldPos.Z - radius) / size), math.floor((worldPos.Z + radius) / size) do
			for y = minY, maxY do
				local minPoint = Vector3.new(x * size, if ChunkManager.UseY then y * size else worldPos.Y, z * size)
				local maxPoint = minPoint + Vector3.new(size, if ChunkManager.UseY then size else 0, size)
				local closest = Vector3.new(
					math.clamp(worldPos.X, minPoint.X, maxPoint.X),
					if ChunkManager.UseY then math.clamp(worldPos.Y, minPoint.Y, maxPoint.Y) else worldPos.Y,
					math.clamp(worldPos.Z, minPoint.Z, maxPoint.Z)
				)
				local offset = closest - worldPos
				if offset:Dot(offset) <= radiusSq then
					table.insert(keys, Vector3.new(x, y, z))
				end
			end
		end
	end
	return keys
end

function ChunkManager.SetTimeScaleInRadius(worldPos: Vector3, radius: number, scale: number)
	for _, key in ChunkManager.GetChunkKeysInRadius(worldPos, radius) do
		ChunkManager.SetTimeScaleForKey(key, scale, true)
	end
end

function ChunkManager.SetLoadedAt(worldPos: Vector3, loaded: boolean)
	local chunk = ChunkManager.GetOrCreateChunk(worldPos)
	chunk.Loaded = loaded
	chunk.Persistent = true
end

-- Whether systems should simulate/query at this position right now.
function ChunkManager.IsActiveAt(worldPos: Vector3): boolean
	if not ChunkManager.FreezeUnloaded then
		return true
	end
	local chunk = chunks[toChunkKey(worldPos)]
	return chunk == nil or chunk.Loaded
end

local function isChunkActive(chunk): boolean
	return chunk.Loaded or not ChunkManager.FreezeUnloaded
end
ChunkManager.IsChunkActive = isChunkActive

--------------------------------------------------------------------------------
-- Entity membership (called by the Entity system)
--------------------------------------------------------------------------------

function ChunkManager._addEntity(entity, worldPos: Vector3)
	local chunk = ChunkManager.GetOrCreateChunk(worldPos)
	if not chunk.Entities[entity] then
		chunk.Entities[entity] = true
		chunk.EntityCount += 1
	end
	return chunk
end

function ChunkManager._removeEntity(entity, chunk)
	if chunk and chunk.Entities[entity] then
		chunk.Entities[entity] = nil
		chunk.EntityCount -= 1
		maybeCollect(chunk)
	end
end

-- Moves the entity to the chunk containing worldPos if it changed.
-- Returns the (possibly new) chunk, and whether it changed.
function ChunkManager._updateEntity(entity, currentChunk, worldPos: Vector3)
	local key = toChunkKey(worldPos)
	if currentChunk and currentChunk.Key == key then
		return currentChunk, false
	end
	ChunkManager._removeEntity(entity, currentChunk)
	return ChunkManager._addEntity(entity, worldPos), true
end

--------------------------------------------------------------------------------
-- Spatial queries
--------------------------------------------------------------------------------

export type QueryOptions = {
	IncludeFrozen: boolean?, -- include entities in unloaded/frozen chunks
	Filter: ((entity: any) -> boolean)?,
}

local function sweepChunks(minPos: Vector3, maxPos: Vector3, options: QueryOptions?, visit)
	local size = ChunkManager.ChunkSize
	local includeFrozen = options and options.IncludeFrozen
	local minY, maxY = 0, 0
	if ChunkManager.UseY then
		minY = math.floor(minPos.Y / size)
		maxY = math.floor(maxPos.Y / size)
	end
	for x = math.floor(minPos.X / size), math.floor(maxPos.X / size) do
		for z = math.floor(minPos.Z / size), math.floor(maxPos.Z / size) do
			for y = minY, maxY do
				local chunk = chunks[Vector3.new(x, y, z)]
				if chunk and (includeFrozen or isChunkActive(chunk)) and chunk.EntityCount > 0 then
					visit(chunk)
				end
			end
		end
	end
end

function ChunkManager.GetEntitiesInChunk(worldPos: Vector3)
	local result = {}
	local chunk = chunks[toChunkKey(worldPos)]
	if chunk then
		for entity in chunk.Entities do
			table.insert(result, entity)
		end
	end
	return result
end

function ChunkManager.GetEntitiesInRadius(worldPos: Vector3, radius: number, options: QueryOptions?)
	local result = {}
	local filter = options and options.Filter
	local extent = Vector3.new(radius, radius, radius)
	sweepChunks(worldPos - extent, worldPos + extent, options, function(chunk)
		for entity in chunk.Entities do
			local offset = entity:GetPosition() - worldPos
			if offset.Magnitude <= radius + entity.HitboxRadius then
				if not filter or filter(entity) then
					table.insert(result, entity)
				end
			end
		end
	end)
	return result
end

function ChunkManager.GetEntitiesInBox(cframe: CFrame, size: Vector3, options: QueryOptions?)
	local result = {}
	local filter = options and options.Filter
	local half = size / 2
	-- conservative world-space AABB around the oriented box
	local extent = Vector3.new(
		math.abs(cframe.RightVector.X) * half.X
			+ math.abs(cframe.UpVector.X) * half.Y
			+ math.abs(cframe.LookVector.X) * half.Z,
		math.abs(cframe.RightVector.Y) * half.X
			+ math.abs(cframe.UpVector.Y) * half.Y
			+ math.abs(cframe.LookVector.Y) * half.Z,
		math.abs(cframe.RightVector.Z) * half.X
			+ math.abs(cframe.UpVector.Z) * half.Y
			+ math.abs(cframe.LookVector.Z) * half.Z
	)
	sweepChunks(cframe.Position - extent, cframe.Position + extent, options, function(chunk)
		for entity in chunk.Entities do
			local localPos = cframe:PointToObjectSpace(entity:GetPosition())
			local pad = entity.HitboxRadius
			if
				math.abs(localPos.X) <= half.X + pad
				and math.abs(localPos.Y) <= half.Y + pad
				and math.abs(localPos.Z) <= half.Z + pad
			then
				if not filter or filter(entity) then
					table.insert(result, entity)
				end
			end
		end
	end)
	return result
end

--------------------------------------------------------------------------------
-- Auto-load: keep chunks near player characters loaded, freeze the rest
--------------------------------------------------------------------------------

export type AutoLoadConfig = {
	Enabled: boolean,
	Radius: number?, -- studs around each character, default 256
	Interval: number?, -- refresh cadence in real seconds, default 0.5
}

function ChunkManager.ConfigureAutoLoad(config: AutoLoadConfig)
	if autoLoadConnection then
		autoLoadConnection:Disconnect()
		autoLoadConnection = nil
	end
	if not config.Enabled then
		return
	end

	local radius = config.Radius or 256
	local chunkRadius = math.ceil(radius / ChunkManager.ChunkSize)

	autoLoadConnection = Heartbeat.ConnectInterval(config.Interval or 0.5, function()
		-- gather occupied chunk keys around players
		local loadedKeys: { [Vector3]: boolean } = {}
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = character and character.PrimaryPart
			if root then
				local center = toChunkKey(root.Position)
				local minY, maxY = 0, 0
				if ChunkManager.UseY then
					minY, maxY = -chunkRadius, chunkRadius
				end
				for dx = -chunkRadius, chunkRadius do
					for dz = -chunkRadius, chunkRadius do
						for dy = minY, maxY do
							loadedKeys[center + Vector3.new(dx, dy, dz)] = true
						end
					end
				end
			end
		end
		for key, chunk in chunks do
			chunk.Loaded = loadedKeys[key] == true
		end
	end, {
		Name = "ChunkManager.AutoLoad",
		Priority = -100, -- resolve load state before entity/hitbox systems run
	})
end

--------------------------------------------------------------------------------
-- Replication (optional): mirrors chunk + global time scales to clients so
-- client-side visual simulation (see Projectile) dilates identically.
--------------------------------------------------------------------------------

function ChunkManager._replicateScale(chunk)
	if not replicationEnabled or not RunService:IsServer() then
		return
	end
	local VisualOffload = require(script.Parent.VisualOffload)
	VisualOffload.Fire("ChunkScale", { Key = chunk.Key, Scale = chunk.TimeScale })
end

function ChunkManager.EnableReplication()
	if replicationEnabled then
		return
	end
	replicationEnabled = true
	local VisualOffload = require(script.Parent.VisualOffload)

	if RunService:IsServer() then
		-- Snapshot for a joining client, sent when IT asks (below): pushed on
		-- PlayerAdded it would usually arrive before the client registered its
		-- ChunkSnapshot handler, and VisualOffload drops messages nobody is
		-- listening for -- live-server joiners then never saw the time scales
		-- already in place. One request per player per few seconds.
		local lastRequest: { [Player]: number } = {}
		VisualOffload.On("ChunkSnapshotRequest", function(_, player)
			if not player then
				return
			end
			local now = os.clock()
			if lastRequest[player] and now - lastRequest[player] < 3 then
				return
			end
			lastRequest[player] = now
			local snapshot = {}
			for key, chunk in chunks do
				if chunk.TimeScale ~= 1 then
					table.insert(snapshot, { Key = key, Scale = chunk.TimeScale })
				end
			end
			VisualOffload.FireClient(player, "ChunkSnapshot", {
				Chunks = snapshot,
				Zones = timeZones,
				GlobalScale = Heartbeat.GetGlobalTimeScale(),
			})
		end)
		Players.PlayerRemoving:Connect(function(player)
			lastRequest[player] = nil
		end)
		-- Mirror global scale changes. Polled in REAL time via a plain task loop,
		-- deliberately NOT a Heartbeat connection: every Heartbeat dt (dilated or
		-- not) is itself multiplied by the current global scale, so a poll tied to
		-- Heartbeat would stop advancing the instant the scale it's watching hits
		-- 0 -- meaning the transition INTO a full freeze could never be detected
		-- or broadcast to any client that didn't set it locally themselves. Real
		-- time keeps ticking regardless of dilation, so this always fires.
		local lastGlobal = Heartbeat.GetGlobalTimeScale()
		task.spawn(function()
			while true do
				task.wait(0.2)
				local current = Heartbeat.GetGlobalTimeScale()
				if current ~= lastGlobal then
					lastGlobal = current
					VisualOffload.Fire("GlobalScale", current)
				end
			end
		end)
	else
		VisualOffload.On("ChunkScale", function(data)
			local chunk = chunks[data.Key] or newChunk(data.Key)
			setChunkScale(chunk, data.Scale)
			chunk.Persistent = true
			maybeCollect(chunk)
		end)
		VisualOffload.On("ChunkSnapshot", function(data)
			for _, entry in data.Chunks do
				local chunk = chunks[entry.Key] or newChunk(entry.Key)
				setChunkScale(chunk, entry.Scale)
				chunk.Persistent = true
			end
			for _, zone in data.Zones or {} do
				ChunkManager.AddTimeScaleZone(zone.Id, zone.Position, zone.Radius, zone.Scale)
			end
			Heartbeat.SetGlobalTimeScale(data.GlobalScale)
		end)
		VisualOffload.On("TimeZoneUpsert", function(zone)
			ChunkManager.AddTimeScaleZone(zone.Id, zone.Position, zone.Radius, zone.Scale)
		end)
		VisualOffload.On("TimeZoneRemove", function(data)
			ChunkManager.RemoveTimeScaleZone(data.Id)
		end)
		VisualOffload.On("GlobalScale", function(scale)
			Heartbeat.SetGlobalTimeScale(scale)
		end)
		-- every handler above is registered now, so the reply can't be dropped
		VisualOffload.Fire("ChunkSnapshotRequest")
	end
end

--------------------------------------------------------------------------------
-- Introspection
--------------------------------------------------------------------------------

function ChunkManager.GetAllChunks()
	local list = {}
	for _, chunk in chunks do
		table.insert(list, chunk)
	end
	return list
end

function ChunkManager.GetStats()
	local loaded, entities = 0, 0
	for _, chunk in chunks do
		if chunk.Loaded then
			loaded += 1
		end
		entities += chunk.EntityCount
	end
	return {
		ChunkCount = chunkCount,
		LoadedChunkCount = loaded,
		TrackedEntityCount = entities,
	}
end

return ChunkManager
