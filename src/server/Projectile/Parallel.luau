--!strict
--!native
--!optimize 2
--[[
	Projectile/Parallel.luau
	Main-thread side of parallel projectile movement. Each frame:

	  PreSimulation (serial)  Dispatch(): every eligible projectile -- no homing,
	                          no lag compensation, not frozen, finite state, its
	                          raycast filter already known to the workers -- is
	                          packed (Sweep's layout) into batches, one per
	                          worker Actor, and sent off. Its pre-dispatch state
	                          is remembered for validation.
	  parallel phase          workers (ProjectileWorkerBootstrap) run Sweep.Run:
	                          plan, cast, integrate, stop at the first contact.
	  Heartbeat (serial)      Collect(): results of THIS frame's batches, keyed by
	                          projectile, for Projectile's step loop to apply.
	                          Anything changed since dispatch, late, or missing is
	                          simply stepped serially as before.

	Workers mirror what they need: time scales/zones (sent when
	ChunkManager.GetTimeVersion changes), raycast filters (sent once per
	distinct filter, usable from the next frame), and which chunks hold
	entities (with every batch). Each bakes its own Occupancy.

	Worker raycasts run in the parallel phase that follows PreSimulation, i.e.
	against the world as it was before this frame's physics step; the serial
	path casts after it. Static geometry is identical; moving parts can differ
	by one physics step.
]]

local SharedTableRegistry = game:GetService("SharedTableRegistry")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local Sweep = require(script.Parent.Sweep)

local Parallel = {}

Parallel.Enabled = true
Parallel.MinProjectiles = 32 -- below this, dispatch overhead isn't worth it

type Worker = { Actor: Actor, Output: SharedTable }

-- What a dispatched projectile looked like, to reject results it outlived.
export type Dispatched = {
	Position: Vector3,
	Velocity: Vector3,
	Age: number,
	Debt: number,
	Scale: number,
	TimeVersion: number,
}

export type Result = Sweep.Result & { From: Dispatched, Uniform: boolean }

local workers: { Worker } = {}
local frame = 0
local sentTimeVersion = -1
local filterIds: { [any]: any } = {} -- instance trie -> { [flags]: id }
local filterReady: { [number]: number } = {} -- id -> first frame workers have it
local nextFilterId = 0
-- per worker: the projectiles in its current batch, by item
local batches: { { any } } = {}
local dispatched: { [any]: Dispatched } = {}
local batchUniform = true

local stats = { Parallel = 0, Serial = 0, Fallback = 0, Late = 0, Frames = 0 }

local function refreshWorkers()
	if #workers > 0 then
		return
	end
	local root = ServerScriptService:FindFirstChild("ProjectileActors", true)
	if not root then
		return
	end
	for _, child in root:GetChildren() do
		local id = tonumber(string.match(child.Name, "(%d+)$"))
		if child:IsA("Actor") and id then
			local outputTable = SharedTableRegistry:GetSharedTable(`RelativityProjectileSweep{id}`)
			if outputTable then
				table.insert(workers, { Actor = child, Output = outputTable })
			end
		end
	end
	table.sort(workers, function(a, b)
		return a.Actor.Name < b.Actor.Name
	end)
end

-- Filter id for a projectile's movement RaycastParams, by content (beam
-- samples rebuild identical params per packet). New ids are sent to every
-- worker and become usable next frame.
local function filterFor(projectile: any): number?
	local cached = projectile._filterId
	if cached then
		return if filterReady[cached] and filterReady[cached] <= frame then cached else nil
	end
	local params: RaycastParams = projectile._rayParams
	local instances = params.FilterDescendantsInstances
	local node = filterIds
	for _, instance in instances do
		local nextNode = node[instance]
		if not nextNode then
			nextNode = {}
			node[instance] = nextNode
		end
		node = nextNode
	end
	local flags = `{params.IgnoreWater}|{params.CollisionGroup}`
	local id = node[flags]
	if not id then
		nextFilterId += 1
		id = nextFilterId
		node[flags] = id
		filterReady[id] = frame + 1
		for _, worker in workers do
			worker.Actor:SendMessage("Filter", id, instances, params.IgnoreWater, params.CollisionGroup)
		end
	end
	projectile._filterId = id
	return if filterReady[id] <= frame then id else nil
end

