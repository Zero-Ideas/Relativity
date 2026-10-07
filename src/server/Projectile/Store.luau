--!strict
--!native
--!optimize 2
--[[
	Projectile/Store.luau
	The hot half of every live projectile, packed into buffers.

	A projectile is still the table Projectile.new returns, and every field
	reads and writes as before (projectile.Position, projectile.Velocity = v,
	projectile.Dead, ...). But the fields touched every frame live in the
	column buffers here (see Layout) instead of in the table, behind the table's metatable. The
	per-frame loops (Parallel's dispatch/apply, the server step loop) read the
	records directly, so a projectile that just flies never has its table
	touched -- a 45-field table is ~2 KB of scattered hash nodes, and at
	100k+ projectiles each field read was roughly a cache miss.

	Layout: structure-of-arrays, one buffer ("column") per group of fields
	used together, indexed by slot. Measured on the apply pass at 180k
	projectiles, columns beat one 96-byte record per projectile by ~40% with
	slots in random order (and ~5x on the step loop's mark/flag reads): each
	hot column is small enough to stay in cache.
	  Motion  24 B  Position, Velocity (3 x f32 each; Vector3 is float32: exact)
	  Time    16 B  Age f64, _simulationDebt f64
	  Marks    4 B  _sweepMark i32 (0 when unset)
	  Flags    1 B  Dead, Dirty, _spawnStreamed, _streamedSynced, and
	                Visualize / Beam ~= nil (fixed at adopt)
	  Scales  16 B  TimeScale f64 (its OWN scale; non-numbers are stored as 1,
	                which is what combinedTimeScale made of them anyway),
	                Source u32 (index into a refcounted source list, 0: none)
	  Cold    32 B  Id, _spawnRealTime, _lastStreamedTimeScale, _parallelState
	                (f64 each; touched at spawn / death / repack, not per frame)
	The buffers are replaced when they grow, so read Store.Motion etc. afresh
	rather than keeping them across anything that can spawn a projectile.

	EFFICIENT projectiles (the default for plain shots, see Projectile.new)
	have no table of their own beyond a tiny handle ({ _slot }): everything
	constant per config lives in one shared, frozen spec (Spec.luau), and the
	handle's metatable (Store.HandleMetatable) reads a field from, in order:
	the record, the handle's own extras (`_x`, created by the first write of
	a non-record field -- that projectile's override), lazily created values
	(signals, scratch tables), the spec, then the class. Writing a motion
	constant (Gravity, Radius...) also marks the record Dirty, so the worker
	repacks it next frame.

	Dirty is set by any write of a motion field (Position, Velocity, Age,
	_simulationDebt, TimeScale, Dead) through the table: it tells Parallel the
	worker's copy is stale, instead of comparing every field per frame.
	Parallel clears it when it repacks the projectile.

	Lifetime: adopt() moves a new table's hot fields in; release() (when the
	step loop drops it from `active`) copies them back out as plain fields, so
	a handle a caller kept keeps working, and frees the slot. Generation[slot]
	counts releases, so a stale reference to a reused slot can be recognised.
]]

local Store = {}

-- column strides (bytes per slot)
local MOTION, TIME, MARKS, SCALES, COLD = 24, 16, 4, 16, 32
Store.MotionStride, Store.TimeStride, Store.MarkStride, Store.ScaleStride = MOTION, TIME, MARKS, SCALES

local DEAD, DIRTY, SPAWN_STREAMED, SYNCED, VISUALIZE, BEAM = 1, 2, 4, 8, 16, 32
Store.Dead, Store.Dirty, Store.SpawnStreamed, Store.Synced, Store.Visualize, Store.Beam =
	DEAD, DIRTY, SPAWN_STREAMED, SYNCED, VISUALIZE, BEAM

local readf32, writef32, readf64, writef64 = buffer.readf32, buffer.writef32, buffer.readf64, buffer.writef64
local readu8, writeu8, readu32, writeu32 = buffer.readu8, buffer.writeu8, buffer.readu32, buffer.writeu32
local readi32, writei32 = buffer.readi32, buffer.writei32
local band, bor, bnot = bit32.band, bit32.bor, bit32.bnot

local capacity = 1024
Store.Motion = buffer.create(capacity * MOTION)
Store.Time = buffer.create(capacity * TIME)
Store.Marks = buffer.create(capacity * MARKS)
Store.Flags = buffer.create(capacity)
Store.Scales = buffer.create(capacity * SCALES)
Store.Cold = buffer.create(capacity * COLD)
Store.Generation = {} :: { number } -- [slot] = times released
local used = 0 -- slots ever handed out
local free: { number } = {}

-- Sources (the shooter Entity), shared by many projectiles: [index] = source.
Store.Sources = {} :: { any }
local sourceIndex: { [any]: number } = {}
local sourceRefs: { number } = {}
local freeSources: { number } = {}

-- Hot fields and their kind.
local HOT: { [string]: number } = {
	Position = 1, Velocity = 2, Age = 3, _simulationDebt = 4, TimeScale = 5,
	Dead = 6, _spawnStreamed = 7, _streamedSynced = 8, _sweepMark = 9,
	Id = 10, _spawnRealTime = 11, _lastStreamedTimeScale = 12, _parallelState = 13,
}
Store.HotFields = HOT
local MOTION_LAST = 6 -- kinds 1..6 mark the record Dirty when written

local NAN = 0 / 0
local BAD_POSITION = Vector3.new(NAN, NAN, NAN) -- fails isFiniteVector, so Step expires it

local function readVector(b: buffer, o: number): Vector3
	return Vector3.new(readf32(b, o), readf32(b, o + 4), readf32(b, o + 8))
end

local function writeVector(b: buffer, o: number, v: Vector3)
	writef32(b, o, v.X)
	writef32(b, o + 4, v.Y)
	writef32(b, o + 8, v.Z)
end

local function flag(slot: number, bitValue: number, on: boolean)
	local flags = readu8(Store.Flags, slot)
	writeu8(Store.Flags, slot, if on then bor(flags, bitValue) else band(flags, bnot(bitValue)))
end

local function read(slot: number, kind: number): any
	if kind == 1 then
		return readVector(Store.Motion, slot * MOTION)
	elseif kind == 2 then
		return readVector(Store.Motion, slot * MOTION + 12)
	elseif kind == 3 then
		return readf64(Store.Time, slot * TIME)
	elseif kind == 4 then
		return readf64(Store.Time, slot * TIME + 8)
	elseif kind == 5 then
		return readf64(Store.Scales, slot * SCALES)
	elseif kind == 6 then
		return band(readu8(Store.Flags, slot), DEAD) ~= 0
	elseif kind == 7 then
		return band(readu8(Store.Flags, slot), SPAWN_STREAMED) ~= 0
	elseif kind == 8 then
		return band(readu8(Store.Flags, slot), SYNCED) ~= 0
	elseif kind == 9 then
		return readi32(Store.Marks, slot * MARKS)
	elseif kind == 10 then
		return readf64(Store.Cold, slot * COLD)
	elseif kind == 11 then
		return readf64(Store.Cold, slot * COLD + 8)
	elseif kind == 12 then
		return readf64(Store.Cold, slot * COLD + 16)
	end
	local state = readf64(Store.Cold, slot * COLD + 24)
	return if state == 0 then nil else state
end

local function write(slot: number, kind: number, value: any)
	if kind == 1 then
		writeVector(Store.Motion, slot * MOTION, if typeof(value) == "Vector3" then value else BAD_POSITION)
	elseif kind == 2 then
		-- (Step turns a non-vector Velocity into zero; same here)
		writeVector(Store.Motion, slot * MOTION + 12, if typeof(value) == "Vector3" then value else Vector3.zero)
	elseif kind == 3 then
		writef64(Store.Time, slot * TIME, tonumber(value) or 0)
	elseif kind == 4 then
		writef64(Store.Time, slot * TIME + 8, tonumber(value) or 0)
	elseif kind == 5 then
		writef64(Store.Scales, slot * SCALES, if type(value) == "number" then value else 1)
	elseif kind == 6 then
		flag(slot, DEAD, value == true)
	elseif kind == 7 then
		flag(slot, SPAWN_STREAMED, value == true)
	elseif kind == 8 then
		flag(slot, SYNCED, value == true)
	elseif kind == 9 then
		writei32(Store.Marks, slot * MARKS, tonumber(value) or 0)
	elseif kind == 10 then
		writef64(Store.Cold, slot * COLD, tonumber(value) or 0)
	elseif kind == 11 then
		writef64(Store.Cold, slot * COLD + 8, tonumber(value) or 0)
	elseif kind == 12 then
		writef64(Store.Cold, slot * COLD + 16, tonumber(value) or 1)
	else
		writef64(Store.Cold, slot * COLD + 24, tonumber(value) or 0)
	end
	if kind <= MOTION_LAST then
		flag(slot, DIRTY, true)
	end
end

local function grow(old: buffer, stride: number): buffer
	local grown = buffer.create(capacity * 2 * stride)
	buffer.copy(grown, 0, old, 0, capacity * stride)
	return grown
end

-- A fresh slot, every column zeroed.
local function allocate(): number
	local slot = table.remove(free)
	if not slot then
		slot = used
		used += 1
		if used > capacity then
			Store.Motion = grow(Store.Motion, MOTION)
			Store.Time = grow(Store.Time, TIME)
			Store.Marks = grow(Store.Marks, MARKS)
			Store.Flags = grow(Store.Flags, 1)
			Store.Scales = grow(Store.Scales, SCALES)
			Store.Cold = grow(Store.Cold, COLD)
			capacity *= 2
		end
		Store.Generation[slot] = 0
	end
	buffer.fill(Store.Motion, slot * MOTION, 0, MOTION)
	buffer.fill(Store.Time, slot * TIME, 0, TIME)
	writei32(Store.Marks, slot * MARKS, 0)
	writeu8(Store.Flags, slot, 0)
	buffer.fill(Store.Scales, slot * SCALES, 0, SCALES)
	buffer.fill(Store.Cold, slot * COLD, 0, COLD)
	return slot
end

local function addSource(source: any): number
	if source == nil then
		return 0
	end
	local index = sourceIndex[source]
	if not index then
		index = table.remove(freeSources) or #Store.Sources + 1
		sourceIndex[source] = index
		Store.Sources[index] = source
		sourceRefs[index] = 0
	end
	sourceRefs[index] += 1
	return index
end

local function dropSource(index: number)
	if index == 0 then
		return
	end
	sourceRefs[index] -= 1
	if sourceRefs[index] == 0 then
		sourceIndex[Store.Sources[index]] = nil
		Store.Sources[index] = nil
		table.insert(freeSources, index)
	end
end

-- REPACK fields: what a worker's packed copy of a projectile depends on
-- besides the record -- its motion constants (Sweep.MotionSpec) and what
-- makes it eligible for the workers at all (Homing, lag compensation).
-- Writing one mid-flight marks the record Dirty, so that frame's worker
-- result is discarded, the projectile steps serially with the new value and
-- is repacked (or stays serial, e.g. once it has Homing). On a full
-- projectile they live in a side table (`_w`) instead of on the table itself,
-- so that writing them reaches __newindex.
local REPACK = {
	Acceleration = true, AccelerationDirection = true, Gravity = true, MinSpeed = true, MaxSpeed = true,
	Radius = true, Lifetime = true, Homing = true, RewindSeconds = true,
}

-- The metatable full (table-backed) live projectiles get: hot fields go to
-- the record, REPACK fields to `_w`, anything else is an ordinary field (or
-- a method from `class`).
function Store.Metatable(class: any): any
	return {
		__index = function(self: any, key: any): any
			local kind = HOT[key]
			if kind then
				return read(self._slot, kind)
			end
			if REPACK[key] then
				local watched = rawget(self, "_w")
				if watched then
					return watched[key]
				end
			end
			return class[key]
		end,
		__newindex = function(self: any, key: any, value: any)
			local kind = HOT[key]
			if kind then
				write(self._slot, kind, value)
				return
			end
			local watched = REPACK[key] and rawget(self, "_w")
			if watched then
				watched[key] = value
				flag(self._slot, DIRTY, true)
				return
			end
			rawset(self, key, value)
		end,
	}
end

local NIL = newproxy() -- an extras entry meaning "overridden to nil"

-- The metatable of an efficient projectile handle built from `spec` (see the
-- module comment). `lazy[key]()` makes a value the first time it's read
-- (signals, scratch tables) and keeps it in the handle's extras.
function Store.HandleMetatable(spec: any, class: any, lazy: { [string]: () -> any }): any
	return {
		__index = function(self: any, key: any): any
			local kind = HOT[key]
			if kind then
				local slot = rawget(self, "_slot")
				-- (released: its record fields were copied in, so a missing one is nil)
				return if slot then read(slot, kind) else nil
			end
			local extras = rawget(self, "_x")
			if extras then
				local value = extras[key]
				if value ~= nil then
					return if value == NIL then nil else value
				end
			end
			local make = lazy[key]
			if make then
				local value = make()
				if not extras then
					extras = {}
					rawset(self, "_x", extras)
				end
				extras[key] = value
				return value
			end
			local value = spec[key]
			if value ~= nil then
				return value
			end
			return class[key]
		end,
		__newindex = function(self: any, key: any, value: any)
			local kind = HOT[key]
			local slot = rawget(self, "_slot")
			if kind and slot then
				write(slot, kind, value)
				return
			end
			local extras = rawget(self, "_x")
			if value == nil then
				if spec[key] == nil then
					-- nothing to shadow: just drop any override
					if extras then
						extras[key] = nil
					end
					return
				end
				value = NIL
			end
			if not extras then
				extras = {}
				rawset(self, "_x", extras)
			end
			extras[key] = value
			if slot and REPACK[key] then
				flag(slot, DIRTY, true)
			end
		end,
	}
end

-- A field's value if it already exists, without creating a lazy one (so
-- firing or cleaning up a signal nobody connected to costs nothing).
function Store.Peek(state: any, key: string): any
	local value = rawget(state, key)
	if value ~= nil then
		return value
	end
	local extras = rawget(state, "_x")
	value = extras and extras[key]
	return if value == NIL then nil else value
