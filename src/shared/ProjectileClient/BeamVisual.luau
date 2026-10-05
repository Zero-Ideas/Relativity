--!strict
-- Finite, traveling cylinders along a bounded path, not an instantaneous ray
-- from the muzzle to the cursor. Sustained channels share a linked centerline
-- with server collision; individual beams retain their traveled path tail.
-- Collision/damage/bounce/pierce/homing stay server-owned.
local ChunkManager = require(script.Parent.Parent.ChunkManager)
local Types = require(script.Parent.Types)
local Protocol = require(script.Parent.Parent.ProjectileProtocol)
local Geometry = require(script.Parent.BeamGeometry)
local View = require(script.Parent.View)
local RunService = game:GetService("RunService")
local Planner = require(script.Parent.Parent.ProjectileStepPlanner)
local Prediction = require(script.Parent.Prediction)
local Heartbeat = require(script.Parent.Parent.Heartbeat)
local BeamPath = require(script.Parent.Parent:WaitForChild("Projectile"):WaitForChild("BeamPath"))

local BeamVisual = {}
local MAX_SEGMENTS = 8
local MAX_RETIRE_UPDATES = 128
local retired: { any } = {}
local retireCursor = 1
local clock = 0
local ROTATION = CFrame.Angles(0, math.pi / 2, 0) -- cylinder's X axis -> path Z
local groups: { [number]: any } = {}
local pending: { [any]: any } = {}
local applyConnection: RBXScriptConnection? = nil
local predicting: { [any]: boolean } = {}

-- Advance all channel endpoints to ONE presentation epoch before joining any
-- of them. The ordinary round-robin renderer must not mix endpoint ages.
function BeamVisual.PredictGroups(now: number, simulationClock: number)
	for state in predicting do
		local visual = state.visual
		if not visual or not state.predictedAt then continue end
		if now < state.predictedAt then visual.lastSimulationTime = simulationClock; continue end
		local elapsed = math.max(now - state.predictedAt, 0)
		local _, moved = Prediction.simulate(visual, elapsed * state.globalScale * visual.timeScale)
		state.predictedAt = now
		visual.lastSimulationTime = simulationClock
		if state.group then state.group.dirty = true
		elseif moved then BeamVisual.Update(visual, visual.position, visual.velocity) end
	end
end

