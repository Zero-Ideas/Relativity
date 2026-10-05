-- Studio-only, deterministic gameplay VM harness. Tests the FIRST wire frame,
-- not merely the server's eventual topology. No messages reach real clients.
local shared=game.ReplicatedStorage._BeamWireAfterShared
local server=game.ServerScriptService._BeamWireAfterServer
local P=require(server.Projectile)
local H=require(server.Projectile.BeamProjectileHandler)
local HB=require(shared.Heartbeat)
local V=require(shared.VisualOffload)
local Protocol=require(shared.ProjectileProtocol)
local limit=require(shared.Projectile.BeamPath).MaxStretch
local origin=Vector3.new(0,6000,0)
local channel=987654101
local known,paths,spawns={},{},{}
local fresh={}
local function receive()
	local count=0
	table.clear(fresh)
	for _,event in V.Events do
		if event.Key==Protocol.Channels.SpawnBatch then
			assert(#event.Data<=1000,"spawn batching cap was increased")
			for _,data in event.Data do
				known[data.Id]=true;spawns[data.Id]=data
				fresh[data.Id]=true
				paths[data.Id]=data.Beam and data.Beam.Path
				count+=1
			end
		elseif event.Key==Protocol.Channels.Move then
			for _,data in event.Data do if known[data.Id] then paths[data.Id]=data.BeamPath;fresh[data.Id]=true end end
		end
	end
	table.clear(V.Events)
	return count
end
local function checkFirstFrame()
	local missing=0
	for _,p in P.GetAll() do if not p.Dead and p.Beam and p.Beam.ChannelId==channel then
		if not known[p.Id] then missing+=1 end
		local path=assert(paths[p.Id],"first-frame beam spawn omitted its completed body")
		-- Quiet older packets now predict locally; only snapshots actually sent
		-- this frame must match the completed authoritative path verbatim.
		if fresh[p.Id] then
			assert(#path==#p._beamSpan,"wire body differs from authoritative body")
			for i,point in path do assert((point-p._beamSpan[i]).Magnitude<.001,"mixed-frame wire endpoints") end
		end
	end end
	assert(missing==0,"newest head published before "..missing.." of its joiners")
end
local function launch(position)
	return H.Launch({Origin=position,Direction=Vector3.yAxis,Speed=60,Lifetime=5,Visualize=true,
		Beam={ChannelId=channel}})
end
local function xyz(v)return {v.X,v.Y,v.Z}end
local ok,problem=xpcall(function()
	launch(origin);HB.Step(1/60);receive()
	launch(origin+Vector3.xAxis*limit*2.5);HB.Step(1/60);receive();checkFirstFrame()
	-- Replay exactly these first-frame snapshots in the client geometry test.
	local snapshot={}
	for id,path in paths do
		local data=spawns[id]
		if data and data.Beam and data.Beam.ChannelId==channel then
			local points={};for _,point in path do table.insert(points,xyz(point))end
			table.insert(snapshot,{Id=id,Position=xyz(path[1]),Path=points})
		end
	end
	local value=Instance.new("StringValue");value.Name="_BeamFirstFrameSnapshot"
	value.Value=game:GetService("HttpService"):JSONEncode(snapshot);value.Parent=game.ReplicatedStorage
	script:SetAttribute("FirstFramePackets",#snapshot)
	-- Repeat publication while the newest link needs different subdivisions.
	for frame=1,20 do
		launch(origin+Vector3.xAxis*(math.sin(frame)*limit*2.5))
		HB.Step(1/60);receive();checkFirstFrame()
	end
	-- Standalone beam snapshots keep their already-swept launch origin.
	local solo=P.new({Origin=origin+Vector3.zAxis*200,Direction=Vector3.yAxis,Speed=60,
		Visualize=true,Beam={}})
	HB.Step(1/60);receive()
	assert(spawns[solo.Id].Beam.Origin==origin+Vector3.zAxis*200,"standalone beam lost its swept origin")
	assert((spawns[solo.Id].Position-spawns[solo.Id].Beam.Origin).Magnitude>.5)
	-- End-of-frame publication must retain FIFO caps for ordinary volleys.
	for _,p in P.GetAll()do p:Destroy(nil,"test-cleanup")end
	HB.Step(1/60);receive()
	for _=1,2501 do P.new({Origin=origin,Speed=0,Lifetime=5,Visualize=true})end
	local batches={}
	for i=1,3 do HB.Step(1/60);batches[i]=receive()end
	assert(batches[1]==1000 and batches[2]==1000 and batches[3]==501,"ordinary spawn cohorts changed")
	script:SetAttribute("OrdinarySpawnBatches",table.concat(batches,","))
	-- A shot already dead in its first step must never be spawned afterward.
	local fleeting=P.new({Origin=origin,Speed=0,Lifetime=.001,Visualize=true})
	HB.Step(1/60);receive()
	assert(fleeting.Dead and not known[fleeting.Id],"dead shot got a late visual")
end,debug.traceback)
for _,p in P.GetAll()do p:Destroy(nil,"test-cleanup")end
script:SetAttribute("Passed",ok);script:SetAttribute("Problem",if ok then "" else tostring(problem))
script:SetAttribute("Complete",true)
print("[BeamFirstFrameReplication]",ok,problem)
