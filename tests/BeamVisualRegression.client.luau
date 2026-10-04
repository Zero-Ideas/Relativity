-- Temporary Studio LocalScript; never shipped by the Rojo game project.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio())
local modules = game.ReplicatedStorage.Shared.ProjectileClient
local Geometry = require(modules.BeamGeometry)
local Beam = require(modules.BeamVisual)
local VisualModel = require(modules.VisualModel)
local paths = {}
for index = 1, 30 do paths[index] = { Vector3.new(index * 5, 0, 0), Vector3.new(index * 5 + 40, 0, 0) } end
local merged, joints = Geometry.Merge(paths, .35)
assert(#merged == 1 and #joints == 2, "overlapping packets did not become a single span")
local farPaths = {}
local farHeading = Vector3.new(1,.3,-.7).Unit
local farOrigin = Vector3.new(236,300,919)
for index = 1, 150 do
	farPaths[index] = { farOrigin + farHeading * (10000 + index * 60), farOrigin + farHeading * (10133 + index * 60) }
end
local farSpans = Geometry.Merge(farPaths,.35)
assert(#farSpans == 1, "float error fragmented long-range beam into " .. #farSpans .. " bars")
local corner, cornerJoints = Geometry.Merge({ { Vector3.zero, Vector3.xAxis * 20, Vector3.new(20, 0, 20) } }, .35)
assert(#corner == 2 and #cornerJoints == 3, "bend did not retain a shared rounded joint")
local disjoint = Geometry.Merge({ { Vector3.zero, Vector3.xAxis * 10 }, { Vector3.xAxis * 30, Vector3.xAxis * 40 } }, .35)
assert(#disjoint == 2, "renderer connected untraveled space")
local origin = Vector3.new(0, 300, 0)
local direction = Vector3.new(1, .3, -.7).Unit
local visuals = {}
local group
for index = 1, 30 do
	local position = origin + direction * (index * 5)
	local model, rig = Beam.Build({ Id = index, Position = position, Velocity = direction * 2000,
		Beam = { ChannelId = 900000001, Origin = origin, Length = 40, Radius = .35 } })
	local visual = { id = index, model = model, rig = rig, position = position, velocity = direction * 2000,
		inView = true, timeScale = 1, life = 5, gravity = 0, acceleration = 0, minSpeed = 0,
		maxSpeed = math.huge, simulationDebt = 0, synced = false }
	Beam.Attach(visual)
	visuals[index], group = visual, rig.beam.group
end
Beam.FlushGroups()
Beam.ApplyGroups()
local activeCylinders = 0
for _, instance in group.model:GetDescendants() do
	if instance:IsA("Part") and instance.Shape == Enum.PartType.Cylinder and instance.Transparency < 1 then
		activeCylinders += 1
		assert(math.abs(instance.CFrame.RightVector:Dot(direction)) > .999, "first-frame off-axis cylinder")
	end
end
assert(activeCylinders == 2, "30 packets created separate bars: " .. activeCylinders)
assert(#group.segments == 1 and #group.joints == 2)
for _, visual in visuals do visual.inView = false end
Beam.FlushGroups()
Beam.ApplyGroups()
assert(group.segments[1].core.Transparency == 1, "stale offscreen geometry remains")
visuals[30].inView = true
VisualModel.Place(visuals[30], visuals[30].position + direction * 5, direction * 2000)
Beam.FlushGroups()
Beam.ApplyGroups()
assert(group.segments[1].core.Transparency == 0)
local groupModel = group.model
for _, visual in visuals do Beam.Retire(visual, 0) end
Beam.StepRetired(.5)
assert(groupModel.Parent == nil, "last packet did not release shared geometry")
for _, visual in visuals do assert(visual.model.Parent == nil, "packet metadata leaked") end
local contact = origin + direction * 30
local cornerModel, cornerRig = Beam.Build({ Id = 100, Position = origin + direction * 50, Velocity = direction * 2000,
	Beam = { ChannelId = 900000002, Origin = origin, Length = 80, Radius = .35 } })
local corrected = { id = 100, model = cornerModel, rig = cornerRig, position = contact + Vector3.yAxis * 30,
	velocity = Vector3.yAxis * 2000, inView = true, timeScale = 1, synced = true }
Beam.Attach(corrected)
Beam.Correct(corrected, contact)
VisualModel.Place(corrected, corrected.position, corrected.velocity)
Beam.FlushGroups()
Beam.ApplyGroups()
assert(#cornerRig.beam.group.segments == 2 and #cornerRig.beam.group.joints == 3, "bounce lost continuous rounded corner")
assert((cornerRig.beam.points[2] - contact).Magnitude < .001, "bounce retained predicted overshoot")
corrected.inView = false
corrected.position += Vector3.zAxis * 10
Beam.Update(corrected, corrected.position, Vector3.zAxis * 2000)
corrected.inView = true
Beam.Reset(corrected)
assert(#cornerRig.beam.points == 4, "offscreen homing history was replaced with a shortcut")
corrected.timeScale = 0
Beam.Retire(corrected, 0)
Beam.StepRetired(.5)
assert(cornerModel.Parent ~= nil and cornerRig.beam.length > 60, "frozen beam tail drained in real time")
corrected.timeScale = 1
Beam.StepRetired(.5)
assert(cornerModel.Parent == nil, "corrected beam tail leaked")
script:SetAttribute("ActiveCylinders", activeCylinders)
script:SetAttribute("Complete", true)
print("[BeamVisualRegression] PASS: one shared span, round bends, no wall shortcuts, spawn orientation, culling, drain cleanup")
