-- Run as a temporary server Script in a Studio playtest (not shipped by Rojo).
-- Exercises real modules on the gameplay VM; do not require them from MCP's
-- isolated execution VM and expect to share Entity/Projectile state.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio(), "Studio-only regression test")
local shared = game.ReplicatedStorage.Shared
local server = game.ServerScriptService.Server
local Compiler = require(shared.SpellCompiler)
local Runes = require(shared.SpellRunes)
local Runtime = require(server.SpellRuntime)
local Projectile = require(server.Projectile)
local Config = require(server.Projectile.Config)
local Quota = require(server.ProjectileQuota)
local Entity = require(shared.Entity)
local BeamHandler = require(server.Projectile.BeamProjectileHandler)

local function plan(modifiers, vessel)
	local graph = Compiler.CreateDefaultGraph()
	graph.runes[3].rune = "Range"
	graph.runes[3].params = { Level = 5 }
	graph.runes[4].rune = vessel or "Beam"
	for index, kind in modifiers or {} do
		local id = "mod_" .. index
		table.insert(graph.runes, { id = id, rune = kind, x = 362, y = 320, params = Runes.DefaultParams(kind) })
		table.insert(graph.wires, { from = id, fromPort = "mod", to = "orb", toPort = "mods" })
	end
	return Compiler.Compile(graph)
end

local defaults = Config.normalize({ Beam = {} }, 60)
assert(defaults.Speed == 2000 and defaults.Radius == .35 and defaults.Beam.Length == 24)
local regular = Config.normalize({}, 60)
assert(regular.Speed == 100 and regular.Radius == 0 and regular.Beam == nil)
local burst = Projectile.Burst({ Beam = { Length = 10 }, Visualize = false }, 2)
assert(burst[1].Beam ~= burst[2].Beam, "burst shares beam config")
for _, p in burst do p:Destroy() end
local compiled, errors = plan({ "Speed", "Size", "Gravity", "Bounce", "Pierce", "Homing", "Sustain" })
assert(compiled, errors[1] and errors[1].message)
assert(not plan({ "Sustain" }, "Orb"), "Sustain accepted on Orb")
assert(not plan({ "Sustain", "Sustain" }), "duplicate Sustain accepted")
assert(Runes.TriggerApplies("Beam", "OnTimer") and Runes.TriggerApplies("Beam", "OnProximity"))
for tier, duration in Runes.ModifierTables.Sustain do assert(duration == tier) end

local viewer = game.Players:GetPlayers()[1]
assert(viewer and viewer.Character, "a playtest player is required")
-- Isolate the test from real mouse releases, tool swaps and the player's
-- existing projectile quota. Nothing modifies their spell cards or caster.
local character = game.ReplicatedStorage.Dummy:Clone()
for _, v in character:GetDescendants() do if v:IsA("BaseScript") then v:Destroy() end end
character.Name = "BeamRegressionCaster"
character:PivotTo(viewer.Character:GetPivot() * CFrame.new(0, 100, 0))
character.HumanoidRootPart.Anchored = true
character.Parent = workspace
local assembler = Instance.new("Tool")
assembler.Name = "SpellAssembler"
assembler.RequiresHandle = false
assembler.Parent = character
local player = { UserId = -42424243, Parent = game.Players, Character = character }
local caster = Entity.new(character, { ScaleHumanoid = true })
local origin = character:GetPivot().Position + Vector3.new(0, 5, 0)
local aim = origin + Vector3.new(0, 0, -500)
local request = { player = player, character = character, caster = caster, origin = origin, cursorPoint = aim,
	live = function() return origin, aim end }
local baseline = Quota.Get(player)
local sustainPlan = assert(plan({ "Sustain" }))
local seen, spawned, energy, count, changed = {}, {}, 0, 0, false
local capture = RunService.Heartbeat:Connect(function()
	BeamHandler.KeepAlive(player)
	for _, p in Projectile.GetBySource(caster) do
		if p.Beam and not seen[p.Id] then
			seen[p.Id] = true
			table.insert(spawned, p)
			energy += p.Damage
			count += 1
			if p.Velocity.X > 1000 then changed = true end
		end
	end
end)
Runtime.Cast(sustainPlan, request)
assert(Runtime.IsSustaining(player))
task.wait(.2)
aim = origin + Vector3.new(500, 0, 0)
task.wait(1.1)
capture:Disconnect()
assert(changed, "sustain didn't follow live aim")
local expectedPackets = math.ceil(1 / BeamHandler.GetInterval(2000) - 1e-6)
assert(count == expectedPackets, "expected " .. expectedPackets .. " packets, got " .. count)
-- Range V consumes 15%, Sustain I consumes 4%; Fire impact .8 x Beam .8.
local expected = 30 * (1 - .15 - .04) * .8 * .8
assert(math.abs(energy - expected) < .001, "sustain multiplied/lost cast energy")
assert(not Runtime.IsSustaining(player), "sustain did not finish")
for _, p in spawned do p:Destroy() end
assert(Quota.Get(player) == baseline, "sustain leaked projectile quota")

Runtime.Cast(sustainPlan, request)
task.wait(.05)
BeamHandler.Stop(player)
assert(not Runtime.IsSustaining(player), "release didn't stop channel")
character.Humanoid:UnequipTools()
assembler.Parent = nil
task.wait(.05)
assert(not Runtime.IsSustaining(player), "unequip didn't cancel sustain")
for _, p in Projectile.GetBySource(caster) do if p.Beam then p:Destroy() end end
assert(Quota.Get(player) == baseline, "cancel leaked projectile quota")

-- Ordinary cylinder-head sweeps must hit a target away from the center ray.
local target = Instance.new("Part")
target.Anchored = true
target.Size = Vector3.new(.2, 2, 2)
target.Position = origin + Vector3.new(.35, 0, -20)
target.Parent = workspace
local hit = false
local p = Projectile.new({ Origin = origin, Direction = -Vector3.zAxis, Beam = {}, Lifetime = .1,
	IgnoreInstances = { character }, Visualize = false })
p.OnHit:Connect(function(info) hit = info.Part == target end)
task.wait(.15)
target:Destroy()
assert(hit and p.Dead, "beam radius missed off-axis geometry")
BeamHandler.Stop(player)
caster:Destroy()
character:Destroy()
assembler:Destroy()
script:SetAttribute("Packets", count)
script:SetAttribute("DamageEnergy", energy)
script:SetAttribute("Complete", true)
print("[BeamRegression] PASS: registry, burst isolation, flight, live aim, energy, cancel, quota, cylinder sweep")
