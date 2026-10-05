-- Studio-only regression: a steady sustain must pass the former 150 ceiling.
local server=game.ServerScriptService._BeamStretchServer
local P=require(server.Projectile)
local H=require(server.BeamProjectileHandler)
local Runtime=require(server.SpellRuntime)
local Q=require(server.ProjectileQuota)
local Entity=require(game.ReplicatedStorage.Shared.Entity)
local character=game.ReplicatedStorage.Dummy:Clone()
for _,v in character:GetDescendants() do
	if v:IsA("BaseScript") then v:Destroy() elseif v:IsA("BasePart") then v.Anchored=true end
end
character:PivotTo(CFrame.new(0,7000,0));character.Parent=workspace
local tool=Instance.new("Tool");tool.Name="SpellAssembler";tool.RequiresHandle=false;tool.Parent=character
local user={UserId=-42424111,Parent=game.Players,Character=character}
local caster=Entity.new(character,{ScaleHumanoid=true})
local at=Vector3.new(0,7005,0)
local compiled={manaRoots={"mana"},
	runes={mana={rune="Mana",params={Amount=30}},fire={rune="Fire",params={}},
		beam={rune="Beam",params={}},sustain={rune="Sustain",params={Level=5}}},
	inputs={mana={},fire={},beam={},sustain={}},
	outputs={mana={out={{to="fire"}}},fire={out={{to="beam"}}},beam={},sustain={}},
	vessels={beam={mods={"sustain"},triggers={},count=1,modCost=0,triggerShare=0}}}
local ok,problem=xpcall(function()
	Runtime.Cast(compiled,{player=user,character=character,caster=caster,origin=at,cursorPoint=at-Vector3.zAxis*300})
	local untilTime=os.clock()+2
	repeat task.wait(.03);H.KeepAlive(user) until os.clock()>untilTime
	H.Stop(user)
	local roots,count,heads,children,totalDamage=0,0,0,0,0
	for _,p in P.GetBySource(caster) do if not p.Dead then
		count+=1;totalDamage+=p.Damage
		if p._beamJoiner then children+=1 else heads+=1 end
		if not p._beamPrevious then roots+=1 end
		if p._beamPrevious then
			assert(not p._beamPrevious.Dead,"steady link points to a dead beamlet")
			assert(p._beamSpan and (#p._beamSpan>=2 or (p.Position-p._beamPrevious.Position).Magnitude<.01),
				"steady link lost its body")
			assert((p._beamSpan[#p._beamSpan]-p._beamPrevious.Position).Magnitude<.01,"authoritative endpoint gap")
		end
	end end
	assert(count>150,"test did not cross the old quota ceiling")
	assert(roots==1,"steady firing split into "..roots.." disconnected chains")
	assert(Q.Get(user)==count,"shared quota did not count real children")
	script:SetAttribute("Active",count);script:SetAttribute("Heads",heads);script:SetAttribute("Children",children)
	script:SetAttribute("Roots",roots);script:SetAttribute("Damage",totalDamage)
end,debug.traceback)
H.Stop(user)
for _,p in P.GetBySource(caster) do p:Destroy(nil,"test-cleanup") end
task.wait(.04)
assert(Q.Get(user)==0,"steady sustain leaked quota")
caster:Destroy();character:Destroy()
script:SetAttribute("Passed",ok);script:SetAttribute("Problem",if ok then "" else tostring(problem));script:SetAttribute("Complete",true)
print("[SteadyBeamQuota]",ok,problem,script:GetAttribute("Active"),"projectiles; chains",script:GetAttribute("Roots"))
