-- Temporary normal Studio Script, using the fresh independent-beamlet harness.
local P=require(game.ServerScriptService._BeamStretchServer.Projectile)
local Entity=require(game.ReplicatedStorage.Shared.Entity)
local viewer=game.Players:GetPlayers()[1]
local at=Vector3.new(500,5000,0)
local model=game.ReplicatedStorage.Dummy:Clone()
for _,v in model:GetDescendants() do
	if v:IsA("BaseScript") then v:Destroy() elseif v:IsA("BasePart") then v.Anchored=true end
end
model.Humanoid.MaxHealth=1000;model.Humanoid.Health=1000
model:PivotTo(CFrame.new(at));model.Parent=workspace
local target=Entity.new(model,{ScaleHumanoid=true,Health=1000,MaxHealth=1000})
local prototype=P.new({Origin=at+Vector3.xAxis*100,Speed=0,Lifetime=1,Beam={},Damage=37,MaxPierces=1,PierceFalloff=.15,Visualize=false})
local child=P.CreateBeamSample(prototype,at-Vector3.zAxis*15,Vector3.zAxis*200,{})
local hits=0
child.OnHit:Connect(function(hit)
	if hit.Entity==target then
		hits+=1
		target:TakeDamage(child.Damage*child.DamageMultiplier,{Hurtbox=hit.Hurtbox})
	end
end)
local ok,problem=xpcall(function()
	local deadline=os.clock()+.5
	repeat task.wait() until hits>0 or os.clock()>deadline
	assert(hits==1 and math.abs(target.Health-963)<.001,"child failed Entity damage pipeline")
	assert(child.PiercesLeft==0 and math.abs(child.DamageMultiplier-.85)<.001,"child lost pierce falloff")
	task.wait(.04)
	assert(hits==1,"child repeatedly hit the same pierced Entity")
end,debug.traceback)
script:SetAttribute("Damage",1000-target.Health)
script:SetAttribute("Hits",hits)
script:SetAttribute("Passed",ok)
script:SetAttribute("Problem",if ok then "" else tostring(problem))
script:SetAttribute("Complete",true)
child:Destroy(nil,"test-cleanup");prototype:Destroy(nil,"test-cleanup");target:Destroy();model:Destroy()
print("[BeamEntityChildren]",ok,problem)
