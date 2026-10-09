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
	entities (with every batch). Occupancy masks are baked once and copied to
	each worker at startup, followed by changed-cell deltas.

	Worker raycasts run in the parallel phase that follows PreSimulation, i.e.
	against the world as it was before this frame's physics step; the serial
	path casts after it. Static geometry is identical; moving parts can differ
	by one physics step.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local Sweep = require(script.Parent.Sweep)
local Store = require(script.Parent.Store)
local ApplyPass = require(script.Parent.ApplyPass)
local Homing = require(script.Parent.Homing)
local Replication = require(script.Parent.Replication)
local Entity = require(Shared:WaitForChild("Entity"))

-- Homing target tags -> a bit each (a spec's TagMask; 0 means any entity).
local tagBits: { [string]: number } = {}
local tagCount = 0
local function tagMaskOf(homing: any): number
	local tags = homing and (homing.TargetTags or (homing.TargetTag and { homing.TargetTag }))
	if not tags then
		return 0
	end
	local mask = 0
	for _, tag in tags do
		local bitValue = tagBits[tag]
		if not bitValue then
			if tagCount >= 30 then
				return -1 -- (too many distinct tags: never matches on a worker)
			end
			tagCount += 1
			bitValue = bit32.lshift(1, tagCount - 1)
			tagBits[tag] = bitValue
		end
		mask = bit32.bor(mask, bitValue)
	end
	return mask
end

-- This frame's homing targets (built at dispatch while anything homes): the
-- entities, their positions and tag bits for the workers, and entity -> index.
local frameTargets: { any } = {}
local frameTargetIndex: { [any]: number } = {}
local homingFrame: Sweep.HomingFrame = { Positions = {}, Bits = {} }

local function buildHomingFrame()
	table.clear(frameTargets)
	table.clear(frameTargetIndex)
	table.clear(homingFrame.Positions)
	table.clear(homingFrame.Bits)
	for _, entity in Entity.GetAll() do
		if entity.IsDestroyed then
			continue
		end
		local bits = 0
		for tag, bitValue in tagBits do
			if entity:HasTag(tag) then
				bits = bit32.bor(bits, bitValue)
			end
		end
		local index = #frameTargets + 1
		frameTargets[index] = entity
		frameTargetIndex[entity] = index
		homingFrame.Positions[index] = entity:GetPosition()
		homingFrame.Bits[index] = bits
	end
end

-- target -> its position this dispatch (many projectiles can hunt one target)
local goalCache: { [any]: Vector3 | false } = {}
local function goalOf(target: any): Vector3?
	if target == nil then
		return nil
	end
	local cached = goalCache[target]
	if cached == nil then
		cached = Homing.targetPosition(target) or false
		goalCache[target] = cached
	end
	return cached or nil
end
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
local S_MOTION, S_TIME, S_MARK, S_SCALE = Store.MotionStride, Store.TimeStride, Store.MarkStride, Store.ScaleStride
local writei32 = buffer.writei32
local DEAD_OR_DIRTY = bit32.bor(Store.Dead, Store.Dirty)
local SWEEP_DONE = Sweep.Done
local LIMIT = SafeMath.Limit
local abs = math.abs

type Worker = { Actor: Actor, Id: number }
-- A worker's latest result, as fired through ProjectileActors.Results.
type Result = { Frame: number, Count: number, Ms: number, Data: buffer?, Checks: number, Skipped: number, Contacts: any,
	HomingOut: buffer? }
local results: { [number]: Result } = {} -- worker id -> latest

-- Receives a result Apply can't take directly and says what happens to its
-- slot (Refresh or Drop): the projectile, the result (status, position,
-- velocity, age, remaining, guard), whether it was changed since it was
-- packed (Dirty), the scale it was sent with, and the dispatch's time version
-- and uniform-time flag.
export type Applier = (projectile: any, status: number, position: Vector3, velocity: Vector3, age: number,
	remaining: number, guard: number, dirty: boolean, fromScale: number, timeVersion: number,
	uniform: boolean, contact: WorkerContact?, homingTimers: { number }?) -> number

-- A worker's contact for a result that stopped at one: the segment it cast
-- and what it hit, so the serial code can resolve it without casting again.
export type WorkerContact = { From: Vector3, Displacement: Vector3, Instance: Instance, Position: Vector3,
	Normal: Vector3, Distance: number }

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
	Homing: { boolean }, -- the item homes (its state goes in HomingIn each dispatch)
	-- (cached at pack, for dispatch: its Homing table, Source, and whether a
	-- custom Filter keeps its target searches on the main thread)
	HomingConfig: { any },
	HomingSource: { any },
	HomingMainSearch: { boolean },
	HomingCount: number,
	HomingIn: buffer?,
}

