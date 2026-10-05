-- Normal LocalScript, isolated renderer clone; no real game beam channels.
local modules = game.ReplicatedStorage.Shared._BeamPredictionClient
local Beam = require(modules.BeamVisual)
local Geometry = require(modules.BeamGeometry)
local CM = require(game.ReplicatedStorage.Shared.ChunkManager)
local origin = Vector3.new(0, 7000, 0)
local visuals = {}
local function make(id, position, previous, path, velocity, standalone)
	local model, rig = Beam.Build({Id=id, Position=position, Velocity=velocity, Lifetime=10,
		ServerTime=100, GlobalScale=1,
		Beam={ChannelId=if standalone then nil else 987654202,PreviousId=previous,
			Origin=position,Radius=.35,Length=24,Path=path}})
	local v = {id=id,model=model,rig=rig,position=position,velocity=velocity,life=10,
		gravity=0,acceleration=0,minSpeed=0,maxSpeed=math.huge,simulationDebt=0,
		timeScale=1,lastSimulationTime=0,inView=true}
	Beam.Attach(v); table.insert(visuals,v); return v
end
local zone = "BeamPredictionRegression"
local ok, problem = xpcall(function()
	local front = make(987654211,origin+Vector3.xAxis*20,nil,{origin+Vector3.xAxis*20},Vector3.yAxis*100)
	local back = make(987654212,origin,front.id,{origin,front.position},Vector3.yAxis*50)
	local solo = make(987654213,origin+Vector3.zAxis*100,nil,nil,Vector3.yAxis*100,true)
	Beam.PredictGroups(100.2,.2); Beam.FlushGroups(.2)
	assert((solo.position-(origin+Vector3.new(0,20,100))).Magnitude<.001,
		"standalone beam ignored its motion epoch")
	local path = back.rig.beam.linkPoints
	assert((path[1]-back.position).Magnitude<.001 and (path[#path]-front.position).Magnitude<.001,
		"endpoints predicted at different epochs")
	assert((front.position-(origin+Vector3.new(20,20,0))).Magnitude<.001,
		"timestamped flight did not consume elapsed motion")
	-- Repeat tessellation after stretching an EXISTING beamlet; no one-time split.
	Beam.PredictGroups(101,1); Beam.FlushGroups(1)
	path = back.rig.beam.linkPoints
	local spans = Geometry.Merge({path},.35)
	assert(#spans>2)
	for _,span in spans do assert((span[2]-span[1]).Magnitude<=12.002) end
	-- Apply a steering/bounce seed at its true epoch and catch up once.
	front.position = origin+Vector3.xAxis*40; front.velocity = -Vector3.xAxis*100
	Beam.AdoptPath(front,{front.position},false)
	Beam.AdoptMotion(front,101,1,0)
	Beam.PredictGroups(101.1,1.1); Beam.FlushGroups(1.1)
	assert((front.position-(origin+Vector3.xAxis*30)).Magnitude<.002)
	assert((back.rig.beam.linkPoints[2]-front.position).Magnitude<.002)
	-- Frozen global epoch does not move, even while real time continues.
	local frozen = front.position
	Beam.AdoptMotion(front,101.1,0,0)
	Beam.PredictGroups(102,2)
	assert(front.position==frozen)
	-- Clipped back endpoint stays a world anchor, not a predecessor prediction.
	local clip = back.position+Vector3.xAxis*3
	Beam.AdoptPath(back,{back.position,clip},true)
	Beam.PredictGroups(102.1,2.1); Beam.FlushGroups(2.1)
	assert(back.rig.beam.linkPoints[2]==clip)
	-- Each endpoint samples the same spatial time-field independently.
	CM.AddTimeScaleZone(zone,front.position,2,0)
	Beam.AdoptMotion(front,102.1,1,0)
	local before = front.position
	Beam.PredictGroups(102.2,2.2)
	assert(front.position==before,"frozen spatial endpoint moved")
	CM.RemoveTimeScaleZone(zone)
	-- Explicit unlink must not resurrect the old predecessor connection.
	Beam.AdoptMotion(back,102.2,1,0)
	Beam.AdoptPath(back,{back.position,back.position+Vector3.zAxis*4},false)
	Beam.PredictGroups(102.3,2.3); Beam.FlushGroups(2.3)
	assert((back.rig.beam.linkPoints[2]-back.rig.beam.linkPoints[1]-Vector3.zAxis*4).Magnitude<.002)
	-- An impact/removal must never tether a moving packet to a stale front.
	local missingFront = make(987654214,origin+Vector3.xAxis*20,nil,{origin+Vector3.xAxis*20},Vector3.zero)
	local fastBack = make(987654215,origin,missingFront.id,{origin,missingFront.position},Vector3.yAxis*2000)
	Beam.Discard(missingFront)
	Beam.PredictGroups(100.5,.5); Beam.FlushGroups(.5)
	local fragment = fastBack.rig.beam.linkPoints
	assert(#fragment==2 and (fragment[2]-fragment[1]).Magnitude<21,
		"missing front drew a giant beam to its old spawn/impact point")
	-- An alive but inconsistent front cannot authorize a giant new connection.
	Beam.AdoptMotion(fastBack,100.5,1,front.id)
	Beam.FlushGroups(.5)
	assert(#fastBack.rig.beam.linkPoints==1,"stale steering link drew a giant shortcut")
	-- Hit retirement freezes the supplied collision path, not predicted endpoints.
	local approved = {fastBack.position,fastBack.position+Vector3.xAxis*4}
	Beam.AdoptPath(fastBack,approved,false,true)
	Beam.Retire(fastBack,0)
	assert(fastBack.rig.beam.points[2]==approved[2],"impact retirement extrapolated a final server path")
	Beam.StepRetired(60)
end, debug.traceback)
CM.RemoveTimeScaleZone(zone)
for _,v in visuals do if v.model.Parent then Beam.Discard(v) end end
script:SetAttribute("Passed",ok)
script:SetAttribute("Problem",if ok then "" else tostring(problem))
script:SetAttribute("Complete",true)
print("[BeamPredictionGeometry]",ok,problem)
