-- Run through Studio MCP/plugin in Client context, NOT as a LocalScript:
-- source cloning requires plugin capabilities. No live packets/settings touched.
local shared = game.ReplicatedStorage.Shared
local clone = shared.Projectile.Client:Clone()
clone.Name = "ProjectileAdmissionRegression"
clone.Source = clone.Source
	:gsub('require%(Shared:WaitForChild%("Heartbeat"%)%)', 'require(script.TestHeartbeat)')
	:gsub('require%(Shared:WaitForChild%("VisualOffload"%)%)', 'require(script.TestOffload)')
	:gsub('require%(script.VisualModel%)', 'require(script.TestVisualModel)')
local function module(name, source)
	local m = Instance.new("ModuleScript"); m.Name = name; m.Source = source; m.Parent = clone
end
module("TestHeartbeat", [[local H={};function H.Connect(fn) H.Step=fn end;function H.GetGlobalTimeScale() return 1 end;return H]])
module("TestOffload", [[local O={Handlers={}};function O.On(c,fn) O.Handlers[c]=fn end;function O.Emit(c,d) O.Handlers[c](d) end;return O]])
module("TestVisualModel", [[local M={Built={},Retired={}}
function M.Build(d) table.insert(M.Built,d.Id);return Instance.new('Folder'),nil end
function M.GetLongestEffectLifetime() return 0 end
function M.Retire(v) table.insert(M.Retired,v.id);v.model:Destroy() end
setmetatable(M,{__index=function() return function() end end});return M]])
clone.Parent = shared.Projectile
local ok, err = pcall(function()
	local client = require(clone)
	local bus = require(clone.TestOffload)
	local model = require(clone.TestVisualModel)
	local clock = require(clone.TestHeartbeat)
	local channels = require(shared.Projectile.Protocol).Channels
	client.EnableClientRendering()
	client.SetRenderSettings({MaxRendered = 2, MaxSmooth = 0})
	local function spawn(id, beam)
		return {Id=id,Position=Vector3.zero,Velocity=Vector3.zAxis,Lifetime=100,MaxRealLifetime=100,TimeScale=0,
			Beam=if beam then {Length=4,Radius=0.2,Origin=Vector3.zero} else nil}
	end
	bus.Emit(channels.SpawnBatch, {spawn(1),spawn(2,true),spawn(3),spawn(4,true)})
	assert(client.GetStats().Visuals == 2 and #model.Built == 2, "Excess ordinary/beam spawns constructed visuals")
	local prediction = require(clone.Prediction)
	local original = prediction.simulate
	local visited = {}
	prediction.simulate = function(v, dt) visited[v.id]=true;return original(v,dt) end
	clock.Step(1/60)
	assert(not visited[3] and not visited[4], "Rejected spawns entered simulation")
	bus.Emit(channels.Move, {{Id=3,Position=Vector3.zero,Velocity=Vector3.one,Bounced=true}})
	bus.Emit(channels.Sync, {Id=4,Position=Vector3.zero,Velocity=Vector3.one,Synced=true})
	bus.Emit(channels.TimeScale, {Id=3,TimeScale=2})
	bus.Emit(channels.HitBatch, {{Id=4,Position=Vector3.zero,Normal=Vector3.yAxis}})
	assert(#model.Built == 2 and client.GetStats().Visuals == 2, "Correction resurrected a rejected visual")
	bus.Emit(channels.HitBatch, {{Id=1,Position=Vector3.zero,Normal=Vector3.yAxis}})
	bus.Emit(channels.SpawnBatch, {spawn(5),spawn(6)})
	assert(client.GetStats().Visuals == 2 and #model.Built == 3, "Freed slot was not reused correctly")
	client.SetRenderSettings({MaxRendered=1})
	assert(client.GetStats().Visuals == 1, "Lowering cap retained excess simulation")
	client.SetRenderSettings({MaxRendered=0})
	bus.Emit(channels.SpawnBatch, {spawn(7),spawn(8,true)})
	assert(client.GetStats().Visuals == 0 and #model.Built == 3, "Zero cap admitted projectiles")
	client.SetRenderSettings({MaxRendered=2})
	assert(client.GetStats().Visuals == 0, "Raising cap replayed rejected events")
	bus.Emit(channels.SpawnBatch, {spawn(9)})
	assert(client.GetStats().Visuals == 1, "Raised cap did not admit new events")
	client.SetRenderSettings({MaxRendered=0})
	print("[ProjectileAdmissionRegression] PASS: early rejection, beams, no simulation/resurrection, slot reuse, shrink/zero/raise")
end)
clone:Destroy()
assert(ok, err)
