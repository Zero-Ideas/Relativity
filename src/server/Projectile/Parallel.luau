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
	updated straight from the worker's output. Together with Store.luau (the
	projectile's own hot fields in a buffer), a projectile that just flies
	costs the main thread only buffer reads and writes per frame -- its table
	(at tens of thousands of projectiles, mostly cache misses) isn't touched.

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
	  Heartbeat (serial)      Apply(): a plain "moved, hit nothing" result for a
	                          projectile nothing touched is written straight
	                          into its Store record and its slot. Anything else
	                          goes to Projectile's applier (the serial code),
	                          which answers Refresh (repack, or release if no
	                          longer eligible) or Drop (dead: release). A late
	                          batch is released whole.

	Anything changed behind a slot's back (an ability moved it, a time scale
	changed...) shows up as the record's Dirty flag or a different scale, and
	the projectile is stepped serially -- so the slot never has to be told.

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
local Store = require(script.Parent.Store)
local Profile = require(script.Parent.Profile)
local SafeMath = require(Shared:WaitForChild("SafeMath"))

local Parallel = {}

Parallel.Enabled = true
Parallel.MinProjectiles = 32 -- below this, dispatch overhead isn't worth it

-- What an applier returns for a result (see Parallel.Apply).
Parallel.Drop = 0 -- dead: release the slot
Parallel.Refresh = 2 -- alive, but the serial code finished the frame: repack or release
local REFRESH = Parallel.Refresh

-- projectile._parallelState
local QUEUED, SLOTTED = 1, 2

local IN, OUT = Sweep.InputStride, Sweep.OutputStride
local IN_MOTION = Sweep.InputMotion
local OUT_STATUS, OUT_POSITION, OUT_VELOCITY = Sweep.OutStatus, Sweep.OutPosition, Sweep.OutVelocity
local OUT_AGE, OUT_REMAINING = Sweep.OutAge, Sweep.OutRemaining
local IN_AGE, IN_REMAINING = Sweep.InputAge, Sweep.InputRemaining
local MIN_CAPACITY = 64
local readf64, writef64, readf32, writef32, bufferCopy = buffer.readf64, buffer.writef64, buffer.readf32, buffer.writef32, buffer.copy
local readu8, readu32, writeu8, band = buffer.readu8, buffer.readu32, buffer.writeu8, bit32.band
local STRIDE = Store.Stride
local S_POSITION, S_VELOCITY, S_AGE, S_DEBT = Store.Position, Store.Velocity, Store.Age, Store.Debt
local S_SCALE, S_MARK, S_SOURCE, S_FLAGS = Store.TimeScale, Store.Mark, Store.Source, Store.Flags
local DEAD_OR_DIRTY = bit32.bor(Store.Dead, Store.Dirty)
local SWEEP_DONE = Sweep.Done
local LIMIT = SafeMath.Limit
local abs = math.abs

type Worker = { Actor: Actor, Output: SharedTable }

-- Receives a result Apply can't take directly and says what happens to its
-- slot (Refresh or Drop): the projectile, the result (status, position,
-- velocity, age, remaining, guard), whether it was changed since it was
-- packed (Dirty), the scale it was sent with, and the dispatch's time version
-- and uniform-time flag.
export type Applier = (projectile: any, status: number, position: Vector3, velocity: Vector3, age: number,
	remaining: number, guard: number, dirty: boolean, fromScale: number, timeVersion: number,
	uniform: boolean) -> number

