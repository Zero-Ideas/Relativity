--!strict
--[[
	ProjectileWorkerBootstrap (server)
	Parallel projectile movement workers (see Projectile/Parallel.luau for the
	main-thread side and Projectile/Sweep.luau for the loop they run).

	Run normally, this script creates WORKER_COUNT Actors under
	ProjectileActors, each holding a clone of itself, plus the Results event
	they report through. Inside an Actor it becomes a worker that keeps its
	own mirrors of everything Sweep needs -- chunk time scales and zones
	("TimeWorld"), raycast filters ("Filter"), and its own Occupancy bake --
	and on each "Sweep" message runs its batch in parallel, then fires its
	result buffer (plus the frame it belongs to) through the "Results"
	BindableEvent next to the actors -- one copy, no strings. It arrives
	before that frame's Heartbeat, where Parallel.Apply reads it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- More workers than cores is fine (the parallel phase spreads them over the
-- engine's threads) and evens out the slowest batch; each costs a Luau VM and
-- its own occupancy copy.
local WORKER_COUNT = 6

local actor = script:GetActor()
if not actor then
	local folder = script.Parent:FindFirstChild("ProjectileActors")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ProjectileActors"
		folder.Parent = script.Parent
	end
	if not folder:FindFirstChild("Results") then
		local results = Instance.new("BindableEvent")
		results.Name = "Results"
		results.Parent = folder
	end
	if not folder:FindFirstChild("OccupancyHello") then
		local hello = Instance.new("BindableEvent")
		hello.Name = "OccupancyHello" -- a worker is listening: send it every shape so far
		hello.Parent = folder
	end
	if not folder:FindFirstChildWhichIsA("Actor") then
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
-- (tells Occupancy it's a worker's copy: it takes the main thread's shape
-- probes instead of running its own -- see Occupancy.ApplyShape)
_G.__RelativityOccupancyWorker = true
local Occupancy = require(projectileModule:WaitForChild("Occupancy"))
local results = (actor.Parent :: Instance):WaitForChild("Results") :: BindableEvent

local filters: { [number]: RaycastParams } = {}
local filterIgnores: { [number]: { [Instance]: boolean } } = {} -- filter id -> its excluded instances (for Occupancy)

actor:BindToMessage("OccupancyShape", function(part: BasePart, boxes: { Vector3 })
	Occupancy.ApplyShape(part, boxes)
end)
-- now that it's bound, ask for every shape the main thread already sent
-- (Actor messages sent before a handler is bound are dropped)
task.defer(function()
	((actor.Parent :: Instance):WaitForChild("OccupancyHello") :: BindableEvent):Fire(actor)
end)
local specs: { [number]: Sweep.MotionSpec } = {}

-- Motion spec `id` (a projectile's per-shot constants, see Sweep.MotionSpec).
-- Like filters, only used from the frame after it's sent.
actor:BindToMessageParallel("Motion", function(id: number, spec: Sweep.MotionSpec)
	specs[id] = spec
end)
local entityChunks: { [Vector3]: boolean } = {}

-- Raycast filter `id` (a projectile's movement RaycastParams, by content).
-- A SERIAL handler: setting FilterDescendantsInstances isn't allowed in
-- parallel. Filters are only used from the frame after they're sent; until
-- one arrives, castHits reports a contact and the serial path casts it.
actor:BindToMessage("Filter", function(id: number, instances: { Instance }, ignoreWater: boolean, group: string)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = instances
	params.IgnoreWater = ignoreWater
	params.CollisionGroup = group
	filters[id] = params
	local set = {}
	for _, instance in instances do
		set[instance] = true
	end
	filterIgnores[id] = set
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
-- The cast's RaycastResult when it hits something (true when it can't be
-- cast here), else nil.
local function castHits(from: Vector3, displacement: Vector3, radius: number, filter: number): any
	if Occupancy.SegmentClear(from, displacement, radius, filterIgnores[filter]) then
		return nil
	end
	local params = filters[filter]
	if not params then
		return true -- unknown filter: let the serial path cast it
	end
	if radius > 0 then
		return workspace:Spherecast(from, radius, displacement, params)
	end
	return workspace:Raycast(from, displacement, params)
end

-- This batch's contacts, handed back with the results so the main thread can
-- resolve them without casting the same segment again (columns, by order of
-- item).
local contacts = { Item = {}, From = {}, Displacement = {}, Instance = {}, Position = {}, Normal = {}, Distance = {} }
local function onContact(item: number, from: Vector3, displacement: Vector3, hit: RaycastResult)
	local n = #contacts.Item + 1
	contacts.Item[n], contacts.From[n], contacts.Displacement[n] = item, from, displacement
	contacts.Instance[n], contacts.Position[n], contacts.Normal[n], contacts.Distance[n] =
		hit.Instance, hit.Position, hit.Normal, hit.Distance
end

actor:BindToMessageParallel("Sweep", function(frame: number, input: buffer, count: number, uniformTime: boolean, entityKeys: { Vector3 })
	local started = os.clock()
	table.clear(entityChunks)
	for _, key in entityKeys do
		entityChunks[key] = true
	end
	local result = buffer.create(Sweep.OutputSize(count))
	for _, column in contacts do
		table.clear(column)
	end
	for item = 1, count do
		Sweep.Run(input, item, result, uniformTime, specs, castHits, hasEntities, onContact)
	end
	local ms = (os.clock() - started) * 1000 -- how long this batch took (Stats tab)
	local occupancy = Occupancy.TakeStats()
	task.synchronize()
	results:Fire(workerId, frame, count, ms, result, occupancy.Checks, occupancy.Skipped, {
		occupancy.NotReady, occupancy.TooWide, occupancy.OutsideTerrain, occupancy.Blocked, occupancy.BlockedMoving,
		occupancy.DynamicParts, occupancy.LargestDynamic,
	}, contacts)
end)
