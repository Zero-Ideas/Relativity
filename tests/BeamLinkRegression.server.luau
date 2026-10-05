-- Temporary normal Studio Script, never shipped by the Rojo game project.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio())
local shared = game.ReplicatedStorage.Shared
local server = game.ServerScriptService.Server
local Entity = require(shared.Entity)
local Path = require(shared.BeamPath)
local Handler = require(server.BeamProjectileHandler)
local viewer = game.Players:GetPlayers()[1]
assert(viewer and viewer.Character)
local origin = viewer.Character:GetPivot().Position + Vector3.new(0,180,0)
-- Put the target inside a gap requiring adaptive joiners, not near a head.
local frontPosition, backPosition = origin + Vector3.new(0,0,-Path.MaxStretch*3), origin + Vector3.new(30,0,-20)
local midpoint = (frontPosition+backPosition)*.5
local fixture = game.ReplicatedStorage.Dummy:Clone()
for _, instance in fixture:GetDescendants() do
	if instance:IsA("BaseScript") then instance:Destroy()
	elseif instance:IsA("BasePart") then instance.Anchored = true end
end
fixture.Name = "TiltedBeamRegressionDummy"
fixture.Humanoid.MaxHealth = 1000
fixture.Humanoid.Health = 1000
fixture:PivotTo(CFrame.new(midpoint))
fixture.Parent = workspace
local target = Entity.new(fixture, { ScaleHumanoid = true, Health = 1000, MaxHealth = 1000 })

local function pair(channel, extra)
	local first = Handler.Launch({ Origin = frontPosition, Direction = -Vector3.zAxis, Speed = 0,
		Lifetime = 1, Beam = { ChannelId = channel }, Radius = .5, Visualize = false })
	local config = { Origin = backPosition, Direction = Vector3.xAxis, Speed = 0,
		Lifetime = 1, Beam = { ChannelId = channel }, Radius = .5, Damage = 17, Visualize = false }
	for key, value in extra or {} do config[key] = value end
	return first, Handler.Launch(config)
end

local first, second = pair(910000001)
local hits = 0
local triggered = {}
local before = target.Health
script:SetAttribute("Before", before)
second.OnHit:Connect(function(hit)
	if hit.Entity == target then
		hits += 1
		target:TakeDamage(second.Damage * second.DamageMultiplier, { Hurtbox = hit.Hurtbox })
		-- Trigger callbacks may add a new channel while the span pass is
		-- iterating. Its joiners must not be lost during channel compaction.
		local start = origin + Vector3.yAxis*20
		table.insert(triggered, Handler.Launch({Origin=start,Speed=0,Lifetime=1,
			Beam={ChannelId=910000010},Visualize=false}))
		table.insert(triggered, Handler.Launch({Origin=start+Vector3.xAxis*Path.MaxStretch*2,Speed=0,Lifetime=1,
			Beam={ChannelId=910000010},Visualize=false}))
	end
end)
task.wait(.06)
script:SetAttribute("Hits", hits)
script:SetAttribute("After", target.Health)
assert(second.Beam.PreviousId == first.Id, "linked stream did not reference its preceding sample")
assert(second.Dead and second._beamBodyHit, "tilted connector missed the dummy away from both head trajectories")
assert(hits == 1 and math.abs(before-target.Health-17) < .001, "connector bypassed/duplicated Entity damage")
local triggerDeadline=os.clock()+.5
repeat task.wait() until triggered[2] and triggered[2]._beamSpan or os.clock()>triggerDeadline
assert(triggered[2] and triggered[2]._beamSpan,"trigger-created channel lost its adaptive span")
for _,p in triggered do p:Destroy() end
first:Destroy()

local pierceFront, piercing = pair(910000002, { MaxPierces = 1, PierceFalloff = .15 })
local pierceHits = 0
piercing.OnHit:Connect(function(hit) if hit.Entity == target then pierceHits += 1 end end)
task.wait(.08)
assert(not piercing.Dead and piercing.PiercesLeft == 0 and math.abs(piercing.DamageMultiplier-.85) < .001)
assert(pierceHits == 1, "stationary linked cylinder repeatedly damaged the same pierced dummy")
piercing:Destroy()
pierceFront:Destroy()
target:Destroy()
fixture:Destroy()

local wall = Instance.new("Part")
wall.Anchored = true
wall.Size = Vector3.new(2,6,2)
wall.Position = midpoint
wall.Parent = workspace
local bounceFront, bouncing = pair(910000003, { Speed = 10, Bounces = 1, Restitution = .7 })
task.wait(.05)
assert(not bouncing.Dead and bouncing.BouncesLeft == 1 and #bouncing._beamTurns == 0, "body contact prematurely bounced the distant head")
assert((bouncing.Position-backPosition).Magnitude < 3, "body contact teleported trailing head onto wall")
assert(bouncing._beamSpan and #bouncing._beamSpan >= 2, "blocked body was not clipped")
assert(bouncing._beamSpanClipped==true,"clipped body did not replicate its disconnected front")
bouncing:Destroy()
bounceFront:Destroy()
wall:Destroy()
local contact = origin+Vector3.new(0,0,-15)
local path = Path.Connect(origin, origin+Vector3.new(15,0,-15), {}, { contact })
assert(#path == 3 and path[2] == contact, "bounce connection shortcuts through the corner")
assert(Path.Connect(origin, frontPosition, { contact }, {}) == nil, "different bounce branches connected through geometry")
script:SetAttribute("Complete", true)
script:SetAttribute("Damage", before-target.Health)
print("[BeamLinkRegression] PASS: tilted Entity damage, piercing once, falloff, body clipping without head teleport, no corner shortcuts")
