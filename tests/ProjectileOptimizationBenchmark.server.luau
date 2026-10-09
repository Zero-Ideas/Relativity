-- Isolated baseline/current fixture benchmark. Both use identical conservative
-- occupancy stubs, real engine casts, no visuals, and the same world geometry.
-- Reports raw alternating samples and medians; does not assert noisy timings.
local fixture={}
for _,label in {"Old","New"} do
	local server=game.ServerScriptService["_ProjectileOptimization"..label.."Server"]
	local shared=game.ReplicatedStorage["_ProjectileOptimization"..label.."Shared"]
	local P=require(server.Projectile)
	require(server.Projectile.Parallel).Enabled=false
	fixture[label]={P=P,H=require(server.Projectile.BeamProjectileHandler),R=require(server.Projectile.Raycast),
		O=require(server.Projectile.Occupancy),C=require(shared.ChunkManager)}
end
local samples={}
local function measure(name,iterations,fn)
	local rows={Old={},New={}}
	for round=1,7 do
		for _,label in if round%2==0 then {"New","Old"} else {"Old","New"} do
			local f=fixture[label]
			for _=1,20 do fn(f) end
			local started=os.clock()
			for _=1,iterations do fn(f) end
			table.insert(rows[label],(os.clock()-started)*1e6/iterations)
		end
		task.wait()
	end
	local function median(values)
		local sorted=table.clone(values);table.sort(sorted);return sorted[4]
	end
	samples[name]={Unit="microseconds/call",Old=median(rows.Old),New=median(rows.New),Samples=rows}
end
local objects={}
local origin=Vector3.new(30016,20032,30016)
local wall=Instance.new("Part");wall.Anchored=true;wall.Size=Vector3.new(1,16,16)
wall.Position=origin+Vector3.xAxis*20;wall.Parent=workspace;table.insert(objects,wall)
local marker={}
local ok,problem=xpcall(function()
	for _,f in fixture do
		f.probe=f.P.new({Origin=origin,Speed=0,Radius=.35,Beam={},Lifetime=1000,Visualize=false})
		-- Real servers have entities elsewhere even when this cast is remote.
		f.chunk=f.C._addEntity(marker,origin+Vector3.zAxis*2048)
		f.O.Clear=true
	end
	measure("CastOccupancySkipped",10000,function(f) f.R.castMovement(f.probe,origin,Vector3.xAxis*30) end)
	for _,f in fixture do f.O.Clear=false end
	measure("CastEmptyChunkWall",5000,function(f) f.R.castMovement(f.probe,origin,Vector3.xAxis*30) end)
	measure("CastEmptyChunkMiss",5000,function(f) f.R.castMovement(f.probe,origin+Vector3.yAxis*40,Vector3.xAxis*30) end)
	measure("CastEmptyCrossChunkMiss",5000,function(f) f.R.castMovement(f.probe,origin+Vector3.yAxis*40,Vector3.xAxis*200) end)
	for _,f in fixture do f.C._removeEntity(marker,f.chunk);f.chunk=f.C._addEntity(marker,origin) end
	measure("CastOccupiedKnown",5000,function(f) f.R.castMovement(f.probe,origin,Vector3.xAxis*30,nil,true) end)
	measure("CastOccupiedBody",5000,function(f) f.R.castMovement(f.probe,origin,Vector3.xAxis*30) end)
	for _,f in fixture do f.C._removeEntity(marker,f.chunk);f.probe:Destroy(nil,"test-cleanup");f.O.Clear=true end
	for _,f in fixture do
		for channel=1,8 do
			for index=1,128 do
				f.H.Launch({Origin=Vector3.new(index*16,24000,channel*128),Speed=0,Lifetime=1000,
					Beam={ChannelId=990000000+channel},Radius=.35,Visualize=false})
			end
		end
	end
	measure("Beam1024OccupancySkipped",40,function(f) f.P._TestBeamStep(1/60) end)
	for _,f in fixture do f.O.Clear=false end
	measure("Beam1024EngineMiss",40,function(f) f.P._TestBeamStep(1/60) end)
end,debug.traceback)
for _,f in fixture do
	if f.chunk then f.C._removeEntity(marker,f.chunk) end
	for _,p in f.P.GetAll() do p:Destroy(nil,"test-cleanup") end
end
for _,v in objects do v:Destroy() end
local results=Instance.new("StringValue");results.Name="Results"
results.Value=game:GetService("HttpService"):JSONEncode(samples);results.Parent=script
script:SetAttribute("Complete",true);script:SetAttribute("Passed",ok)
script:SetAttribute("Problem",if ok then "" else tostring(problem))
print("[ProjectileOptimizationBenchmark]",ok,problem,results.Value)
