-- Source injection is handled by tools/test_projectile_maintenance.py.
-- Engine doubles test lifecycle/geometry logic, not Roblox scheduler throughput.
local checks = 0
local function check(condition, message)
	assert(condition, message)
	checks += 1
end
local now = 0
local os = setmetatable({ clock = function() return now end }, { __index = os })
local deps = {}
local require = function(name) assert(deps[name], name); return deps[name] end
local parent = setmetatable({}, { __index = function(_, key) return key end })
local script = { Parent = parent }

-- Intern vectors to reproduce Vector3's value equality when used as grid keys.
local Vector3, methods, vectors = {}, {}, {}
local mt = {}
function Vector3.new(x, y, z)
	local key = `{x}|{y}|{z}`
	if not vectors[key] then vectors[key] = setmetatable({ X=x, Y=y, Z=z }, mt) end
	return vectors[key]
end
mt.__index = function(v, key)
	if key == "Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end
	if key == "Unit" then return v / v.Magnitude end
	return methods[key]
end
mt.__add = function(a,b) return Vector3.new(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
mt.__sub = function(a,b) return Vector3.new(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
mt.__mul = function(a,b)
	if type(a)=="number" then a,b=b,a end
	return Vector3.new(a.X*b,a.Y*b,a.Z*b)
end
mt.__div = function(a,b) return Vector3.new(a.X/b,a.Y/b,a.Z/b) end
mt.__unm = function(a) return a * -1 end
function methods:Min(b) return Vector3.new(math.min(self.X,b.X),math.min(self.Y,b.Y),math.min(self.Z,b.Z)) end
function methods:Max(b) return Vector3.new(math.max(self.X,b.X),math.max(self.Y,b.Y),math.max(self.Z,b.Z)) end
function methods:Dot(b) return self.X*b.X+self.Y*b.Y+self.Z*b.Z end
function methods:Lerp(b,t) return self+(b-self)*t end
Vector3.zero,Vector3.one=Vector3.new(0,0,0),Vector3.new(1,1,1)
Vector3.xAxis,Vector3.yAxis,Vector3.zAxis=Vector3.new(1,0,0),Vector3.new(0,1,0),Vector3.new(0,0,1)
local typeof = function(v) return if getmetatable(v)==mt then "Vector3" else type(v) end
deps.SafeMath={Limit=1e9,direction=function(v,fallback) return if v.Magnitude>1e-8 then v.Unit else fallback end}
deps.Motion={MinStepDt=1e-6,PositionEpsilon=1e-4}
deps.StepPlanner={}
deps.Types={}

local function signal()
	local callbacks={}
	return { Connect=function(_,fn) table.insert(callbacks,fn);return {Disconnect=function() end} end,
		Fire=function(_,...) for _,fn in callbacks do fn(...) end end }
end
local players={PlayerRemoving=signal(),GetPlayers=function() return {} end}
local remote={Name="VisualOffloadRemote",OnServerEvent=signal(),FireClient=function() end,FireAllClients=function() end,
	IsA=function(_,name) return name=="RemoteEvent" end}
local shared={WaitForChild=function(self,name) return if name=="Projectile" then self else name end}
local replicated={WaitForChild=function() return shared end,FindFirstChild=function() return remote end}
local services={Players=players,ReplicatedStorage=replicated,RunService={IsServer=function() return true end}}
local game={GetService=function(_,name) return services[name] end}
local workspace={Raycast=function() return nil end}
local tasks=0
local task={spawn=function(fn,...) tasks+=1;fn(...) end}

-- LOAD FilterRegistry
do
	local messages={}
	local registry=FilterRegistry.new(function(...) table.insert(messages,{...}) end)
	local a,b={},{}
	local function params(list,water) return {FilterDescendantsInstances=list,IgnoreWater=water,CollisionGroup="Default"} end
	local p,q=params({a}),params({a,b})
	check(registry:Get(p,0)==nil,"filter became usable before delivery")
	local first=registry:Get(p,1)
	check(first==1 and registry:Get(params({a}),1)==first,"equal filters did not share ID")
	registry:Get(q,1)
	local second=registry:Get(q,2)
	registry:Retain(second)
	now=61;registry:Collect(now)
	check(not registry:Ready(first,100) and registry:Ready(second,100),"retirement removed live filter")
	check(registry.Trie[a][b]~=nil,"pruning removed shared prefix")
	check(messages[#messages][1]=="RetireFilters","worker retirement not sent")
	check(registry:Get(p,100)==nil,"stale weak-cache ID was reused")
	local replacement=registry:Get(p,101)
	check(replacement>second,"retired ID aliased replacement")
	registry:Release(second)
	now=122;registry:Collect(now)
	check(next(registry.Trie)==nil,"unused Instance trie branches retained")
	registry:Get(p,200);registry:Reset()
	check(messages[#messages][1]=="ResetFilters" and next(registry.Records)==nil,"surviving workers not reset")
	check(registry:Get(p,201)==nil and registry:Get(p,202)>replacement,"reset reused stale ID")
	local churn=FilterRegistry.new(function() end)
	for _=1,200 do churn:Get(params({{}}),0) end
	now+=61;churn:Collect(now)
	check(#churn.Ids==136,"filter maintenance exceeded its frame budget")
	churn:Collect(now);churn:Collect(now);churn:Collect(now)
	check(#churn.Ids==0 and next(churn.Trie)==nil,"bounded collection failed to drain")
end

local all,enumerations,narrow={},0,0
deps.Entity={PositionVersion=0,GetAll=function() enumerations+=1;return table.clone(all) end,Get=function() return nil end}
local Entity=deps.Entity
-- LOAD Math
-- LOAD RewindHit
do
	local function target(position,history,radius)
		local entity={Position=position,_history=history or {},BodyOffset=Vector3.zero,HitboxRadius=radius or 2,
			HeadOffset=Vector3.zero,HeadRadius=1,_headOffset=nil,Rewound=history and history[1].Position or position}
		function entity:GetPosition() return self.Position end
		function entity:IsActive() return true end
		function entity:GetBodyPositionAt() narrow+=1;return self.Rewound+self.BodyOffset end
		function entity:GetHeadPositionAt() return self._headOffset and self.Rewound+self._headOffset+self.HeadOffset end
		return entity
	end
	local p={Radius=0,Source=nil,Filter=nil,_ignore={},_rewindCache={},_rewindTime=0,_rayParams={}}
	local function hit(a,b)
		p._rewindCache={}
		return RewindHit.check(p,a,b)
	end
	local border=target(Vector3.new(65,0,16))
	local distant=target(Vector3.new(3000,0,3000))
	all={border,distant};RewindHit.BeginFrame()
	check(hit(Vector3.new(63,0,0),Vector3.new(63,0,32))==border,"neighbor sphere missed at chunk border")
	local before=enumerations;local tested=narrow
	check(hit(Vector3.new(63,0,0),Vector3.new(63,0,32))==border,"repeat border hit changed")
	check(enumerations==before and narrow-tested==1,"broadphase rebuilt per shot or tested distant entity")
	local crossing=target(Vector3.new(512,0,16),{{Position=Vector3.new(63,0,16)}})
	all={crossing};RewindHit.BeginFrame()
	check(hit(Vector3.new(63,0,0),Vector3.new(63,0,32))==crossing,"historical chunk missed")
	crossing.Rewound=Vector3.new(287.5,0,16)
	check(hit(Vector3.new(287.5,0,0),Vector3.new(287.5,0,32))==crossing,"interpolated historical path missed")
	local negative=target(Vector3.new(-65,-65,-16))
	all={negative};RewindHit.BeginFrame()
	check(hit(Vector3.new(-63,-65,0),Vector3.new(-63,-65,-32))==negative,"negative-coordinate border missed")
	local middle=target(Vector3.new(128,0,0))
	all={middle};RewindHit.BeginFrame()
	check(hit(Vector3.zero,Vector3.new(256,0,0))==middle,"intermediate chunk omitted")
	p.Radius=2;all={border};RewindHit.BeginFrame()
	check(hit(Vector3.new(61,0,0),Vector3.new(61,0,32))==border,"projectile radius omitted")
	p.Radius=0
	local head=target(Vector3.new(400,0,400));head._headOffset=Vector3.new(-337,10,-384)
	all={head};RewindHit.BeginFrame()
	local found,_,_,hurtbox=hit(Vector3.new(63,10,0),Vector3.new(63,10,32))
	check(found==head and hurtbox=="Head","head offset omitted from broadphase")
	local huge=target(Vector3.new(100000,0,0),{{Position=Vector3.new(63,0,16)}})
	all={huge};RewindHit.BeginFrame()
	check(hit(Vector3.new(63,0,0),Vector3.new(63,0,32))==huge,"large teleport fallback lost entity")
	all={middle};Entity.PositionVersion+=1
	check(hit(Vector3.zero,Vector3.new(100000,0,0))==middle,"large query fallback lost entity")
	all={border};Entity.PositionVersion+=1
	check(hit(Vector3.new(63,0,0),Vector3.new(63,0,32))==border,"entity insertion did not invalidate index")
	p._ignore[border]=true
	check(hit(Vector3.new(63,0,0),Vector3.new(63,0,32))==nil,"ignore list bypassed")
	p._ignore={};p.Filter=function() return false end
	check(hit(Vector3.new(63,0,0),Vector3.new(63,0,32))==nil,"entity filter bypassed")
	p.Filter=nil
	workspace.Raycast=function() return {Instance={},Position=Vector3.new(63,0,1)} end
	check(hit(Vector3.new(63,0,0),Vector3.new(63,0,32))==nil,"line of sight bypassed")
	workspace.Raycast=function() return nil end
end

-- LOAD Quota
do
	Quota.Maximum,Quota.GlobalMaximum=3,5
	local a,b={Parent=players},{Parent=players}
	check(Quota.TryAcquire(a,3) and Quota.TryAcquire(b,2),"normal quota admission failed")
	check(not Quota.TryAcquire(b,1) and Quota.GetTotal()==5,"global budget not enforced")
	check(not Quota.TryAcquire(a,1),"player budget not enforced")
	a.Parent=nil;players.PlayerRemoving:Fire(a)
	check(Quota.GetTotal()==5 and not Quota.TryAcquire(a,1),"departing player bypassed global budget")
	Quota.Release(a,100);Quota.Release(a,100)
	check(Quota.GetTotal()==2,"over-release or disconnect double-decremented total")
	check(not Quota.TryAcquire(b,0/0) and not Quota.TryAcquire(b,math.huge),"invalid quota count accepted")
	Quota.Release(b,math.huge);check(Quota.GetTotal()==2,"invalid release changed total")
	Quota.Release(b,2);check(Quota.GetTotal()==0,"quota did not drain")
end

-- LOAD VisualOffload
do
	local count=0;local player={}
	VisualOffload.On("Test",function(payload,who) check(who==player and payload==42,"dispatch signature changed");count+=1 end)
	for _=1,300 do remote.OnServerEvent:Fire(player,"Test",42) end
	check(count==240,"ingress burst not bounded")
	local before=tasks
	remote.OnServerEvent:Fire(player,"Unknown",42)
	remote.OnServerEvent:Fire(player,{},42)
	check(tasks==before,"invalid channel spawned tasks")
	now+=1;remote.OnServerEvent:Fire(player,"Test",42)
	check(count==241,"ingress bucket did not refill")
	players.PlayerRemoving:Fire(player)
	remote.OnServerEvent:Fire(player,"Test",42)
	check(count==242,"ingress state not cleaned up")
end

-- LOAD Store
-- LOAD Sweep
-- LOAD ApplyPass
local emitted,sweeps,sets,resets=0,0,0,0
local resultSignal=signal()
local actors={}
for index=1,2 do
	local actor={Name=`ProjectileWorker{index}`,records=buffer.create(10000),scales=buffer.create(10000),timers=buffer.create(10000)}
	function actor:IsA(name) return name=="Actor" end
	function actor:SendMessage(channel,...)
		if channel~="Sweep" then return end
		local frame,ops,count,dt=...
		sweeps+=1
		local offset=0
		while ops and offset<buffer.len(ops) do
			local op=buffer.readu8(ops,offset)
			if op==Sweep.OpReset then resets+=1;offset+=1
			elseif op==Sweep.OpSet then
				sets+=1;local i=buffer.readu32(ops,offset+1)-1
				buffer.copy(self.records,i*48,ops,offset+5,48)
				buffer.copy(self.scales,i*8,ops,offset+Sweep.SetOpScale,8)
				offset+=Sweep.SetOpBytes
			else
				local to=buffer.readu32(ops,offset+1)-1;local from=buffer.readu32(ops,offset+5)-1
				buffer.copy(self.records,to*48,self.records,from*48,48)
				buffer.copy(self.scales,to*8,self.scales,from*8,8);offset+=9
			end
		end
		ApplyPass.Prepare(self.records,self.scales,self.timers,count,dt,nil)
		local output=buffer.create(count*44)
		for i=0,count-1 do
			buffer.copy(output,i*44+4,self.records,i*48+8,24)
			buffer.writef64(output,i*44+28,buffer.readf64(self.records,i*48+32)+dt)
		end
		ApplyPass.Commit(self.records,self.timers,output,count,nil,nil,{},{})
		resultSignal:Fire(index,frame,count,0,output,0,0,nil,nil,nil,{},nil,nil)
	end
	actors[index]=actor
end
local root={ChildAdded=signal(),ChildRemoved=signal(),GetChildren=function() return actors end,
	FindFirstChild=function(_,name) return if name=="Results" then {Event=resultSignal} else nil end}
services.ServerScriptService={FindFirstChild=function() return root end}
deps.ChunkManager={ChunkSize=64,UseY=false,GetTimeVersion=function() return 0 end,GetAllChunks=function() return {} end,
	GetTimeScaleZones=function() return {} end,GetEntityChunkMask=function() return {} end,IsTimeUniform=function() return true end}
deps.Homing={};deps.Replication={};deps.Profile={Add=function() end,Count=function() end}
-- LOAD Parallel
do
	local shots={}
	local settings={Acceleration=0,Gravity=0,MinSpeed=0,MaxSpeed=math.huge,Radius=1,Lifetime=1000,MaxRealLifetime=1000,
		_rayParams={FilterDescendantsInstances={},IgnoreWater=true,CollisionGroup="Default"}}
	local meta=Store.HandleMetatable(settings,{}, {})
	for i=1,40 do shots[i]=Store.AdoptFast({},meta,Vector3.zero,Vector3.xAxis,1,i,now,1,false,nil) end
	Parallel.SetEligibility(function() return 1 end)
	local mark=0
	local function frame(count,dt,allowed)
		Parallel.Dispatch(count,dt,allowed~=false)
		mark+=1
		if not Parallel.IsPaused() then Parallel.Apply(function() return 1 end,mark,now,0) end
	end
	frame(40,0.1)
	for _,shot in shots do Parallel.Offer(shot) end
	frame(40,0.1) -- register specs and filters
	for _,shot in shots do Parallel.Offer(shot) end
	frame(40,0.1) -- acquire resident slots
	check(buffer.readu8(Store.Resident,shots[1]._slot)>0,"fixture failed to acquire residents")
	local age,packed,resetCount,sweepCount=shots[1].Age,sets,resets,sweeps
	frame(40,0)
	check(Parallel.IsPaused() and shots[1].Age==age and sweeps==sweepCount,"freeze moved resident records")
	check(buffer.readu8(Store.Resident,shots[1]._slot)>0,"freeze released resident slots")
	Store.Release(shots[2]) -- death during freeze must update both aligned arrays
	frame(39,0.1)
	check(sets==packed and resets==resetCount,"unfreeze repacked the population")
	check(math.abs(shots[1].Age-age-0.1)<1e-8,"unfreeze lost or doubled frame budget")
	local newborn=Store.AdoptFast({},meta,Vector3.zero,Vector3.xAxis,1,100,now,1,false,nil)
	check(Parallel.PackNew(newborn,Vector3.zero,Vector3.xAxis,1,settings._rayParams,now+1000),"direct newborn packing failed")
	frame(40,0.1)
	Store.Release(newborn)
	frame(31,0.1)
	check(buffer.readu8(Store.Resident,shots[1]._slot)>0,"threshold jitter released residents")
	frame(15,0.1)
	check(buffer.readu8(Store.Resident,shots[1]._slot)==0,"exit threshold failed to release residents")
	for _,shot in shots do if shot._slot then Parallel.Offer(shot) end end
	frame(40,0.1)
	frame(40,0.1,false)
	check(buffer.readu8(Store.Resident,shots[1]._slot)==0,"debug serial mode retained stale residents")
	for _,shot in shots do Store.Release(shot) end
	check(Store.Count()==0,"fixture leaked slots")
end
print(`Projectile maintenance regressions passed: {checks} checks`)
