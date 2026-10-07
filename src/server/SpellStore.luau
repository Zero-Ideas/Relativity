--!strict
--[[
	Dedicated persistence/cache for assembled spell cards. This intentionally
	does not share the legacy Player DataStore, so neither system can overwrite
	the other's schema.

	Every environment -- live servers, Studio Play and Team Test -- reads and
	writes the same DataStore, so a spell book follows the player everywhere.
	In Studio this needs Game Settings > Security > "Enable Studio Access to
	API Services".
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local SpellCompiler = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SpellCompiler"))

local STORE_NAME = "RelativitySpellCards_v1"
local SCHEMA_VERSION = 3 -- never silently discard cards that no longer compile
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
	localRevision: number,
	persistedRevision: number,
}

local entries: { [Player]: Entry } = {}
local selectionSaveQueued: { [Player]: boolean } = {}

local function blankData()
	return {
		schemaVersion = SCHEMA_VERSION,
		activeSlot = nil,
		slots = {},
		updatedAt = os.time(),
		revision = 0,
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
			local compiled, errors, normalized = SpellCompiler.Compile(record.graph)
			if compiled and normalized then
				normalized.name = typeof(record.name) == "string" and string.sub(record.name, 1, 96) or compiled.name
				data.slots[tostring(slot)] = {
					name = normalized.name,
					graph = normalized,
					savedAt = typeof(record.savedAt) == "number" and record.savedAt or 0,
				}
			else
				data.slots[tostring(slot)] = {
					name = typeof(record.name) == "string" and string.sub(record.name, 1, 96) or "Unrecognized spell",
					graph = copy(record.graph), savedAt = record.savedAt or 0, invalid = true,
					error = errors[1] and errors[1].message or "This saved graph cannot be compiled.",
				}
			end
		end
	end
	local active = raw.activeSlot
	if typeof(active) == "number" and active % 1 == 0 and data.slots[tostring(active)] then
		data.activeSlot = active
	end
	data.updatedAt = typeof(raw.updatedAt) == "number" and raw.updatedAt or 0
	data.revision = typeof(raw.revision) == "number" and raw.revision or 0
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
		dirty = entry.dirty,
		saving = entry.saving,
		storageMode = "DataStore",
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
		localRevision = 0,
		persistedRevision = 0,
	}
	entries[player] = entry
	local ok, result
	ok, result = withRetries(function() return store:GetAsync(keyFor(player)) end)
	if entries[player] ~= entry then
		return
	end
	if ok and result ~= nil then
		if typeof(result) ~= "table" or (result.slots ~= nil and typeof(result.slots) ~= "table") then
			ok, result = false, "Stored spell book is malformed; refusing to overwrite it."
		elseif result.revision ~= nil and (typeof(result.revision) ~= "number" or result.revision ~= result.revision
			or result.revision < 0 or result.revision % 1 ~= 0 or result.revision >= 1e15) then
			ok, result = false, "Stored spell revision is malformed; refusing to overwrite it."
		end
		if ok and result.schemaVersion ~= nil and (typeof(result.schemaVersion) ~= "number"
			or result.schemaVersion % 1 ~= 0 or result.schemaVersion < 1) then
			ok, result = false, "Stored spell schema is malformed; refusing to overwrite it."
		end
		if ok and result.slots then
			for slot, record in result.slots do
				local index = tonumber(slot)
				if not index or index % 1 ~= 0 or index < 1 or index > 5 or typeof(record) ~= "table" then
					ok, result = false, "Stored spell slot is malformed; refusing to overwrite it."
					break
				end
			end
		end
	end
	if ok and typeof(result) == "table" and typeof(result.schemaVersion) == "number" and result.schemaVersion > SCHEMA_VERSION then
		ok, result = false, "A newer spell-card schema exists; this server must not overwrite it."
	end
	if ok then
		entry.data = sanitizeLoaded(result)
		entry.persistedRevision = entry.data.revision
		entry.available = true
	else
		entry.error = if RunService:IsStudio() then tostring(result) else "Spell cards could not be loaded; saving is disabled to protect existing data."
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

-- Cast feedback only needs the slot, not a copy of all five saved graphs.
function SpellStore.GetActiveSlot(player: Player): number?
	local entry = entries[player]
	return if entry and entry.loaded and entry.available then entry.data.activeSlot else nil
end

function SpellStore.Save(player: Player): (boolean, string?)
	local entry = entries[player]
	if not entry or not entry.loaded or not entry.available then
		return false, entry and entry.error or "Spell data has not loaded."
	end
	if entry.saving then
		return false, "A spell save is already in progress."
	end
	entry.saving = true
	entry.data.updatedAt = os.time()
	local snapshot = copy(entry.data)
	local localRevision = entry.localRevision
	local expectedRevision = entry.persistedRevision
	snapshot.revision = expectedRevision + 1
	snapshot.saveId = HttpService:GenerateGUID(false)
	local ok, result = withRetries(function()
		return store:UpdateAsync(keyFor(player), function(old)
			if old ~= nil and typeof(old) ~= "table" then return nil end
			-- Idempotent retry if the first write succeeded but its response
			-- failed. Otherwise reject an older server overwriting a new one.
			if typeof(old) == "table" and old.saveId == snapshot.saveId then return old end
			if typeof(old) == "table" and typeof(old.schemaVersion) == "number" and old.schemaVersion > SCHEMA_VERSION then return nil end
			local revision = typeof(old) == "table" and old.revision or 0
			if revision ~= expectedRevision then return nil end
			return snapshot
		end)
	end)
	entry.saving = false
	if ok and typeof(result) == "table" then
		entry.persistedRevision = snapshot.revision
		entry.data.revision = snapshot.revision
		entry.dirty = entry.localRevision ~= localRevision
		entry.error = nil
		return true, nil
	end
	entry.dirty = true
	entry.error = if ok then "Spell cards changed in another session. Rejoin before saving; no stored data was overwritten."
		else "Spell save failed; the in-session copy is still available."
	if RunService:IsStudio() and not ok then entry.error = tostring(result) end
	if ok then entry.available = false end
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
	if entry.saving then return false, "A spell save is already in progress." end
	local compiled, errors, normalized = SpellCompiler.Compile(graph)
	if not compiled then return false, errors[1] and errors[1].message or "Invalid spell graph." end
	entry.data.slots[tostring(slot)] = { name = name, graph = copy(normalized), savedAt = os.time() }
	entry.localRevision += 1
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
	if entry.saving then return false, "A spell save is already in progress." end
	entry.data.slots[tostring(slot)] = nil
	if entry.data.activeSlot == slot then
		entry.data.activeSlot = nil
	end
	entry.dirty = true
	entry.localRevision += 1
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
	if entry.saving then return false, "A spell save is already in progress." end
	if entry.data.slots[tostring(slot)].invalid then return false, "This saved spell no longer compiles; its original graph has been preserved." end
	entry.data.activeSlot = slot
	entry.dirty = true
	entry.localRevision += 1
	-- Selection is immediately authoritative in the server cache. Disk/network
	-- persistence must not hold its acknowledgement hostage; coalesce rapid
	-- changes, with the existing autosave/leave/shutdown flush as backstops.
	if not selectionSaveQueued[player] then
		selectionSaveQueued[player] = true
		task.delay(1, function()
			selectionSaveQueued[player] = nil
			if entries[player] == entry and entry.dirty and entry.available and not entry.saving then
				SpellStore.Save(player)
			end
		end)
	end
	return true, nil, publicState(entry)
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
