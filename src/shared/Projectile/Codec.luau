--!strict
--!native
--!optimize 2
--[[
	Projectile/Codec.luau
	Binary wire format for the two per-frame projectile batches, ProjMove and
	ProjHitBatch (see Projectile.Protocol for the payload fields). A table batch
	makes Roblox send every key name of every entry; these are packed buffers
	instead: each entry is a fixed header plus only the optional fields it
	has, flagged in a bitmask.

	The server encodes each entry ONCE (EncodeMove / EncodeHit -> buffer) and
	Join()s the chunks for each recipient, so nearby players sharing shots
	don't re-encode them. The client decodes a whole message back into the
	same payload tables (DecodeMoves / DecodeHits), so its handlers don't
	change.

	Vectors are 3 x f32 (positions keep ~1/1000 stud at 8000 studs out);
	ServerTime stays f64 -- beam epochs need its full precision.

	Move entry:  u32 Id, u16 flags, f32x3 Position, f32x3 Velocity, then by flag:
	             u32 BeamPreviousId, f64 ServerTime, f32 GlobalScale,
	             f32 TimeScale, path BeamPath, f32 Lifetime, f32x3 Point,
	             f32x3 Normal          (Bounced / Corrected / BeamClipped are flags)
	Hit entry:   u32 Id, u8 flags, f32x3 Position, f32x3 Normal, then by flag:
	             string Kind, path BeamPath        (BeamBody / BeamClipped are flags)
	path:        u16 count, count x f32x3;  string: u8 length, bytes
]]

local ProjectileCodec = {}

local MOVE_BOUNCED = 0x001
local MOVE_CORRECTED = 0x002
local MOVE_PREVIOUS = 0x004
local MOVE_SERVER_TIME = 0x008
local MOVE_GLOBAL_SCALE = 0x010
local MOVE_TIME_SCALE = 0x020
local MOVE_PATH = 0x040
local MOVE_CLIPPED = 0x080
local MOVE_LIFETIME = 0x100
local MOVE_POINT = 0x200
local MOVE_NORMAL = 0x400

local HIT_KIND = 0x01
local HIT_BEAM_BODY = 0x02
local HIT_PATH = 0x04
local HIT_CLIPPED = 0x08

local MAX_PATH = 65535
local MAX_KIND = 255

local writeu8, writeu16, writeu32 = buffer.writeu8, buffer.writeu16, buffer.writeu32
local writef32, writef64, writestring = buffer.writef32, buffer.writef64, buffer.writestring
local readu8, readu16, readu32 = buffer.readu8, buffer.readu16, buffer.readu32
local readf32, readf64, readstring = buffer.readf32, buffer.readf64, buffer.readstring
local band, bor = bit32.band, bit32.bor

local function writeVector(b: buffer, offset: number, v: Vector3): number
	writef32(b, offset, v.X)
	writef32(b, offset + 4, v.Y)
	writef32(b, offset + 8, v.Z)
	return offset + 12
end

local function readVector(b: buffer, offset: number): (Vector3, number)
	return Vector3.new(readf32(b, offset), readf32(b, offset + 4), readf32(b, offset + 8)), offset + 12
end

