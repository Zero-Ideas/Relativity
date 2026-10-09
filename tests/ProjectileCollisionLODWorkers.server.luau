-- Run after the isolated fixture's serial regressions. Exercises real Actor
-- dispatch/results with a grazing wall that only the full-radius sweep hits.
local root=game.ServerScriptService._ProjectileOptimizationNewServer
local shared=game.ReplicatedStorage._ProjectileOptimizationNewShared
local P=require(root.Projectile)
local Parallel=require(root.Projectile.Parallel)
local Chunks=require(shared.ChunkManager)
local oldActors=root:FindFirstChild("ProjectileActors")
if oldActors then
	for _,child in oldActors:GetChildren() do if child:IsA("Actor") then child:Destroy() end end
end
local bootstrap=root.ProjectileWorkerBootstrap:Clone()
bootstrap.Name="OptimizationWorkers";bootstrap.Disabled=false;bootstrap.Parent=root
Parallel.Enabled=true
local origin=Vector3.new(40016,26016,40016)
local wall=Instance.new("Part");wall.Anchored=true;wall.Size=Vector3.new(1,1,4)
wall.Position=origin+Vector3.new(120,1.25,0);wall.Parent=workspace
local marker,chunk={},nil
local rows={}
local function trial(occupied)
	if occupied then chunk=Chunks._addEntity(marker,origin) end
	-- Mark each traversed X chunk, just as a scene with nearby targets would.
	local second
	if occupied then second=Chunks._addEntity({},origin+Vector3.xAxis*120) end
	Parallel.TakeStats()
	local shots={}
	for _=1,64 do table.insert(shots,P.new({Origin=origin,Direction=Vector3.xAxis,Speed=600,
		Radius=1,Lifetime=3,Visualize=false})) end
	task.wait(.4)
	local alive=0;for _,p in shots do if not p.Dead then alive+=1 end end
	local stats=Parallel.TakeStats()
	rows[if occupied then "Occupied" else "Empty"]={Alive=alive,Parallel=stats}
	assert(stats.Parallel>0,"test never used Actor results")
	assert(alive==(if occupied then 0 else 64),"worker chose the wrong cast shape")
	for _,p in shots do p:Destroy(nil,"test-cleanup") end
	if chunk then Chunks._removeEntity(marker,chunk);chunk=nil end
	if second then for e in second.Entities do Chunks._removeEntity(e,second) end end
	task.wait(.1)
end
local ok,problem=xpcall(function()
	task.wait(.5)
	trial(false);trial(true);trial(false)
end,debug.traceback)
if chunk then Chunks._removeEntity(marker,chunk) end
for _,p in P.GetAll() do p:Destroy(nil,"test-cleanup") end
wall:Destroy();Parallel.Enabled=false
local out=Instance.new("StringValue");out.Name="Results";out.Value=game:GetService("HttpService"):JSONEncode(rows);out.Parent=script
script:SetAttribute("Complete",true);script:SetAttribute("Passed",ok);script:SetAttribute("Problem",if ok then "" else tostring(problem))
print("[ProjectileCollisionLODWorkers]",ok,problem)