local function predictedPath(state: any): { Vector3 }?
	local source = state.authoritativePath
	if not source or not state.visual or not state.predictedAt then return source end
	local result = table.clone(source)
	if #result == 0 then return result end
	local position = state.visual.position
	result[1] = position
	if #result > 1 and not state.pathClipped then
		local front = state.group.byId[state.previousId]
		if front and front.visual and not front.retired then
			result[#result] = front.visual.position
		elseif state.previousId == 0 then
			-- A detached fragment translates; world bend vertices remain fixed.
			result[#result] += position - source[1]
		else
			-- The front is gone/pending; never pin a moving packet to an old
			-- spawn/impact location. Translate the last approved finite fragment
			-- until the server supplies a replacement link or a clipped anchor.
			if #result == 2 then result[2] += position - source[1]
			else return { position } end
		end
	end
	-- Prediction cannot authorize a giant collision body. Physical refinement
	-- seeds replacement nodes on the next server frame; until those arrive,
	-- don't draw a shortcut from a moving head to a stale bend/impact anchor.
	for index = 1, #result - 1 do
		if (result[index+1]-result[index]).Magnitude > BeamPath.MaxStretch * 2 then
			return { position }
		end
	end
	return result
end

function BeamVisual.AdoptMotion(visual: Types.Visual, serverTime: number?, globalScale: number?, previousId: number?)
	local state = visual.rig and visual.rig.beam
	if not state then return end
	if previousId ~= nil then state.previousId = previousId end
	if serverTime then
		state.predictedAt = serverTime
		state.globalScale = globalScale or Heartbeat.GetGlobalTimeScale()
	end
	if state.group then state.group.dirty = true end
end

local function part(parent: Instance, name: string, color: Color3, transparency: number, initialPose: CFrame?): Part
	local p = Instance.new("Part")
	p.Name, p.Color, p.Transparency = name, color, transparency
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.one * 0.05
	p.Material = Enum.Material.Neon
	p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = false, false, false, false
	-- Motor6D.Transform is applied in the engine's simulation phase. New
	-- cylinders need their correct world pose BEFORE being made visible;
	-- otherwise their default X-axis orientation flashes for one frame.
	if initialPose then p.CFrame = initialPose end
	p.Parent = parent
	return p
end

local function motor(driver: BasePart, p: BasePart, initialPose: CFrame?): Motor6D
	local joint = Instance.new("Motor6D")
	-- Connecting Part1 immediately applies C0/C1, before Transform's deferred
	-- engine update. Seed C0 as well as the Part pose to prevent an axis flash.
	joint.C0 = if initialPose then driver.CFrame:ToObjectSpace(initialPose) else CFrame.identity
	joint.Part0, joint.Part1, joint.Parent = driver, p, driver
	return joint
end

local function shape(group: any, pool: any, index: number, pose: CFrame, size: Vector3, ball: boolean)
	local pair = pool[index]
	if not pair then
		local core = part(group.model, if ball then "BeamJointCore" else "BeamCore", group.core, 1, pose)
		local glow = part(group.model, if ball then "BeamJointGlow" else "BeamGlow", group.color, 1, pose)
		if ball then core.Shape = Enum.PartType.Ball; glow.Shape = Enum.PartType.Ball end
		pair = { core = core, glow = glow, coreMotor = motor(group.driver, core, pose), glowMotor = motor(group.driver, glow, pose) }
		pool[index] = pair
	end
	local transform = group.driver.CFrame:ToObjectSpace(pose)
	pair.core.Size = if ball then size * .55 else Vector3.new(size.X, size.Y * .55, size.Z * .55)
	pair.glow.Size = size
	pair.coreMotor.Transform = pair.coreMotor.C0:Inverse() * transform
	pair.glowMotor.Transform = pair.glowMotor.C0:Inverse() * transform
	pair.core.Transparency, pair.glow.Transparency = 0, .5
end

local function hideAfter(pool: any, used: number)
	for index = used + 1, #pool do
		pool[index].core.Transparency, pool[index].glow.Transparency = 1, 1
	end
end

-- Apply size and Motor6D pose together before the engine commits transforms.
-- Reusing a long cylinder at a new angle during Heartbeat otherwise exposes
-- its new length at the old orientation for a rendered frame.
function BeamVisual.ApplyGroups()
	for group, geometry in pending do
		pending[group] = nil
		if not group.model.Parent then continue end
		for index, span in geometry.segments do
			local a, b = span[1], span[2]
			local length = (b - a).Magnitude
			local up = if math.abs((b - a).Y / length) > .99 then Vector3.xAxis else Vector3.yAxis
			shape(group, group.segments, index, CFrame.lookAt((a + b) * .5, b, up) * ROTATION,
				Vector3.new(math.min(length, Geometry.MaxSegmentLength), group.radius * 2, group.radius * 2), false)
		end
		hideAfter(group.segments, #geometry.segments)
		for index, point in geometry.joints do
			shape(group, group.joints, index, CFrame.new(point), Vector3.one * group.radius * 2, true)
		end
		hideAfter(group.joints, #geometry.joints)
	end
end

-- One aggregation per channel per frame, never one visible bar per packet.
-- Only already-simulated paths enter the union. Offscreen packets retain the
-- normal prediction timestamp/correction rules and resume through Reset.
function BeamVisual.GetBounds(visual: Types.Visual, position: Vector3, simulationClock: number): (Vector3, number)
	local state = visual.rig and visual.rig.beam
	if not state then return position, 0 end
	local path = if state.group then predictedPath(state) else state.authoritativePath
	if path and #path > 1 then
		local low, high = position, position
		for _, point in path do low, high = low:Min(point), high:Max(point) end
		return (low+high)*.5, (high-low).Magnitude*.5+state.maxLength
	end
	return position, state.maxLength
end

function BeamVisual.FlushGroups(simulationClock: number?)
	for _, group in groups do
		for state in group.members do
			local visual = state.visual
			local visible = if state.retired then View.contains((state.points[1]+state.points[#state.points])*.5, state.length*.5+state.radius)
				else visual and visual.inView or false
			if visible ~= state.wasVisible then state.wasVisible = visible; group.dirty = true end
		end
		if not group.dirty then continue end
		group.dirty = false
		local paths = {}
		for state in group.members do
			local visual = state.visual
			local inView = if state.retired then View.contains((state.points[1]+state.points[#state.points])*.5, state.length*.5+state.radius)
				else visual and visual.inView
			if not inView then continue end
			if state.retired then
				if state.length > 1e-4 then table.insert(paths, state.points) end
				continue
			end
			-- A sustained sample renders exactly ONE server-approved path.
			-- Its old travel history is never a second tail, even after a split,
			-- clipping, interest loss, delayed pose, or missing predecessor.
			state.linkPoints = predictedPath(state)
			if state.linkPoints and #state.linkPoints > 0 then table.insert(paths, state.linkPoints) end
		end
		if #paths > 0 then
			local segments, joints = Geometry.Merge(paths, group.radius)
			pending[group] = { segments = segments, joints = joints }
		elseif group.visible then
			-- Do not leave stale cylinders at their exit pose where a camera turn
			-- could expose them while their authoritative heads are elsewhere.
			pending[group] = { segments = {}, joints = {} }
		end
		group.visible = #paths > 0
	end
end

local function releaseState(visual: Types.Visual)
	local state = (visual.rig :: Types.Rig).beam
	predicting[state] = nil
	pending[state] = nil
	local group = state.group
	if group then
		group.dirty = true
		group.members[state] = nil
		group.byId[state.id] = nil
		if next(group.members) == nil then
			groups[group.id], pending[group] = nil, nil
			group.model:Destroy()
		end
	end
	visual.model:Destroy()
end

local function trim(state: any, distance: number)
	local points = state.points
	while distance > 0 and #points > 1 do
		local length = (points[2] - points[1]).Magnitude
		if distance >= length then
			table.remove(points, 1)
			distance -= length
			state.length -= length
		else
			points[1] = points[1]:Lerp(points[2], distance / length)
			state.length -= distance
			distance = 0
		end
	end
	state.length = math.max(state.length, 0)
end

local function append(state: any, position: Vector3)
	local points = state.points
	local last = points[#points]
	local offset = position - last
	local distance = offset.Magnitude
	if distance < 1e-4 then return end
	if #points >= 2 then
		local previous = last - points[#points - 1]
		if previous.Magnitude > 1e-4 and previous.Unit:Dot(offset.Unit) > 0.9999 then
			points[#points] = position
		else
			table.insert(points, position)
		end
	else
		table.insert(points, position)
	end
	state.length += distance
	trim(state, math.max(state.length - state.maxLength, 0))
	-- Drop old detail instead of drawing a shortcut across a bend/wall.
	while #points > MAX_SEGMENTS + 1 do trim(state, (points[2] - points[1]).Magnitude) end
end

local function draw(rig: Types.Rig)
	local state = rig.beam
	if state.group then return end
	state.model, state.driver = rig.model, rig.driver
	state.joints = state.joints or {}
	local spans = {}
	for index = 1, #state.points-1 do table.insert(spans, { state.points[index], state.points[index+1] }) end
	pending[state] = { segments = Geometry.Split(spans), joints = {} }
	if not applyConnection then applyConnection = RunService.PreSimulation:Connect(BeamVisual.ApplyGroups) end
end
function BeamVisual.Build(data: Protocol.SpawnPayload): (Instance, Types.Rig)
	local beam = assert(data.Beam)
	local spec = data.Visual
	local color = spec and spec.Color or Color3.fromRGB(255, 96, 28)
	if beam.ChannelId then
		local group = groups[beam.ChannelId]
		if not group then
			local model = Instance.new("Model")
			model.Name = "SustainedBeam_" .. beam.ChannelId
			local driver = part(model, "ProjectileMotorRoot", color, 1)
			driver.Anchored = true
			driver.CFrame = CFrame.new(beam.Origin)
			local root = part(model, "BeamHead", color, 1)
			group = { id = beam.ChannelId, model = model, driver = driver, root = root,
				motor = motor(driver, root), color = color, core = spec and spec.Core or Color3.new(1, 1, 1),
				radius = math.max(beam.Radius, .025), segments = {}, joints = {}, members = {}, byId = {}, visible = false, dirty = true }
			groups[beam.ChannelId] = group
			model.Parent = workspace
			if not applyConnection then applyConnection = RunService.PreSimulation:Connect(BeamVisual.ApplyGroups) end
		end
		-- Each logical packet owns only metadata, not cylinders/Motor6Ds. Its
		-- placeholder can retire without deleting another packet's shared rig.
		local placeholder = Instance.new("Folder")
		placeholder.Name = "BeamPacket_" .. data.Id
		placeholder.Parent = group.model
		local state = { points = { data.Position }, length = 0, maxLength = beam.Length,
			radius = group.radius, speed = data.Velocity.Magnitude, group = group,
			id = data.Id, previousId = beam.PreviousId or 0,
			predictedAt = data.ServerTime, globalScale = data.GlobalScale or Heartbeat.GetGlobalTimeScale(),
		}
		state.authoritativePath = beam.Path
		state.pathClipped = beam.Clipped
		group.members[state] = true
		group.byId[data.Id] = state
		group.dirty = true
		return placeholder, { model = placeholder, driver = group.driver, root = group.root,
			motor = group.motor, rootOffset = CFrame.identity, beam = state }
	end
	local model = Instance.new("Model")
	model.Name = "ProjectileBeam"
	local driver = part(model, "ProjectileMotorRoot", color, 1)
	driver.Anchored = true
	driver.CFrame = CFrame.new(data.Position)
	local root = part(model, "BeamHead", color, 1)
	model.PrimaryPart = root
	local rig: Types.Rig = {
		driver = driver, root = root, motor = motor(driver, root), model = model,
		rootOffset = CFrame.identity,
		beam = { points = { beam.Origin }, segments = {}, length = 0,
			predictedAt = data.ServerTime, globalScale = data.GlobalScale or Heartbeat.GetGlobalTimeScale(),
			maxLength = beam.Length, radius = math.max(beam.Radius, 0.025),
			color = color, core = spec and spec.Core or Color3.new(1, 1, 1), speed = data.Velocity.Magnitude },
	}
	append(rig.beam, data.Position)
	draw(rig)
	model.Parent = workspace
	return model, rig
end

function BeamVisual.Attach(visual: Types.Visual)
	local rig = visual.rig
	if rig and rig.beam then
		rig.beam.visual = visual
		predicting[rig.beam] = true
	end
end

function BeamVisual.AdoptPath(visual: Types.Visual, points: { Vector3 }?, clipped: boolean?, final: boolean?)
	local state = visual.rig and visual.rig.beam
	if not state then return end
	state.authoritativePath = points
	state.pathClipped = clipped
	state.finalPath = final == true
	if state.group then state.group.dirty = true end
end

-- Interest loss is not an impact: do not leave a retired copy with the same
-- id in a channel when the authoritative re-entry snapshot rebuilds it.
function BeamVisual.Discard(visual: Types.Visual): boolean
	if not visual.rig or not visual.rig.beam then return false end
	releaseState(visual)
	return true
end

function BeamVisual.ShouldPlayImpact(visual: Types.Visual, point: Vector3): boolean
	local rig = visual.rig
	local group = rig and rig.beam and rig.beam.group
	if not group then return true end
	-- Cosmetic throttle only: every packet still delivers its server damage.
	local now = os.clock()
	if group.lastImpact and now - group.lastImpact < .1 and (point - group.impactPoint).Magnitude < 4 then return false end
	group.lastImpact, group.impactPoint = now, point
	return true
end

function BeamVisual.Update(visual: Types.Visual, position: Vector3, velocity: Vector3)
	local rig = visual.rig
	if not rig or not rig.beam then return end
	rig.beam.linkPoints = nil
	if rig.beam.group then
		rig.beam.group.dirty = true
		rig.beam.points, rig.beam.length = {position}, 0
		rig.beam.speed = velocity.Magnitude
		return
	end
	append(rig.beam, position)
	rig.beam.speed = velocity.Magnitude
	draw(rig)
end

function BeamVisual.StopBody(visual: Types.Visual, contact: Vector3)
	local state = visual.rig and visual.rig.beam
	if not state or not state.group then return end
	state.group.dirty = true
	local stop = table.clone(state.authoritativePath or { contact })
	if #stop == 1 then
		state.stopPath, state.pathClipped = { contact }, true
		return
	end
	-- The actual stop can precede a predecessor's next bounce. Retain only
	-- the contacts up to the segment containing this impact, never overshoot.
	local best, distance = 1, math.huge
	for index = 1, #stop - 1 do
		local a, b = stop[index], stop[index+1]
		local offset = b-a
		local t = math.clamp((contact-a):Dot(offset)/math.max(offset:Dot(offset),1e-8),0,1)
		local d = (a+offset*t-contact).Magnitude
		if d < distance then best, distance = index, d end
	end
	while #stop > best + 1 do table.remove(stop) end
	stop[#stop] = contact
	state.stopPath = stop
	state.pathClipped = true
end

-- Remove predicted overshoot before an authoritative bounce/impact. Retain
-- the incoming path up to the contact, then let the new heading extend it.
function BeamVisual.Correct(visual: Types.Visual, contact: Vector3)
	local rig = visual.rig
	if not rig or not rig.beam then return end
	local state, bestIndex, bestDistance = rig.beam, 1, math.huge
	if state.group then state.group.dirty = true; return end
	for index = 1, #state.points - 1 do
		local a, b = state.points[index], state.points[index + 1]
		local offset = b - a
		local t = math.clamp((contact - a):Dot(offset) / math.max(offset:Dot(offset), 1e-8), 0, 1)
		local distance = (a + offset * t - contact).Magnitude
		if distance < bestDistance then bestIndex, bestDistance = index, distance end
	end
	while #state.points > bestIndex + 1 do table.remove(state.points) end
	if #state.points > 1 then state.points[#state.points] = contact else table.insert(state.points, contact) end
	state.length = 0
	for index = 1, #state.points - 1 do state.length += (state.points[index + 1] - state.points[index]).Magnitude end
	trim(state, math.max(state.length - state.maxLength, 0))
end

function BeamVisual.Reset(visual: Types.Visual)
	local rig = visual.rig
	if rig and rig.beam then
		local state = rig.beam
		if state.group then
			state.group.dirty = true
			state.points, state.length = {visual.position}, 0
			return
		end
		rig.beam.points = { visual.position }
		rig.beam.length = 0
		draw(rig)
	end
end

function BeamVisual.Retire(visual: Types.Visual, delay: number): boolean
	local rig = visual.rig
	if not rig or not rig.beam then return false end
	if rig.beam.retired then return true end
	local state = rig.beam
	predicting[state] = nil
	if state.group then
		state.group.dirty = true
		local points = state.stopPath or (if state.finalPath then state.authoritativePath else predictedPath(state))
		state.points = if points and #points > 0 then table.clone(points) else { visual.position }
		state.length = 0
		for index = 1, #state.points - 1 do state.length += (state.points[index+1]-state.points[index]).Magnitude end
	end
	if state.speed <= 1e-4 then state.points = { state.points[#state.points] }; state.length = 0 end
	state.retired = true
	-- Drain already-traveled geometry from the tail. Hiding the whole packet
	-- on impact would leave a frame-sized hole in a sustained beam.
	table.insert(retired, { visual = visual, lastClock = clock, started = os.clock(), delay = delay })
	return true
end

function BeamVisual.StepRetired(globalDt: number)
	clock += globalDt
	local visited = 0
	local budget = math.min(#retired, MAX_RETIRE_UPDATES)
	while #retired > 0 and visited < budget do
		if retireCursor > #retired then retireCursor = 1 end
		local item = retired[retireCursor]
		local visual = item.visual
		local rig = visual.rig :: Types.Rig
		local state = rig.beam
		local elapsed = (clock - item.lastClock) * visual.timeScale
		item.lastClock = clock
		local remaining = math.max(elapsed, 0) + (state.retireDebt or 0)
		local beforeLength = state.length
		if elapsed <= 0 then
			-- Like server Step, frozen time does not spend carried simulation debt.
		elseif ChunkManager.IsTimeUniform() then
			trim(state, remaining * state.speed)
			remaining = 0
		else
			local guard = 0
			while remaining > 1e-6 and #state.points > 1 and state.speed > 1e-4 and guard < 16 do
				guard += 1
				local origin, offset = state.points[1], state.points[2]-state.points[1]
				if offset.Magnitude < 1e-4 then trim(state,.0001); continue end
				local scale = ChunkManager.GetTimeScaleAt(origin)
				if scale <= 0 then remaining = 0; break end
				local dt = Planner.StepDt(origin, offset.Unit*state.speed, Vector3.zero, scale, remaining,
					math.huge, true, false, offset.Magnitude/state.speed)
				if dt <= 0 then break end
				trim(state, dt*state.speed)
				remaining -= dt/scale
			end
		end
		state.retireDebt = remaining
		if state.group and state.length ~= beforeLength then state.group.dirty = true end
		draw(rig)
		visited += 1
		if (state.length <= 1e-4 and os.clock() - item.started >= item.delay) or os.clock() - item.started >= 60 then
			releaseState(visual)
			table.remove(retired, retireCursor)
		else
			retireCursor += 1
		end
	end
end

return BeamVisual
