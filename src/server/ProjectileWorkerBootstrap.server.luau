--!strict
--[[
	ProjectileWorkerBootstrap (server)
	Parallel projectile movement workers (see Projectile/Parallel.luau for the
	main-thread side and Projectile/Sweep.luau for the loop they run).

	Run normally, this script creates WORKER_COUNT Actors under
	ProjectileActors, each holding a clone of itself, plus one SharedTable per
	worker for its results. Inside an Actor it becomes a worker that keeps its
	own mirrors of everything Sweep needs -- chunk time scales and zones
	("TimeWorld"), raycast filters ("Filter"), and its own Occupancy bake --
	and on each "Sweep" message runs its batch in parallel, writing a packed
	result string plus the frame it belongs to into its SharedTable.
]]

local SharedTableRegistry = game:GetService("SharedTableRegistry")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WORKER_COUNT = 4

local actor = script:GetActor()
if not actor then
	local folder = script.Parent:FindFirstChild("ProjectileActors")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ProjectileActors"
		folder.Parent = script.Parent
	end
	for index = 1, WORKER_COUNT do
		local key = `RelativityProjectileSweep{index}`
		if not SharedTableRegistry:GetSharedTable(key) then
			SharedTableRegistry:SetSharedTable(key, SharedTable.new())
		end
	end
	if #folder:GetChildren() == 0 then
		for index = 1, WORKER_COUNT do
			local workerActor = Instance.new("Actor")
			workerActor.Name = `ProjectileWorker{index}`
			local workerScript = script:Clone()
			workerScript.Name = "Worker"
			workerScript.Parent = workerActor
			workerActor.Parent = folder
		end
	end
	return
end

--------------------------------------------------------------------------------
-- Worker
--------------------------------------------------------------------------------

local workerId = assert(tonumber(string.match(actor.Name, "(%d+)$")), "projectile worker needs a numeric suffix")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local projectileModule = (actor.Parent :: Instance).Parent:WaitForChild("Projectile")
local Sweep = require(projectileModule:WaitForChild("Sweep"))
local Occupancy = require(projectileModule:WaitForChild("Occupancy"))
local output = SharedTableRegistry:GetSharedTable(`RelativityProjectileSweep{workerId}`)

local filters: { [number]: RaycastParams } = {}
local entityChunks: { [Vector3]: boolean } = {}

-- Raycast filter `id` (a projectile's movement RaycastParams, by content).
actor:BindToMessageParallel("Filter", function(id: number, instances: { Instance }, ignoreWater: boolean, group: string)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = instances
	params.IgnoreWater = ignoreWater
	params.CollisionGroup = group
	filters[id] = params
end)

-- The main thread's chunk time scales and zones, replacing what we had.
actor:BindToMessageParallel("TimeWorld", function(chunkSize: number, useY: boolean, chunks: { any }, zones: { any })
	ChunkManager.ChunkSize, ChunkManager.UseY = chunkSize, useY
	for _, chunk in ChunkManager.GetAllChunks() do
		if chunk.TimeScale ~= 1 then
			ChunkManager.SetTimeScaleForKey(chunk.Key, 1, false)
		end
	end
	for _, zone in ChunkManager.GetTimeScaleZones() do
		ChunkManager.RemoveTimeScaleZone(zone.Id)
	end
	for _, chunk in chunks do
		ChunkManager.SetTimeScaleForKey(chunk.Key, chunk.Scale, true)
	end
	for _, zone in zones do
		ChunkManager.AddTimeScaleZone(zone.Id, zone.Position, zone.Radius, zone.Scale)
	end
end)

local function hasEntities(position: Vector3): boolean
	return entityChunks[ChunkManager.ToChunkKey(position)] == true
end

-- Same as Raycast.castMovement's decision: empty space is skipped, otherwise
-- the engine cast with the projectile's filter. True when anything is hit.
local function castHits(from: Vector3, displacement: Vector3, radius: number, filter: number): boolean
	if Occupancy.SegmentClear(from, displacement, radius) then
		return false
	end
	local params = filters[filter]
	if not params then
		return true -- unknown filter: let the serial path cast it
	end
	if radius > 0 then
		return workspace:Spherecast(from, radius, displacement, params) ~= nil
	end
	return workspace:Raycast(from, displacement, params) ~= nil
end

actor:BindToMessageParallel("Sweep", function(frame: number, input: buffer, count: number, uniformTime: boolean, entityKeys: { Vector3 })
	table.clear(entityChunks)
	for _, key in entityKeys do
		entityChunks[key] = true
	end
	local result = buffer.create(Sweep.OutputSize(count))
	for item = 1, count do
		Sweep.Run(input, item, result, uniformTime, castHits, hasEntities)
	end
	output.data = buffer.tostring(result)
	output.count = count
	output.frame = frame
end)
