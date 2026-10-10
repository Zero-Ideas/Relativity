--!strict
--[[
	ProjectileWorkerBootstrap (server)
	Parallel projectile movement workers (see Projectile/Parallel.luau for the
	main-thread side and Projectile/Sweep.luau for the loop they run).

	Run normally, this script creates WORKER_COUNT Actors under
	ProjectileActors, each holding a clone of itself, plus the Results event
	they report through. Inside an Actor it becomes a worker that keeps its
	own mirrors of everything Sweep needs -- chunk time scales and zones
	("TimeWorld"), raycast filters ("Filter"), and imported Occupancy masks --
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
		hello.Name = "OccupancyHello" -- a worker is listening: send it the baked grid
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
local CollisionLOD = require(projectileModule:WaitForChild("CollisionLOD"))
-- Workers import centrally baked masks; they never probe shapes/read terrain.
_G.__RelativityOccupancyWorker = true
local Occupancy = require(projectileModule:WaitForChild("Occupancy"))
local results = (actor.Parent :: Instance):WaitForChild("Results") :: BindableEvent

local filters: { [number]: RaycastParams } = {}
local filterIgnores: { [number]: { [Instance]: boolean } } = {} -- filter id -> its excluded instances (for Occupancy)

local occupancySnapshotRequested = false
actor:BindToMessage("OccupancyBake", function(update)
	if Occupancy.ApplyBake(update) then
		occupancySnapshotRequested = false
	elseif not occupancySnapshotRequested then
		occupancySnapshotRequested = true
		((actor.Parent :: Instance):WaitForChild("OccupancyHello") :: BindableEvent):Fire(actor)
	end
end)
-- now that it's bound, ask for the complete grid the main thread already baked
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
-- engine casts this batch made (the Stats tab's sphere / ray counts)
local sphereCasts, rayCasts = 0, 0

-- Where a batch's time goes (the analytics stream's WorkerProfile): one item
-- in SAMPLE is timed in detail -- its whole Sweep.Run, its occupancy checks,
-- its engine casts -- and the split is scaled to the whole loop, so the
-- clock calls don't distort the loop being measured.
local SAMPLE = 16
local sampling = false
local phaseTiming = { 0, 0, 0, 0, 0, 0, 0, 0 }
local sampledOccupancy, sampledEngine = 0, 0
local lastWait, lastFire = 0, 0 -- (the previous batch: synchronize wait, results:Fire; ms)

local function castHits(from: Vector3, displacement: Vector3, radius: number, filter: number, nearEntities: boolean): any
	local t0 = if sampling then os.clock() else 0
	if Occupancy.SegmentClear(from, displacement, radius, filterIgnores[filter]) then
		if sampling then
			sampledOccupancy += os.clock() - t0
		end
		return nil
	end
	local t1 = if sampling then os.clock() else 0
	if sampling then
		sampledOccupancy += t1 - t0
	end
	local params = filters[filter]
	if not params then
		return true -- unknown filter: let the serial path cast it
	end
	local hit
	if radius > 0 then
		-- Reuse the entity-chunk snapshot already sent for adaptive stepping.
		if not nearEntities then
			radius = CollisionLOD.Radius(entityChunks, ChunkManager.ChunkSize, ChunkManager.UseY, from, displacement, radius)
		end
	end
	if radius > 0 then
		sphereCasts += 1
		hit = workspace:Spherecast(from, radius, displacement, params)
	else
		rayCasts += 1
		hit = workspace:Raycast(from, displacement, params)
	end
	if sampling then
		sampledEngine += os.clock() - t1
	end
	return hit
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

-- This worker's resident slots (see Parallel): the input records it keeps
-- between frames, each one's time scale, real-time deadline and homing
-- timers. Main sends edits (Sweep.OpSet / OpMove / OpReset) with each frame.
local IN, OUT = Sweep.InputStride, Sweep.OutputStride
local IN_MOTION, IN_AGE, IN_REMAINING = Sweep.InputMotion, Sweep.InputAge, Sweep.InputRemaining
local OUT_POSITION, OUT_AGE, OUT_REMAINING = Sweep.OutPosition, Sweep.OutAge, Sweep.OutRemaining
local HOMING_IN, HOMING_OUT = Sweep.HomingInStride, Sweep.HomingOutStride
local SET_BYTES, MOVE_BYTES = Sweep.SetOpBytes, Sweep.MoveOpBytes
local SET_SCALE, SET_DEADLINE, SET_TIMERS = Sweep.SetOpScale, Sweep.SetOpDeadline, Sweep.SetOpTimers
local LIMIT = require(Shared:WaitForChild("SafeMath")).Limit
local DONE = Sweep.Done
local bufferCopy, readf64, writef64, readf32, readu8, readu32 =
	buffer.copy, buffer.readf64, buffer.writef64, buffer.readf32, buffer.readu8, buffer.readu32

local capacity = 0
local records = buffer.create(0)
local scales = buffer.create(0)
local deadlines = buffer.create(0)
local timers = buffer.create(0)

local function ensure(count: number)
	if count <= capacity then
		return
	end
	local grown = math.max(count, capacity * 2, 256)
	local function grow(old: buffer, stride: number): buffer
		local new = buffer.create(grown * stride)
		bufferCopy(new, 0, old, 0, capacity * stride)
		return new
	end
	records, scales, deadlines, timers = grow(records, IN), grow(scales, 8), grow(deadlines, 8), grow(timers, 24)
	capacity = grown
end

local function applyOps(ops: buffer)
	local size = buffer.len(ops)
	local p = 0
	while p < size do
		local op = readu8(ops, p)
		if op == Sweep.OpSet then
			local item = readu32(ops, p + 1)
			ensure(item)
			local i = item - 1
			bufferCopy(records, i * IN, ops, p + 5, IN)
			writef64(scales, i * 8, readf64(ops, p + SET_SCALE))
			writef64(deadlines, i * 8, readf64(ops, p + SET_DEADLINE))
			bufferCopy(timers, i * 24, ops, p + SET_TIMERS, 24)
			p += SET_BYTES
		elseif op == Sweep.OpMove then
			local to, from = readu32(ops, p + 1) - 1, readu32(ops, p + 5) - 1
			bufferCopy(records, to * IN, records, from * IN, IN)
			bufferCopy(scales, to * 8, scales, from * 8, 8)
			bufferCopy(deadlines, to * 8, deadlines, from * 8, 8)
			bufferCopy(timers, to * 24, timers, from * 24, 24)
			p += MOVE_BYTES
		else
			p += 1 -- (reset: the new count says how many are live)
		end
	end
end

actor:BindToMessageParallel("Sweep", function(frame: number, ops: buffer?, count: number, globalDt: number, now: number,
	uniformTime: boolean, entityKeys: { Vector3 }, homingIn: buffer?, homingFrame: Sweep.HomingFrame?)
	local started = os.clock()
	if ops then
		applyOps(ops)
	end
	ensure(count)
	if count == 0 then
		return
	end
	-- this frame's budget on top of each slot's carried debt
	for item = 1, count do
		local o = (item - 1) * IN + IN_REMAINING
		writef64(records, o, readf64(records, o) + globalDt * readf64(scales, (item - 1) * 8))
	end
	-- homing items' timers (kept here) into this frame's homing input
	if homingIn then
		for item = 1, count do
			local h = (item - 1) * HOMING_IN
			if readu8(homingIn, h) ~= 0 then
				bufferCopy(homingIn, h + 24, timers, (item - 1) * 24, 24)
			end
		end
	end
	table.clear(entityChunks)
	for _, key in entityKeys do
		entityChunks[key] = true
	end
	local result = buffer.create(Sweep.OutputSize(count))
	for _, column in contacts do
		table.clear(column)
	end
	local homingOut = if homingIn then buffer.create(count * Sweep.HomingOutStride) else nil
	Occupancy.BeginBatch()
	local loopStarted = os.clock()
	local sampledRun = 0
	sampledOccupancy, sampledEngine = 0, 0
	for index = 1, #phaseTiming do
		phaseTiming[index] = 0
	end
	local exceptions: { number } = {}
	local changes: { number } = {}
	for item = 1, count do
		local i = item - 1
		if not (now < readf64(deadlines, i * 8)) then
			-- past MaxRealLifetime: hand it back as it stands (the serial code expires it)
			local r = i * IN
			local position = Vector3.new(readf32(records, r + 8), readf32(records, r + 12), readf32(records, r + 16))
			local velocity = Vector3.new(readf32(records, r + 20), readf32(records, r + 24), readf32(records, r + 28))
			Sweep.WriteOutput(result, item, Sweep.Contact, position, velocity, readf64(records, r + IN_AGE),
				readf64(records, r + IN_REMAINING), 0)
			table.insert(exceptions, item)
			continue
		end
		if item % SAMPLE == 0 then
			sampling = true
			local t = os.clock()
			Sweep.Run(records, item, result, uniformTime, specs, castHits, hasEntities, onContact, homingIn, homingOut, homingFrame,
				phaseTiming)
			sampledRun += os.clock() - t
			sampling = false
		else
			Sweep.Run(records, item, result, uniformTime, specs, castHits, hasEntities, onContact, homingIn, homingOut, homingFrame)
		end
		local o = i * OUT
		local homes = homingOut ~= nil and homingIn ~= nil and readu8(homingIn :: buffer, i * HOMING_IN) ~= 0
		if homes then
			local change = readf64(homingOut :: buffer, i * HOMING_OUT + 24)
			if change ~= 0 then
				table.insert(changes, item)
				table.insert(changes, change)
			end
		end
		if readu8(result, o) == DONE then
			local px, py, pz = readf32(result, o + OUT_POSITION), readf32(result, o + OUT_POSITION + 4), readf32(result, o + OUT_POSITION + 8)
			if math.abs(px) <= LIMIT and math.abs(py) <= LIMIT and math.abs(pz) <= LIMIT then
				-- plain: it carries on from here next frame (kept in this record)
				local r = i * IN
				bufferCopy(records, r + IN_MOTION, result, o + OUT_POSITION, 24)
				writef64(records, r + IN_AGE, readf64(result, o + OUT_AGE))
				writef64(records, r + IN_REMAINING, readf64(result, o + OUT_REMAINING))
				if homes then
					bufferCopy(timers, i * 24, homingOut :: buffer, i * HOMING_OUT, 24)
				end
				continue
			end
		end
		table.insert(exceptions, item)
	end
	local loopEnded = os.clock()
	Occupancy.EndBatch()
	local loop = loopEnded - loopStarted
	-- substeps run (the guard byte of every result)
	local substeps = 0
	local outStride = Sweep.OutputStride
	for item = 1, count do
		substeps += buffer.readu8(result, (item - 1) * outStride + 1)
	end
	local scale = if sampledRun > 0 then loop / sampledRun else 0
	local occupancyTime, engineTime = sampledOccupancy * scale, sampledEngine * scale
	local ms = (loopEnded - started) * 1000 -- how long this batch took (Stats tab)
	local occupancy = Occupancy.TakeStats()
	local profile = {
		WSetup = (loopStarted - started) * 1000,
		WOccupancy = occupancyTime * 1000,
		WEngine = engineTime * 1000,
		WPlanIntegrate = math.max(loop - occupancyTime - engineTime, 0) * 1000,
		WSyncWait = lastWait,
		WFire = lastFire,
		WItemsCount = count,
		WContactsCount = #contacts.Item,
		WSubstepsCount = substeps,
		-- (the plan/integrate share, split: sampled phases scaled like the rest)
		WRunReads = phaseTiming[1] * scale * 1000,
		WRunSample = phaseTiming[2] * scale * 1000,
		WRunEntityCheck = phaseTiming[3] * scale * 1000,
		WRunStepDt = phaseTiming[4] * scale * 1000,
		WRunHoming = phaseTiming[5] * scale * 1000,
		WRunIntegrate = phaseTiming[6] * scale * 1000,
		WRunWrite = phaseTiming[7] * scale * 1000,
		WRunStraight = phaseTiming[8] * scale * 1000,
		WExceptionsCount = #exceptions,
		WOpsKBCount = if ops then buffer.len(ops) / 1024 else 0,
	}
	local handoffStarted = os.clock()
	task.synchronize()
	local fireStarted = os.clock()
	lastWait = (fireStarted - handoffStarted) * 1000
	results:Fire(workerId, frame, count, ms, result, occupancy.Checks, occupancy.Skipped, {
		occupancy.NotReady, occupancy.TooWide, occupancy.OutsideTerrain, occupancy.Blocked, occupancy.BlockedMoving,
		occupancy.DynamicParts, occupancy.LargestDynamic, sphereCasts, rayCasts,
	}, contacts, homingOut, exceptions, changes, profile)
	lastFire = (os.clock() - fireStarted) * 1000
	sphereCasts, rayCasts = 0, 0
end)
