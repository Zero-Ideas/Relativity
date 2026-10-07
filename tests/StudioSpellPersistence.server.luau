-- Studio-only. Uses an isolated synthetic user key, never real player cards.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio())
local Store = require(game.ServerScriptService.Server.SpellStore)
local Compiler = require(game.ReplicatedStorage.Shared.SpellCompiler)
local bridge = game.ServerStorage.RelativityStudioSpellStore
local fake = { UserId = -42424242, Parent = game.Players }
Store.Load(fake)
assert(Store.GetState(fake).available, "local persistence unavailable")
for slot = 1, 5 do
	local graph = Compiler.CreateDefaultGraph()
	graph.name = "Persistence regression " .. slot
	local ok, err = Store.PutSlot(fake, slot, graph.name, graph)
	assert(ok, err)
end
local ok, err = Store.SetActive(fake, 3)
assert(ok, err)
-- Activation now acknowledges the server cache immediately; explicitly flush
-- before testing disk reload instead of relying on synchronous selection I/O.
ok, err = Store.Save(fake)
assert(ok, err)
local raw = bridge:Invoke("Load", fake.UserId)
local rejoined = { UserId = fake.UserId, Parent = game.Players }
Store.Load(rejoined)
local restored = Store.GetState(rejoined)
for slot = 1, 5 do assert(restored.slots[tostring(slot)].name == "Persistence regression " .. slot) end
assert(restored.activeSlot == 3 and restored.storageMode == "StudioLocal" and not restored.sessionOnly)

-- A second session changed the book: a stale revision must not overwrite it.
local stale = table.clone(raw)
stale.revision = raw.revision + 1
stale.saveId = game.HttpService:GenerateGUID(false)
local result = bridge:Invoke("Save", fake.UserId, stale, raw.revision - 1)
assert(result == nil and bridge:Invoke("Load", fake.UserId).revision == raw.revision, "stale save overwrote newer book")
script:SetAttribute("FiveSlots", true)
script:SetAttribute("ActiveSlot", restored.activeSlot)
script:SetAttribute("ConflictProtected", true)
script:SetAttribute("Complete", true)
print("[StudioSpellPersistence] PASS: five slots, active selection, reload, stale-write protection")