local workers: { Worker } = {}
local frame = 0
local sentTimeVersion = -1
local filterIds: { [any]: any } = {} -- instance trie -> { [flags]: id }
local filterReady: { [number]: number } = {} -- id -> first frame workers have it
local nextFilterId = 0
local specIds: { [any]: any } = {} -- trie of motion-spec values -> id
local specReady: { [number]: number } = {} -- id -> first frame workers have it
local nextSpecId = 0
local MAX_SPECS = 65535 -- past this many distinct specs, new ones just step serially
local batches: { Batch } = {}
local batchUniform = true
local batchTimeVersion = 0
local running = false -- the last Dispatch sent batches
local inFlight = false -- between a Dispatch and its Apply
local queue: { any } = {}
local scaleOf: (any) -> number? = function()
	return nil
end
local released: { number } = {} -- scratch for Apply
local deferred: { number } = {} -- scratch for Apply
local homingTimers: { number } = { 0, 0, 0 } -- scratch for Apply

local stats = { Parallel = 0, Resumed = 0, Serial = 0, Fallback = 0, Late = 0, Frames = 0, SlowestWorkerMs = 0, WorkerMs = 0,
	AppliedFrames = 0, WorkerChecks = 0, WorkerSkipped = 0 }
-- workers' reasons a cast wasn't skipped: not ready, too wide, outside terrain, blocked, blocked by a moving part
local workerReasons = { 0, 0, 0, 0, 0 }

-- Rescanned whenever an actor is added or removed (the bootstrap may still be
-- creating them when the first dispatch runs). Returns true when the list
-- changed, so Dispatch can release every slot (batches follow worker order).
local workersStale = true
local actorsRoot: Instance? = nil
local resultsConnected = false

