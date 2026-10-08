-- Run in an isolated Studio harness with a recording VisualOffload transport.
-- Does not move the player or alter the live game's projectile registry.
local shared = game.ReplicatedStorage._ProjectileRegressionShared
local server = game.ServerScriptService._ProjectileRegressionServer
local Replication = require(server.Projectile.Replication)
local Transport = require(shared.VisualOffload)
local Protocol = require(shared.Projectile.Protocol)
local player = game.Players:GetPlayers()[1]
assert(player and player.Character and player.Character.PrimaryPart)
local near = player.Character.PrimaryPart.Position + Vector3.yAxis*5
local p = {
	Id = 990000001, Position = near, Velocity = Vector3.xAxis*100,
	Lifetime = 20, Age = 0, MaxRealLifetime = 60, _spawnRealTime = os.clock(),
	Gravity = 0, Acceleration = 0, MinSpeed = 0, MaxSpeed = math.huge,
	_lastStreamedTimeScale = 1, VisualScale = 1, DestroyDelay = 0,
	WaitForParticles = true, WaitForTrails = true, Visualize = true,
	VisualRange = 40, Dead = false,
}
local function messages(channel)
	local result = {}
	for _, message in Transport.Messages do
		if message.Channel == channel and (not message.Player or message.Player == player) then
			for _, payload in message.Payload do table.insert(result, payload) end
		end
	end
	return result
end
Replication.spawnVisual(p)
Replication.flushSpawnBatch()
assert(#messages(Protocol.Channels.SpawnBatch) == 1, "initial spawn was not observed")
table.clear(Transport.Messages)
p.Position = near + Vector3.xAxis*100
Replication.flushSpawnBatch()
assert(messages(Protocol.Channels.RangeExit)[1] == p.Id, "range loss did not retire observer interest")
table.clear(Transport.Messages)
-- Bounce, personal scale and homing transition all occur out of range.
p.Velocity = -Vector3.xAxis*100
p.HomingTarget = {}
p.Age = 3
Replication.updateTimeScale(p, .2)
Replication.updateSyncState(p)
Replication.queueBounce(p,p.Position,Vector3.xAxis)
Replication.flushMoveBatch()
assert(#Transport.Messages == 0, "out-of-range observer received stale correction")
p.Position = near
Replication.flushSpawnBatch()
local returned = messages(Protocol.Channels.SpawnBatch)
assert(#returned == 1 and returned[1].Position == near and returned[1].Velocity == p.Velocity)
assert(returned[1].Synced and returned[1].TimeScale == .2 and returned[1].Lifetime == 17,
	"re-entry did not restore homing, scale, remaining lifetime and authoritative pose")
table.clear(Transport.Messages)
-- A death just outside the range must reach existing observers, even before
-- the next interest check: hit delivery is based on subscriptions, not distance.
p.Position = near+Vector3.xAxis*100
p.Dead = true
Replication.queueHit(p,{Position=p.Position,Normal=Vector3.yAxis,Kind="world"})
Replication.flushHitBatch()
assert(#messages(Protocol.Channels.HitBatch) == 1, "out-of-range death was lost")
table.clear(Transport.Messages)
Replication.flushSpawnBatch()
assert(#Transport.Messages == 0, "dead projectile respawned on interest scan")
-- Corrections share the 2500 cap with continuous poses, rather than being
-- prepended without a limit and synchronizing all cohorts into one spike.
for index=1,5000 do
	local state=table.clone(p)
	state.Id=990010000+index
	state.Dead=false
	state.VisualRange=math.huge
	state._spawnStreamed=true
	Replication.queueBounce(state,near,Vector3.xAxis)
end
Replication.flushMoveBatch()
assert(#messages(Protocol.Channels.Move)==2500,"bounce volley bypassed bounded move batch")
table.clear(Transport.Messages)
Replication.flushMoveBatch()
assert(#messages(Protocol.Channels.Move)==2500,"second bounce cohort was lost")
table.clear(Transport.Messages)
Replication.flushMoveBatch()
assert(#Transport.Messages==0,"bounce queue did not drain")
script:SetAttribute("Complete",true)
print("[ProjectileInterestRegression] PASS: re-entry, bounce/homing/time-scale snapshot, out-of-range death, bounded 5000-correction volley")
