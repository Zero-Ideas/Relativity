-- Normal Studio Script in fresh isolated modules; never shipped by Rojo.
local shared=game.ReplicatedStorage._BeamStretchShared
local server=game.ServerScriptService._BeamStretchServer
local Handler=require(server.BeamProjectileHandler)
local Projectile=require(server.Projectile)
local Chunks=require(shared.ChunkManager)
local Path=require(shared.BeamPath)
local viewer=game.Players:GetPlayers()[1]
local origin=Vector3.new(0,5000,0)
local spawned,samples={},{}
local function chainPoints(p)
	local points,seen={},{}
	while p and not seen[p.Id] do
		seen[p.Id]=true;table.insert(points,p.Position);p=p._beamPrevious
	end
	return points
end
local zoneId="_BeamMovingJoinerZone"
local wall
local function launch(position)
	local p=Handler.Launch({Origin=position,Direction=Vector3.yAxis,Speed=80,Radius=.1,
		Lifetime=5,Beam={ChannelId=970000001},Visualize=false})
	table.insert(spawned,p);return p
end
local ok,problem=xpcall(function()
	local baseline=#Projectile.GetAll()
	local front=launch(origin)
	local back=launch(origin+Vector3.xAxis*Path.MaxStretch*4)
	local deadline=os.clock()+1
	repeat task.wait() until back._beamSpan and #chainPoints(back)>=5 or os.clock()>deadline
	assert(back._beamSpan and #chainPoints(back)>=5,"initial moving subdivision missing")
	local initialCount=Handler.GetJoinerStats().Active
	local frozenPoint=chainPoints(back)[3]
	Chunks.AddTimeScaleZone(zoneId,frozenPoint,8,0)
	-- Hold ORIGINAL endpoints still: only the existing children move.
	front.Velocity,back.Velocity=Vector3.zero,Vector3.zero
	local parentDistance=(front.Position-back.Position).Magnitude
	task.wait(.35)
	assert(chainPoints(back)[#chainPoints(back)]==front.Position and back._beamSpan,"moving child link broke unexpectedly")
	assert(Handler.GetJoinerStats().Active>initialCount,"stretched CHILD gaps weren't subdivided again")
	assert(math.abs((front.Position-back.Position).Magnitude-parentDistance)<.001,"original heads moved")
	local frozenFound,movingFound=false,false
	local points=chainPoints(back)
	for index,point in points do
		if (point-frozenPoint).Magnitude<.005 then frozenFound=true end
		if index>1 and index<#points and point.Y>frozenPoint.Y+1 then movingFound=true end
		if index>1 then assert((point-points[index-1]).Magnitude<=Path.MaxStretch+.005,"child gap exceeded cap") end
	end
	assert(frozenFound and movingFound,"children were re-Lerped instead of independently frozen/moving")
	assert(#Projectile.GetAll()==baseline+2+Handler.GetJoinerStats().Active,"beamlet registration disagrees with live child count")
	script:SetAttribute("InitialJoiners",initialCount)
	script:SetAttribute("RefinedJoiners",Handler.GetJoinerStats().Active)
	Chunks.RemoveTimeScaleZone(zoneId)
	local child=Projectile.CreateBeamSample(back,origin+Vector3.yAxis*80,Vector3.xAxis*100,{})
	table.insert(samples,child)
	child.Gravity,child.TimeScale=20,.5
	local age=child.Age
	assert(child:Step(.1))
	assert(math.abs(child.Age-age-.05)<.001 and math.abs(child.Velocity.Y+1)<.01,"sample gravity/personal time differs from projectile physics")
	local turn=Projectile.CreateBeamSample(back,origin+Vector3.yAxis*100,Vector3.xAxis*100,{})
	table.insert(samples,turn)
	turn.Homing={Target=origin+Vector3.yAxis*200,TurnRate=math.rad(180),Delay=0}
	turn.HomingTarget=turn.Homing.Target
	assert(turn:Step(.1) and turn.Velocity.Y>1,"sample homing did not steer")
	local bounceOrigin=origin+Vector3.yAxis*150
	wall=Instance.new("Part");wall.Anchored=true;wall.Size=Vector3.new(1,20,20)
	wall.Position=bounceOrigin+Vector3.xAxis*8;wall.Parent=workspace
	local bounce=Projectile.CreateBeamSample(back,bounceOrigin,Vector3.xAxis*100,{})
	table.insert(samples,bounce)
	bounce.BouncesLeft,bounce.Restitution=1,1
	assert(bounce:Step(.1) and bounce.BouncesLeft==0 and #bounce._beamTurns==1 and bounce.Velocity.X<0,
		"sample did not bounce on its own arrival")
	assert(back.BouncesLeft==0 and #back._beamTurns==0,"child bounced the parent")
end,debug.traceback)
Chunks.RemoveTimeScaleZone(zoneId)
for _,p in samples do p:Destroy() end
for _,p in Projectile.GetAll() do if p.Beam and p.Beam.ChannelId==970000001 then p:Destroy(nil,"test-cleanup") end end
if wall then wall:Destroy() end
assert(ok,problem)
script:SetAttribute("Complete",true)
print("[BeamMovingJoinerRegression] PASS: moving children, recursive child-gap refinement, frozen curve, shared gravity/homing/bounce physics, real registered/colliding beamlets")
