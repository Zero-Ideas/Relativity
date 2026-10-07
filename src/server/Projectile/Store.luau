--!strict
--!native
--!optimize 2
--[[
	Projectile/Store.luau
	The hot half of every live projectile, packed into one buffer.

	A projectile is still the table Projectile.new returns, and every field
	reads and writes as before (projectile.Position, projectile.Velocity = v,
	projectile.Dead, ...). But the fields touched every frame live in a 64-byte
	record here instead of in the table, behind the table's metatable. The
	per-frame loops (Parallel's dispatch/apply, the server step loop) read the
	records directly, so a projectile that just flies never has its table
	touched -- a 45-field table is ~2 KB of scattered hash nodes, and at
	100k+ projectiles each field read was roughly a cache miss.

	Record (STRIDE bytes, slot * STRIDE):
	   0  Position        3 x f32 (Vector3 is float32, so this is exact)
	  12  Velocity        3 x f32
	  24  Age             f64
	  32  _simulationDebt f64
	  40  TimeScale       f64 (its OWN scale; non-numbers are stored as 1, which
	                           is what combinedTimeScale made of them anyway)
	  48  _sweepMark      f64 (0 when unset)
	  56  Source          u32 index into a refcounted source list (0: none)
	  60  flags           u8  (Dead, Dirty, _spawnStreamed, _streamedSynced, and
	                           Visualize / Beam ~= nil, fixed at adopt)

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

local STRIDE = 64
local POSITION, VELOCITY, AGE, DEBT, SCALE, MARK, SOURCE, FLAGS = 0, 12, 24, 32, 40, 48, 56, 60

Store.Stride = STRIDE
Store.Position, Store.Velocity, Store.Age, Store.Debt = POSITION, VELOCITY, AGE, DEBT
Store.TimeScale, Store.Mark, Store.Source, Store.Flags = SCALE, MARK, SOURCE, FLAGS

local DEAD, DIRTY, SPAWN_STREAMED, SYNCED, VISUALIZE, BEAM = 1, 2, 4, 8, 16, 32
Store.Dead, Store.Dirty, Store.SpawnStreamed, Store.Synced, Store.Visualize, Store.Beam =
	DEAD, DIRTY, SPAWN_STREAMED, SYNCED, VISUALIZE, BEAM

local readf32, writef32, readf64, writef64 = buffer.readf32, buffer.writef32, buffer.readf64, buffer.writef64
local readu8, writeu8, readu32, writeu32 = buffer.readu8, buffer.writeu8, buffer.readu32, buffer.writeu32
local band, bor, bnot = bit32.band, bit32.bor, bit32.bnot

local capacity = 1024
Store.data = buffer.create(capacity * STRIDE)
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

local function flag(b: buffer, o: number, bitValue: number, on: boolean)
	local flags = readu8(b, o + FLAGS)
	writeu8(b, o + FLAGS, if on then bor(flags, bitValue) else band(flags, bnot(bitValue)))
end

local function read(slot: number, kind: number): any
	local b, o = Store.data, slot * STRIDE
	if kind == 1 then
		return readVector(b, o + POSITION)
	elseif kind == 2 then
		return readVector(b, o + VELOCITY)
	elseif kind == 3 then
		return readf64(b, o + AGE)
	elseif kind == 4 then
		return readf64(b, o + DEBT)
	elseif kind == 5 then
		return readf64(b, o + SCALE)
	elseif kind == 6 then
		return band(readu8(b, o + FLAGS), DEAD) ~= 0
	elseif kind == 7 then
		return band(readu8(b, o + FLAGS), SPAWN_STREAMED) ~= 0
	elseif kind == 8 then
		return band(readu8(b, o + FLAGS), SYNCED) ~= 0
	end
	return readf64(b, o + MARK)
end

local function write(slot: number, kind: number, value: any)
	local b, o = Store.data, slot * STRIDE
	if kind == 1 then
		writeVector(b, o + POSITION, if typeof(value) == "Vector3" then value else BAD_POSITION)
	elseif kind == 2 then
		-- (Step turns a non-vector Velocity into zero; same here)
		writeVector(b, o + VELOCITY, if typeof(value) == "Vector3" then value else Vector3.zero)
	elseif kind == 3 then
		writef64(b, o + AGE, tonumber(value) or 0)
	elseif kind == 4 then
		writef64(b, o + DEBT, tonumber(value) or 0)
	elseif kind == 5 then
		writef64(b, o + SCALE, if type(value) == "number" then value else 1)
	elseif kind == 6 then
		flag(b, o, DEAD, value == true)
	elseif kind == 7 then
		flag(b, o, SPAWN_STREAMED, value == true)
	elseif kind == 8 then
		flag(b, o, SYNCED, value == true)
	else
		writef64(b, o + MARK, tonumber(value) or 0)
	end
	if kind <= MOTION_LAST then
		flag(b, o, DIRTY, true)
	end
end

local function allocate(): number
	local slot = table.remove(free)
	if slot then
		return slot
	end
	slot = used
	used += 1
	if used > capacity then
		local grown = buffer.create(capacity * 2 * STRIDE)
		buffer.copy(grown, 0, Store.data, 0, capacity * STRIDE)
		capacity *= 2
		Store.data = grown
	end
	Store.Generation[slot] = 0
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

-- The metatable live projectiles get: hot fields go to the record, anything
-- else is an ordinary field (or a method from `class`).
function Store.Metatable(class: any): any
	return {
		__index = function(self: any, key: any): any
			local kind = HOT[key]
			if kind then
				return read(self._slot, kind)
			end
			return class[key]
		end,
		__newindex = function(self: any, key: any, value: any)
			local kind = HOT[key]
			if kind then
				write(self._slot, kind, value)
			else
				rawset(self, key, value)
			end
		end,
	}
end

-- Moves a new projectile table's hot fields into a fresh record and gives it
-- `metatable` (from Store.Metatable). Returns the table.
function Store.Adopt(state: any, metatable: any): any
	local slot = allocate()
	local b, o = Store.data, slot * STRIDE
	buffer.fill(b, o, 0, STRIDE)
	for key, kind in HOT do
		local value = rawget(state, key)
		rawset(state, key, nil)
		write(slot, kind, value)
	end
	local flags = band(readu8(b, o + FLAGS), bnot(DIRTY))
	if state.Visualize then
		flags = bor(flags, VISUALIZE)
	end
	if state.Beam ~= nil then
		flags = bor(flags, BEAM)
	end
	writeu8(b, o + FLAGS, flags)
	writeu32(b, o + SOURCE, addSource(state.Source))
	rawset(state, "_slot", slot)
	return setmetatable(state, metatable)
end

-- Copies a projectile's hot fields back into its table as plain fields,
-- gives it `metatable` (the class) and frees its record. No-op if it has none.
function Store.Release(state: any, metatable: any)
	local slot = rawget(state, "_slot")
	if not slot then
		return
	end
	dropSource(readu32(Store.data, slot * STRIDE + SOURCE))
	setmetatable(state, metatable)
	rawset(state, "_slot", nil)
	for key, kind in HOT do
		rawset(state, key, read(slot, kind))
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
	return copy
end

function Store.ClearDirty(slot: number)
	flag(Store.data, slot * STRIDE, DIRTY, false)
end

-- Live slots (for the Stats tab).
function Store.Count(): number
	return used - #free
end

return Store
