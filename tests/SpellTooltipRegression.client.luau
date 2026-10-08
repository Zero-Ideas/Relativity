-- Studio client: pure description/cache and binding lifecycle checks.
local client = game.Players.LocalPlayer.PlayerScripts.Client
local Tooltip = require(client.SpellTooltip)
local Shared = game.ReplicatedStorage.Shared
local Compiler = require(Shared.SpellCompiler)
local Encyclopedia = require(Shared.SpellEncyclopedia)
local preset = Encyclopedia.Get("FireBolt")
local record = { name = preset.Name, graph = preset.Graph, ref = "e:FireBolt" }
local text, cost = Tooltip.Describe(record)
assert(string.find(text, preset.Description, 1, true), "Missing preset description")
assert(cost == Compiler.Compile(preset.Graph).manaCost and string.find(text, "mana", 1, true), "Missing mana cost")
local custom = { name = "Custom", graph = Compiler.CreateDefaultGraph() }
local description = Tooltip.Describe(custom)
assert(string.find(description, "Fire", 1, true) and string.find(description, "Modifiers:", 1, true), "Missing generated custom description")
assert(Tooltip.Describe(custom) == description, "Unstable description cache")
local target = Instance.new("Frame")
local cleanup = Tooltip.Bind(target, function() return record end)
assert(Tooltip.Bind(target, function() return custom end) == cleanup, "Duplicate hover bindings")
cleanup(); cleanup(); target:Destroy()
print("[SpellTooltipRegression] PASS: preset/custom descriptions, mana, cache, retained binding, cleanup")
