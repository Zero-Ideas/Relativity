-- Private gameplay-VM harness: fake transport and deterministic real-time clock.
local shared = game.ReplicatedStorage._BeamPredictionShared
local server = game.ServerScriptService._BeamPredictionServer
local P = require(server.Projectile)
local H = require(server.Projectile.BeamProjectileHandler)
local R = require(server.Projectile.Replication)
local HB = require(shared.Heartbeat)
local V = require(shared.VisualOffload)
local Protocol = require(shared.ProjectileProtocol)
local origin = Vector3.new(0, 6000, 0)
local moves, known = {}, {}
local function receive()
	local count = 0
	table.clear(moves)
	for _, event in V.Events do
		if event.Key == Protocol.Channels.SpawnBatch then
			assert(#event.Data <= 1000)
			for _, data in event.Data do
				known[data.Id] = true
				assert(not data.Synced, "beam still disables local prediction")
				assert(data.ServerTime and data.GlobalScale, "motion seed has no epoch")
				assert(data.Beam.Turns == nil, "unused history still on wire")
			end
		elseif event.Key == Protocol.Channels.Move then
			assert(#event.Data <= 2500)
			for _, data in event.Data do
				moves[data.Id] = data
				assert(known[data.Id], "correction arrived before spawn")
				assert(data.ServerTime and data.BeamPreviousId ~= nil)
				assert(data.BeamTurns == nil and data.BeamUnlinked == nil)
				count += 1
			end
		end
	end
	table.clear(V.Events)
	return count
end
local function launch(position)
	return H.Launch({Origin=position,Direction=Vector3.yAxis,Speed=60,Lifetime=10,
		Visualize=true,Beam={ChannelId=987654201}})
end
local ok, problem = xpcall(function()
	local front = launch(origin)
	HB.Step(1/60); receive()
	local back = launch(origin + Vector3.xAxis * 85)
	HB.Step(1/60); receive()
	assert(moves[front.Id], "singleton suppression was not sent immediately")
	for _, p in P.GetAll() do assert(known[p.Id], "first-frame joiner absent") end
	local before = R.getQueueStats()
	local sent = 0
	for _ = 1, 120 do HB.Step(1/60); sent += receive() end
	local after = R.getQueueStats()
	local candidates = after.BeamPoseCandidates-before.BeamPoseCandidates
	assert(sent < candidates * .15, "ballistic beam still streams near frame rate")
	script:SetAttribute("BallisticUpdates", sent)
	script:SetAttribute("OldFrameRateUpdates", candidates)
	-- Steering uses a faster sparse refresh, not a synced/render-only state.
	front.HomingTarget = {} -- no Homing config: physics unchanged, transport classification only
	local steering = 0
	for _ = 1, 60 do HB.Step(1/60); receive(); if moves[front.Id] then steering += 1 end end
	assert(steering == 60, "homing steering was throttled")
	script:SetAttribute("SteeringUpdates", steering)
	front.HomingTarget = nil
	-- All endpoints get an immediate epoch correction when global time changes,
	-- including entering zero time (periodic dilated timers must not stall it).
	HB.Scale = 0
	HB.Step(1/60); receive()
	for _, p in P.GetAll() do assert(moves[p.Id] and moves[p.Id].GlobalScale == 0) end
	HB.Scale = .2
	HB.Step(1/60); receive()
	for _, p in P.GetAll() do assert(moves[p.Id] and moves[p.Id].GlobalScale == .2) end
	back:SetTimeScale(.3)
	HB.Step(1/60); receive()
	assert(moves[back.Id] and moves[back.Id].TimeScale == .3, "personal scale did not rebaseline")
	-- A bounce correction bypasses the sparse cadence and is not duplicated.
	R.queueBounce(back, back.Position, Vector3.yAxis)
	HB.Step(1/60); receive()
	assert(moves[back.Id] and moves[back.Id].Bounced, "bounce was throttled")
	-- Relinking/refinement produces immediate topology updates, including child links.
	back.Position += Vector3.xAxis * 90
	HB.Step(1/60); receive()
	assert(moves[back.Id] and moves[back.Id].BeamPreviousId == back.Beam.PreviousId)
	for _, p in P.GetAll() do assert(known[p.Id], "new child was not seeded") end
end, debug.traceback)
for _, p in P.GetAll() do p:Destroy(nil, "test-cleanup") end
script:SetAttribute("Passed", ok)
script:SetAttribute("Problem", if ok then "" else tostring(problem))
script:SetAttribute("Complete", true)
print("[BeamPredictionReplication]", ok, problem)
