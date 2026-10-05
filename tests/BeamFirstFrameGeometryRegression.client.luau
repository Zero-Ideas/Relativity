-- Studio-only replay of the server's actual FIRST-frame wire snapshots.
local module=game.ReplicatedStorage.Shared._BeamFirstFrameClient
local Beam=require(module.BeamVisual)
local Geometry=require(module.BeamGeometry)
local packet=game.ReplicatedStorage:WaitForChild("_BeamFirstFrameSnapshot",5)
assert(packet,"server first-frame wire capture missing")
local data=game:GetService("HttpService"):JSONDecode(packet.Value)
local visuals={}
local group
local function vector(t)return Vector3.new(t[1],t[2],t[3])end
local ok,problem=xpcall(function()
	local paths={}
	for _,entry in data do
		local points={};for _,v in entry.Path do table.insert(points,vector(v))end
		local position=vector(entry.Position)
		local model,rig=Beam.Build({Id=entry.Id,Position=position,Velocity=Vector3.yAxis*60,
			Beam={ChannelId=987654102,Origin=position,Length=24,Radius=.35,Path=points}})
		local visual={id=entry.Id,model=model,rig=rig,position=position,velocity=Vector3.yAxis*60,
			inView=true,timeScale=1,synced=true}
		Beam.Attach(visual);table.insert(visuals,visual);group=rig.beam.group
		table.insert(paths,points)
	end
	Beam.FlushGroups();Beam.ApplyGroups()
	game:GetService("RunService").Heartbeat:Wait()
	local parts={}
	for _,pair in group.segments do if pair.core.Transparency<1 then
		assert(pair.core.Size.X<=Geometry.MaxSegmentLength+.002,"oversized first-frame cylinder")
		local p=pair.core
		local half=p.CFrame.RightVector*p.Size.X*.5
		table.insert(parts,{p.Position-half,p.Position+half})
	end end
	-- Every interior rendered endpoint must meet another real cylinder.
	-- A missing joiner would expose two extra free endpoints in the middle.
	local loose=0
	for i,span in parts do for _,point in span do
		local joined=false
		for j,other in parts do if i~=j then
			if (point-other[1]).Magnitude<.02 or (point-other[2]).Magnitude<.02 then joined=true;break end
		end end
		if not joined then loose+=1 end
	end end
	assert(#parts>=7,"first frame omitted joining sections")
	assert(loose==2,"first visible frame contains "..loose.." disconnected endpoints")
	script:SetAttribute("Cylinders",#parts);script:SetAttribute("OpenEndpoints",loose)
end,debug.traceback)
for _,visual in visuals do Beam.Discard(visual)end
script:SetAttribute("Passed",ok);script:SetAttribute("Problem",if ok then "" else tostring(problem))
script:SetAttribute("Complete",true)
print("[BeamFirstFrameGeometry]",ok,problem)
