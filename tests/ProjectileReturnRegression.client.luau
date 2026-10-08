-- Private-network Studio harness: exercises the real updated renderer.
local shared=game.ReplicatedStorage._ProjectileRegressionShared
local transport=require(shared.VisualOffload)
local protocol=require(shared.Projectile.Protocol)
local view=require(shared.Projectile.Client.View)
-- Test flight stays high above the map; avoid moving the user's camera.
view.contains=function() return true end
local renderer=require(shared.Projectile.Client)
renderer.EnableClientRendering()
local spawns,exits=0,0
local connections={}
table.insert(connections,transport.On(protocol.Channels.SpawnBatch,function(batch)
	for _,d in batch do
		spawns+=1
		script:SetAttribute("Spawns",spawns)
		script:SetAttribute("Velocity",d.Velocity)
	end
end))
table.insert(connections,transport.On(protocol.Channels.RangeExit,function(ids)
	exits+=#ids
	script:SetAttribute("Exits",exits)
end))
table.insert(connections,game:GetService("RunService").Heartbeat:Connect(function()
	local count=renderer.GetStats().Visuals
	script:SetAttribute("Visuals",count)
	script:SetAttribute("PeakVisuals",math.max(script:GetAttribute("PeakVisuals") or 0,count))
	if spawns>=2 and exits>=1 and count>0 then script:SetAttribute("ReturnVisible",true) end
end))
script.Destroying:Connect(function() for _,c in connections do c:Disconnect() end end)
script:SetAttribute("Ready",true)
