-- Temporary Studio LocalScript; never shipped by the Rojo game project.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio())
local modules = game.ReplicatedStorage.Shared.Projectile.Client
local Geometry = require(modules.BeamGeometry)
local dots, dotCaps = Geometry.Merge({{Vector3.zero},{Vector3.xAxis*50}}, .35)
assert(#dots == 0 and #dotCaps == 0, "zero-length paths left floating glow dots")
local Beam = require(modules.BeamVisual)
local VisualModel = require(modules.VisualModel)
local paths = {}
for index = 1, 30 do paths[index] = { Vector3.new(index * 5, 0, 0), Vector3.new(index * 5 + 40, 0, 0) } end
local merged, joints = Geometry.Merge(paths, .35)
assert(#merged == math.ceil(185/(Geometry.MaxSegmentLength-.01)) and #joints == 2, "overlapping packets did not become one subdivided span")
for _, span in merged do assert((span[2]-span[1]).Magnitude <= Geometry.MaxSegmentLength+.002) end
local farPaths = {}
local farHeading = Vector3.new(1,.3,-.7).Unit
local farOrigin = Vector3.new(236,300,919)
for index = 1, 150 do
	farPaths[index] = { farOrigin + farHeading * (10000 + index * 60), farOrigin + farHeading * (10133 + index * 60) }
end
local farSpans = Geometry.Merge(farPaths,.35)
assert(#farSpans == math.ceil(9073/(Geometry.MaxSegmentLength-.01)), "float error fragmented long-range beam")
for _, span in farSpans do assert((span[2]-span[1]).Magnitude <= Geometry.MaxSegmentLength+.01) end
local corner, cornerJoints = Geometry.Merge({ { Vector3.zero, Vector3.xAxis * 20, Vector3.new(20, 0, 20) } }, .35)
assert(#corner == 4 and #cornerJoints == 3, "bend did not retain a shared rounded joint")
local disjoint = Geometry.Merge({ { Vector3.zero, Vector3.xAxis * 10 }, { Vector3.xAxis * 30, Vector3.xAxis * 40 } }, .35)
assert(#disjoint == 2, "renderer connected untraveled space")
local flick,flickJoints=Geometry.Merge({ { Vector3.xAxis*4000,Vector3.zero,-Vector3.xAxis*4000+Vector3.yAxis*200 } },1.2)
assert(#flick>600 and #flickJoints==3,"fast flick was not subdivided with a shared turn")
for _,span in flick do assert((span[2]-span[1]).Magnitude<=Geometry.MaxSegmentLength+.002) end
local origin = Vector3.new(0, 300, 0)
local direction = Vector3.new(1, .3, -.7).Unit
local visuals = {}
local group
for index = 1, 30 do
	local position = origin + direction * ((31-index) * 5)
	local path = if index>1 then {position,position+direction*5} else {position}
	local model, rig = Beam.Build({ Id = index, Position = position, Velocity = direction * 2000,
		Beam = { ChannelId = 900000001, PreviousId = if index > 1 then index-1 else nil, Origin = origin, Length = 40, Radius = .35, Path=path } })
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
assert(activeCylinders == 2*math.ceil(150/(Geometry.MaxSegmentLength-.01)), "30 packets failed bounded-section union: " .. activeCylinders)
assert(#group.joints == 2)
for _, pair in group.segments do assert(pair.glow.Size.X <= Geometry.MaxSegmentLength) end
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
Beam.AdoptPath(corrected,{origin,contact,corrected.position})
Beam.FlushGroups()
Beam.ApplyGroups()
assert(#cornerRig.beam.group.segments == 6 and #cornerRig.beam.group.joints == 3, "bounce lost continuous rounded corner")
assert((cornerRig.beam.authoritativePath[2] - contact).Magnitude < .001, "bounce retained predicted overshoot")
corrected.inView = false
corrected.position += Vector3.zAxis * 10
Beam.Update(corrected, corrected.position, Vector3.zAxis * 2000)
corrected.inView = true
Beam.Reset(corrected)
Beam.AdoptPath(corrected,{origin,contact,contact+Vector3.yAxis*30,corrected.position})
assert(#cornerRig.beam.authoritativePath == 4, "offscreen homing path was replaced with a shortcut")
corrected.timeScale = 0
Beam.Retire(corrected, 0)
Beam.StepRetired(.5)
assert(cornerModel.Parent ~= nil and cornerRig.beam.length > 60, "frozen beam tail drained in real time")
corrected.timeScale = 1
Beam.StepRetired(.5)
assert(cornerModel.Parent == nil, "corrected beam tail leaked")
local linkedVisuals = {}
local offsets = { Vector3.new(0,0,-60), Vector3.new(8,0,-35), Vector3.new(5,0,-10) }
local linkedGroup
for index, offset in offsets do
	local model, rig = Beam.Build({ Id = 200+index, Position = origin+offset, Velocity = offset.Unit*2000,
		Beam = { ChannelId = 900000003, PreviousId = if index > 1 then 199+index else nil, Origin = origin, Length = 133, Radius = .35,
			Path=if index>1 then {origin+offset,origin+offsets[index-1]} else {origin+offset} } })
	local visual = { id = 200+index, model = model, rig = rig, position = origin+offset, velocity = offset.Unit*2000,
		inView = true, timeScale = 1, synced = false }
	Beam.Attach(visual)
	linkedVisuals[index], linkedGroup = visual, rig.beam.group
end
Beam.FlushGroups()
Beam.ApplyGroups()
assert(#linkedGroup.segments > 3 and #linkedGroup.joints == 3, "steered beam was not one subdivided connected path")
for _, pair in linkedGroup.segments do assert(pair.glow.Size.X <= Geometry.MaxSegmentLength) end
for index = 2, 3 do
	local path = linkedVisuals[index].rig.beam.linkPoints
	assert(path and (path[1]-(origin+offsets[index])).Magnitude < .001)
	assert((path[#path]-(origin+offsets[index-1])).Magnitude < .001, "adjacent tilted ends are not joined")
end
Beam.StopBody(linkedVisuals[2], origin+(offsets[1]+offsets[2])*.5)
for _, visual in linkedVisuals do Beam.Retire(visual,0) end
Beam.StepRetired(.5)
assert(linkedGroup.model.Parent == nil, "steered stream leaked shared geometry")
local splitVisuals={}
local splitGroup
local Path=require(modules.Parent.Projectile.BeamPath)
for index=1,2 do
	local back=origin+Vector3.xAxis*((index-1)*Path.MaxStretch*3)
	local position=back+Vector3.xAxis*10
	local model,rig=Beam.Build({Id=910000+index,Position=position,Velocity=Vector3.xAxis*2000,
		Beam={ChannelId=900000004,PreviousId=if index==2 then 910001 else nil,Origin=back,Length=24,Radius=.35,
			Path=if index==2 then Path.Connect(position,origin+Vector3.xAxis*10) else {position}}})
	local visual={id=910000+index,model=model,rig=rig,position=position,velocity=Vector3.xAxis*2000,
		inView=true,timeScale=1,synced=false}
	Beam.Attach(visual);splitVisuals[index],splitGroup=visual,rig.beam.group
end
Beam.FlushGroups();Beam.ApplyGroups()
local filled=splitVisuals[2].rig.beam.linkPoints
assert(filled and #filled==4,"client did not generate joiners across a growing gap")
for index=1,#filled-1 do assert((filled[index+1]-filled[index]).Magnitude<=Path.MaxStretch+.002) end
-- A server-authoritative beam must not speculate on a path before the
-- server admits its joiners within the frame/channel budget.
splitVisuals[2].synced=true
-- The server sends compact endpoints. Grow the same approved red span
-- repeatedly and check its actual cylinder Instances, not just pure math.
local previousSegments=0
for _,multiple in {3,6,9} do
	local front=splitVisuals[1].position
	local back=front+Vector3.xAxis*(Path.MaxStretch*multiple)
	splitVisuals[2].position=back
	Beam.AdoptPath(splitVisuals[2],{back,front})
	VisualModel.Place(splitVisuals[2],back,Vector3.xAxis*2000)
	Beam.FlushGroups();Beam.ApplyGroups()
	local visible=0
	for _,pair in splitGroup.segments do
		if pair.core.Transparency<1 then
			visible+=1
			assert(pair.core.Size.X<=Geometry.MaxSegmentLength+.002,
				"growing authoritative connector contains an oversized cylinder")
		end
	end
	assert(visible>previousSegments,"growing connector did not gain rendered sections")
	previousSegments=visible
end
Beam.AdoptPath(splitVisuals[2],nil)
Beam.FlushGroups();Beam.ApplyGroups()
assert(splitVisuals[2].rig.beam.linkPoints==nil,"client invented unapproved joiners")
for _,pair in splitGroup.joints do assert(pair.core.Transparency==1,"unapproved zero-length body left a glow dot") end
-- A real disconnected fragment has its own finite authoritative body; it
-- remains visible without inventing a chord back to the preceding sample.
Beam.AdoptPath(splitVisuals[2],{splitVisuals[2].position,splitVisuals[2].position+Vector3.xAxis*10})
Beam.FlushGroups();Beam.ApplyGroups()
assert(splitGroup.segments[1].core.Transparency==0,"finite independent fragment was hidden")
for _,visual in splitVisuals do Beam.Discard(visual) end
local standaloneModel,standaloneRig=Beam.Build({Id=900001,Position=origin+Vector3.xAxis*250,
	Velocity=Vector3.xAxis*2000,Beam={Origin=origin,Length=300,Radius=1.2}})
Beam.ApplyGroups()
assert(#standaloneRig.beam.segments>20,"single beam still uses oversized bars")
for _,pair in standaloneRig.beam.segments do
	assert(pair.glow.Size.X<=Geometry.MaxSegmentLength and math.abs(pair.glow.Size.Y-2.4)<.001,
		"beam length affected diameter or exceeded cap")
end
assert(Beam.Discard({model=standaloneModel,rig=standaloneRig}),"range discard failed")
assert(standaloneModel.Parent==nil,"range discard left geometry behind")
script:SetAttribute("ActiveCylinders", activeCylinders)
script:SetAttribute("Complete", true)
print("[BeamVisualRegression] PASS: joined bounded sections, round bends, no wall shortcuts, spawn orientation, culling, drain cleanup")
