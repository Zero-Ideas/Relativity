--!strict
-- Finite, traveling cylinders along a bounded path, not an instantaneous ray
-- from the muzzle to the cursor. Only the existing projectile head drives this
-- cosmetic tail. Collision/damage/bounce/pierce/homing stay server-owned.
local ChunkManager = require(script.Parent.Parent.ChunkManager)
local Types = require(script.Parent.Types)
local Protocol = require(script.Parent.Parent.ProjectileProtocol)
local Geometry = require(script.Parent.BeamGeometry)
local View = require(script.Parent.View)
local RunService = game:GetService("RunService")
local Prediction = require(script.Parent.Prediction)
local Motion = require(script.Parent.Parent.ProjectileMotion)

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
				Vector3.new(length, group.radius * 2, group.radius * 2), false)
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
function BeamVisual.FlushGroups()
	for _, group in groups do
		local paths = {}
		for state in group.members do
			local visual = state.visual
			local inView = if state.retired then View.contains(state.points[#state.points], state.maxLength)
				else visual and visual.inView
			if inView and state.length > 1e-4 then table.insert(paths, state.points) end
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
	local group = state.group
	if group then
		group.members[state] = nil
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
	for index = 1, #state.points - 1 do
		local a, b = state.points[index], state.points[index + 1]
		local length = (b - a).Magnitude
		local up = if length > 1e-4 and math.abs((b - a).Y / length) > .99 then Vector3.xAxis else Vector3.yAxis
		local pose = if length > 1e-4 then CFrame.lookAt((a + b) * 0.5, b, up) * ROTATION else CFrame.new(a)
		local segment = state.segments[index]
		if not segment then
			local core = part(rig.model, "BeamCore", state.core, 0, pose)
			local glow = part(rig.model, "BeamGlow", state.color, 0.5, pose)
			segment = { core = core, glow = glow, coreMotor = motor(rig.driver, core, pose), glowMotor = motor(rig.driver, glow, pose) }
			state.segments[index] = segment
		end
		if length > 1e-4 then
			local transform = rig.driver.CFrame:ToObjectSpace(pose)
			segment.core.Size = Vector3.new(length + state.radius * 0.1, state.radius * 1.1, state.radius * 1.1)
			segment.glow.Size = Vector3.new(length + state.radius * 0.1, state.radius * 2, state.radius * 2)
			segment.coreMotor.Transform = segment.coreMotor.C0:Inverse() * transform
			segment.glowMotor.Transform = segment.glowMotor.C0:Inverse() * transform
			segment.core.Transparency, segment.glow.Transparency = 0, 0.5
		else
			segment.core.Transparency, segment.glow.Transparency = 1, 1
		end
	end
	for index = #state.points, #state.segments do
		state.segments[index].core.Transparency = 1
		state.segments[index].glow.Transparency = 1
	end
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
				radius = math.max(beam.Radius, .025), segments = {}, joints = {}, members = {}, visible = false }
			groups[beam.ChannelId] = group
			model.Parent = workspace
			if not applyConnection then applyConnection = RunService.PreSimulation:Connect(BeamVisual.ApplyGroups) end
		end
		-- Each logical packet owns only metadata, not cylinders/Motor6Ds. Its
		-- placeholder can retire without deleting another packet's shared rig.
		local placeholder = Instance.new("Folder")
		placeholder.Name = "BeamPacket_" .. data.Id
		placeholder.Parent = group.model
		local state = { points = { beam.Origin }, length = 0, maxLength = beam.Length,
			radius = group.radius, speed = data.Velocity.Magnitude, group = group }
		group.members[state] = true
		append(state, data.Position)
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
	if rig and rig.beam then rig.beam.visual = visual end
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
	append(rig.beam, position)
	rig.beam.speed = velocity.Magnitude
	draw(rig)
end

-- Remove predicted overshoot before an authoritative bounce/impact. Retain
-- the incoming path up to the contact, then let the new heading extend it.
function BeamVisual.Correct(visual: Types.Visual, contact: Vector3)
	local rig = visual.rig
	if not rig or not rig.beam then return end
	local state, bestIndex, bestDistance = rig.beam, 1, math.huge
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
			local delta = (visual.position - state.points[#state.points]).Magnitude
			if not visual.synced and delta > state.maxLength and Prediction.canDefer(visual) then
				-- Rebuild only the recent tail after a long offscreen interval.
				-- The settled velocity/position already include elapsed time; this
				-- is a cosmetic backwards sample, never a second simulation step.
				local acceleration = Motion.GetAcceleration(visual.velocity, visual.acceleration, visual.accelerationDirection, visual.gravity)
				local duration = math.min(state.maxLength / math.max(visual.velocity.Magnitude, 1), 1)
				state.points, state.length = {}, 0
				for index = 0, MAX_SEGMENTS do
					local t = duration * (1 - index / MAX_SEGMENTS)
					local point = visual.position - visual.velocity * t + acceleration * (.5 * t * t)
					if index == 0 then table.insert(state.points, point) else append(state, point) end
				end
			else
				append(state, visual.position)
			end
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
	rig.beam.retired = true
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
		local elapsed = (clock - item.lastClock) * visual.timeScale * ChunkManager.GetTimeScaleAt(visual.position)
		item.lastClock = clock
		trim(state, math.max(elapsed, 0) * state.speed)
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
