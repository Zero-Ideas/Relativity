--!strict
--!native
--!optimize 2
--[[
	Projectile/Parallel.luau
	Main-thread side of parallel projectile movement.

	Each worker Actor owns a batch of SLOTS. A slot holds one projectile's
	packed movement record (Sweep's input layout) and what the projectile
	looked like after the last frame, and it persists across frames: a
	projectile that just flies is packed once, and from then on its record is
	updated straight from the worker's output. So the per-frame main-thread
	cost is a pass over compact arrays plus the applier, instead of re-reading
	every projectile table (which, at tens of thousands of projectiles, is
	mostly cache misses).

	  Offer()                 a projectile that stepped serially (or was just
	                          made) asks for a slot; it's queued.
	  PreSimulation (serial)  Dispatch(): queued projectiles that are eligible --
	                          no homing, no lag compensation, not frozen,
	                          finite state, raycast filter already known to the
	                          workers -- are packed into the emptiest batch;
	                          then every slot's step budget is written and each
	                          batch is sent off.
	  parallel phase          workers (ProjectileWorkerBootstrap) run Sweep.Run:
	                          plan, cast, integrate, stop at the first contact.
	  Heartbeat (serial)      Apply(): results of THIS frame's batches go to
	                          Projectile's applier, which says what happens to
	                          the slot: Keep (the slot takes the result),
	                          Refresh (the serial code finished the frame:
	                          repack, or release if no longer eligible) or Drop
	                          (dead: release). A late batch is released whole.

	Anything changed behind a slot's back (an ability moved it, it gained
	homing, time scales changed...) is caught by the applier comparing the
	projectile with the slot, and stepped serially -- so the slot never has to
	be told.

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
local Profile = require(script.Parent.Profile)

local Parallel = {}

Parallel.Enabled = true
Parallel.MinProjectiles = 32 -- below this, dispatch overhead isn't worth it

-- What an applier returns for a result (see Parallel.Apply).
Parallel.Drop = 0 -- dead: release the slot
Parallel.Keep = 1 -- moved exactly as the worker said: the slot takes the result
Parallel.Refresh = 2 -- alive, but the serial code finished the frame: repack or release
local DROP, KEEP, REFRESH = Parallel.Drop, Parallel.Keep, Parallel.Refresh

-- projectile._parallelState
local QUEUED, SLOTTED = 1, 2

local IN, OUT = Sweep.InputStride, Sweep.OutputStride
local IN_MOTION, OUT_MOTION = Sweep.InputMotion, Sweep.OutputMotion
local IN_AGE, IN_REMAINING = Sweep.InputAge, Sweep.InputRemaining
local MIN_CAPACITY = 64
local writef64, bufferCopy = buffer.writef64, buffer.copy

type Worker = { Actor: Actor, Output: SharedTable }

-- Receives one finished result and says what happens to its slot: the
-- projectile, the result (status, position, velocity, age, remaining,
-- guard), what it looked like when the worker started (position, velocity,
-- age, debt, scale), its real-time deadline, and the dispatch's time version
-- and uniform-time flag.
export type Applier = (projectile: any, status: number, position: Vector3, velocity: Vector3, age: number,
	remaining: number, guard: number, fromPosition: Vector3, fromVelocity: Vector3, fromAge: number,
	fromDebt: number, fromScale: number, deadline: number, timeVersion: number, uniform: boolean) -> number

-- A worker's slots, item 1..Count (compact: released slots are swap-removed).
type Batch = {
	Count: number,
	Sent: number, -- items dispatched this frame (0: nothing to apply)
	Capacity: number,
	Input: buffer,
	Projectiles: { any },
	Position: { Vector3 },
	Velocity: { Vector3 },
	Age: { number },
	Debt: { number },
	Scale: { number },
	Deadline: { number }, -- os.clock() past which MaxRealLifetime is up
}

local workers: { Worker } = {}
local frame = 0
local sentTimeVersion = -1
local filterIds: { [any]: any } = {} -- instance trie -> { [flags]: id }
local filterReady: { [number]: number } = {} -- id -> first frame workers have it
local nextFilterId = 0
local batches: { Batch } = {}
local batchUniform = true
local batchTimeVersion = 0
local running = false -- the last Dispatch sent batches
local queue: { any } = {}
local scaleOf: (any) -> number? = function()
	return nil
end
local released: { number } = {} -- scratch for Apply

local stats = { Parallel = 0, Resumed = 0, Serial = 0, Fallback = 0, Late = 0, Frames = 0, SlowestWorkerMs = 0, WorkerMs = 0, AppliedFrames = 0 }

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

--------------------------------------------------------------------------------
-- Slots
--------------------------------------------------------------------------------

local function newBatch(): Batch
	return {
		Count = 0, Sent = 0, Capacity = MIN_CAPACITY, Input = buffer.create(Sweep.InputSize(MIN_CAPACITY)),
		Projectiles = {}, Position = {}, Velocity = {}, Age = {}, Debt = {}, Scale = {}, Deadline = {},
	}
end

-- Resizes a batch's input buffer, keeping its records.
local function resize(batch: Batch, capacity: number)
	local input = buffer.create(Sweep.InputSize(capacity))
	bufferCopy(input, 0, batch.Input, 0, batch.Count * IN)
	batch.Input, batch.Capacity = input, capacity
end

-- Packs `projectile` into slot `item` (new or reused) with its current state.
local function pack(batch: Batch, item: number, projectile: any, filter: number, scale: number)
	batch.Projectiles[item] = projectile
	batch.Position[item] = projectile.Position
	batch.Velocity[item] = projectile.Velocity
	batch.Age[item] = projectile.Age
	batch.Debt[item] = projectile._simulationDebt
	batch.Scale[item] = scale
	batch.Deadline[item] = projectile._spawnRealTime + projectile.MaxRealLifetime
	-- remaining is written at each dispatch
	Sweep.WriteInput(batch.Input, item, item, filter, projectile, 0)
end

-- Its scale and filter id if it may have a slot right now, else nil.
local function eligible(projectile: any): (number?, number?)
	local scale = scaleOf(projectile)
	if not scale then
		return nil, nil
	end
	local filter = projectile._filterId
	if not filter or filterReady[filter] > frame then
		filter = filterFor(projectile)
	end
	return scale, filter
end

-- Swap-removes slot `item`.
local function release(batch: Batch, item: number)
	local last = batch.Count
	local projectiles = batch.Projectiles
	projectiles[item]._parallelState = nil
	if item ~= last then
		local input = batch.Input
		local o = (item - 1) * IN
		bufferCopy(input, o, input, (last - 1) * IN, IN)
		writef64(input, o, item) -- (the record's index slot)
		projectiles[item] = projectiles[last]
		batch.Position[item] = batch.Position[last]
		batch.Velocity[item] = batch.Velocity[last]
		batch.Age[item] = batch.Age[last]
		batch.Debt[item] = batch.Debt[last]
		batch.Scale[item] = batch.Scale[last]
		batch.Deadline[item] = batch.Deadline[last]
	end
	projectiles[last] = nil
	batch.Count = last - 1
end

local function releaseBatch(batch: Batch)
	local projectiles = batch.Projectiles
	for item = 1, batch.Count do
		projectiles[item]._parallelState = nil
		projectiles[item] = nil
	end
	batch.Count, batch.Sent = 0, 0
end

-- Empties every slot and the queue (parallel movement paused or off).
local function releaseAll()
	for _, batch in batches do
		releaseBatch(batch)
	end
	for _, projectile in queue do
		projectile._parallelState = nil
	end
	table.clear(queue)
end

-- `fn(projectile)`: its combined time scale when it may move in parallel,
-- else nil. Called when a projectile is packed or repacked.
function Parallel.SetEligibility(fn: (any) -> number?)
	scaleOf = fn
end

-- Asks for a slot for `projectile` (call after it stepped serially or was
-- created). Packed at the next Dispatch if it's still eligible then.
function Parallel.Offer(projectile: any)
	if running and not projectile._parallelState then
		projectile._parallelState = QUEUED
		table.insert(queue, projectile)
	end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

-- Packs queued projectiles and sends this frame's batches. `allowed` false
-- (e.g. debug rays on) pauses parallel movement: every slot is released and
-- everything steps serially.
function Parallel.Dispatch(activeCount: number, globalDt: number, allowed: boolean)
	local clock = os.clock
	local setupStarted = clock()
	for _, batch in batches do
		batch.Sent = 0
	end
	refreshWorkers()
	local workerCount = #workers
	running = Parallel.Enabled and allowed and workerCount > 0 and activeCount >= Parallel.MinProjectiles and globalDt > 0
	if not running then
		releaseAll()
		return
	end
	frame += 1
	syncTimeWorld()
	batchTimeVersion = ChunkManager.GetTimeVersion()
	batchUniform = ChunkManager.IsTimeUniform()
	for w = 1, workerCount do
		local batch = batches[w]
		if not batch then
			batches[w] = newBatch()
		elseif batch.Capacity > MIN_CAPACITY and batch.Count * 4 < batch.Capacity then
			-- (the whole buffer is copied to the worker each frame)
			resize(batch, math.max(MIN_CAPACITY, batch.Count * 2))
		end
	end

	-- the queue: into the emptiest batch
	local acquireStarted = clock()
	local acquired = 0
	for _, projectile in queue do
		projectile._parallelState = nil
		if projectile.Dead then
			continue
		end
		local scale, filter = eligible(projectile)
		if not scale or not filter then
			continue
		end
		local batch = batches[1]
		for w = 2, workerCount do
			if batches[w].Count < batch.Count then
				batch = batches[w]
			end
		end
		local item = batch.Count + 1
		if item > batch.Capacity then
			resize(batch, batch.Capacity * 2)
		end
		batch.Count = item
		pack(batch, item, projectile, filter, scale)
		projectile._parallelState = SLOTTED
		acquired += 1
	end
	table.clear(queue)

	-- this frame's step budget for every slot
	local loopStarted = clock()
	for w = 1, workerCount do
		local batch = batches[w]
		local input, debts, scales = batch.Input, batch.Debt, batch.Scale
		for item = 1, batch.Count do
			writef64(input, (item - 1) * IN + IN_REMAINING, globalDt * scales[item] + debts[item])
		end
	end

	local sendStarted = clock()
	local keys = entityChunkKeys()
	local slots = 0
	for w = 1, workerCount do
		local batch = batches[w]
		local count = batch.Count
		slots += count
		if count > 0 then
			batch.Sent = count
			workers[w].Actor:SendMessage("Sweep", frame, batch.Input, count, batchUniform, keys)
		end
	end
	stats.Frames += 1
	Profile.Add("DispatchSetup", acquireStarted - setupStarted)
	Profile.Add("DispatchAcquire", loopStarted - acquireStarted)
	Profile.Add("DispatchLoop", sendStarted - loopStarted)
	Profile.Add("DispatchSend", clock() - sendStarted)
	Profile.Count("Slots", slots)
	Profile.Count("Acquired", acquired)
end

-- Hands every finished result of this frame to `apply`, straight from the
-- workers' buffers (no per-projectile tables), and updates or releases each
-- slot by its answer. Batches a worker hasn't finished (or never got) are
-- released -- those projectiles just step serially and are offered again.
function Parallel.Apply(apply: Applier)
	local clock = os.clock
	local SAMPLE = Profile.SAMPLE
	local decodeTime, loopTime, readTime, applyTime, releaseTime, applied, sampled, releases = 0, 0, 0, 0, 0, 0, 0, 0
	local slowest, total, any = 0, 0, false
	for w, batch in batches do
		local count = batch.Sent
		if count == 0 then
			continue
		end
		batch.Sent = 0
		local worker = workers[w]
		local outputTable = worker and worker.Output
		if not outputTable or outputTable.frame ~= frame or outputTable.count ~= count then
			stats.Late += count
			releases += batch.Count
			releaseBatch(batch)
			continue
		end
		local decodeStarted = clock()
		local ms = tonumber(outputTable.ms) or 0
		slowest, total, any = math.max(slowest, ms), total + ms, true
		local data = buffer.fromstring(outputTable.data :: string)
		local input = batch.Input
		local projectiles, positions, velocities, ages, debts, scales, deadlines =
			batch.Projectiles, batch.Position, batch.Velocity, batch.Age, batch.Debt, batch.Scale, batch.Deadline
		local loopStarted = clock()
		decodeTime += loopStarted - decodeStarted
		local dropped = 0
		-- One result in SAMPLE has its read and its applier timed (Profile.luau).
		local tick = 0
		for item = 1, count do
			tick += 1
			local timed = tick == SAMPLE
			local t0 = 0
			if timed then
				tick = 0
				sampled += 1
				t0 = clock()
			end
			local status, position, velocity, age, remaining, guard = Sweep.ReadOutputValues(data, item)
			local t1 = 0
			if timed then
				t1 = clock()
			end
			local projectile = projectiles[item]
			local outcome = apply(projectile, status, position, velocity, age, remaining, guard,
				positions[item], velocities[item], ages[item], debts[item], scales[item], deadlines[item],
				batchTimeVersion, batchUniform)
			if outcome == KEEP then
				positions[item], velocities[item], ages[item], debts[item] = position, velocity, age, remaining
				local o = (item - 1) * IN
				bufferCopy(input, o + IN_MOTION, data, (item - 1) * OUT + OUT_MOTION, 48)
				writef64(input, o + IN_AGE, age)
			else
				local keep = false
				if outcome == REFRESH and not projectile.Dead then
					local scale, filter = eligible(projectile)
					if scale and filter then
						pack(batch, item, projectile, filter, scale)
						keep = true
					end
				end
				if not keep then
					dropped += 1
					released[dropped] = item
				end
			end
			if timed then
				local t2 = clock()
				readTime += t1 - t0
				applyTime += t2 - t1
			end
		end
		applied += count
		local releaseStarted = clock()
		loopTime += releaseStarted - loopStarted
		-- backwards, so a swap never moves a slot that's still to be released
		for index = dropped, 1, -1 do
			release(batch, released[index])
		end
		releases += dropped
		releaseTime += clock() - releaseStarted
	end
	Profile.Add("ApplyDecode", decodeTime)
	Profile.Add("ApplyLoop", loopTime)
	Profile.Add("ApplyRelease", releaseTime)
	Profile.Count("Released", releases)
	if sampled > 0 then
		local scaleUp = applied / sampled
		Profile.Add("ApplyRead", readTime * scaleUp)
		Profile.Add("ApplyResult", applyTime * scaleUp)
	end
	if any then
		stats.SlowestWorkerMs += slowest
		stats.WorkerMs += total
		stats.AppliedFrames += 1
	end
end

-- Per-frame totals from the step loop (Resumed: a worker stopped at a contact
-- and the serial code finished the frame).
function Parallel.AddCounts(parallel: number, resumed: number, serial: number, fallback: number)
	stats.Parallel += parallel
	stats.Resumed += resumed
	stats.Serial += serial
	stats.Fallback += fallback
end

-- Counters since the last call, then resets.
function Parallel.TakeStats()
	local snapshot = table.clone(stats)
	snapshot.Workers = #workers
	local frames = math.max(stats.AppliedFrames, 1)
	snapshot.SlowestWorkerMs = stats.SlowestWorkerMs / frames -- per frame, averaged
	snapshot.WorkerMs = stats.WorkerMs / frames
	stats.Parallel, stats.Resumed, stats.Serial, stats.Fallback, stats.Late, stats.Frames = 0, 0, 0, 0, 0, 0
	stats.SlowestWorkerMs, stats.WorkerMs, stats.AppliedFrames = 0, 0, 0
	return snapshot
end

return Parallel
