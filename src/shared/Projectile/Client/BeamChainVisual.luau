--!strict
--[[
	Projectile/Client/BeamChainVisual.luau
	Draws sustained beam chains from the server's BeamWire stream (sending
	side: ServerScriptService Projectile/BeamChain). Purely cosmetic.

	Each chain is a set of samples moving deterministically (velocity +
	constant acceleration, the chain's time scale, chunk dilation) between the
	server's events. Every frame each sample's body is rebuilt the way the
	server builds it: to the sample ahead through the bounce corners
	(BeamPath.Plan), else its clipped / fragment / tail body. One pooled set of
	cylinders per chain, posed through Motor6D.Transform like BeamVisual.

	Timing: a chain keeps one clock offset (the smallest transit seen), so
	samples from late messages catch up by exactly their extra delay and stay
	evenly spaced instead of inheriting network jitter.

	Drawing: bodies are joined end to end into strands (a sample's body ends
	where the one ahead of it starts) and vertices that are straight to within
	a fraction of the radius are dropped, so a steady beam is a handful of
	long cylinders however many samples it has. Cylinders are cut at fixed
	lengths from the back, so only the front piece of a strand changes size.
]]

local RunService = game:GetService("RunService")
local Shared = script.Parent.Parent.Parent
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local Heartbeat = require(Shared:WaitForChild("Heartbeat"))
local VisualOffload = require(Shared:WaitForChild("VisualOffload"))
local ProjectileShared = Shared:WaitForChild("Projectile")
local Planner = require(ProjectileShared:WaitForChild("StepPlanner"))
local BeamPath = require(ProjectileShared:WaitForChild("BeamPath"))
local BeamWire = require(ProjectileShared:WaitForChild("BeamWire"))
local View = require(script.Parent.View)
local Impact = require(script.Parent.Impact)

local Op, Section, DeathKind, Flag = BeamWire.Op, BeamWire.Section, BeamWire.Death, BeamWire.SpawnFlag
local ReadU8, ReadU32, ReadF32, ReadF64, ReadV3 = BeamWire.ReadU8, BeamWire.ReadU32, BeamWire.ReadF32, BeamWire.ReadF64, BeamWire.ReadV3

local BeamChainVisual = {}

local MAX_SEGMENT = 128 -- studs per pooled cylinder
local STRAIGHT = 0.15 -- of the radius: how far a merged straight run may stray from a dropped vertex
local EXPIRE_GRACE = 0.5 -- seconds a sample out of life waits for the server's death before dying here
local MAX_PARTS_PER_FRAME = 3000 -- cylinders + joint balls shown at once, all chains (about where a live server starts to lag)
local JOINT_COS = math.cos(math.rad(12)) -- bends sharper than this get a ball
local DEAD_GRACE = 0.25 -- real seconds a dead sample is kept for in-flight messages
local GHOST_LIFETIME = 1.5 -- a dead sample still named as a link target
local DRAIN_LIMIT = 5
local IMPACT_THROTTLE, IMPACT_SPACING = 0.1, 4
local ROTATION = CFrame.Angles(0, math.pi / 2, 0) -- cylinder X axis -> path Z
local SIZE_SLACK = 0.02 -- studs a cylinder may be off before its Size is rewritten
local DEATH_KINDS = { [DeathKind.World] = "world", [DeathKind.Entity] = "entity", [DeathKind.Other] = "detonate" }

type Sample = {
	id: number,
	pos: Vector3,
	vel: Vector3,
	life: number,
	ahead: number,
	turns: { Vector3 },
	origin: Vector3?,
	fragment: Vector3?,
	everLinked: boolean,
	clip: { Vector3 }?,
	dead: boolean,
	stopped: boolean,
	diedAt: number,
	expiredAt: number?,
}

local chains: { [number]: any } = {}
local pending: { [any]: any } = {}
-- The player's projectile render limits (ClientSettings, via
-- ProjectileClient.SetRenderSettings): nothing past MaxDistance studs from
-- the camera is drawn, at most MaxRendered pieces (cylinders + joint balls)
-- are shown across all chains, and about MaxUpdates pieces are rebuilt per
-- frame -- chains past that keep their last pose and go first next frame.
local limits = { MaxDistance = 2048, MaxRendered = 5000, MaxUpdates = 2500 }
local applyConnection: RBXScriptConnection? = nil
local enabled = false
local uniform = true

