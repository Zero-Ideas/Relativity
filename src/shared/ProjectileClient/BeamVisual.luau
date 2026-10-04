--!strict
-- Finite, traveling cylinders along a bounded path, not an instantaneous ray
-- from the muzzle to the cursor. Only the existing projectile head drives this
-- cosmetic tail. Collision/damage/bounce/pierce/homing stay server-owned.
local ChunkManager = require(script.Parent.Parent.ChunkManager)
local Types = require(script.Parent.Types)
local Protocol = require(script.Parent.Parent.ProjectileProtocol)

local BeamVisual = {}
local MAX_SEGMENTS = 8
local MAX_RETIRE_UPDATES = 128
local retired: { any } = {}
local retireCursor = 1
local clock = 0
local ROTATION = CFrame.Angles(0, math.pi / 2, 0) -- cylinder's X axis -> path Z

local function part(parent: Instance, name: string, color: Color3, transparency: number): Part
	local p = Instance.new("Part")
	p.Name, p.Color, p.Transparency = name, color, transparency
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.one * 0.05
	p.Material = Enum.Material.Neon
	p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = false, false, false, false
	p.Parent = parent
	return p
end

local function motor(driver: BasePart, p: BasePart): Motor6D
	local joint = Instance.new("Motor6D")
	joint.Part0, joint.Part1, joint.Parent = driver, p, driver
	return joint
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
	for index = 1, #state.points - 1 do
		local segment = state.segments[index]
		if not segment then
			local core = part(rig.model, "BeamCore", state.core, 0)
			local glow = part(rig.model, "BeamGlow", state.color, 0.5)
			segment = { core = core, glow = glow, coreMotor = motor(rig.driver, core), glowMotor = motor(rig.driver, glow) }
			state.segments[index] = segment
		end
		local a, b = state.points[index], state.points[index + 1]
		local length = (b - a).Magnitude
		if length > 1e-4 then
			local pose = CFrame.lookAt((a + b) * 0.5, b) * ROTATION
			local transform = rig.driver.CFrame:ToObjectSpace(pose)
			segment.core.Size = Vector3.new(length + state.radius * 0.1, state.radius * 1.1, state.radius * 1.1)
			segment.glow.Size = Vector3.new(length + state.radius * 0.1, state.radius * 2, state.radius * 2)
			segment.coreMotor.Transform, segment.glowMotor.Transform = transform, transform
			segment.core.Transparency, segment.glow.Transparency = 0, 0.5
		end
	end
	for index = #state.points, #state.segments do
		state.segments[index].core.Transparency = 1
		state.segments[index].glow.Transparency = 1
	end
end

function BeamVisual.Build(data: Protocol.SpawnPayload): (Instance, Types.Rig)
	local beam = assert(data.Beam)
	local model = Instance.new("Model")
	model.Name = "ProjectileBeam"
	local spec = data.Visual
	local color = spec and spec.Color or Color3.fromRGB(255, 96, 28)
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
		rig.beam.points = { visual.position }
		rig.beam.length = 0
		draw(rig)
	end
end

function BeamVisual.Retire(visual: Types.Visual, delay: number): boolean
	local rig = visual.rig
	if not rig or not rig.beam then return false end
	-- Drain already-traveled geometry from the tail. Hiding the whole packet
	-- on impact would leave a frame-sized hole in a sustained beam.
	table.insert(retired, { visual = visual, lastClock = clock, started = os.clock(), delay = delay })
	return true
end

function BeamVisual.StepRetired(globalDt: number)
	clock += globalDt
	local visited = 0
	while #retired > 0 and visited < math.min(#retired, MAX_RETIRE_UPDATES) do
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
			visual.model:Destroy()
			table.remove(retired, retireCursor)
		else
			retireCursor += 1
		end
	end
end

return BeamVisual
