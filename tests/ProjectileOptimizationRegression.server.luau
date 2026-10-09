-- Run in an isolated gameplay-VM fixture named _ProjectileOptimizationNew*.
-- Fixture transport records events; occupancy is forced to cast (conservative).
local server = game.ServerScriptService._ProjectileOptimizationNewServer
local shared = game.ReplicatedStorage._ProjectileOptimizationNewShared
local P = require(server.Projectile)
require(server.Projectile.Parallel).Enabled = false
local Ray = require(server.Projectile.Raycast)
local LOD = require(server.Projectile.CollisionLOD)
local Store = require(server.Projectile.Store)
local Chunks = require(shared.ChunkManager)
local Entity = require(shared.Entity)
local occupancy = require(server.Projectile.Occupancy)
occupancy.Clear = false
local objects, entities, shots = {}, {}, {}
local checks = 0
local function check(value, message)
	assert(value, message); checks += 1
end
local function part(position, size)
	local p = Instance.new("Part")
	p.Anchored, p.CanCollide, p.Size, p.Position = true, true, size, position
	p.Parent = workspace; table.insert(objects,p); return p
end
local function shot(position, extra)
	local config = {Origin=position, Speed=0, Radius=1, Beam={}, Visualize=false, Lifetime=60}
	for k,v in extra or {} do config[k]=v end
	local p=P.new(config); table.insert(shots,p); return p
end
local ok, problem = xpcall(function()
	local origin = Vector3.new(20000+32, 16000+32, 20000+32)
	-- Pure policy: test interior chunks, occupied boundaries (including radius
	-- grazing a neighbor), negative coordinates, 3D, and bounded lookup work.
	local mask = {[Vector3.new(0,0,0)]=true}
	check(LOD.Radius(mask,64,false,Vector3.new(32,0,32),Vector3.xAxis*8,1)==1,"occupied interior downgraded")
	check(LOD.Radius(mask,64,false,Vector3.new(96,0,96),Vector3.xAxis*8,1)==0,"empty interior not a ray")
	check(LOD.Radius(mask,64,false,Vector3.new(96,0,32),-Vector3.xAxis*80,1)==1,"crossing occupied chunk downgraded")
	check(LOD.Radius(mask,64,false,Vector3.new(80,0,64.5),-Vector3.xAxis*20,1)==1,"radius grazing occupied neighbor downgraded")
	check(LOD.Radius(mask,64,false,Vector3.new(-32,0,-32),-Vector3.xAxis*8,1)==0,"negative empty chunk")
	check(LOD.Radius(mask,64,true,Vector3.new(32,96,32),Vector3.xAxis*8,1)==0,"3D empty layer")
	check(LOD.Radius(mask,64,true,Vector3.new(32,96,32),-Vector3.yAxis*80,1)==1,"3D occupied crossing")
	check(LOD.Radius(mask,64,false,Vector3.new(96,0,96),Vector3.new(1024,0,1024),1)==1,"lookup budget exceeded")
	-- Live membership is stable by identity and updates only at transitions.
	local live=Chunks.GetEntityChunkMask()
	local a,b={},{}
	local chunk=Chunks._addEntity(a,origin)
	Chunks._addEntity(b,origin)
	check(live[chunk.Key] and live==Chunks.GetEntityChunkMask(),"missing live mask")
	Chunks._removeEntity(a,chunk)
	check(live[chunk.Key],"removed occupied chunk too early")
	Chunks._removeEntity(b,chunk)
	check(not live[chunk.Key],"last entity left stale occupancy")
	-- Engine behavior: a grazing wall misses the centerline but hits the sphere.
	local wall=part(origin+Vector3.new(12,1.25,0),Vector3.new(1,1,4))
	local p=shot(origin)
	check(Ray.castMovement(p,origin,Vector3.xAxis*24)==nil,"empty chunk used a sphere")
	local marker={};local occupied=Chunks._addEntity(marker,origin)
	check(Ray.castMovement(p,origin,Vector3.xAxis*24)~=nil,"occupied chunk lost radius")
	check(Ray.castMovement(p,origin,Vector3.xAxis*24,nil,true)~=nil,"known occupied fast path")
	Chunks._removeEntity(marker,occupied)
	check(Ray.castMovement(p,origin,Vector3.xAxis*24)==nil,"entity removal did not switch back")
	wall:Destroy()
	-- Body piercing must preserve motion without dirtying the worker slot.
	local body=part(origin+Vector3.xAxis*12,Vector3.new(2,6,6))
	local target=Entity.new(body,{Health=1000,MaxHealth=1000})
	table.insert(entities,target)
	local piercing=shot(origin,{Speed=100,Direction=Vector3.zAxis,MaxPierces=1})
	local hits=0
	piercing.OnHit:Connect(function(hit) if hit.Entity==target then hits+=1 end end)
	Store.ClearDirty(piercing._slot)
	local position,velocity=piercing.Position,piercing.Velocity
	local path={origin,origin+Vector3.xAxis*24}
	local result=piercing:ResolveBeamSpan(path,true)
	check(hits==1 and not piercing.Dead and piercing.PiercesLeft==0,"body piercing changed")
	check(piercing.Position==position and piercing.Velocity==velocity,"body hit moved the tip")
	check(not bit32.btest(buffer.readu8(Store.Flags,piercing._slot),Store.Dirty),"body hit dirtied movement")
	check(result==path,"unclipped span allocated another path")
	piercing:ResolveBeamSpan(path,true)
	check(hits==1,"pierced body hit twice")
	check(piercing._spanParams~=nil,"pierced filter not rebuilt")
	-- Genuine callback edits must remain visible and must still invalidate workers.
	local changed=shot(origin,{Speed=100,Direction=Vector3.zAxis,MaxPierces=1})
	changed.OnHit:Connect(function() changed.Velocity=Vector3.yAxis*123 end)
	Store.ClearDirty(changed._slot)
	changed:ResolveBeamSpan(path,true)
	check(changed.Velocity==Vector3.yAxis*123,"callback motion was overwritten")
	check(bit32.btest(buffer.readu8(Store.Flags,changed._slot),Store.Dirty),"callback mutation failed to invalidate worker")
	-- Clipped snapshots own their arrays; later caller/geometry changes cannot
	-- mutate a queued impact or replication snapshot.
	target:Destroy(); body:Destroy()
	local blocker=part(origin+Vector3.xAxis*12,Vector3.new(1,8,8))
	local cut=p:ResolveBeamSpan(path,false)
	check(cut~=path and #cut==2 and cut[2].X<path[2].X,"world clip lost independent snapshot")
	check(p._beamSpanClipped==true and not p.Dead,"clipping killed a launched packet")
	local empty={origin}
	check(p:ResolveBeamSpan(empty)==empty,"point-only span slow path")
	blocker:Destroy()
end,debug.traceback)
for _,p in shots do p:Destroy(nil,"test-cleanup") end
for _,e in entities do if not e.IsDestroyed then e:Destroy() end end
for _,v in objects do v:Destroy() end
script:SetAttribute("Checks",checks)
script:SetAttribute("Passed",ok)
script:SetAttribute("Problem",if ok then "" else tostring(problem))
script:SetAttribute("Complete",true)
print("[ProjectileOptimizationRegression]",ok,checks,problem)