local function pathSize(path: { Vector3 }): number
	return 2 + math.min(#path, MAX_PATH) * 12
end

local function writePath(b: buffer, offset: number, path: { Vector3 }): number
	local count = math.min(#path, MAX_PATH)
	writeu16(b, offset, count)
	offset += 2
	for index = 1, count do
		offset = writeVector(b, offset, path[index])
	end
	return offset
end

local function readPath(b: buffer, offset: number): ({ Vector3 }, number)
	local count = readu16(b, offset)
	offset += 2
	local path = table.create(count)
	for index = 1, count do
		path[index], offset = readVector(b, offset)
	end
	return path, offset
end

--------------------------------------------------------------------------------
-- ProjMove
--------------------------------------------------------------------------------

function ProjectileCodec.EncodeMove(p: any): buffer
	local flags, size = 0, 4 + 2 + 12 + 12
	if p.Bounced then flags = bor(flags, MOVE_BOUNCED) end
	if p.Corrected then flags = bor(flags, MOVE_CORRECTED) end
	if p.BeamPreviousId ~= nil then flags = bor(flags, MOVE_PREVIOUS); size += 4 end
	if p.ServerTime ~= nil then flags = bor(flags, MOVE_SERVER_TIME); size += 8 end
	if p.GlobalScale ~= nil then flags = bor(flags, MOVE_GLOBAL_SCALE); size += 4 end
	if p.TimeScale ~= nil then flags = bor(flags, MOVE_TIME_SCALE); size += 4 end
	if p.BeamPath ~= nil then flags = bor(flags, MOVE_PATH); size += pathSize(p.BeamPath) end
	if p.BeamClipped then flags = bor(flags, MOVE_CLIPPED) end
	if p.Lifetime ~= nil then flags = bor(flags, MOVE_LIFETIME); size += 4 end
	if p.Point ~= nil then flags = bor(flags, MOVE_POINT); size += 12 end
	if p.Normal ~= nil then flags = bor(flags, MOVE_NORMAL); size += 12 end

	local b = buffer.create(size)
	writeu32(b, 0, p.Id)
	writeu16(b, 4, flags)
	local offset = writeVector(b, 6, p.Position)
	offset = writeVector(b, offset, p.Velocity)
	if p.BeamPreviousId ~= nil then writeu32(b, offset, p.BeamPreviousId); offset += 4 end
	if p.ServerTime ~= nil then writef64(b, offset, p.ServerTime); offset += 8 end
	if p.GlobalScale ~= nil then writef32(b, offset, p.GlobalScale); offset += 4 end
	if p.TimeScale ~= nil then writef32(b, offset, p.TimeScale); offset += 4 end
	if p.BeamPath ~= nil then offset = writePath(b, offset, p.BeamPath) end
	if p.Lifetime ~= nil then writef32(b, offset, p.Lifetime); offset += 4 end
	if p.Point ~= nil then offset = writeVector(b, offset, p.Point) end
	if p.Normal ~= nil then writeVector(b, offset, p.Normal) end
	return b
end

function ProjectileCodec.DecodeMoves(b: buffer): { any }
	local list = {}
	local offset, length = 0, buffer.len(b)
	while offset < length do
		local p: any = { Id = readu32(b, offset) }
		local flags = readu16(b, offset + 4)
		p.Position, offset = readVector(b, offset + 6)
		p.Velocity, offset = readVector(b, offset)
		if band(flags, MOVE_BOUNCED) ~= 0 then p.Bounced = true end
		if band(flags, MOVE_CORRECTED) ~= 0 then p.Corrected = true end
		if band(flags, MOVE_PREVIOUS) ~= 0 then p.BeamPreviousId = readu32(b, offset); offset += 4 end
		if band(flags, MOVE_SERVER_TIME) ~= 0 then p.ServerTime = readf64(b, offset); offset += 8 end
		if band(flags, MOVE_GLOBAL_SCALE) ~= 0 then p.GlobalScale = readf32(b, offset); offset += 4 end
		if band(flags, MOVE_TIME_SCALE) ~= 0 then p.TimeScale = readf32(b, offset); offset += 4 end
		if band(flags, MOVE_PATH) ~= 0 then p.BeamPath, offset = readPath(b, offset) end
		if band(flags, MOVE_CLIPPED) ~= 0 then p.BeamClipped = true end
		if band(flags, MOVE_LIFETIME) ~= 0 then p.Lifetime = readf32(b, offset); offset += 4 end
		if band(flags, MOVE_POINT) ~= 0 then p.Point, offset = readVector(b, offset) end
		if band(flags, MOVE_NORMAL) ~= 0 then p.Normal, offset = readVector(b, offset) end
		table.insert(list, p)
	end
	return list
end

--------------------------------------------------------------------------------
-- ProjHitBatch
--------------------------------------------------------------------------------

function ProjectileCodec.EncodeHit(p: any): buffer
	local flags, size = 0, 4 + 1 + 12 + 12
	local kind: string? = p.Kind
	if kind ~= nil then
		kind = string.sub(kind, 1, MAX_KIND)
		flags = bor(flags, HIT_KIND)
		size += 1 + #(kind :: string)
	end
	if p.BeamBody then flags = bor(flags, HIT_BEAM_BODY) end
	if p.BeamPath ~= nil then flags = bor(flags, HIT_PATH); size += pathSize(p.BeamPath) end
	if p.BeamClipped then flags = bor(flags, HIT_CLIPPED) end

	local b = buffer.create(size)
	writeu32(b, 0, p.Id)
	writeu8(b, 4, flags)
	local offset = writeVector(b, 5, p.Position)
	offset = writeVector(b, offset, p.Normal)
	if kind ~= nil then
		writeu8(b, offset, #kind)
		writestring(b, offset + 1, kind)
		offset += 1 + #kind
	end
	if p.BeamPath ~= nil then writePath(b, offset, p.BeamPath) end
	return b
end

function ProjectileCodec.DecodeHits(b: buffer): { any }
	local list = {}
	local offset, length = 0, buffer.len(b)
	while offset < length do
		local p: any = { Id = readu32(b, offset) }
		local flags = readu8(b, offset + 4)
		p.Position, offset = readVector(b, offset + 5)
		p.Normal, offset = readVector(b, offset)
		if band(flags, HIT_KIND) ~= 0 then
			local count = readu8(b, offset)
			p.Kind = readstring(b, offset + 1, count)
			offset += 1 + count
		end
		if band(flags, HIT_BEAM_BODY) ~= 0 then p.BeamBody = true end
		if band(flags, HIT_PATH) ~= 0 then p.BeamPath, offset = readPath(b, offset) end
		if band(flags, HIT_CLIPPED) ~= 0 then p.BeamClipped = true end
		table.insert(list, p)
	end
	return list
end

--------------------------------------------------------------------------------
-- Batching
--------------------------------------------------------------------------------

-- Concatenates encoded entries into one message.
function ProjectileCodec.Join(chunks: { buffer }): buffer
	local total = 0
	for _, chunk in chunks do
		total += buffer.len(chunk)
	end
	local out = buffer.create(total)
	local offset = 0
	for _, chunk in chunks do
		local size = buffer.len(chunk)
		buffer.copy(out, offset, chunk, 0, size)
		offset += size
	end
	return out
end

return ProjectileCodec
