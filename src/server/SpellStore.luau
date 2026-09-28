--!strict
--[[
	Dedicated persistence/cache for assembled spell cards. This intentionally
	does not share the legacy Player DataStore, so neither system can overwrite
	the other's schema.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SpellCompiler = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SpellCompiler"))

local STORE_NAME = "RelativitySpellCards_v1"
local SCHEMA_VERSION = 2
local SAVE_INTERVAL = 60
local RETRY_DELAYS = { 1, 2, 4 }

local store = DataStoreService:GetDataStore(STORE_NAME)
local SpellStore = {}

type Entry = {
	loaded: boolean,
	available: boolean,
	sessionOnly: boolean,
	dirty: boolean,
	saving: boolean,
	error: string?,
	data: any,
}

local entries: { [Player]: Entry } = {}

local function blankData()
	return {
		schemaVersion = SCHEMA_VERSION,
		activeSlot = nil,
		slots = {},
		updatedAt = os.time(),
	}
end

local function copy(value: any, depth: number?): any
	if typeof(value) ~= "table" then
		return value
	end
	local level = depth or 0
	if level > 8 then
		return nil
	end
	local result = {}
	for key, child in value do
		result[copy(key, level + 1)] = copy(child, level + 1)
	end
	return result
end

local function sanitizeLoaded(raw: any)
	local data = blankData()
	if typeof(raw) ~= "table" then
		return data
	end
	local rawSlots = typeof(raw.slots) == "table" and raw.slots or {}
	for slot = 1, 5 do
		local record = rawSlots[tostring(slot)] or rawSlots[slot]
		if typeof(record) == "table" then
			local compiled, _, normalized = SpellCompiler.Compile(record.graph)
			if compiled and normalized then
				normalized.name = typeof(record.name) == "string" and string.sub(record.name, 1, 96) or compiled.name
				data.slots[tostring(slot)] = {
					name = normalized.name,
					graph = normalized,
					savedAt = typeof(record.savedAt) == "number" and record.savedAt or 0,
				}
			end
		end
	end
	local active = raw.activeSlot
	if typeof(active) == "number" and active % 1 == 0 and data.slots[tostring(active)] then
		data.activeSlot = active
	end
	data.updatedAt = typeof(raw.updatedAt) == "number" and raw.updatedAt or 0
	return data
end

local function keyFor(player: Player): string
	return `player_{player.UserId}`
end

local function withRetries(operation: () -> any): (boolean, any)
	local lastError
	for attempt = 1, #RETRY_DELAYS + 1 do
		local ok, result = pcall(operation)
		if ok then
			return true, result
		end
		lastError = result
		if attempt <= #RETRY_DELAYS then
			task.wait(RETRY_DELAYS[attempt])
		end
	end
	return false, lastError
end

local function publicState(entry: Entry)
	return {
		available = entry.available,
		sessionOnly = entry.sessionOnly,
		error = entry.error,
		activeSlot = entry.data.activeSlot,
		slots = copy(entry.data.slots),
	}
end

function SpellStore.Load(player: Player)
	if entries[player] then
		return
	end
	local entry: Entry = {
		loaded = false,
		available = false,
		sessionOnly = false,
		dirty = false,
		saving = false,
		error = nil,
		data = blankData(),
	}
	entries[player] = entry
	if RunService:IsStudio() then
		entry.loaded = true
		entry.available = true
		entry.sessionOnly = true
		entry.error = "Studio session-only mode; production spell cards are untouched."
		warn("[SpellStore] Studio session-only mode; skipping DataStore access.")
		return
	end

	local ok, result = withRetries(function()
		return store:GetAsync(keyFor(player))
	end)
	if entries[player] ~= entry then
		return
	end
	if ok then
		entry.data = sanitizeLoaded(result)
		entry.available = true
	else
		entry.error = "Spell cards could not be loaded; saving is disabled to protect existing data."
		warn(`[SpellStore] load failed for {player.UserId}: {tostring(result)}`)
	end
	entry.loaded = true
end

function SpellStore.WaitForLoad(player: Player, timeout: number?): boolean
	local started = os.clock()
	while player.Parent and (not entries[player] or not entries[player].loaded) do
		if timeout and os.clock() - started >= timeout then
			return false
		end
		task.wait()
	end
	return entries[player] ~= nil and entries[player].loaded
end

function SpellStore.GetState(player: Player)
	SpellStore.WaitForLoad(player, 15)
	local entry = entries[player]
	if not entry then
		return { available = false, sessionOnly = false, error = "Spell state is unavailable.", slots = {} }
	end
	return publicState(entry)
end

function SpellStore.GetActive(player: Player)
	local entry = entries[player]
	if not entry or not entry.loaded or not entry.available or not entry.data.activeSlot then
		return nil
	end
	return entry.data.slots[tostring(entry.data.activeSlot)]
end

function SpellStore.Save(player: Player): (boolean, string?)
	local entry = entries[player]
	if not entry or not entry.loaded or not entry.available then
		return false, entry and entry.error or "Spell data has not loaded."
	end
	if entry.sessionOnly then
		entry.dirty = false
		return true, entry.error
	end
	if entry.saving then
		return false, "A spell save is already in progress."
	end
	entry.saving = true
	entry.data.updatedAt = os.time()
	local snapshot = copy(entry.data)
	local ok, result = withRetries(function()
		return store:UpdateAsync(keyFor(player), function(_old)
			return snapshot
		end)
	end)
	entry.saving = false
	if ok then
		entry.dirty = false
		entry.error = nil
		return true, nil
	end
	entry.dirty = true
	entry.error = "Spell save failed; the in-session copy is still available."
	warn(`[SpellStore] save failed for {player.UserId}: {tostring(result)}`)
	return false, entry.error
end

function SpellStore.PutSlot(player: Player, slot: number, name: string, graph: any)
	local entry = entries[player]
	if not entry or not entry.loaded or not entry.available then
		return false, entry and entry.error or "Spell data has not loaded."
	end
	if slot % 1 ~= 0 or slot < 1 or slot > 5 then
		return false, "Slot must be from 1 to 5."
	end
	entry.data.slots[tostring(slot)] = { name = name, graph = copy(graph), savedAt = os.time() }
	entry.dirty = true
	local ok, err = SpellStore.Save(player)
	return ok, err, publicState(entry)
end

function SpellStore.DeleteSlot(player: Player, slot: number)
	local entry = entries[player]
	if not entry or not entry.loaded or not entry.available then
		return false, entry and entry.error or "Spell data has not loaded."
	end
	if slot % 1 ~= 0 or slot < 1 or slot > 5 then
		return false, "Slot must be from 1 to 5."
	end
	entry.data.slots[tostring(slot)] = nil
	if entry.data.activeSlot == slot then
		entry.data.activeSlot = nil
	end
	entry.dirty = true
	local ok, err = SpellStore.Save(player)
	return ok, err, publicState(entry)
end

function SpellStore.SetActive(player: Player, slot: number)
	local entry = entries[player]
	if not entry or not entry.loaded or not entry.available then
		return false, entry and entry.error or "Spell data has not loaded."
	end
	if slot % 1 ~= 0 or slot < 1 or slot > 5 or not entry.data.slots[tostring(slot)] then
		return false, "That spell card does not exist."
	end
	entry.data.activeSlot = slot
	entry.dirty = true
	local ok, err = SpellStore.Save(player)
	return ok, err, publicState(entry)
end

local function onPlayer(player: Player)
	task.spawn(SpellStore.Load, player)
end

for _, player in Players:GetPlayers() do
	onPlayer(player)
end
Players.PlayerAdded:Connect(onPlayer)

Players.PlayerRemoving:Connect(function(player)
	local entry = entries[player]
	if entry and entry.loaded and entry.available and entry.dirty then
		SpellStore.Save(player)
	end
	entries[player] = nil
end)

task.spawn(function()
	while true do
		task.wait(SAVE_INTERVAL)
		for player, entry in entries do
			if player.Parent and entry.loaded and entry.available and entry.dirty and not entry.saving then
				task.spawn(SpellStore.Save, player)
			end
		end
	end
end)

game:BindToClose(function()
	local remaining = 0
	for player, entry in entries do
		if entry.loaded and entry.available and entry.dirty and not entry.sessionOnly then
			remaining += 1
			task.spawn(function()
				SpellStore.Save(player)
				remaining -= 1
			end)
		end
	end
	local deadline = os.clock() + 10
	while remaining > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)

return SpellStore
