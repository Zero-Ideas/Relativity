-- Fresh-module Studio harness; validates adaptive joiners and bounded work.
local shared=game.ReplicatedStorage._BeamStretchShared
local server=game.ServerScriptService._BeamStretchServer
local Path=require(shared.BeamPath)
local Handler=require(server.BeamProjectileHandler)
local Projectile=require(server.Projectile)
local function liveCount()
	local count=0
	for _,p in Projectile.GetAll() do if not p.Dead then count+=1 end end
	return count
end
local function root(p)
	local seen={}
	while p._beamPrevious and not seen[p.Id] do seen[p.Id]=true;p=p._beamPrevious end
	return p
end
local function clean()
	for _,p in Projectile.GetAll() do if p.Beam and p.Beam.ChannelId>=940000001 and p.Beam.ChannelId<=940000005 then p:Destroy(nil,"test-cleanup") end end
	task.wait()
end
local limit=Path.MaxStretch
local function check(points)
	assert(points)
	for index=1,#points-1 do assert((points[index+1]-points[index]).Magnitude<=limit+.002,"joiner exceeds configured spacing") end
end
check(Path.Connect(Vector3.zero,Vector3.xAxis*limit))
local corners,required=Path.Plan(Vector3.zero,Vector3.xAxis*(limit*3))
assert(required==2 and corners)
local pool,output,indices={},{},{}
local points=Path.Fill(corners,pool,output,indices)
check(points)
assert(#points==4 and #pool==2)
local reused=pool[1]
local compact=Path.Compact(points,indices)
assert(#compact==2 and compact[1]==Vector3.zero and compact[2]==Vector3.xAxis*(limit*3),"network sends every deterministic joiner")
local short=assert(Path.Plan(Vector3.zero,Vector3.xAxis*(limit*.5)))
Path.Fill(short,pool,output,indices)
Path.Fill(corners,pool,output,indices)
assert(pool[1]==reused and #pool==2,"shrinking/regrowing link reallocates joiners")
local corner=Vector3.xAxis*(limit*1.5)
local bent=Vector3.new(limit*1.5,0,limit*1.5)
local bendCorners,bendCount=Path.Plan(Vector3.zero,bent,{}, {corner})
assert(bendCorners and bendCount==2)
local bend=Path.Fill(bendCorners,pool,output,indices)
check(bend)
local bendCompact=Path.Compact(bend,indices)
assert(#bendCompact==3 and bendCompact[2]==corner,"joiners shortcut a bounce corner")
local partial=table.clone(bend)
partial[#partial]=partial[#partial-1]:Lerp(partial[#partial],.5)
local partialCompact=Path.Compact(partial,indices)
assert(#partialCompact==3 and partialCompact[2]==corner and partialCompact[3]==partial[#partial],"clipped network path lost exact corner")
assert(not Path.Connect(Vector3.zero,Vector3.xAxis*(limit*(Path.MaxJoinersPerLink+2))),"unbounded joiner generation")
assert(not Path.Connect(Vector3.zero,Vector3.xAxis,{corner},{}),"invalid bounce branches reconnected")
assert(Handler.GetInterval(1e9)==1/60,"unbounded emission rate")
local origin=Vector3.new(200,5000,0)
local spawned={}
local originalBeamBudget=Handler.MaxJoinersPerBeam
local originalCreationBudget=Handler.MaxNewJoinersPerFrame
local function launch(position,channel)
	local p=Handler.Launch({Origin=position,Speed=0,Lifetime=5,Beam={ChannelId=channel},Visualize=false})
	table.insert(spawned,p);return p
end
local ok,problem=xpcall(function()
	local baseline=liveCount()
	local a=launch(origin,940000001)
	local b=launch(origin+Vector3.xAxis*(limit*3),940000001)
	task.wait(.04)
	assert(root(b)==a and b._beamSpan and #b._beamSpan>=2,"long gap did not receive moving joiners")
	assert(Handler.GetJoinerStats().Active==2)
	assert(liveCount()==baseline+2+Handler.GetJoinerStats().Active,"child count disagrees with registered simulation")
	b.Position=origin+Vector3.xAxis*(limit*.5)
	task.wait(.04)
	assert(Handler.GetJoinerStats().Active>=2 and root(b)==a,"shrinking discarded persistent samples")
	b.Position=origin+Vector3.xAxis*(limit*3)
	task.wait(.04)
	assert(Handler.GetJoinerStats().Active>=2 ,"stable children were recreated each frame")
	-- Keep growing the SAME connector after spawn; long cross-links must
	-- acquire additional joiners, not only their initial subdivision.
	for _,multiple in {4,6,8} do
		b.Position=origin+Vector3.xAxis*(limit*multiple)
		task.wait(.04)
		assert(root(b)==a and Handler.GetJoinerStats().Active>=multiple-1,
			"growing connector did not gain joiners after spawn")
		check(b._beamSpan)
		assert(liveCount()==baseline+2+Handler.GetJoinerStats().Active,"growing children missing from simulation")
	end
	b.Position=origin+Vector3.xAxis*(limit*(Path.MaxJoinersPerLink+50))
	task.wait(.04)
	assert(b.Beam.PreviousId==nil and (b._beamSpan and #b._beamSpan>=2),"over-budget link did not retain a finite independent fragment")
	b.Position=origin+Vector3.xAxis
	task.wait(.04)
	assert(b.Beam.PreviousId==nil,"broken samples silently reattached")
	clean()
	table.clear(spawned)
	-- Force the per-channel budget and verify only one link can be filled.
	local oldBudget=Handler.MaxJoinersPerBeam
	Handler.MaxJoinersPerBeam=2
	local one=launch(origin,940000002)
	local two=launch(origin+Vector3.xAxis*(limit*2),940000002)
	local three=launch(origin+Vector3.xAxis*(limit*4),940000002)
	local four=launch(origin+Vector3.xAxis*(limit*6),940000002)
	task.wait(.04)
	Handler.MaxJoinersPerBeam=oldBudget
	assert(root(two)==one and root(three)==one and four.Beam.PreviousId==nil,"per-beam joiner budget bypassed")
	clean()
	table.clear(spawned)
	-- A global creation cap applies across channels, not separately to each.
	local oldCreate=Handler.MaxNewJoinersPerFrame
	Handler.MaxNewJoinersPerFrame=1
	local first=launch(origin,940000003)
	local next=launch(origin+Vector3.xAxis*(limit*2),940000003)
	local other=launch(origin+Vector3.zAxis*20,940000004)
	local last=launch(origin+Vector3.zAxis*20+Vector3.xAxis*(limit*2),940000004)
	task.wait(.04)
	Handler.MaxNewJoinersPerFrame=oldCreate
	assert((next.Beam.PreviousId==nil)~=(last.Beam.PreviousId==nil),"global allocation budget was not shared")
	assert(Handler.GetJoinerStats().Active==1)
	clean()
	table.clear(spawned)
	-- Allocation exhaustion must never delete already-admitted children.
	local updateFront=launch(origin,940000005)
	local updateBack=launch(origin+Vector3.xAxis*(limit*3),940000005)
	task.wait(.04)
	local existing=Handler.GetJoinerStats().Active
	Handler.MaxNewJoinersPerFrame=0
	task.wait(.05)
	assert(root(updateBack)==updateFront and Handler.GetJoinerStats().Active==existing,
		"allocation exhaustion deleted existing children")
end,debug.traceback)
Handler.MaxJoinersPerBeam=originalBeamBudget
Handler.MaxNewJoinersPerFrame=originalCreationBudget
clean()
assert(ok,problem)
assert(Handler.GetJoinerStats().Active==0,"destroy leaked joiner count")
script:SetAttribute("Complete",true)
print("[BeamStretchRegression] PASS: adaptive joiners, exact bends, pool reuse, real child registration, finite fragments, bounded allocation without deleting live children")
