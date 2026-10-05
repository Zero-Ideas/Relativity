-- Normal Script in the isolated Studio harness; never ships with the game.
local shared = game.ReplicatedStorage._BeamStretchShared
local server = game.ServerScriptService._BeamStretchServer
local Handler = require(server.Projectile.BeamProjectileHandler)
local Projectile = require(server.Projectile)
local function root(p)
	local seen={}
	while p._beamPrevious and not seen[p.Id] do seen[p.Id]=true;p=p._beamPrevious end
	return p
end
local function clean()
	for _,p in Projectile.GetAll() do if p.Beam and p.Beam.ChannelId>=920000001 and p.Beam.ChannelId<=920000003 then p:Destroy(nil,"test-cleanup") end end
end
local Chunks = require(shared.ChunkManager)
local viewer = game.Players:GetPlayers()[1]
local origin = viewer.Character:GetPivot().Position + Vector3.yAxis*240
local wall = Instance.new("Part")
wall.Name = "_BeamContinuityWall"
wall.Anchored = true
wall.Size = Vector3.new(2,20,20)
wall.Position = origin + Vector3.xAxis*100
wall.Parent = workspace
local spawned = {}
local zoneId = "_BeamContinuityZone"
local function launch(position,channel,extras)
	local config={Origin=position,Direction=Vector3.xAxis,Speed=100,Lifetime=5,
		Bounces=2,Restitution=1,Radius=.35,Beam={ChannelId=channel},Visualize=false}
	for key,value in extras or {} do config[key]=value end
	local p=Handler.Launch(config); table.insert(spawned,p); return p
end
local ok,problem=xpcall(function()
	local front=launch(origin+Vector3.xAxis*65,920000001)
	local back=launch(origin+Vector3.xAxis*45,920000001)
	local tail=launch(origin+Vector3.xAxis*25,920000001)
	local frontHits,backHits,tailHits=0,0,0
	front.OnHit:Connect(function() frontHits+=1 end)
	back.OnHit:Connect(function() backHits+=1 end)
	tail.OnHit:Connect(function() tailHits+=1 end)
	local deadline=os.clock()+1.2
	repeat task.wait() until frontHits>0 or os.clock()>deadline
	assert(frontHits==1 and #front._beamTurns==1,"leading head did not bounce")
	assert(backHits==0 and tailHits==0 and back.BouncesLeft==2 and tail.BouncesLeft==2,
		"one wall bounce cascaded through the whole beam")
	assert(back.Position.X < wall.Position.X-15 and tail.Position.X < back.Position.X,
		"trailing endpoints collapsed onto leading contact")
	assert(back._beamSpan and #back._beamSpan>=3,"incoming/outgoing sections lost their corner")
	repeat task.wait() until backHits>0 or os.clock()>deadline
	assert(backHits==1 and back.BouncesLeft==1 and tailHits==0,"trailing head did not bounce at its own arrival")
	clean()
	table.clear(spawned)
	-- A stopped leading head is still the front of the remaining incoming
	-- section. Trigger/death must not teleport or immediately delete its back.
	local stopped=launch(origin+Vector3.xAxis*65,920000002,{Bounces=0})
	local incoming=launch(origin+Vector3.xAxis*45,920000002,{Bounces=0})
	deadline=os.clock()+1.2
	repeat task.wait() until stopped.Dead or os.clock()>deadline
	assert(stopped.Dead and not incoming.Dead and incoming.Beam.PreviousId==stopped.Id)
	assert(incoming._beamSpan and #incoming._beamSpan==2,"world impact tore the remaining incoming span")
	clean()
	table.clear(spawned)
	-- The back freezes while the front travels outside a spherical zone.
	-- A frozen back gets additional joiners as its moving front gets farther
	-- away; neither endpoint teleports or prematurely consumes a bounce.
	Chunks.AddTimeScaleZone(zoneId,origin,15,0)
	local spacing=require(shared.Projectile.BeamPath).MaxStretch
	wall.Position=origin+Vector3.xAxis*(spacing*5)
	local moving=launch(origin+Vector3.xAxis*(spacing*.9),920000003)
	local frozen=launch(origin,920000003)
	task.wait(.15)
	assert((frozen.Position-origin).Magnitude<.001,"frozen endpoint moved")
	assert(moving.Position.X>origin.X+spacing and frozen._beamSpan and root(frozen)==moving,
		"dilation boundary did not receive adaptive joiners")
	assert(Handler.GetJoinerStats().Active>=1)
	Chunks.RemoveTimeScaleZone(zoneId)
	task.wait(.08)
	assert(frozen.Position.X>origin.X+1 and frozen.BouncesLeft==2,"thaw jumped/bounced frozen body")
	assert(root(frozen)==moving,"thaw broke a valid subdivided link")
end,debug.traceback)
Chunks.RemoveTimeScaleZone(zoneId)
clean()
wall:Destroy()
assert(ok,problem)
script:SetAttribute("Complete",true)
print("[BeamContinuityRegression] PASS: independent bounce arrival, no clumping, world-stop continuity, frozen boundary and thaw")