end

-- Moves hot fields into a fresh record and gives `state` `metatable`.
-- They're read from `values` (default: `state` itself, whose copies are then
-- removed); Visualize / Beam / Source come from there too. Returns `state`.
function Store.Adopt(state: any, metatable: any, values: any?): any
	local from = values or state
	local slot = allocate()
	for key, kind in HOT do
		local value = rawget(from, key)
		if from == state then
			rawset(state, key, nil)
		end
		write(slot, kind, value)
	end
	local flags = band(readu8(Store.Flags, slot), bnot(DIRTY))
	if rawget(from, "Visualize") then
		flags = bor(flags, VISUALIZE)
	end
	if rawget(from, "Beam") ~= nil then
		flags = bor(flags, BEAM)
	end
	writeu8(Store.Flags, slot, flags)
	writeu32(Store.Scales, slot * SCALES + 8, addSource(rawget(from, "Source")))
	if from == state then
		local watched = {}
		for key in REPACK do
			watched[key] = rawget(state, key)
			rawset(state, key, nil)
		end
		rawset(state, "_w", watched)
	end
	rawset(state, "_slot", slot)
	return setmetatable(state, metatable)
end

-- Store.Adopt for a fresh efficient handle from plain values (no temporary
-- table: Projectile.Fire's path). Age, debt, mark and the stream flags start
-- at 0 / false.
function Store.AdoptFast(handle: any, metatable: any, position: Vector3, velocity: Vector3, timeScale: number,
	id: number, spawnTime: number, lastScale: number, visualize: boolean, source: any): any
	local slot = allocate()
	local m = slot * MOTION
	writeVector(Store.Motion, m, position)
	writeVector(Store.Motion, m + 12, velocity)
	writef64(Store.Scales, slot * SCALES, timeScale)
	writeu32(Store.Scales, slot * SCALES + 8, addSource(source))
	local c = slot * COLD
	writef64(Store.Cold, c, id)
	writef64(Store.Cold, c + 8, spawnTime)
	writef64(Store.Cold, c + 16, lastScale)
	writeu8(Store.Flags, slot, if visualize then VISUALIZE else 0)
	rawset(handle, "_slot", slot)
	return setmetatable(handle, metatable)
end

-- Copies a projectile's hot fields back into its table as plain fields
-- (so a kept handle still reads them), gives it `metatable` if one is given
-- (a full projectile goes back to the class; an efficient handle keeps its
-- own) and frees its record. No-op if it has none.
function Store.Release(state: any, metatable: any?)
	local slot = rawget(state, "_slot")
	if not slot then
		return
	end
	dropSource(readu32(Store.Scales, slot * SCALES + 8))
	if metatable then
		setmetatable(state, metatable)
	end
	rawset(state, "_slot", nil)
	for key, kind in HOT do
		rawset(state, key, read(slot, kind))
	end
	local watched = rawget(state, "_w")
	if watched then
		rawset(state, "_w", nil)
		for key, value in watched do
			rawset(state, key, value)
		end
	end
	Store.Generation[slot] += 1
	table.insert(free, slot)
end

-- A plain copy of a projectile (live or released): its fields, hot ones
-- included, with no record and no metatable -- ready for Adopt.
function Store.CloneRaw(state: any): any
	local copy = table.clone(state)
	setmetatable(copy, nil)
	local slot = rawget(state, "_slot")
	if slot then
		for key, kind in HOT do
			rawset(copy, key, read(slot, kind))
		end
		rawset(copy, "_slot", nil)
	end
	local watched = rawget(state, "_w")
	if watched then
		rawset(copy, "_w", nil)
		for key, value in watched do
			rawset(copy, key, value)
		end
	end
	return copy
end

function Store.MarkDirty(slot: number)
	flag(slot, DIRTY, true)
end

function Store.ClearDirty(slot: number)
	flag(slot, DIRTY, false)
end

-- Live slots (for the Stats tab).
function Store.Count(): number
	return used - #free
end

return Store
