-- Studio-only, fresh gameplay VM modules; not shipped by Rojo.
local shared = game.ReplicatedStorage._BeamStretchShared
local server = game.ServerScriptService._BeamStretchServer
local P = require(server.Projectile)
local H = require(server.Projectile.BeamProjectileHandler)
local Chunks = require(shared.ChunkManager)
local Path = require(shared.Projectile.BeamPath)
local Runtime = require(server.SpellRuntime)
local Quota = require(server.ProjectileQuota)
local Entity = require(shared.Entity)
local Transport = require(shared.VisualOffload)
local viewer = game.Players:GetPlayers()[1]
local origin = viewer.Character:GetPivot().Position + Vector3.yAxis*450
local objects, projectiles = {}, {}
local zone = "_IndependentBeamletFreeze"
local player, caster
local function children(channel)
	local result = {}
	for _, p in P.GetAll() do
		if p.Beam and p.Beam.ChannelId == channel and p._beamJoiner then table.insert(result,p) end
	end
	return result
end
local function clear()
	for _, p in P.GetAll() do p:Destroy(nil,"test-cleanup") end
end
local ok, problem = xpcall(function()
	local channel = 980000001
	local front = H.Launch({Origin=origin,Direction=Vector3.yAxis,Speed=60,Lifetime=5,Beam={ChannelId=channel},Visualize=false})
	local back = H.Launch({Origin=origin+Vector3.xAxis*Path.MaxStretch*4,Direction=Vector3.yAxis,Speed=60,Lifetime=5,Beam={ChannelId=channel},Visualize=false,Damage=80})
	local deadline=os.clock()+.3
	repeat task.wait() until #children(channel)>=3 or os.clock()>deadline
	local initial = children(channel)
	script:SetAttribute("RawChildren",#initial)
	assert(#initial >= 3,"gap did not produce real beamlets")
	assert(#P.GetAll() == #initial+2,"children weren't registered in authoritative simulation")
	local total = back.Damage
	local ids = {[back.Id]=true,[front.Id]=true}
	for _, p in initial do
		assert(not ids[p.Id],"sub-beam reused its parent's ID");ids[p.Id]=true
		total += p.Damage
	end
	assert(math.abs(total-80)<.001,"subdivision multiplied damage")
	local frozen = initial[2].Position
	Chunks.AddTimeScaleZone(zone,frozen,8,0)
	front.Velocity,back.Velocity=Vector3.zero,Vector3.zero
	task.wait(.4)
	local refined = children(channel)
	assert(#refined > #initial,"existing child links were not re-subdivided")
	local held,moving=false,false
	for _,p in refined do
		if (p.Position-frozen).Magnitude < .01 then held=true end
		if p.Position.Y > frozen.Y+2 then moving=true end
		if p._beamPrevious and not p._beamPrevious.Dead then
			local path=assert(Path.Connect(p.Position,p._beamPrevious.Position,p._beamTurns,p._beamPrevious._beamTurns))
			for i=2,#path do assert((path[i]-path[i-1]).Magnitude<=Path.MaxStretch+.01,"child gap exceeded cap") end
		end
	end
	assert(held and moving,"children did not obey independent chunk clocks")
	-- Losing one child must NOT delete its siblings.
	local removed = refined[1]
	removed:Destroy(nil,"test-cleanup")
	task.wait(.03)
	local survivors=0
	for _,p in refined do if not p.Dead then survivors+=1 end end
	assert(survivors>=#refined-1,"one child death deleted its siblings")
	script:SetAttribute("InitialChildren",#initial)
	script:SetAttribute("RefinedChildren",#refined)
	Chunks.RemoveTimeScaleZone(zone)
	clear();task.wait(.03)

	-- Real SpellRuntime OnImpact -> Explosion on independently hitting children.
	local character = game.ReplicatedStorage.Dummy:Clone()
	table.insert(objects,character)
	for _,v in character:GetDescendants() do
		if v:IsA("BaseScript") then v:Destroy()
		elseif v:IsA("BasePart") then v.Anchored=true end
	end
	character:PivotTo(CFrame.new(origin+Vector3.yAxis*100))
	character.Parent=workspace
	local tool=Instance.new("Tool");tool.Name="SpellAssembler";tool.RequiresHandle=false;tool.Parent=character
	player={UserId=-42424999,Parent=game.Players,Character=character}
	caster=Entity.new(character,{ScaleHumanoid=true})
	local at=origin+Vector3.yAxis*105
	local compiled={
		manaRoots={"mana"},
		runes={mana={rune="Mana",params={Amount=30}},fire={rune="Fire",params={}},
			beam={rune="Beam",params={}},sustain={rune="Sustain",params={Seconds=1}},
			impact={rune="OnImpact",params={Share=50}},blast={rune="Explosion",params={Radius=4,Edge=0}}},
		inputs={mana={},fire={},beam={},sustain={},impact={},blast={}},
		outputs={mana={out={{to="fire"}}},fire={out={{to="beam"}}},beam={},
			sustain={},impact={out={{to="blast"}}},blast={}},
		vessels={beam={mods={"sustain"},triggers={"impact"},count=1,modCost=0,triggerShare=.5},
			blast={mods={},triggers={},count=1,modCost=0,triggerShare=0}},
	}
	Runtime.Cast(compiled,{player=player,character=character,caster=caster,origin=at,cursorPoint=at-Vector3.zAxis*300})
	local first=assert(P.GetBySource(caster)[1])
	first.Position=at+Vector3.xAxis*120
	first.Velocity=Vector3.zero
	local deadline=os.clock()+.25
	repeat task.wait() until #children(first.Beam.ChannelId)>=3 or os.clock()>deadline
	script:SetAttribute("SustainingBeforeStop",H.IsActive(player))
	script:SetAttribute("LiveSpellCount",#P.GetBySource(caster))
	script:SetAttribute("QuotaBeforeStop",Quota.Get(player))
	script:SetAttribute("CasterHealth",caster.Health)
	script:SetAttribute("CasterHumanoid",character.Humanoid.Health)
	script:SetAttribute("FirstDead",first.Dead)
	script:SetAttribute("BudgetSplits",H.GetJoinerStats().BudgetSplits)
	H.Stop(player)
	local liveChildren=children(first.Beam.ChannelId)
	assert(#liveChildren>=3,"spell didn't produce independent beamlets")
	local activeCount=0
	for _,p in P.GetBySource(caster) do if not p.Dead then activeCount+=1 end end
	script:SetAttribute("QuotaCount",Quota.Get(player));script:SetAttribute("LiveCount",activeCount)
	assert(Quota.Get(player)==activeCount,"children bypassed projectile quota: "..Quota.Get(player).." vs "..activeCount)
	local wall=Instance.new("Part");wall.Anchored=true;wall.Size=Vector3.new(400,2,400)
	wall.Position=at-Vector3.yAxis*8;wall.Parent=workspace;table.insert(objects,wall)
	for _,p in P.GetBySource(caster) do p.Velocity=if p._beamJoiner then -Vector3.yAxis*100 else Vector3.zero end
	local before=#Transport.Events
	task.wait(.2)
	local explosions=0
	for i=before+1,#Transport.Events do if Transport.Events[i].Key=="SpellExplosion" then explosions+=1 end end
	assert(explosions>=2,"children collided without independently firing spell explosions")
	local dead=0
	for _,p in liveChildren do if p.Dead then dead+=1 end end
	assert(dead>=2,"real sub-beams didn't hit the wall")
	script:SetAttribute("IndependentExplosions",explosions)
	clear();task.wait(.04)
	assert(Quota.Get(player)==0,"child destruction leaked quota")
	assert(H.GetJoinerStats().Active==0,"child cleanup leaked simulation state")
end,debug.traceback)
Chunks.RemoveTimeScaleZone(zone)
clear()
if player then H.Stop(player) end
if caster then caster:Destroy() end
for _,v in objects do v:Destroy() end
script:SetAttribute("Complete",true)
script:SetAttribute("Passed",ok)
script:SetAttribute("Problem",if ok then "" else tostring(problem))
print("[IndependentBeamlets]",ok,problem,"children",script:GetAttribute("InitialChildren"),"->",script:GetAttribute("RefinedChildren"),"independent explosions",script:GetAttribute("IndependentExplosions"))
