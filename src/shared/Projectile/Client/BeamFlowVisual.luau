--!strict
--[[
	Projectile/Client/BeamFlowVisual.luau
	Draws flowing beams from the server's BeamWire.FlowChannel stream
	(sending side: ServerScriptService Projectile/BeamFlow). Purely cosmetic.

	A beam is an ordered list of points, oldest (the front) to newest (the
	caster's end); material joins each point to the next older one unless
	the newer has a gap. Free points move on their own (velocity + constant
	acceleration, the beam's time scale, chunk dilation) and the front trims
	itself by the lifetime exactly as on the server; pinned points (where the
	beam is cut, bends or passes through something) and the caster's end
	only move when the server says. Every joined pair is one ribbon
	(BeamRibbon), straight runs merged.

	Timing: a beam keeps one clock offset (the smallest transit seen), so
	points from late messages catch up by exactly their extra delay.
]]

local RunService = game:GetService("RunService")
local Shared = script.Parent.Parent.Parent
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local Heartbeat = require(Shared:WaitForChild("Heartbeat"))
local VisualOffload = require(Shared:WaitForChild("VisualOffload"))
local ProjectileShared = Shared:WaitForChild("Projectile")
local Planner = require(ProjectileShared:WaitForChild("StepPlanner"))
local BeamWire = require(ProjectileShared:WaitForChild("BeamWire"))
local View = require(script.Parent.View)
local Impact = require(script.Parent.Impact)
local Ribbon = require(script.Parent.BeamRibbon)

local FlowOp, FlowFlag, Section, Kind, DeathKind =
	BeamWire.FlowOp, BeamWire.FlowFlag, BeamWire.Section, BeamWire.AnchorKind, BeamWire.Death
local ReadU8, ReadU32, ReadF32, ReadF64, ReadV3 = BeamWire.ReadU8, BeamWire.ReadU32, BeamWire.ReadF32, BeamWire.ReadF64, BeamWire.ReadV3

local BeamFlowVisual = {}

local MAX_PIECES = 3000 -- ribbons shown at once, all beams
local STRAIGHT = 0.15 -- of the radius: how far a merged straight run may stray from a dropped point
local IMPACT_THROTTLE, IMPACT_SPACING = 0.1, 4
local IMPACT_KINDS = { [DeathKind.World] = "world", [DeathKind.Entity] = "entity", [DeathKind.Other] = "detonate" }

type Point = {
	id: number,
	kind: number,
	gap: boolean,
	pos: Vector3,
	vel: Vector3,
	age: number,
	tau: number,
}

local beams: { [number]: any } = {}
local pending: { [any]: { Vector3 } } = {}
local limits = { MaxDistance = 2048, MaxRendered = 5000 }
local enabled = false
local uniform = true

local function newBeam(id: number): any
	local folder = Instance.new("Folder")
	folder.Name = "BeamFlow_" .. id
	folder.Parent = workspace
	local beam = {
		id = id,
		folder = folder,
		ribbons = {},
		points = {} :: { Point },
		byId = {} :: { [number]: Point },
		radius = .35,
		lifetime = 3,
		color = Color3.fromRGB(255, 96, 28),
		core = Color3.new(1, 1, 1),
		accel = Vector3.zero,
		timeScale = 1,
		clock = 0,
		offset = nil :: number?,
		lastImpact = 0,
		impactPoint = Vector3.zero,
	}
	beams[id] = beam
	return beam
end

local function destroyBeam(beam: any)
	beams[beam.id] = nil
	pending[beam] = nil
	Ribbon.Clear(beam.ribbons) -- (their attachments are on Terrain)
	beam.folder:Destroy()
end

local function simulated(beam: any, seconds: number): number
	return seconds * Heartbeat.GetGlobalTimeScale() * beam.timeScale
end

local function move(beam: any, point: Point, dt: number)
	if dt <= 0 or point.kind ~= Kind.Free then
		return
	end
	if not uniform then
		dt *= Planner.ChunkTimeScaleAt(point.pos)
	end
	local accel = beam.accel
	point.pos += point.vel * dt + accel * (.5 * dt * dt)
	point.vel += accel * dt
	point.age += dt
end

-- The extra delay of a section stamped `serverTime` over the beam's
-- fastest-seen transit (re-baselining everything if this one was faster).
local function lagOf(beam: any, serverTime: number): number
	local transit = math.max(workspace:GetServerTimeNow() - serverTime, 0)
	local offset = beam.offset
	if not offset then
		beam.offset = transit
		return 0
	end
	if transit < offset then
		local catchUp = simulated(beam, offset - transit)
		for _, point in beam.points do
			move(beam, point, catchUp)
		end
		beam.offset = transit
		return 0
	end
	return transit - offset
end

local function indexOf(beam: any, id: number): number?
	local point = beam.byId[id]
	return if point then table.find(beam.points, point) else nil
end

-- Puts `point` just newer than point `olderId` (0: the front), or by its tau
-- when that one is already gone here.
local function place(beam: any, point: Point, olderId: number)
	local points = beam.points
	local at: number
	if olderId == 0 then
		at = 1
	else
		local index = indexOf(beam, olderId)
		if index then
			at = index + 1
		else
			at = #points + 1
			for index2, other in points do
				if other.tau > point.tau then
					at = index2
					break
				end
			end
		end
	end
	table.insert(points, at, point)
end

local function playImpact(beam: any, position: Vector3, normal: Vector3, kind: number)
	if not View.contains(position) then
		return
	end
	local now = os.clock()
	if now - beam.lastImpact < IMPACT_THROTTLE and (position - beam.impactPoint).Magnitude < IMPACT_SPACING then
		return
	end
	beam.lastImpact, beam.impactPoint = now, position
	Impact.Play(position, normal, IMPACT_KINDS[kind] or "world")
end

local function readSection(r: BeamWire.Reader)
	local id = ReadU32(r)
	local kind = ReadU8(r)
	local serverTime = ReadF64(r)
	local clock = ReadF32(r)
	local beam = beams[id]
	if kind == Section.Snapshot then
		if beam then
			table.clear(beam.points)
			table.clear(beam.byId)
			beam.offset = nil
		else
			beam = newBeam(id)
		end
		beam.radius = math.max(ReadF32(r), .025)
		beam.lifetime = ReadF32(r)
		beam.color = Color3.fromRGB(ReadU8(r), ReadU8(r), ReadU8(r))
		beam.core = Color3.fromRGB(ReadU8(r), ReadU8(r), ReadU8(r))
		beam.accel = ReadV3(r)
		beam.timeScale = ReadF32(r)
	elseif kind == Section.Exit or kind == Section.End then
		if beam then
			destroyBeam(beam)
		end
		beam = nil
	end
	if beam then
		beam.clock = clock
	end
	local lag = if beam then lagOf(beam, serverTime) else 0
	while true do
		local op = ReadU8(r)
		if op == FlowOp.End then
			return
		elseif op == FlowOp.Add then
			local pointId, olderId, pointKind, flags = ReadU32(r), ReadU32(r), ReadU8(r), ReadU8(r)
			local pos, vel, age, tau = ReadV3(r), ReadV3(r), ReadF32(r), ReadF32(r)
			if beam and not beam.byId[pointId] then
				local point: Point = { id = pointId, kind = pointKind, gap = bit32.btest(flags, FlowFlag.Gap),
					pos = pos, vel = vel, age = age, tau = tau }
				beam.byId[pointId] = point
				place(beam, point, olderId)
				move(beam, point, simulated(beam, lag))
			end
		elseif op == FlowOp.Pin then
			local pointId, pos, tau = ReadU32(r), ReadV3(r), ReadF32(r)
			local point = beam and beam.byId[pointId]
			if point then
				point.pos, point.tau = pos, tau
				point.age = math.max(beam.clock - tau, 0)
			end
		elseif op == FlowOp.State then
			local pointId, pointKind, flags = ReadU32(r), ReadU8(r), ReadU8(r)
			local pos, vel, age, tau = ReadV3(r), ReadV3(r), ReadF32(r), ReadF32(r)
			local point = beam and beam.byId[pointId]
			if point then
				point.kind, point.gap = pointKind, bit32.btest(flags, FlowFlag.Gap)
				point.pos, point.vel, point.age, point.tau = pos, vel, age, tau
				move(beam, point, simulated(beam, lag))
			end
		elseif op == FlowOp.Remove then
			local pointId = ReadU32(r)
			if beam then
				local index = indexOf(beam, pointId)
				if index then
					table.remove(beam.points, index)
				end
				beam.byId[pointId] = nil
			end
		elseif op == FlowOp.Order then
			local pointId, olderId = ReadU32(r), ReadU32(r)
			if beam then
				local index = indexOf(beam, pointId)
				if index then
					local point = table.remove(beam.points, index) :: Point
					place(beam, point, olderId)
				end
			end
		elseif op == FlowOp.Scale then
			local scale = ReadF32(r)
			if beam then
				beam.timeScale = scale
			end
		elseif op == FlowOp.Impact then
			local pos, normal, impactKind = ReadV3(r), ReadV3(r), ReadU8(r)
			if beam then
				playImpact(beam, pos, normal, impactKind)
			end
		else
			warn("[BeamFlowVisual] unknown op", op)
			r.n = buffer.len(r.buf)
			return
		end
	end
end

local function onMessage(payload: any)
	if typeof(payload) ~= "buffer" then
		return
	end
	local r = BeamWire.Reader(payload)
	while BeamWire.More(r) do
		readSection(r)
	end
end

-- The front: material older than the lifetime is gone (as on the server).
local function trim(beam: any)
	local points = beam.points
	local lifetime = beam.lifetime
	while #points > 0 do
		local front = points[1]
		if front.age < lifetime then
			return
		end
		local nextPoint = points[2]
		if not nextPoint or nextPoint.gap or nextPoint.age >= lifetime then
			table.remove(points, 1)
			beam.byId[front.id] = nil
			if points[1] then
				points[1].gap = false
			end
			continue
		end
		local t = math.clamp((front.age - lifetime) / math.max(front.age - nextPoint.age, 1e-6), 0, 1)
		front.pos = front.pos:Lerp(nextPoint.pos, t)
		front.vel = front.vel:Lerp(nextPoint.vel, t)
		front.tau += (nextPoint.tau - front.tau) * t
		front.age = lifetime
		front.kind = Kind.Free
		return
	end
end

function BeamFlowVisual.Step(globalDt: number)
	if not enabled then
		return
	end
	uniform = ChunkManager.IsTimeUniform()
	local camera = workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else Vector3.zero
	local reach = limits.MaxDistance
	local piecesLeft = math.min(MAX_PIECES, limits.MaxRendered)
	for _, beam in beams do
		local dt = simulated(beam, globalDt)
		beam.clock += dt
		for _, point in beam.points do
			if point.kind == Kind.Free then
				move(beam, point, dt)
			else
				point.age = math.max(beam.clock - point.tau, 0)
			end
		end
		trim(beam)

		-- every joined pair, straight runs merged, newest first
		local segments: { Vector3 } = {}
		local points = beam.points
		local tolerance = math.max(beam.radius * STRAIGHT, 1e-3)
		local function flush(run: { Vector3 })
			for index = 1, #run - 1 do
				local a, b = run[index], run[index + 1]
				local mid = (a + b) * .5
				local half = (b - a).Magnitude * .5
				if piecesLeft > 0 and View.contains(mid, half + beam.radius) and (mid - eye).Magnitude - half <= reach then
					table.insert(segments, a)
					table.insert(segments, b)
					piecesLeft -= 1
				end
			end
		end
		local run: { Vector3 } = {}
		local anchor, heading: Vector3? = nil, nil
		for index = #points, 1, -1 do
			local point = points[index]
			local position = point.pos
			if #run == 0 then
				run[1], anchor, heading = position, position, nil
			else
				local offset = position - (anchor :: Vector3)
				if not heading then
					if offset.Magnitude > 1e-3 then
						heading = offset.Unit
					end
					run[#run + 1] = position
				else
					local along = offset:Dot(heading)
					if along > 0 and (offset - heading * along).Magnitude <= tolerance and #run >= 2 then
						run[#run] = position -- (still on the line: extend it)
					else
						anchor = run[#run]
						local leg = position - anchor
						heading = if leg.Magnitude > 1e-3 then leg.Unit else nil
						run[#run + 1] = position
					end
				end
			end
			if point.gap or index == 1 then
				flush(run)
				run, anchor, heading = {}, nil, nil
			end
		end
		pending[beam] = segments
	end
end

-- Attachment moves land before the frame renders.
local function apply()
	for beam, segments in pending do
		pending[beam] = nil
		if not beam.folder.Parent then
			continue
		end
		local diameter = beam.radius * 2
		for index = 1, #segments, 2 do
			Ribbon.Set(beam.ribbons, (index + 1) // 2, beam.folder, segments[index], segments[index + 1], diameter,
				beam.core, beam.color)
		end
		Ribbon.HideAfter(beam.ribbons, #segments // 2)
	end
end

function BeamFlowVisual.SetRenderSettings(settings: { [string]: number })
	for key in limits do
		local value = settings[key]
		if typeof(value) == "number" and value == value and value >= 0 then
			limits[key] = value
		end
	end
end

function BeamFlowVisual.GetStats(): (number, number)
	local beamCount, pointCount = 0, 0
	for _, beam in beams do
		beamCount += 1
		pointCount += #beam.points
	end
	return beamCount, pointCount
end

function BeamFlowVisual.Enable()
	if enabled or RunService:IsServer() then
		return
	end
	enabled = true
	VisualOffload.On(BeamWire.FlowChannel, onMessage)
	RunService.PreSimulation:Connect(apply)
end

return BeamFlowVisual
