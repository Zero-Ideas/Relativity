-- Isolated transport fixture exercising actual client message handlers,
-- not only BeamVisual helpers. Install _BeamPredictionProtocolShared first.
local shared = game.ReplicatedStorage._BeamPredictionProtocolShared
local Client = require(shared.ProjectileClient)
local V = require(shared.VisualOffload)
local HB = require(shared.Heartbeat)
local Beam = require(shared.ProjectileClient.BeamVisual)
local RunService = game:GetService("RunService")
local camera = workspace.CurrentCamera
local heading = camera.CFrame.LookVector
local origin = camera.CFrame.Position + heading * 50
local channel = 987654203
local front, back = 987654221, 987654222
local ok, problem = xpcall(function()
	Client.EnableClientRendering()
	local stamp = workspace:GetServerTimeNow() - .25
	V.Emit("ProjSpawnBatch", {
		{Id=front,Position=origin+heading*20,Velocity=heading*2000,Lifetime=5,MaxRealLifetime=10,
			ServerTime=stamp,GlobalScale=1,Beam={ChannelId=channel,Origin=origin+heading*20,
			Length=24,Radius=.35,Path={origin+heading*20}}},
		{Id=back,Position=origin,Velocity=heading*2000,Lifetime=5,MaxRealLifetime=10,
			ServerTime=stamp,GlobalScale=1,Beam={ChannelId=channel,Origin=origin,
			Length=24,Radius=.35,PreviousId=front,Path={origin,origin+heading*20}}},
	})
	local function frame()
		HB.Step(1/60)
		Beam.ApplyGroups()
		RunService.Heartbeat:Wait()
	end
	frame()
	local model = assert(workspace:FindFirstChild("SustainedBeam_"..channel))
	local function checkFinite()
		local count = 0
		for _, p in model:GetChildren() do
			if p.Name=="BeamCore" and p.Transparency<1 then
				count += 1
				assert(p.Size.X<=12.002,"cylinder exceeded cap")
				assert((p.Position-origin).Magnitude>100,"timestamp prediction stayed at old spawn")
			end
		end
		assert(count>0 and count<10,"spawn/impact tether created an enormous centerline")
		return count
	end
	script:SetAttribute("InitialCylinders",checkFinite())
	-- Move the front to its real hit location, then remove it. Its final path
	-- is a singleton; the surviving back must not join to that old/retired tip.
	V.Emit("ProjHitBatch",{{Id=front,Position=origin+heading*520,Normal=-heading,
		BeamPath={origin+heading*520},Kind="world"}})
	frame(); frame()
	script:SetAttribute("ImpactCylinders",checkFinite())
	-- A delayed topology correction is adopted at its epoch and caught up,
	-- not applied as 'now' and then simulated a second time by the scheduler.
	stamp = workspace:GetServerTimeNow()-.05
	local seed = origin+heading*600
	V.Emit("ProjMove",{{Id=back,Position=seed,Velocity=heading*2000,Lifetime=4,
		ServerTime=stamp,GlobalScale=1,TimeScale=1,BeamPreviousId=0,
		BeamPath={seed,seed+heading*20}}})
	frame(); checkFinite()
	V.Emit("ProjHitBatch",{{Id=back,Position=seed+heading*100,Normal=-heading,
		BeamPath={seed+heading*100},Kind=nil}})
	HB.Step(1)
end,debug.traceback)
-- Retired zero-length fixtures drain in this isolated controller only.
HB.Step(60)
script:SetAttribute("Passed",ok)
script:SetAttribute("Problem",if ok then "" else tostring(problem))
script:SetAttribute("Complete",true)
print("[BeamPredictionProtocol]",ok,problem)