--------------------------------------------------------------------------------
-- Rig (cf. BeamVisual)
--------------------------------------------------------------------------------

local function part(parent: Instance, name: string, color: Color3, pose: CFrame?): Part
	local p = Instance.new("Part")
	p.Name, p.Color, p.Transparency = name, color, 1
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.one * 0.05
	p.Material = Enum.Material.Neon
	p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = false, false, false, false
	p.Massless = true -- (cosmetic: no mass to recompute when it's resized)
	-- (posed before becoming visible: no one-frame default-axis flash)
	if pose then
		p.CFrame = pose
	end
	p.Parent = parent
	return p
end

local function motor(driver: BasePart, p: BasePart, pose: CFrame?): Motor6D
	local joint = Instance.new("Motor6D")
	joint.C0 = if pose then driver.CFrame:ToObjectSpace(pose) else CFrame.identity
	joint.Part0, joint.Part1, joint.Parent = driver, p, driver
	return joint
end

local function shape(chain: any, pool: { any }, index: number, pose: CFrame, size: Vector3, ball: boolean)
	local pair = pool[index]
	if not pair then
		local core = part(chain.model, if ball then "BeamJointCore" else "BeamCore", chain.core, pose)
		local glow = part(chain.model, if ball then "BeamJointGlow" else "BeamGlow", chain.color, pose)
		if ball then
			core.Shape, glow.Shape = Enum.PartType.Ball, Enum.PartType.Ball
		end
		local coreMotor = motor(chain.driver, core, pose)
		pair = { core = core, glow = glow, coreMotor = coreMotor, glowMotor = motor(chain.driver, glow, pose),
			inverse = coreMotor.C0:Inverse() }
		pool[index] = pair
	end
	-- (the driver never moves and a pair's C0 never changes: keep both
	-- inverses instead of reading them back every frame)
	local driverInverse = chain.driverInverse
	if not driverInverse then
		driverInverse = chain.driver.CFrame:Inverse()
		chain.driverInverse = driverInverse
	end
	local transform = pair.inverse * (driverInverse * pose)
	local last = pair.size
	if not last or math.abs(last.X - size.X) > SIZE_SLACK or math.abs(last.Y - size.Y) > SIZE_SLACK then
		-- (a beam's length jitters by float error every frame; changes this
		-- small are invisible, and each write rebuilds the part)
		pair.size = size
		pair.core.Size = if ball then size * .55 else Vector3.new(size.X, size.Y * .55, size.Z * .55)
		pair.glow.Size = size
	end
	pair.coreMotor.Transform = transform
	pair.glowMotor.Transform = transform
	if not pair.shown then
		pair.shown = true
		pair.core.Transparency, pair.glow.Transparency = 0, .5
	end
end

local function hideAfter(pool: { any }, used: number)
	for index = used + 1, #pool do
		local pair = pool[index]
		if pair.shown then
			pair.shown = false
			pair.core.Transparency, pair.glow.Transparency = 1, 1
		end
	end
end

-- Size and pose land together before the engine commits transforms.
local function apply()
	for chain, geometry in pending do
		pending[chain] = nil
		if not chain.model.Parent then
			continue
		end
		local diameter = chain.radius * 2
		local segments = geometry.segments
		for index = 1, #segments, 2 do
			local a, b = segments[index], segments[index + 1]
			local offset = b - a
			local length = offset.Magnitude
			local up = if math.abs(offset.Y / length) > .99 then Vector3.xAxis else Vector3.yAxis
			shape(chain, chain.segments, (index + 1) // 2, CFrame.lookAt((a + b) * .5, b, up) * ROTATION,
				Vector3.new(length, diameter, diameter), false)
		end
		hideAfter(chain.segments, #segments // 2)
		for index, point in geometry.joints do
			shape(chain, chain.joints, index, CFrame.new(point), Vector3.one * diameter, true)
		end
		hideAfter(chain.joints, #geometry.joints)
	end
end

--------------------------------------------------------------------------------
-- Chains
--------------------------------------------------------------------------------

local function newChain(id: number): any
	local model = Instance.new("Model")
	model.Name = "BeamChain_" .. id
	local chain = {
		id = id,
		model = model,
		driver = nil :: any,
		radius = .35,
		length = 24,
		color = Color3.fromRGB(255, 96, 28),
		core = Color3.new(1, 1, 1),
		gravity = Vector3.zero,
		timeScale = 1,
		offset = nil :: number?,
		samples = {} :: { [number]: Sample },
		segments = {},
		joints = {},
		drains = {},
		ended = false,
		lastImpact = 0,
		impactPoint = Vector3.zero,
	}
	chains[id] = chain
	return chain
end

local function destroyChain(chain: any)
	chains[chain.id] = nil
	pending[chain] = nil
	chain.model:Destroy()
end

local function advance(chain: any, s: Sample, dt: number)
	if dt <= 0 or s.stopped or s.life <= 0 then
		return
	end
	if not uniform then
		dt *= Planner.ChunkTimeScaleAt(s.pos)
	end
	dt = math.min(dt, s.life)
	local g = chain.gravity
	s.pos += s.vel * dt + g * (.5 * dt * dt)
	s.vel += g * dt
	s.life -= dt
end

-- Real seconds -> this chain's simulated seconds.
local function simulated(chain: any, seconds: number): number
	return seconds * Heartbeat.GetGlobalTimeScale() * chain.timeScale
end

-- The extra delay of a section stamped `serverTime` over the chain's
-- fastest-seen transit (re-baselining everything if this one was faster).
local function lagOf(chain: any, serverTime: number): number
	local transit = math.max(workspace:GetServerTimeNow() - serverTime, 0)
	local offset = chain.offset
	if not offset then
		chain.offset = transit
		return 0
	end
	if transit < offset then
		local catchUp = simulated(chain, offset - transit)
		for _, s in chain.samples do
			advance(chain, s, catchUp)
		end
		chain.offset = transit
		return 0
	end
	return transit - offset
end

local function trim(points: { Vector3 }, distance: number): number
	while distance > 0 and #points > 1 do
		local length = (points[2] - points[1]).Magnitude
		if distance >= length then
			table.remove(points, 1)
			distance -= length
		else
			points[1] = points[1]:Lerp(points[2], distance / length)
			distance = 0
		end
	end
	local total = 0
	for index = 1, #points - 1 do
		total += (points[index + 1] - points[index]).Magnitude
	end
	return total
end

local function tailOf(chain: any, s: Sample): { Vector3 }?
	local origin = s.origin
	if not origin then
		return nil
	end
	-- Back along what it actually travelled: its bounce corners, newest
	-- first, then where it was launched -- capped like the server's tail.
	local cap = math.min(chain.length, BeamPath.MaxStretch)
	local points = { s.pos }
	local total, last = 0, s.pos
	local turns = s.turns
	for index = #turns + 1, 1, -1 do
		local point = if index > 1 then turns[index - 1] else origin
		local span = (point - last).Magnitude
		if span < 1e-4 then
			continue
		end
		if total + span >= cap then
			table.insert(points, last:Lerp(point, (cap - total) / span))
			return points
		end
		total += span
		table.insert(points, point)
		last = point
	end
	return points
end

-- This sample's body, built exactly as the server builds it.
local function pathOf(chain: any, s: Sample, incoming: { [number]: boolean }): { Vector3 }?
	if s.dead then
		return nil
	end
	local clip = s.clip
	if clip then
		local points = table.clone(clip)
		points[1] = s.pos
		return points
	end
	if s.ahead ~= 0 then
		local ahead = chain.samples[s.ahead]
		if not ahead then
			return nil
		end
		if #s.turns == 0 and #ahead.turns == 0 then
			-- (the usual straight link: what Plan returns, without a new
			-- table every frame -- callers that keep it must copy it)
			local path = s.straight
			if not path then
				path = {}
				s.straight = path
			end
			table.clear(path)
			path[1] = s.pos
			if (ahead.pos - s.pos).Magnitude > 1e-4 then
				path[2] = ahead.pos
			end
			return path
		end
		return (BeamPath.Plan(s.pos, ahead.pos, s.turns, ahead.turns))
	end
	if incoming[s.id] then
		return nil
	end
	local fragment = s.fragment
	if fragment then
		return { s.pos, s.pos + fragment }
	end
	if not s.everLinked then
		return tailOf(chain, s)
	end
	return nil
end

local function incomingOf(chain: any, into: { [number]: boolean }?): { [number]: boolean }
	local incoming = into or {}
	if into then
		table.clear(into)
	end
	for _, s in chain.samples do
		if not s.dead and s.ahead ~= 0 then
			incoming[s.ahead] = true
		end
	end
	return incoming
end

local function playImpact(chain: any, point: Vector3, normal: Vector3, kind: string)
	if not View.contains(point) then
		return
	end
	-- Cosmetic throttle only: every packet's server damage is unaffected.
	local now = os.clock()
	if now - chain.lastImpact < IMPACT_THROTTLE and (point - chain.impactPoint).Magnitude < IMPACT_SPACING then
		return
	end
	chain.lastImpact, chain.impactPoint = now, point
	Impact.Play(point, normal, kind)
end

-- Its body at death, cut at the contact (nothing past what stopped it).
local function deathPath(path: { Vector3 }, contact: Vector3?): { Vector3 }
	if not contact or #path < 2 then
		return path
	end
	local best, distance = 1, math.huge
	for index = 1, #path - 1 do
		local a, b = path[index], path[index + 1]
		local offset = b - a
		local t = math.clamp((contact - a):Dot(offset) / math.max(offset:Dot(offset), 1e-8), 0, 1)
		local d = (a + offset * t - contact).Magnitude
		if d < distance then
			best, distance = index, d
		end
	end
	while #path > best + 1 do
		table.remove(path)
	end
	path[#path] = contact
	return path
end

--------------------------------------------------------------------------------
-- Messages
--------------------------------------------------------------------------------

local function readSpawn(r: BeamWire.Reader): Sample
	local id = ReadU32(r)
	local pos, vel = ReadV3(r), ReadV3(r)
	local life = ReadF32(r)
	local ahead = ReadU32(r)
	local flags = ReadU8(r)
	local fragment = if bit32.btest(flags, Flag.Fragment) then ReadV3(r) else nil
	local origin = if bit32.btest(flags, Flag.Origin) then ReadV3(r) else nil
	local turns = {}
	for index = 1, ReadU8(r) do
		turns[index] = ReadV3(r)
	end
	local stopped = bit32.btest(flags, Flag.Stopped)
	return {
		id = id,
		pos = pos,
		vel = vel,
		life = life,
		ahead = ahead,
		turns = turns,
		origin = origin,
		fragment = if fragment and fragment.Magnitude > 1e-4 then fragment else nil,
		everLinked = bit32.btest(flags, Flag.EverLinked),
		clip = nil,
		dead = stopped,
		stopped = stopped,
		diedAt = os.clock(),
	}
end

local function onDeath(chain: any, s: Sample, kind: number, contact: Vector3?, normal: Vector3?, bodyHit: boolean)
	local body = pathOf(chain, s, incomingOf(chain))
	s.dead, s.diedAt = true, os.clock()
	if body and #body > 1 then
		body = table.clone(body) -- (drained in place; pathOf may reuse its table)
		local speed = s.vel.Magnitude
		local points = deathPath(body, if kind ~= DeathKind.Expire then contact else nil)
		if speed > 1e-3 and #points > 1 then
			table.insert(chain.drains, { points = points, speed = speed, started = os.clock() })
		end
	end
	if kind == DeathKind.World and not bodyHit and contact and normal then
		-- Parked one radius off the wall; followers keep ending here.
		s.stopped = true
		s.pos = contact + normal * chain.radius
		s.vel = Vector3.zero
	end
	if kind ~= DeathKind.Expire and contact and normal then
		playImpact(chain, contact, normal, DEATH_KINDS[kind] or "world")
	end
end

local function readSection(r: BeamWire.Reader)
	local id = ReadU32(r)
	local kind = ReadU8(r)
	local serverTime = ReadF64(r)
	local chain = chains[id]
	if kind == Section.Snapshot then
		if chain then
			table.clear(chain.samples)
			table.clear(chain.drains)
			chain.offset, chain.ended = nil, false
		else
			chain = newChain(id)
		end
		chain.radius = math.max(ReadF32(r), .025)
		chain.length = ReadF32(r)
		chain.color = Color3.fromRGB(ReadU8(r), ReadU8(r), ReadU8(r))
		chain.core = Color3.fromRGB(ReadU8(r), ReadU8(r), ReadU8(r))
		chain.gravity = ReadV3(r)
		chain.timeScale = ReadF32(r)
		if not chain.driver then
			local driver = part(chain.model, "ProjectileMotorRoot", chain.color)
			driver.Anchored = true
			chain.driver = driver
			chain.model.Parent = workspace
		end
	elseif kind == Section.Exit then
		if chain then
			destroyChain(chain)
		end
		chain = nil
	elseif kind == Section.End then
		if chain then
			chain.ended = true
			-- (the server has nothing left: whatever is still flying here ends)
			for _, s in chain.samples do
				if not s.dead then
					onDeath(chain, s, DeathKind.Expire, nil, nil, false)
				end
			end
		end
	end
	local lag = if chain then lagOf(chain, serverTime) else 0
	while true do
		local op = ReadU8(r)
		if op == Op.End then
			return
		elseif op == Op.Spawn then
			local s = readSpawn(r)
			if chain then
				chain.samples[s.id] = s
				advance(chain, s, simulated(chain, lag))
			end
		elseif op == Op.Pose then
			local sid, pos, vel, life = ReadU32(r), ReadV3(r), ReadV3(r), ReadF32(r)
			local s = chain and chain.samples[sid]
			if s and not s.dead then
				s.pos, s.vel, s.life = pos, vel, life
				advance(chain, s, simulated(chain, lag))
			end
		elseif op == Op.Bounce then
			local sid, pos, vel, contact, normal = ReadU32(r), ReadV3(r), ReadV3(r), ReadV3(r), ReadV3(r)
			local turns = {}
			for index = 1, ReadU8(r) do
				turns[index] = ReadV3(r)
			end
			local s = chain and chain.samples[sid]
			if s and not s.dead then
				s.pos, s.vel = pos, vel
				table.move(turns, 1, #turns, #s.turns + 1, s.turns)
				advance(chain, s, simulated(chain, lag))
				playImpact(chain, contact, normal, "bounce")
			end
		elseif op == Op.Link then
			local sid, ahead = ReadU32(r), ReadU32(r)
			local fragment = if ahead == 0 then ReadV3(r) else nil
			local s = chain and chain.samples[sid]
			if s then
				s.ahead, s.everLinked = ahead, true
				s.fragment = if fragment and fragment.Magnitude > 1e-4 then fragment else nil
			end
		elseif op == Op.Clip then
			local sid = ReadU32(r)
			local n = ReadU8(r)
			local points = if n > 0 then table.create(n) else nil
			for index = 1, n do
				(points :: { Vector3 })[index] = ReadV3(r)
			end
			local s = chain and chain.samples[sid]
			if s then
				s.clip = points
			end
		elseif op == Op.Death then
			local sid, deathKind = ReadU32(r), ReadU8(r)
			local contact, normal, bodyHit = nil, nil, false
			if deathKind ~= DeathKind.Expire then
				contact, normal, bodyHit = ReadV3(r), ReadV3(r), ReadU8(r) == 1
			end
			local s = chain and chain.samples[sid]
			if s and not s.dead then
				onDeath(chain, s, deathKind, contact, normal, bodyHit)
			end
		elseif op == Op.Scale then
			local scale = ReadF32(r)
			if chain then
				chain.timeScale = scale
			end
		else
			warn("[BeamChainVisual] unknown op", op)
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

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

function BeamChainVisual.Step(globalDt: number)
	if not enabled then
		return
	end
	uniform = ChunkManager.IsTimeUniform()
	local now = os.clock()
	local partsLeft = math.min(MAX_PARTS_PER_FRAME, limits.MaxRendered)
	local updatesLeft = math.max(limits.MaxUpdates, 1)
	local camera = workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else Vector3.zero
	local reach = limits.MaxDistance
	-- Oldest chain first (chains left stale last frame before that): past
	-- the part budget the same (newest) chains go without pieces every
	-- frame, instead of whichever the hash order reached last -- which
	-- flickered beams in and out under load.
	local order = {}
	for id in chains do
		table.insert(order, id)
	end
	table.sort(order, function(a, b)
		local staleA, staleB = chains[a].stale == true, chains[b].stale == true
		if staleA ~= staleB then
			return staleA
		end
		return a < b
	end)
	for _, id in order do
		local chain = chains[id]
		if not chain.driver then
			continue
		end
		local dt = globalDt * chain.timeScale
		for _, s in chain.samples do
			advance(chain, s, dt) -- (a dead one still moving is a link target until relinked)
			if not s.dead and s.life <= 0 then
				-- Out of life: the server's expiry is on its way. Should it
				-- never come, don't leave the body hanging in the air.
				local expired = s.expiredAt or now
				s.expiredAt = expired
				if now - expired > EXPIRE_GRACE then
					onDeath(chain, s, DeathKind.Expire, nil, nil, false)
				end
			end
		end
		local scratch = chain.scratch
		if not scratch then
			-- per-chain tables reused every frame instead of rebuilt (the
			-- segment / joint lists go to `pending`, which apply() consumes
			-- before the next Step, so they're free again by then)
			scratch = { incoming = {}, segments = {}, joints = {}, ends = {}, into = {}, out = {}, paths = {},
				nextOf = {}, joined = {}, starts = {} }
			chain.scratch = scratch
		end
		local incoming = incomingOf(chain, scratch.incoming)
		for sid, s in chain.samples do
			if s.dead and now - s.diedAt > DEAD_GRACE
				and (not incoming[sid] or (not s.stopped and now - s.diedAt > GHOST_LIFETIME)) then
				chain.samples[sid] = nil
			end
		end
		-- Tails of dead bodies keep flying into whatever stopped them.
		local drains = chain.drains
		for index = #drains, 1, -1 do
			local drain = drains[index]
			local left = trim(drain.points, drain.speed * dt)
			if left <= 1e-3 or now - drain.started > DRAIN_LIMIT then
				table.remove(drains, index)
			end
		end
		if chain.ended and next(chain.samples) == nil and #drains == 0 then
			destroyChain(chain)
			continue
		end
		if updatesLeft <= 0 and chain.drawn then
			-- (over this frame's redraw budget: its last pose stays up, and it
			-- still counts against the piece cap)
			chain.stale = true
			partsLeft -= chain.drawn
			continue
		end
		local partsBefore = partsLeft

		-- Geometry: every visible piece, split into pooled cylinders, with a
		-- ball wherever a body ends or bends sharply.
		local segments: { Vector3 } = scratch.segments
		local jointPoints: { Vector3 } = scratch.joints
		local ends: { [Vector3]: number } = scratch.ends
		local inDirection: { [Vector3]: Vector3 } = scratch.into
		local outDirection: { [Vector3]: Vector3 } = scratch.out
		table.clear(segments)
		table.clear(jointPoints)
		table.clear(ends)
		table.clear(inDirection)
		table.clear(outDirection)
		local radius = chain.radius
		local function addPolyline(points: { Vector3 })
			local first, lastDirection = true, nil
			for index = 1, #points - 1 do
				local a, b = points[index], points[index + 1]
				local offset = b - a
				local length = offset.Magnitude
				if length < 1e-4 then
					continue
				end
				local direction = offset / length
				if first then
					first = false
					ends[a] = (ends[a] or 0) + 1
					outDirection[a] = direction
				elseif lastDirection and lastDirection:Dot(direction) < JOINT_COS and View.contains(a, radius * 2) then
					table.insert(jointPoints, a)
				end
				lastDirection = direction
				if partsLeft <= 0 or not View.contains((a + b) * .5, length * .5 + radius) then
					continue
				end
				-- only the part within render distance of the camera
				local f = eye - a
				local along = f:Dot(direction) -- (the camera's foot on the line)
				local miss = f - direction * along
				local inside = reach * reach - miss:Dot(miss)
				if inside < 0 then
					continue
				end
				local half = math.sqrt(inside)
				local from, to = math.max(along - half, 0), math.min(along + half, length)
				if to - from < 1e-3 then
					continue
				end
				if from > 0 or to < length then
					a, b, length = a + direction * from, a + direction * to, to - from
				end
				-- fixed-length pieces from the back; only the last one varies
				local pieces = math.max(1, math.ceil(length / MAX_SEGMENT - 1e-6))
				for piece = 1, pieces do
					table.insert(segments, a + direction * ((piece - 1) * MAX_SEGMENT))
					table.insert(segments, if piece == pieces then b else a + direction * (piece * MAX_SEGMENT))
				end
				partsLeft -= pieces
			end
			if lastDirection then
				local tip = points[#points]
				ends[tip] = (ends[tip] or 0) + 1
				inDirection[tip] = lastDirection
			end
		end
		-- Strands: every body, joined to the body of the sample ahead where it
		-- ends exactly where that one starts, then straightened.
		local samples = chain.samples
		local paths: { [number]: { Vector3 } } = scratch.paths
		table.clear(paths)
		for sid, s in samples do
			local path = pathOf(chain, s, incoming)
			if path and #path > 1 then
				paths[sid] = path
			end
		end
		local nextOf: { [number]: number } = scratch.nextOf
		local joined: { [number]: boolean } = scratch.joined
		table.clear(nextOf)
		table.clear(joined)
		for sid, path in paths do
			local ahead = samples[sid].ahead
			local following = ahead ~= 0 and paths[ahead]
			if following and not joined[ahead] and (following[1] - path[#path]).Magnitude < 1e-3 then
				nextOf[sid], joined[ahead] = ahead, true
			end
		end
		local starts: { number } = scratch.starts
		table.clear(starts)
		for sid in paths do
			if not joined[sid] then
				table.insert(starts, sid)
			end
		end
		table.sort(starts) -- (a stable order keeps pooled pieces on the same strand)
		local tolerance = math.max(radius * STRAIGHT, 1e-3)
		for _, first in starts do
			local kept = { paths[first][1] }
			local anchor, heading, last = kept[1], nil :: Vector3?, kept[1]
			local sid: number? = first
			local guard = 0
			while sid and guard < 100000 do
				guard += 1
				local path = paths[sid]
				for index = 2, #path do
					local point = path[index]
					local offset = point - anchor
					if not heading then
						if offset.Magnitude > 1e-3 then
							heading = offset.Unit
						end
						last = point
						continue
					end
					local along = offset:Dot(heading)
					if along > 0 and (offset - heading * along).Magnitude <= tolerance then
						last = point -- still on the anchor's line
						continue
					end
					table.insert(kept, last)
					anchor = last
					local leg = point - last
					heading = if leg.Magnitude > 1e-3 then leg.Unit else nil
					last = point
				end
				sid = nextOf[sid]
			end
			table.insert(kept, last)
			addPolyline(kept)
		end
		for _, drain in drains do
			addPolyline(drain.points)
		end
		for point, count in ends do
			local into, out = inDirection[point], outDirection[point]
			if count ~= 2 or not into or not out or into:Dot(out) < JOINT_COS then
				if View.contains(point, radius * 2) then
					table.insert(jointPoints, point)
				end
			end
		end
		for index = #jointPoints, 1, -1 do
			if (jointPoints[index] - eye).Magnitude > reach then
				table.remove(jointPoints, index)
			end
		end
		local jointCount = math.min(#jointPoints, math.max(partsLeft, 0))
		for index = #jointPoints, jointCount + 1, -1 do
			jointPoints[index] = nil
		end
		partsLeft -= jointCount
		pending[chain] = { segments = segments, joints = jointPoints }
		chain.drawn = partsBefore - partsLeft
		chain.stale = nil
		updatesLeft -= math.max(chain.drawn, 1)
	end
end

-- The player's render limits (see `limits`); MaxSmooth doesn't apply (chain
-- pieces aren't tweened).
function BeamChainVisual.SetRenderSettings(settings: { [string]: number })
	for key in limits do
		local value = settings[key]
		if typeof(value) == "number" and value == value and value >= 0 then
			limits[key] = value
		end
	end
end

function BeamChainVisual.GetStats(): (number, number)
	local chainCount, sampleCount = 0, 0
	for _, chain in chains do
		chainCount += 1
		for _, s in chain.samples do
			if not s.dead then
				sampleCount += 1
			end
		end
	end
	return chainCount, sampleCount
end

function BeamChainVisual.Enable()
	if enabled or RunService:IsServer() then
		return
	end
	enabled = true
	VisualOffload.On(BeamWire.Channel, onMessage)
	applyConnection = RunService.PreSimulation:Connect(apply)
end

return BeamChainVisual
