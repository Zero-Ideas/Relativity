--!native
--!strict
--!optimize 2
--[[
	Projectile/BeamWire.luau
	Binary stream for sustained beam chains: server Projectile/BeamChain ->
	client Projectile/Client/BeamChainVisual. A chain's samples move
	deterministically between events, so only events cross the wire (a new
	sample, a bounce, a link change, a clipped body, a death), never a pose per
	sample per frame.

	One message per recipient per frame, on Channel: a run of sections.
	  Section := u32 chainId, u8 kind, f64 serverTime (end of the server frame)
	             [Snapshot: Header] Op* u8 Op.End
	  Header  := f32 radius, f32 length, u8x3 color, u8x3 core, f32x3 gravity, f32 timeScale
	  Op.Spawn  := u32 id, v3 pos, v3 vel, f32 life, u32 ahead, u8 flags,
	               [Fragment: v3 offset] [Origin: v3 origin], u8 n, v3 x n turns
	  Op.Pose   := u32 id, v3 pos, v3 vel, f32 life
	  Op.Bounce := u32 id, v3 pos, v3 vel, v3 contact, v3 normal, u8 n, v3 x n new turns
	  Op.Link   := u32 id, u32 ahead, [ahead == 0: v3 fragment offset]
	  Op.Clip   := u32 id, u8 n, v3 x n (n == 0: the body is whole again)
	  Op.Death  := u32 id, u8 kind, [kind ~= Expire: v3 contact, v3 normal, u8 bodyHit]
	               (a World death without bodyHit parks one radius off the wall)
	  Op.Scale  := f32 timeScale (the chain's personal/local dilation)
	Section.End: the chain is gone on the server (every death already sent).
	Section.Exit: this client left the chain's range; drop it without drains.

	Flowing beams (server Projectile/BeamFlow -> client BeamFlowVisual) use
	FlowChannel, with the same Section framing plus an f32 beam clock after
	the server time:
	  Header    := f32 radius, f32 lifetime, u8x3 color, u8x3 core, f32x3 accel, f32 timeScale
	  FlowOp.Add    := u32 id, u32 olderId (0: the front), u8 kind, u8 flags, v3 pos, v3 vel, f32 age, f32 tau
	  FlowOp.Pin    := u32 id, v3 pos, f32 tau        (a pinned / source point moved)
	  FlowOp.State  := u32 id, u8 kind, u8 flags, v3 pos, v3 vel, f32 age, f32 tau
	  FlowOp.Remove := u32 id
	  FlowOp.Order  := u32 id, u32 olderId           (flowed past a pinned point)
	  FlowOp.Scale  := f32 timeScale
	  FlowOp.Impact := v3 pos, v3 normal, u8 kind (Death kinds)
	Points are ordered oldest (the front) to newest; material joins each
	point to the next older one unless the newer has FlowFlag.Gap.
]]

local BeamWire = {}

BeamWire.Channel = "ProjBeamChain"
BeamWire.Section = table.freeze({ Delta = 0, Snapshot = 1, End = 2, Exit = 3 })
BeamWire.Op = table.freeze({ End = 0, Spawn = 1, Pose = 2, Bounce = 3, Link = 4, Clip = 5, Death = 6, Scale = 7 })
BeamWire.Death = table.freeze({ Expire = 0, World = 1, Entity = 2, Other = 3 })
-- Stopped: a sample already parked at a wall (dead), still anchoring followers.
BeamWire.SpawnFlag = table.freeze({ Fragment = 1, Origin = 2, Joiner = 4, EverLinked = 8, Stopped = 16 })

BeamWire.FlowChannel = "ProjBeamFlow"
BeamWire.FlowOp = table.freeze({ End = 0, Add = 1, Pin = 2, State = 3, Remove = 4, Order = 5, Scale = 6, Impact = 7 })
-- Free: moves with the beam. Source: the caster's end. Cut: pinned where the
-- beam meets something that stops it. Corner: pinned where it bounces. In /
-- Out: pinned where it enters / leaves something it passes through.
BeamWire.AnchorKind = table.freeze({ Free = 0, Source = 1, Cut = 2, Corner = 3, In = 4, Out = 5 })
BeamWire.FlowFlag = table.freeze({ Gap = 1 })

export type Writer = { buf: buffer, n: number }

function BeamWire.Writer(size: number?): Writer
	return { buf = buffer.create(size or 256), n = 0 }
end

local function reserve(w: Writer, bytes: number)
	local need = w.n + bytes
	local size = buffer.len(w.buf)
	if need <= size then
		return
	end
	while size < need do
		size *= 2
	end
	local grown = buffer.create(size)
	buffer.copy(grown, 0, w.buf, 0, w.n)
	w.buf = grown
end
BeamWire.Reserve = reserve

function BeamWire.U8(w: Writer, v: number)
	reserve(w, 1)
	buffer.writeu8(w.buf, w.n, v)
	w.n += 1
end

function BeamWire.U32(w: Writer, v: number)
	reserve(w, 4)
	buffer.writeu32(w.buf, w.n, v)
	w.n += 4
end

function BeamWire.F32(w: Writer, v: number)
	reserve(w, 4)
	buffer.writef32(w.buf, w.n, v)
	w.n += 4
end

function BeamWire.F64(w: Writer, v: number)
	reserve(w, 8)
	buffer.writef64(w.buf, w.n, v)
	w.n += 8
end

function BeamWire.V3(w: Writer, v: Vector3)
	reserve(w, 12)
	local b, n = w.buf, w.n
	buffer.writef32(b, n, v.X)
	buffer.writef32(b, n + 4, v.Y)
	buffer.writef32(b, n + 8, v.Z)
	w.n = n + 12
end

-- Appends `from`'s bytes to `w`.
function BeamWire.Append(w: Writer, from: Writer)
	if from.n == 0 then
		return
	end
	reserve(w, from.n)
	buffer.copy(w.buf, w.n, from.buf, 0, from.n)
	w.n += from.n
end

-- The written bytes as one exactly-sized buffer.
function BeamWire.Finish(w: Writer): buffer
	local out = buffer.create(w.n)
	buffer.copy(out, 0, w.buf, 0, w.n)
	return out
end

export type Reader = { buf: buffer, n: number }

function BeamWire.Reader(buf: buffer): Reader
	return { buf = buf, n = 0 }
end

function BeamWire.More(r: Reader): boolean
	return r.n < buffer.len(r.buf)
end

function BeamWire.ReadU8(r: Reader): number
	local v = buffer.readu8(r.buf, r.n)
	r.n += 1
	return v
end

function BeamWire.ReadU32(r: Reader): number
	local v = buffer.readu32(r.buf, r.n)
	r.n += 4
	return v
end

function BeamWire.ReadF32(r: Reader): number
	local v = buffer.readf32(r.buf, r.n)
	r.n += 4
	return v
end

function BeamWire.ReadF64(r: Reader): number
	local v = buffer.readf64(r.buf, r.n)
	r.n += 8
	return v
end

function BeamWire.ReadV3(r: Reader): Vector3
	local b, n = r.buf, r.n
	r.n = n + 12
	return Vector3.new(buffer.readf32(b, n), buffer.readf32(b, n + 4), buffer.readf32(b, n + 8))
end

return BeamWire