local function refreshWorkers(): boolean
	if not workersStale then
		return false
	end
	local root = actorsRoot or ServerScriptService:FindFirstChild("ProjectileActors", true)
	local event = root and root:FindFirstChild("Results")
	if not root or not event then
		return false
	end
	if not actorsRoot then
		actorsRoot = root
		root.ChildAdded:Connect(function()
			workersStale = true
		end)
		root.ChildRemoved:Connect(function()
			workersStale = true
		end)
	end
	workersStale = false
	table.clear(workers)
	for _, child in root:GetChildren() do
		local id = tonumber(string.match(child.Name, "(%d+)$"))
		if child:IsA("Actor") and id then
			table.insert(workers, { Actor = child, Id = id })
		end
	end
	table.sort(workers, function(x, y)
		return x.Id < y.Id
	end)
	if not resultsConnected then
		resultsConnected = true
		local resultsEvent = event :: BindableEvent
		resultsEvent.Event:Connect(function(id: number, resultFrame: number, count: number, ms: number,
			data: buffer, checks: number, skipped: number, reasons: { number }?, contacts: any, homingOut: buffer?)
			local result = results[id]
			if not result then
				result = { Frame = 0, Count = 0, Ms = 0, Data = nil, Checks = 0, Skipped = 0, Contacts = nil, HomingOut = nil }
				results[id] = result
			end
			result.Frame, result.Count, result.Ms, result.Data = resultFrame, count, ms, data
			result.Contacts = contacts
			result.HomingOut = homingOut
			stats.WorkerChecks += checks
			stats.WorkerSkipped += skipped
			if reasons then
				for index = 1, 5 do
					workerReasons[index] += reasons[index] or 0
				end
				-- (6: that worker's moving-part count; the largest is kept)
				workerReasons[6] = math.max(workerReasons[6] or 0, reasons[6] or 0)
				workerReasons[7] = reasons[7] or workerReasons[7] -- (7: a worker's largest moving part, by name)
			end
		end)
	end
	return true
end

-- Filter id for a projectile's movement RaycastParams, by content (beam
-- samples rebuild identical params per packet). New ids are sent to every
-- worker and become usable next frame.
local filterByParams: { [RaycastParams]: number } = setmetatable({}, { __mode = "k" }) :: any

local function filterFor(projectile: any): number?
	local params: RaycastParams = projectile._rayParams
	-- params are shared between projectiles (Raycast.buildRayParams), so most
	-- lookups end here, without reading FilterDescendantsInstances back (and
	-- nothing is written to the projectile, which for an efficient one would
	-- mean a per-projectile override table)
	local known = filterByParams[params]
	if known then
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
	for key in ChunkManager.GetEntityChunkMask() do
		table.insert(keys, key)
	end
	return keys
end

--------------------------------------------------------------------------------
-- Slots
--------------------------------------------------------------------------------

local function newBatch(): Batch
	return {
		Count = 0, Sent = 0, Capacity = MIN_CAPACITY, Input = buffer.create(Sweep.InputSize(MIN_CAPACITY)),
		Projectiles = {}, Slot = {}, Generation = {}, Scale = {}, Deadline = {}, Homing = {}, HomingCount = 0, HomingIn = nil,
		HomingConfig = {}, HomingSource = {}, HomingMainSearch = {},
	}
end

-- Resizes a batch's input buffer, keeping its records.
local function setHoming(batch: Batch, item: number, homes: boolean)
	local was = batch.Homing[item] == true
	if was ~= homes then
		batch.HomingCount += if homes then 1 else -1
	end
	batch.Homing[item] = homes
end

local function resize(batch: Batch, capacity: number)
	local input = buffer.create(Sweep.InputSize(capacity))
	bufferCopy(input, 0, batch.Input, 0, batch.Count * IN)
	batch.Input, batch.Capacity = input, capacity
end

-- Packs `projectile` into slot `item` (new or reused) with its current state.
local function pack(batch: Batch, item: number, projectile: any, filter: number, spec: number, scale: number)
	local slot = projectile._slot
	batch.Projectiles[item] = projectile
	batch.Slot[item] = slot
	batch.Generation[item] = Store.Generation[slot]
	batch.Scale[item] = scale
	batch.Deadline[item] = projectile._spawnRealTime + projectile.MaxRealLifetime
	local homing = projectile.Homing
	setHoming(batch, item, homing ~= nil)
	batch.HomingConfig[item] = homing
	batch.HomingSource[item] = if homing then projectile.Source else nil
	batch.HomingMainSearch[item] = homing ~= nil and projectile.Filter ~= nil
	-- (remaining holds the carried debt until dispatch adds the frame's budget)
	Sweep.WriteInput(batch.Input, item, spec, filter, projectile, projectile._simulationDebt)
	Store.ClearDirty(slot)
end

-- Motion spec id for a projectile's per-shot constants (see
-- Sweep.MotionSpec), by value; new ids are sent to every worker and become
-- usable next frame. nil if not usable yet (or the values can't be keys).
local NIL = newproxy()
local values = table.create(15) -- scratch
local function lookupSpec(projectile: any): number?
	local node = specIds
	values[1], values[2], values[3] = projectile.Acceleration or 0, projectile.AccelerationDirection, projectile.Gravity or 0
	values[4], values[5], values[6], values[7] = projectile.MinSpeed, projectile.MaxSpeed, projectile.Radius, projectile.Lifetime
	local homing = projectile.Homing
	values[8] = homing and homing.TurnRate
	values[9] = homing and (homing.AcquireRadius ~= nil or homing.TargetTag ~= nil or homing.TargetTags ~= nil)
	values[10] = homing and (homing.Retarget and not homing.Permalock)
	values[11] = homing and projectile.Filter == nil
	values[12] = homing and homing.AcquireRadius
	values[13] = homing and homing.AcquireInterval
	values[14] = homing and homing.ReacquireRate
	values[15] = homing and tagMaskOf(homing)
	for index = 1, 15 do
		local value = values[index]
		if value == nil then
			value = NIL
		elseif value ~= value then
			return nil -- NaN can't be a key; the serial path deals with it
		end
		local nextNode = node[value]
		if not nextNode then
			if index == 15 then
				if nextSpecId >= MAX_SPECS then
					return nil
				end
				nextSpecId += 1
				nextNode = nextSpecId
				specReady[nextNode] = frame + 1
				local spec = Sweep.SpecOf(projectile)
				spec.TagMask = values[15]
				for _, worker in workers do
					worker.Actor:SendMessage("Motion", nextNode, spec)
				end
			else
				nextNode = {}
			end
			node[value] = nextNode
		end
		node = nextNode
	end
	return node :: any
end

-- An efficient projectile with no per-projectile overrides has exactly its
-- compiled config's motion constants, so its spec id is cached per handle
-- metatable (one per config) and packing it skips lookupSpec. (Full
-- projectiles share one metatable and carry their own `_w`: never cached.)
local specByMetatable: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any

local function specFor(projectile: any): number?
	local plainHandle = rawget(projectile, "_slot") ~= nil and rawget(projectile, "_x") == nil
		and rawget(projectile, "_w") == nil
	local metatable = if plainHandle then getmetatable(projectile) else nil
	local id = metatable and specByMetatable[metatable]
	if not id then
		id = lookupSpec(projectile)
		if id and metatable then
			specByMetatable[metatable] = id
		end
	end
	return if id and specReady[id] <= frame then id else nil
end

-- Its scale, filter id and motion spec id if it may have a slot right now,
-- else nil.
-- Per handle metatable (one per compiled config), what packing a plain
-- efficient projectile needs beyond its Store columns: its filter id, spec id
-- and MaxRealLifetime -- filled the first time one of them is packed the
-- slow way (eligible), used by fastAcquire.
type HandleInfo = { Filter: number, Spec: number, MaxRealLifetime: number }
local handleInfo: { [any]: HandleInfo } = setmetatable({}, { __mode = "k" }) :: any

local function plainHandle(projectile: any): boolean
	return rawget(projectile, "_slot") ~= nil and rawget(projectile, "_x") == nil and rawget(projectile, "_w") == nil
end

local function eligible(projectile: any): (number?, number?, number?)
	if not projectile._slot then
		return nil, nil, nil -- (released: it's gone)
	end
	local scale = scaleOf(projectile)
	if not scale then
		return nil, nil, nil
	end
	local filter = filterFor(projectile)
	local spec = specFor(projectile)
	if filter and spec and plainHandle(projectile) then
		local metatable = getmetatable(projectile)
		if not handleInfo[metatable] then
			handleInfo[metatable] = { Filter = filter, Spec = spec, MaxRealLifetime = projectile.MaxRealLifetime }
		end
	end
	return scale, filter, spec
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
		projectiles[item] = projectiles[last]
		batch.Slot[item] = batch.Slot[last]
		batch.Generation[item] = batch.Generation[last]
		batch.Scale[item] = batch.Scale[last]
		batch.Deadline[item] = batch.Deadline[last]
	end
	-- (the released item's flag goes, the last item's moves into its place)
	setHoming(batch, item, batch.Homing[last] == true)
	setHoming(batch, last, false)
	batch.HomingConfig[item], batch.HomingSource[item], batch.HomingMainSearch[item] =
		batch.HomingConfig[last], batch.HomingSource[last], batch.HomingMainSearch[last]
	batch.HomingConfig[last], batch.HomingSource[last], batch.HomingMainSearch[last] = nil, nil, nil
	projectiles[last] = nil
	batch.Count = last - 1
end

local function releaseBatch(batch: Batch)
	local projectiles = batch.Projectiles
	for item = 1, batch.Count do
		projectiles[item]._parallelState = nil
		projectiles[item] = nil
	end
	table.clear(batch.Homing)
	table.clear(batch.HomingConfig)
	table.clear(batch.HomingSource)
	table.clear(batch.HomingMainSearch)
	batch.Count, batch.Sent, batch.HomingCount = 0, 0, 0
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

-- Packs a freshly fired efficient projectile straight into a slot from the
-- values its creator already has (Projectile.Fire) -- no eligibility reads,
-- no lookups. False when it can't (parallel movement off, a batch in flight
-- -- it would also be stepped serially this frame --, its filter or spec
-- not yet known to the workers): Offer it instead.
function Parallel.PackNew(projectile: any, position: Vector3, velocity: Vector3, scale: number,
	rayParams: RaycastParams, deadline: number): boolean
	if not running or inFlight or not (scale > 0) then
		return false
	end
	local filter = filterByParams[rayParams]
	if not filter or filterReady[filter] > frame then
		return false
	end
	local spec = specByMetatable[getmetatable(projectile)]
	if not spec or specReady[spec] > frame then
		return false
	end
	local batch = batches[1]
	if not batch then
		return false
	end
	for w = 2, #workers do
		local candidate = batches[w]
		if candidate and candidate.Count < batch.Count then
			batch = candidate
		end
	end
	local item = batch.Count + 1
	if item > batch.Capacity then
		resize(batch, batch.Capacity * 2)
	end
	batch.Count = item
	local slot = rawget(projectile, "_slot")
	batch.Projectiles[item] = projectile
	batch.Slot[item] = slot
	batch.Generation[item] = Store.Generation[slot]
	batch.Scale[item] = scale
	batch.Deadline[item] = deadline
	setHoming(batch, item, false)
	-- (remaining holds the carried debt -- none yet -- until dispatch adds the budget)
	Sweep.WriteInputValues(batch.Input, item, spec, filter, position, velocity, 0, 0)
	projectile._parallelState = SLOTTED
	return true
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

-- Packs a queued plain efficient projectile from its Store columns, with no
-- metatable reads: the same checks as eligible + pack (parallelScale's),
-- read straight from the columns, and its config's cached filter / spec.
-- False when anything is unusual (no cached info yet, its time scale or sync
-- state needs streaming...): the caller takes the ordinary path.
local function fastAcquire(projectile: any, batch: Batch, now: number): boolean
	local info = handleInfo[getmetatable(projectile)]
	if not info or filterReady[info.Filter] > frame or specReady[info.Spec] > frame then
		return false
	end
	local slot = rawget(projectile, "_slot")
	local flags = buffer.readu8(Store.Flags, slot)
	if bit32.band(flags, bit32.bor(Store.Dead, Store.Synced)) ~= 0 then
		return false
	end
	local cold = slot * Store.ColdStride
	local deadline = buffer.readf64(Store.Cold, cold + 8) + info.MaxRealLifetime
	if not (now < deadline) then
		return false
	end
	-- scale: own * source's, the ordinary case only (else parallelScale decides)
	local s = slot * S_SCALE
	local own = buffer.readf64(Store.Scales, s)
	local index = buffer.readu32(Store.Scales, s + 8)
	local sourceScale: any = if index ~= 0 then Store.Sources[index].TimeScale else 1
	if not (type(sourceScale) == "number" and sourceScale >= 0 and own >= 0 and sourceScale < LIMIT and own < LIMIT) then
		return false
	end
	local scale = sourceScale * own
	-- (a changed scale has to be streamed first: parallelScale does that)
	if not (scale > 0 and scale < LIMIT) or scale ~= buffer.readf64(Store.Cold, cold + 16) then
		return false
	end
	local m = slot * S_MOTION
	local motion = Store.Motion
	for offset = 0, 20, 4 do
		if not (abs(buffer.readf32(motion, m + offset)) <= LIMIT) then
			return false
		end
	end
	local item = batch.Count + 1
	if item > batch.Capacity then
		resize(batch, batch.Capacity * 2)
	end
	batch.Count = item
	batch.Projectiles[item] = projectile
	batch.Slot[item] = slot
	batch.Generation[item] = Store.Generation[slot]
	batch.Scale[item] = scale
	batch.Deadline[item] = deadline
	setHoming(batch, item, false)
	local t = slot * S_TIME
	local o = (item - 1) * IN
	local input = batch.Input
	buffer.writeu32(input, o, info.Spec)
	buffer.writeu32(input, o + 4, info.Filter)
	bufferCopy(input, o + IN_MOTION, motion, m, 24)
	writef64(input, o + IN_AGE, buffer.readf64(Store.Time, t))
	-- (remaining holds the carried debt until dispatch adds the frame's budget)
	writef64(input, o + IN_REMAINING, buffer.readf64(Store.Time, t + 8))
	Store.ClearDirty(slot)
	buffer.writef64(Store.Cold, cold + 24, SLOTTED) -- (_parallelState)
	return true
end

-- Packs queued projectiles and sends this frame's batches. `allowed` false
-- (e.g. debug rays on) pauses parallel movement: every slot is released and
-- everything steps serially.
function Parallel.Dispatch(activeCount: number, globalDt: number, allowed: boolean)
	local clock = os.clock
	local setupStarted = clock()
	for _, batch in batches do
		batch.Sent = 0
	end
	if refreshWorkers() then
		releaseAll() -- (batches follow worker order; this only happens at startup)
	end
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
	local acquireNow = clock()
	for _, projectile in queue do
		local batch = batches[1]
		for w = 2, workerCount do
			if batches[w].Count < batch.Count then
				batch = batches[w]
			end
		end
		if plainHandle(projectile) then
			if fastAcquire(projectile, batch, acquireNow) then
				acquired += 1
				Profile.Count("FastAcquired", 1)
				continue
			end
			Profile.Count("FastMissed", 1)
		end
		projectile._parallelState = nil
		if projectile.Dead then
			continue
		end
		local scale, filter, spec = eligible(projectile)
		if not scale or not filter or not spec then
			continue
		end
		local item = batch.Count + 1
		if item > batch.Capacity then
			resize(batch, batch.Capacity * 2)
		end
		batch.Count = item
		pack(batch, item, projectile, filter, spec, scale)
		projectile._parallelState = SLOTTED
		acquired += 1
	end
	table.clear(queue)

	-- this frame's step budget for every slot: its record's remaining field
	-- holds the carried debt (written by pack and Apply), so this is a
	-- sequential pass over each batch
	local loopStarted = clock()
	for w = 1, workerCount do
		local batch = batches[w]
		local input, scales = batch.Input, batch.Scale
		for item = 1, batch.Count do
			local o = (item - 1) * IN + IN_REMAINING
			writef64(input, o, globalDt * scales[item] + readf64(input, o))
		end
	end

	local homingStarted = clock()
	-- this frame's homing state for every homing item: its target's position
	-- (fixed for the frame -- entities only move during physics; looked up
	-- once per target), its Source's index in the frame's target list, its
	-- flags and its timers (copied from Store). Target searches happen on the
	-- workers, from the frame's target list; a config with a custom Filter
	-- searches here instead, for any search due during this frame's budget.
	local HOMING_IN = Sweep.HomingInStride
	local S_HOMING = Store.HomingStride
	table.clear(goalCache)
	local anyHoming = false
	for w = 1, workerCount do
		if batches[w].HomingCount > 0 then
			anyHoming = true
			break
		end
	end
	if anyHoming then
		buildHomingFrame()
	end
	for w = 1, workerCount do
		local batch = batches[w]
		if batch.HomingCount <= 0 then
			continue
		end
		local homingIn = batch.HomingIn
		if not homingIn or buffer.len(homingIn) < batch.Capacity * HOMING_IN then
			homingIn = buffer.create(batch.Capacity * HOMING_IN)
			batch.HomingIn = homingIn
		end
		local homingFlags, projectiles, slots, input = batch.Homing, batch.Projectiles, batch.Slot, batch.Input
		local configs, sources, mainSearch = batch.HomingConfig, batch.HomingSource, batch.HomingMainSearch
		for item = 1, batch.Count do
			local h = (item - 1) * HOMING_IN
			if not homingFlags[item] then
				buffer.writeu8(homingIn, h, 0)
				continue
			end
			local projectile = projectiles[item]
			local homing = configs[item]
			local target = rawget(projectile, "HomingTarget")
			local goal = goalOf(target)
			local timers = slots[item] * S_HOMING
			local homingTimers = Store.HomingTimers
			if mainSearch[item] and homing and buffer.readf64(homingTimers, timers) <= 0 then
				local budget = readf64(input, (item - 1) * IN + IN_REMAINING) -- (already scaled)
				local searched = false
				if not goal then
					if (homing.AcquireRadius or homing.TargetTag or homing.TargetTags)
						and buffer.readf64(homingTimers, timers + 8) <= budget then
						projectile._acquireTimer = homing.AcquireInterval * (0.5 + math.random())
						searched = true
					end
				elseif not homing.Permalock and homing.Retarget and target ~= homing.Target
					and buffer.readf64(homingTimers, timers + 16) <= budget then
					projectile.ReacquireTimer = homing.ReacquireRate
					searched = true
				end
				if searched then
					local searchStarted = clock()
					target = Homing.acquireTarget(projectile, homing, projectile.Position)
					Profile.Add("HomingSearch", clock() - searchStarted)
					Profile.Count("HomingSearches", 1)
					rawset(projectile, "HomingTarget", target)
					goal = goalOf(target)
					-- (a new target can switch its continuous pose stream on or off)
					Replication.updateSyncState(projectile)
				end
			end
			local flags = Sweep.HomingFlag
			if goal then
				flags += Sweep.HomingTargetPosition
				buffer.writef32(homingIn, h + 8, goal.X)
				buffer.writef32(homingIn, h + 12, goal.Y)
				buffer.writef32(homingIn, h + 16, goal.Z)
			end
			if target ~= nil then
				flags += Sweep.HomingHasTarget
				if homing and target == homing.Target then
					flags += Sweep.HomingExplicit
				end
			end
			buffer.writeu8(homingIn, h, flags)
			buffer.writeu32(homingIn, h + 4, frameTargetIndex[sources[item]] or 0)
			bufferCopy(homingIn, h + 24, homingTimers, timers, 24)
		end
	end
	Profile.Add("HomingDispatch", clock() - homingStarted)
	local sendStarted = clock()
	local keys = entityChunkKeys()
	local slots = 0
	for w = 1, workerCount do
		local batch = batches[w]
		local count = batch.Count
		slots += count
		if count > 0 then
			batch.Sent = count
			inFlight = true
			local homes = batch.HomingCount > 0
			workers[w].Actor:SendMessage("Sweep", frame, batch.Input, count, batchUniform, keys,
				if homes then batch.HomingIn else nil, if homes then homingFrame else nil)
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

-- (Pass 1 of Apply lives in ApplyPass.luau, a small module of its own so it
-- always gets native code.)

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
	local transferred = 0
	local plainTime = 0
	local slowest, total, any = 0, 0, false
	inFlight = false
	local sameVersion = timeVersion == batchTimeVersion
	for w, batch in batches do
		local count = batch.Sent
		if count == 0 then
			continue
		end
		batch.Sent = 0
		local worker = workers[w]
		local result = worker and results[worker.Id]
		local data = result and result.Data
		if not result or not data or result.Frame ~= frame or result.Count ~= count then
			stats.Late += count
			releases += batch.Count
			releaseBatch(batch)
			continue
		end
		-- (the event already handed us our own copy of the worker's buffer)
		local decodeStarted = clock()
		result.Data = nil
		local ms = result.Ms
		slowest, total, any = math.max(slowest, ms), total + ms, true
		transferred += buffer.len(data)
		local input = batch.Input
		local projectiles, slots, generations, scales, deadlines =
			batch.Projectiles, batch.Slot, batch.Generation, batch.Scale, batch.Deadline
		local generationOf = Store.Generation
		local loopStarted = clock()
		decodeTime += loopStarted - decodeStarted
		table.clear(released)
		-- Pass 1, buffers only: every plain result for an untouched projectile.
		-- The rest are deferred to pass 2, so the serial code (raycasts,
		-- Step, allocation) doesn't keep evicting this loop's working set.
		local dropped, slow, keptHere = 0, 0, 0
		local plainStarted = clock()
		if sameVersion then
			dropped, slow, keptHere = ApplyPass(Store.Motion, Store.Time, Store.Marks, Store.Flags, Store.Scales,
				data, input, count, slots, generations, scales, deadlines, generationOf, Store.Sources, now, mark,
				released, deferred, if batch.HomingCount > 0 then batch.Homing else nil, result.HomingOut,
				Store.HomingTimers)
		else
			for item = 1, count do
				deferred[item] = item
			end
			slow = count
		end
		kept += keptHere
		plainTime += clock() - plainStarted

		-- Pass 2: the serial code finishes the rest. Both `deferred` and the
		-- worker's contacts are in item order, so they're matched as we go.
		local slowStarted = clock()
		local contacts = result.Contacts
		local contactItems = contacts and contacts.Item
		local nextContact = 1
		result.Contacts = nil
		local homingOut = result.HomingOut
		result.HomingOut = nil
		local homingItems = batch.Homing
		if homingOut and batch.HomingCount > 0 then
			-- targets the workers searched for (Sweep: -1 none found, >0 an index
			-- into this frame's target list), before the serial pass resumes any
			local HOMING_OUT = Sweep.HomingOutStride
			for item = 1, count do
				if homingItems[item] and generationOf[slots[item]] == generations[item] then
					local change = readf64(homingOut, (item - 1) * HOMING_OUT + 24)
					if change ~= 0 then
						local projectile = projectiles[item]
						rawset(projectile, "HomingTarget", if change > 0 then frameTargets[change] else nil)
						Replication.updateSyncState(projectile)
						Profile.Count("HomingSearches", 1)
					end
				end
			end
		end
		for index = 1, slow do
			local item = deferred[index]
			local projectile = projectiles[item]
			local status, position, velocity, age, remaining, guard = Sweep.ReadOutputValues(data, item)
			local flags = readu8(Store.Flags, slots[item])
			local contact: WorkerContact? = nil
			if contactItems then
				while contactItems[nextContact] and contactItems[nextContact] < item do
					nextContact += 1
				end
				if contactItems[nextContact] == item then
					contact = {
						From = contacts.From[nextContact], Displacement = contacts.Displacement[nextContact],
						Instance = contacts.Instance[nextContact], Position = contacts.Position[nextContact],
						Normal = contacts.Normal[nextContact], Distance = contacts.Distance[nextContact],
					}
				end
			end
			local timers: { number }? = nil
			if homingOut and homingItems[item] then
				local h = (item - 1) * Sweep.HomingOutStride
				homingTimers[1], homingTimers[2], homingTimers[3] =
					readf64(homingOut, h), readf64(homingOut, h + 8), readf64(homingOut, h + 16)
				timers = homingTimers
			end
			local outcome = apply(projectile, status, position, velocity, age, remaining, guard,
				band(flags, Store.Dirty) ~= 0, scales[item], batchTimeVersion, batchUniform, contact, timers)
			local keep = false
			if outcome == REFRESH and not projectile.Dead then
				local repackStarted = clock()
				local scale, filter, spec = eligible(projectile)
				if scale and filter and spec then
					pack(batch, item, projectile, filter, spec, scale)
					keep = true
				end
				Profile.Add("SerialRepack", clock() - repackStarted)
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
	Profile.Count("TransferKB", transferred / 1024)
	Profile.Add("ApplyLoop", loopTime - slowTime)
	Profile.Add("ApplySlow", slowTime)
	Profile.Add("ApplyPlain", plainTime)
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
	stats.WorkerChecks, stats.WorkerSkipped = 0, 0
	snapshot.WorkerReasons = table.clone(workerReasons)
	table.clear(workerReasons)
	for index = 1, 5 do
		workerReasons[index] = 0
	end
	stats.SlowestWorkerMs, stats.WorkerMs, stats.AppliedFrames = 0, 0, 0
	return snapshot
end

return Parallel