local function syncTimeWorld()
	local version = ChunkManager.GetTimeVersion()
	if version == sentTimeVersion then
		return
	end
	sentTimeVersion = version
	local chunks = {}
	for _, chunk in ChunkManager.GetAllChunks() do
		if chunk.TimeScale ~= 1 then
			table.insert(chunks, { Key = chunk.Key, Scale = chunk.TimeScale })
		end
	end
	local zones = {}
	for _, zone in ChunkManager.GetTimeScaleZones() do
		table.insert(zones, { Id = zone.Id, Position = zone.Position, Radius = zone.Radius, Scale = zone.Scale })
	end
	for _, worker in workers do
		worker.Actor:SendMessage("TimeWorld", ChunkManager.ChunkSize, ChunkManager.UseY, chunks, zones)
	end
end

local function entityChunkKeys(): { Vector3 }
	local keys = {}
	for _, chunk in ChunkManager.GetAllChunks() do
		if chunk.EntityCount > 0 then
			table.insert(keys, chunk.Key)
		end
	end
	return keys
end

-- Packs and sends this frame's parallel batches. `scaleOf(projectile)` returns
-- its combined time scale when it may go parallel, else nil.
function Parallel.Dispatch(active: { any }, globalDt: number, scaleOf: (any) -> number?)
	table.clear(dispatched)
	for _, batch in batches do
		table.clear(batch)
	end
	refreshWorkers()
	if not Parallel.Enabled or #workers == 0 or #active < Parallel.MinProjectiles or not (globalDt > 0) then
		return
	end
	frame += 1
	syncTimeWorld()
	local timeVersion = ChunkManager.GetTimeVersion()
	batchUniform = ChunkManager.IsTimeUniform()

	-- pick the eligible projectiles
	local chosen = {}
	local filtersOf = {}
	for _, projectile in active do
		local scale = scaleOf(projectile)
		if not scale then
			continue
		end
		local filter = filterFor(projectile)
		if not filter then
			continue
		end
		table.insert(chosen, projectile)
		filtersOf[#chosen] = filter
		dispatched[projectile] = {
			Position = projectile.Position,
			Velocity = projectile.Velocity,
			Age = projectile.Age,
			Debt = projectile._simulationDebt,
			Scale = scale,
			TimeVersion = timeVersion,
		}
	end
	if #chosen == 0 then
		return
	end

	-- even contiguous slices, one batch per worker
	local workerCount = #workers
	local per = math.ceil(#chosen / workerCount)
	local keys = entityChunkKeys()
	for w = 1, workerCount do
		local first = (w - 1) * per + 1
		local last = math.min(w * per, #chosen)
		local batch = batches[w]
		if not batch then
			batch = {}
			batches[w] = batch
		end
		if first > last then
			continue
		end
		local count = last - first + 1
		local input = buffer.create(Sweep.InputSize(count))
		for i = first, last do
			local projectile = chosen[i]
			local from = dispatched[projectile]
			local item = i - first + 1
			batch[item] = projectile
			Sweep.WriteInput(input, item, item, filtersOf[i], projectile, globalDt * from.Scale + from.Debt)
		end
		workers[w].Actor:SendMessage("Sweep", frame, input, count, batchUniform, keys)
	end
	stats.Frames += 1
end

-- This frame's finished results, keyed by projectile. Batches a worker hasn't
-- finished (or never got) are left out and stepped serially.
function Parallel.Collect(): { [any]: Result }
	local results: { [any]: Result } = {}
	for w, batch in batches do
		if #batch == 0 then
			continue
		end
		local worker = workers[w]
		local outputTable = worker and worker.Output
		if not outputTable or outputTable.frame ~= frame or outputTable.count ~= #batch then
			stats.Late += #batch
			continue
		end
		local data = buffer.fromstring(outputTable.data :: string)
		for item, projectile in batch do
			local result = Sweep.ReadOutput(data, item) :: any
			result.From = dispatched[projectile]
			result.Uniform = batchUniform
			results[projectile] = result
		end
	end
	return results
end

-- Bookkeeping from the step loop, for the Stats tab.
function Parallel.Count(kind: "Parallel" | "Serial" | "Fallback")
	stats[kind] += 1
end

-- Counters since the last call, then resets.
function Parallel.TakeStats()
	local snapshot = table.clone(stats)
	snapshot.Workers = #workers
	stats.Parallel, stats.Serial, stats.Fallback, stats.Late, stats.Frames = 0, 0, 0, 0, 0
	return snapshot
end

return Parallel