-- A worker's slots, item 1..Count (compact: released slots are swap-removed).
type Batch = {
	Count: number,
	Sent: number, -- items dispatched this frame (0: nothing to apply)
	Capacity: number,
	Input: buffer,
	Projectiles: { any },
	Slot: { number }, -- its Store record
	Generation: { number }, -- Store.Generation[slot] when packed (a mismatch: released since)
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
local deferred: { number } = {} -- scratch for Apply

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
local filterByParams: { [RaycastParams]: number } = setmetatable({}, { __mode = "k" }) :: any

local function filterFor(projectile: any): number?
	local cached = projectile._filterId
	if cached then
		return if filterReady[cached] and filterReady[cached] <= frame then cached else nil
	end
	local params: RaycastParams = projectile._rayParams
	-- params are shared between projectiles (Raycast.buildRayParams), so most
	-- lookups end here, without reading FilterDescendantsInstances back
	local known = filterByParams[params]
	if known then
		projectile._filterId = known
		return if filterReady[known] <= frame then known else nil
	end
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
	filterByParams[params] = id
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
		Projectiles = {}, Slot = {}, Generation = {}, Scale = {}, Deadline = {},
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
	local slot = projectile._slot
	batch.Projectiles[item] = projectile
	batch.Slot[item] = slot
	batch.Generation[item] = Store.Generation[slot]
	batch.Scale[item] = scale
	batch.Deadline[item] = projectile._spawnRealTime + projectile.MaxRealLifetime
	-- remaining is written at each dispatch
	Sweep.WriteInput(batch.Input, item, item, filter, projectile, 0)
	Store.ClearDirty(slot)
end

-- Its scale and filter id if it may have a slot right now, else nil.
local function eligible(projectile: any): (number?, number?)
	if not projectile._slot then
		return nil, nil -- (released: it's gone)
	end
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
		batch.Slot[item] = batch.Slot[last]
		batch.Generation[item] = batch.Generation[last]
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
	local store = Store.data
	for w = 1, workerCount do
		local batch = batches[w]
		local input, slots, scales = batch.Input, batch.Slot, batch.Scale
		for item = 1, batch.Count do
			local debt = readf64(store, slots[item] * STRIDE + S_DEBT)
			writef64(input, (item - 1) * IN + IN_REMAINING, globalDt * scales[item] + debt)
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

-- The current scale of the projectile in Store record `o` (its own scale
-- times its source's), or nil when anything is unusual -- then the serial
-- code decides (combinedTimeScale).
local function storeScale(store: buffer, o: number): number?
	local own = readf64(store, o + S_SCALE)
	local index = readu32(store, o + S_SOURCE)
	local sourceScale: any = 1
	if index ~= 0 then
		sourceScale = Store.Sources[index].TimeScale
	end
	if type(sourceScale) == "number" and sourceScale >= 0 and own >= 0 and sourceScale < LIMIT and own < LIMIT then
		local scale = sourceScale * own
		if scale < LIMIT then
			return scale
		end
	end
	return nil
end

-- Applies this frame's results. `mark` is the step loop's frame mark (written
-- into the record of every projectile handled here), `now` its os.clock(),
-- `timeVersion` ChunkManager's current time version. A plain "moved, hit
-- nothing" result for an untouched projectile is written straight into its
-- record and slot; anything else goes to `apply` (see Applier). Batches a
-- worker hasn't finished (or never got) are released -- those projectiles
-- just step serially and are offered again.
function Parallel.Apply(apply: Applier, mark: number, now: number, timeVersion: number)
	local clock = os.clock
	local decodeTime, loopTime, slowTime, releaseTime, releases, kept = 0, 0, 0, 0, 0, 0
	local readTime, transferred = 0, 0
	local slowest, total, any = 0, 0, false
	local sameVersion = timeVersion == batchTimeVersion
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
		-- (timed in two parts: copying the string out of the SharedTable, then
		-- into a buffer -- see the Stats tab's decode line)
		local text = outputTable.data :: string
		local readDone = clock()
		local data = buffer.fromstring(text)
		readTime += readDone - decodeStarted
		transferred += #text
		local input = batch.Input
		local projectiles, slots, generations, scales, deadlines =
			batch.Projectiles, batch.Slot, batch.Generation, batch.Scale, batch.Deadline
		local generationOf = Store.Generation
		local loopStarted = clock()
		decodeTime += loopStarted - decodeStarted
		local dropped, slow = 0, 0
		table.clear(released)
		-- Pass 1, buffers only: every plain result for an untouched projectile.
		-- The rest are deferred to pass 2, so the serial code (raycasts,
		-- Step, allocation) doesn't keep evicting this loop's working set.
		local store = Store.data
		for item = 1, count do
			local slot = slots[item]
			if generationOf[slot] ~= generations[item] then
				-- released since (the step loop dropped it): nothing to apply
				dropped += 1
				released[dropped] = item
				continue
			end
			local o = slot * STRIDE
			local out = (item - 1) * OUT
			if readu8(data, out + OUT_STATUS) ~= SWEEP_DONE or band(readu8(store, o + S_FLAGS), DEAD_OR_DIRTY) ~= 0
				or not sameVersion or not (now < deadlines[item]) or storeScale(store, o) ~= scales[item] then
				slow += 1
				deferred[slow] = item
				continue
			end
			-- position/velocity are float32 in both the output and the record
			bufferCopy(store, o + S_POSITION, data, out + OUT_POSITION, 24)
			local age = readf64(data, out + OUT_AGE)
			writef64(store, o + S_AGE, age)
			writef64(store, o + S_DEBT, readf64(data, out + OUT_REMAINING))
			local px, py, pz = readf32(data, out + OUT_POSITION), readf32(data, out + OUT_POSITION + 4),
				readf32(data, out + OUT_POSITION + 8)
			-- and the slot's packed record (f64) for next frame
			local i = (item - 1) * IN + IN_MOTION
			writef64(input, i, px)
			writef64(input, i + 8, py)
			writef64(input, i + 16, pz)
			writef64(input, i + 24, readf32(data, out + OUT_VELOCITY))
			writef64(input, i + 32, readf32(data, out + OUT_VELOCITY + 4))
			writef64(input, i + 40, readf32(data, out + OUT_VELOCITY + 8))
			writef64(input, (item - 1) * IN + IN_AGE, age)
			if abs(px) <= LIMIT and abs(py) <= LIMIT and abs(pz) <= LIMIT then
				writef64(store, o + S_MARK, mark)
				kept += 1
			else
				-- flew past SafeMath.Limit: dies in the step loop
				writef64(store, o + S_MARK, -mark)
				dropped += 1
				released[dropped] = item
			end
		end

		-- Pass 2: the serial code finishes the rest.
		local slowStarted = clock()
		for index = 1, slow do
			local item = deferred[index]
			local projectile = projectiles[item]
			local status, position, velocity, age, remaining, guard = Sweep.ReadOutputValues(data, item)
			local flags = readu8(Store.data, slots[item] * STRIDE + S_FLAGS)
			local outcome = apply(projectile, status, position, velocity, age, remaining, guard,
				band(flags, Store.Dirty) ~= 0, scales[item], batchTimeVersion, batchUniform)
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
		slowTime += clock() - slowStarted
		-- (releases must go highest item first; pass 2 added some out of order)
		if slow > 0 then
			table.sort(released, function(x, y)
				return x < y
			end)
		end
		local releaseStarted = clock()
		loopTime += releaseStarted - loopStarted
		-- backwards, so a swap never moves a slot that's still to be released
		for index = dropped, 1, -1 do
			release(batch, released[index])
		end
		releases += dropped
		releaseTime += clock() - releaseStarted
	end
	stats.Parallel += kept
	Profile.Add("ApplyDecode", decodeTime)
	Profile.Add("DecodeRead", readTime)
	Profile.Add("DecodeBuffer", decodeTime - readTime)
	Profile.Count("TransferKB", transferred / 1024)
	Profile.Add("ApplyLoop", loopTime - slowTime)
	Profile.Add("ApplySlow", slowTime)
	Profile.Add("ApplyRelease", releaseTime)
	Profile.Count("Released", releases)
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
