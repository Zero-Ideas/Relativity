-- Temporary Studio LocalScript; never shipped by the Rojo game project.
-- Every logical sample has an old vertical trajectory, but the sustained
-- centerline runs sideways. None may add a private trajectory tail.
local modules=game.ReplicatedStorage.Shared.Projectile.Client
local Beam=require(modules.BeamVisual)
local Geometry=require(modules.BeamGeometry)
local origin=Vector3.new(0,500,0)
local visuals={}
local group
for index=1,6 do
	local position=origin+Vector3.xAxis*((index-1)*20)
	local path=if index>1 then {position,position-Vector3.xAxis*20} else nil
	local model,rig=Beam.Build({Id=960000+index,Position=position,Velocity=Vector3.yAxis*100,
		Beam={ChannelId=960000001,PreviousId=if index>1 then 959999+index else nil,
			Origin=position-Vector3.yAxis*20,Length=24,Radius=.35,Path=path}})
	local visual={id=960000+index,model=model,rig=rig,position=position+Vector3.xAxis*2,
		velocity=Vector3.yAxis*100,inView=true,timeScale=1,synced=true}
	Beam.Attach(visual)
	visuals[index],group=visual,rig.beam.group
end
local function checkNoTails()
	Beam.FlushGroups();Beam.ApplyGroups()
	game:GetService("RunService").Heartbeat:Wait()
	local vertical=0
	for _,pair in group.segments do
		if pair.core.Transparency<1 then
			assert(pair.core.Size.X<=Geometry.MaxSegmentLength+.002)
			if math.abs(pair.core.CFrame.RightVector:Dot(Vector3.yAxis))>.99 then vertical+=1 end
		end
	end
	assert(vertical==0,"connected stream exposed per-packet trajectory tails: "..vertical)
end
local ok,problem=xpcall(function()
	-- Neighbor poses need not be from the same streamed round-robin visit.
	-- Connection identity must not be inferred from tiny coordinate equality.
	checkNoTails()
	-- A retired incoming section still owns the preceding endpoint. Its
	-- frozen drain must not expose the preceding packet's old trajectory.
	Beam.Retire(visuals[3],0)
	visuals[3].timeScale=0
	Beam.StepRetired(.1)
	checkNoTails()
	-- A clipped body renders its approved clipped span, not the preceding
	-- sample's old trajectory. Missing/unlinked poses also cannot add tails.
	Beam.AdoptPath(visuals[5],{origin+Vector3.xAxis*80,origin+Vector3.xAxis*70},true)
	Beam.FlushGroups();Beam.ApplyGroups()
	game:GetService("RunService").Heartbeat:Wait()
	local vertical=0
	for _,pair in group.segments do
		if pair.core.Transparency<1 and math.abs(pair.core.CFrame.RightVector:Dot(Vector3.yAxis))>.99 then vertical+=1 end
	end
	assert(vertical==0,"clipped link resurrected a trajectory tail")
	Beam.AdoptPath(visuals[4],nil)
	checkNoTails()
	Beam.Retire(visuals[4],0)
	assert(#visuals[4].rig.beam.points==1,"retirement fell back to old packet history")
end,debug.traceback)
for _,visual in visuals do
	if visual.rig.beam.retired then visual.timeScale=1 else Beam.Discard(visual) end
end
Beam.StepRetired(1)
assert(ok,problem)
script:SetAttribute("Complete",true)
print("[BeamTailOwnershipRegression] PASS: staggered poses, no interior tails, frozen retirement, clipped fragments")
