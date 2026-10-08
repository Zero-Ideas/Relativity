--!strict
--[[
	Dedicated persistence/cache for assembled spells. This intentionally
	does not share the legacy Player DataStore, so neither system can overwrite
	the other's schema.

	Every environment -- live servers, Studio Play and Team Test -- reads and
	writes the same DataStore, so a spell book follows the player everywhere.
	In Studio this needs Game Settings > Security > "Enable Studio Access to
	API Services".

	Schema 4 (in memory):
	  library   -- every spell the player made or was given, any number:
	               { [id] = { name, graph, savedAt, invalid?, error? } }
	  loadout   -- the SLOT_COUNT hotbar slots: { ["1".."5"] = ref }, a ref
	               being "c:<library id>" or "e:<Encyclopedia id>"
	  activeSlot-- the selected hotbar slot (or nil)
	  loadouts  -- saved loadouts: { { name, slots = { [slot] = ref } } }
	  owned     -- Encyclopedia ids bought (free ones need no entry)
	  folders   -- the player's folder names; a library spell's `folder` puts
	               it in one (nil: unfiled)
	Persisted as one main key (everything but the spell graphs, plus an index
	of the library) and the graphs packed into as many "page" keys as they
	need (PAGE_LIMIT characters each) -- so the library has no size cap. Pages
	are written under revision-specific keys before the main key (which
	keeps the revision check against other servers), so a failed or
	conflicting save never damages what the last good save points at.
	Schema 1-3 saves (just the 5 slots) convert on load: each card becomes a
	library spell, equipped in the same slot.

	publicState (sent to the client) keeps the old shape -- slots [1..5] with
	name/graph, activeSlot -- so the hotbar and editor work unchanged, and
	adds library, loadouts and owned.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SpellCompiler = require(Shared:WaitForChild("SpellCompiler"))
local Encyclopedia = require(Shared:WaitForChild("SpellEncyclopedia"))

local STORE_NAME = "RelativitySpellCards_v1"
local SCHEMA_VERSION = 4 -- never silently discard spells that no longer compile
local SLOT_COUNT = 5
local PAGE_LIMIT = 3_500_000 -- characters per library page (a key holds 4,194,304)
local SAVE_INTERVAL = 60
local RETRY_DELAYS = { 1, 2, 4 }
local MAX_LOADOUTS = 100
local NAME_LENGTH = 96

local store = DataStoreService:GetDataStore(STORE_NAME)
local SpellStore = {}
SpellStore.SlotCount = SLOT_COUNT

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
	libraryRevision: number, -- bumped by every library change
	pagesRevision: number, -- the libraryRevision the saved pages hold
}

local entries: { [Player]: Entry } = {}
local selectionSaveQueued: { [Player]: boolean } = {}

local function blankData()
	return {
		schemaVersion = SCHEMA_VERSION,
		activeSlot = nil,
		library = {},
		loadout = {},
		loadouts = {},
		owned = {},
		folders = {},
		pages = {}, -- page keys the library was last saved to
		updatedAt = os.time(),
		revision = 0,
	}
end

local function copy(value: any, depth: number?): any
	if typeof(value) ~= "table" then
		return value
	end
	local level = depth or 0
	if level > 12 then
		return nil
	end
	local result = {}
	for key, child in value do
		result[copy(key, level + 1)] = copy(child, level + 1)
	end
	return result
end

local function newId(): string
	local compact = string.gsub(HttpService:GenerateGUID(false), "-", "")
	return string.lower(compact)
end

local function cleanName(value: any, fallback: string): string
	return if typeof(value) == "string" and value ~= "" then string.sub(value, 1, NAME_LENGTH) else fallback
end

-- A stored spell, compiled to check it; one that no longer compiles keeps
-- its original graph (and why) instead of being dropped.
local function sanitizeSpell(name: any, graph: any, savedAt: any): any
	local compiled, errors, normalized = SpellCompiler.Compile(graph)
	if compiled and normalized then
		normalized.name = cleanName(name, compiled.name)
		return { name = normalized.name, graph = normalized, savedAt = if typeof(savedAt) == "number" then savedAt else 0 }
	end
	return {
		name = cleanName(name, "Unrecognized spell"),
		graph = copy(graph),
		savedAt = if typeof(savedAt) == "number" then savedAt else 0,
		invalid = true,
		error = errors[1] and errors[1].message or "This saved graph cannot be compiled.",
	}
end

local function validRef(value: any): boolean
	return typeof(value) == "string" and #value <= 80 and (string.sub(value, 1, 2) == "c:" or string.sub(value, 1, 2) == "e:")
end

local function cleanSlots(raw: any): { [string]: string }
	local slots = {}
	if typeof(raw) == "table" then
		for slot = 1, SLOT_COUNT do
			local ref = raw[tostring(slot)] or raw[slot]
			if validRef(ref) then
				slots[tostring(slot)] = ref
			end
		end
	end
	return slots
end

-- Schema 1-3: { slots = { ["1".."5"] = { name, graph, savedAt } }, activeSlot }
local function migrateLegacy(raw: any): any
	local data = blankData()
	local rawSlots = if typeof(raw.slots) == "table" then raw.slots else {}
	for slot = 1, SLOT_COUNT do
		local record = rawSlots[tostring(slot)] or rawSlots[slot]
		if typeof(record) == "table" then
			local id = newId()
			data.library[id] = sanitizeSpell(record.name, record.graph, record.savedAt)
			data.loadout[tostring(slot)] = "c:" .. id
		end
	end
	local active = raw.activeSlot
	if typeof(active) == "number" and active % 1 == 0 and data.loadout[tostring(active)] then
		data.activeSlot = active
	end
	data.updatedAt = if typeof(raw.updatedAt) == "number" then raw.updatedAt else 0
	data.revision = if typeof(raw.revision) == "number" then raw.revision else 0
	return data
end

local function keyFor(player: Player): string
	return `player_{player.UserId}`
end

local function pageKey(player: Player, revision: number, index: number): string
	return `player_{player.UserId}_lib_{revision}_{index}`
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

-- Schema 4: the main record (with the library index) and its pages.
local function loadV4(player: Player, raw: any): (boolean, any)
	local data = blankData()
	local pages = if typeof(raw.pages) == "table" then raw.pages else {}
	local graphs: { [string]: any } = {}
	for _, key in pages do
		if typeof(key) ~= "string" then
			return false, "Stored spell page list is malformed; refusing to overwrite it."
		end
		local ok, page = withRetries(function() return store:GetAsync(key) end)
		if not ok then
			return false, page
		end
		if typeof(page) ~= "table" then
			return false, `Spell page {key} is missing; refusing to overwrite the library.`
		end
		for id, stored in page do
			graphs[id] = stored
		end
		table.insert(data.pages, key)
	end
	local index = if typeof(raw.index) == "table" then raw.index else {}
	for id, info in index do
		if typeof(id) ~= "string" or typeof(info) ~= "table" then
			continue
		end
		local stored = graphs[id]
		if typeof(stored) ~= "table" then
			return false, `Spell "{tostring(info.name)}" is missing from its page; refusing to overwrite the library.`
		end
		data.library[id] = sanitizeSpell(info.name, stored.graph, info.savedAt)
		if typeof(info.folder) == "string" then
			data.library[id].folder = cleanName(info.folder, "Folder")
		end
	end
	if typeof(raw.folders) == "table" then
		for _, name in raw.folders do
			if typeof(name) == "string" and not table.find(data.folders, name) then
				table.insert(data.folders, cleanName(name, "Folder"))
			end
		end
	end
	-- (a spell in a folder that isn't listed: list it)
	for _, record in data.library do
		if record.folder and not table.find(data.folders, record.folder) then
			table.insert(data.folders, record.folder)
		end
	end
	data.loadout = cleanSlots(raw.loadout)
	if typeof(raw.loadouts) == "table" then
		for _, saved in raw.loadouts do
			if typeof(saved) == "table" and typeof(saved.name) == "string" then
				table.insert(data.loadouts, { name = cleanName(saved.name, "Loadout"), slots = cleanSlots(saved.slots) })
			end
		end
	end
	if typeof(raw.owned) == "table" then
		for id, value in raw.owned do
			if typeof(id) == "string" and value == true then
				data.owned[id] = true
			end
		end
	end
	local active = raw.activeSlot
	if typeof(active) == "number" and active % 1 == 0 and data.loadout[tostring(active)] then
		data.activeSlot = active
	end
	data.updatedAt = if typeof(raw.updatedAt) == "number" then raw.updatedAt else 0
	data.revision = if typeof(raw.revision) == "number" then raw.revision else 0
	return true, data
end

-- What a loadout ref points at (nil: missing, or not owned).
local function resolve(data: any, ref: string?): any?
	if not ref then
		return nil
	end
	local kind, id = string.sub(ref, 1, 1), string.sub(ref, 3)
	if kind == "c" then
		return data.library[id]
	end
	if kind == "e" and Encyclopedia.IsOwned(id, data.owned) then
		local spell = Encyclopedia.Get(id)
		return spell and spell.Record
	end
	return nil
end

local function publicState(entry: Entry)
	local data = entry.data
	local slots = {}
	for slot = 1, SLOT_COUNT do
		local ref = data.loadout[tostring(slot)]
		local record = resolve(data, ref)
		if record then
			slots[tostring(slot)] = {
				name = record.name,
				graph = copy(record.graph),
				ref = ref,
				source = if string.sub(ref, 1, 1) == "e" then "encyclopedia" else "custom",
				invalid = record.invalid,
				error = record.error,
			}
		end
	end
	local library = {}
	for id, record in data.library do
		table.insert(library, {
			id = id,
			name = record.name,
			graph = copy(record.graph),
			savedAt = record.savedAt,
			folder = record.folder,
			invalid = record.invalid,
			error = record.error,
		})
	end
	table.sort(library, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	return {
		available = entry.available,
		sessionOnly = entry.sessionOnly,
		error = entry.error,
		activeSlot = data.activeSlot,
		slots = slots,
		library = library,
		loadouts = copy(data.loadouts),
		owned = copy(data.owned),
		folders = copy(data.folders),
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
		libraryRevision = 0,
		pagesRevision = 0,
	}
	entries[player] = entry
	local ok, result
	ok, result = withRetries(function() return store:GetAsync(keyFor(player)) end)
	if entries[player] ~= entry then
		return
	end
	local data = nil
	if ok and result ~= nil then
		if typeof(result) ~= "table" then
			ok, result = false, "Stored spell book is malformed; refusing to overwrite it."
		elseif result.revision ~= nil and (typeof(result.revision) ~= "number" or result.revision ~= result.revision
			or result.revision < 0 or result.revision % 1 ~= 0 or result.revision >= 1e15) then
			ok, result = false, "Stored spell revision is malformed; refusing to overwrite it."
		elseif result.schemaVersion ~= nil and (typeof(result.schemaVersion) ~= "number"
			or result.schemaVersion % 1 ~= 0 or result.schemaVersion < 1) then
			ok, result = false, "Stored spell schema is malformed; refusing to overwrite it."
		elseif typeof(result.schemaVersion) == "number" and result.schemaVersion > SCHEMA_VERSION then
			ok, result = false, "A newer spell schema exists; this server must not overwrite it."
		elseif typeof(result.schemaVersion) == "number" and result.schemaVersion >= 4 then
			ok, result = loadV4(player, result)
			data = if ok then result else nil
		else
			if result.slots ~= nil and typeof(result.slots) ~= "table" then
				ok, result = false, "Stored spell book is malformed; refusing to overwrite it."
			elseif result.slots then
				for slot, record in result.slots do
					local index = tonumber(slot)
					if not index or index % 1 ~= 0 or index < 1 or index > SLOT_COUNT or typeof(record) ~= "table" then
						ok, result = false, "Stored spell slot is malformed; refusing to overwrite it."
						break
					end
				end
			end
			if ok then
				data = migrateLegacy(result)
			end
		end
	end
	if entries[player] ~= entry then
		return
	end
	if ok then
		entry.data = data or blankData()
		entry.persistedRevision = entry.data.revision
		entry.available = true
		-- (a converted save has no pages yet: the next save writes them)
		if next(entry.data.library) ~= nil and #entry.data.pages == 0 then
			entry.libraryRevision = 1
			entry.dirty = true
		end
	else
		entry.error = if RunService:IsStudio() then tostring(result) else "Spells could not be loaded; saving is disabled to protect existing data."
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
		return { available = false, sessionOnly = false, error = "Spell state is unavailable.", slots = {}, library = {}, loadouts = {}, owned = {}, folders = {} }
	end
	return publicState(entry)
end

-- The equipped spell's record ({ name, graph }; the same table while it's
-- unchanged, so callers may cache by it).
function SpellStore.GetActive(player: Player)
	local entry = entries[player]
	if not entry or not entry.loaded or not entry.available or not entry.data.activeSlot then
		return nil
	end
	return resolve(entry.data, entry.data.loadout[tostring(entry.data.activeSlot)])
end

-- Cast feedback only needs the slot, not the spell.
function SpellStore.GetActiveSlot(player: Player): number?
	local entry = entries[player]
	return if entry and entry.loaded and entry.available then entry.data.activeSlot else nil
end

-- The record on hotbar `slot` (nil when empty or not owned) -- what the
-- Invoke rune casts.
function SpellStore.GetSlotRecord(player: Player, slot: number): any?
	local entry = entries[player]
	if not entry or not entry.loaded or not entry.available then
		return nil
	end
	return resolve(entry.data, entry.data.loadout[tostring(slot)])
end

-- One library spell's record, for sharing (nil if missing).
function SpellStore.GetLibrarySpell(player: Player, id: string): any?
	local entry = entries[player]
	return entry and entry.available and entry.data.library[id] or nil
end

-- Packs the library's graphs into pages under `revision`'s keys and writes
-- them. Returns the keys, or nil (and why) on failure.
local function writePages(player: Player, library: { [string]: any }, revision: number): ({ string }?, string?)
	local pages: { { [string]: any } } = { {} }
	local size = 2
	local ids = {}
	for id in library do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local record = library[id]
		local stored = { graph = record.graph }
		local length = #HttpService:JSONEncode(stored) + #id + 8
		if size + length > PAGE_LIMIT and next(pages[#pages]) ~= nil then
			table.insert(pages, {})
			size = 2
		end
		pages[#pages][id] = stored
		size += length
	end
	local keys = {}
	for index, page in pages do
		local key = pageKey(player, revision, index)
		local ok, err = withRetries(function()
			return store:SetAsync(key, page)
		end)
		if not ok then
			return nil, tostring(err)
		end
		table.insert(keys, key)
	end
	return keys, nil
end

local function removePages(keys: { string })
	for _, key in keys do
		task.spawn(pcall, function()
			store:RemoveAsync(key)
		end)
	end
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
	local data = entry.data
	data.updatedAt = os.time()
	local localRevision = entry.localRevision
	local libraryRevision = entry.libraryRevision
	local expectedRevision = entry.persistedRevision
	local revision = expectedRevision + 1

	-- library pages first, under this revision's keys (only if it changed)
	local pages = data.pages
	local newPages: { string }? = nil
	if libraryRevision ~= entry.pagesRevision then
		local keys, pageError = writePages(player, copy(data.library), revision)
		if not keys then
			entry.saving = false
			entry.dirty = true
			entry.error = if RunService:IsStudio() then pageError else "Spell save failed; the in-session copy is still available."
			warn(`[SpellStore] page save failed for {player.UserId}: {tostring(pageError)}`)
			return false, entry.error
		end
		newPages = keys
		pages = keys
	end

	local index = {}
	for id, record in data.library do
		index[id] = { name = record.name, savedAt = record.savedAt, folder = record.folder }
	end
	local snapshot = {
		schemaVersion = SCHEMA_VERSION,
		revision = revision,
		saveId = HttpService:GenerateGUID(false),
		updatedAt = data.updatedAt,
		activeSlot = data.activeSlot,
		loadout = copy(data.loadout),
		loadouts = copy(data.loadouts),
		owned = copy(data.owned),
		folders = copy(data.folders),
		index = index,
		pages = copy(pages),
	}
	local ok, result = withRetries(function()
		return store:UpdateAsync(keyFor(player), function(old)
			if old ~= nil and typeof(old) ~= "table" then return nil end
			-- Idempotent retry if the first write succeeded but its response
			-- failed. Otherwise reject an older server overwriting a new one.
			if typeof(old) == "table" and old.saveId == snapshot.saveId then return old end
			if typeof(old) == "table" and typeof(old.schemaVersion) == "number" and old.schemaVersion > SCHEMA_VERSION then return nil end
			local stored = typeof(old) == "table" and old.revision or 0
			if stored ~= expectedRevision then return nil end
			return snapshot
		end)
	end)
	entry.saving = false
	if ok and typeof(result) == "table" then
		entry.persistedRevision = revision
		data.revision = revision
		if newPages then
			removePages(data.pages) -- (the previous save's pages)
			data.pages = newPages
			entry.pagesRevision = libraryRevision
		end
		entry.dirty = entry.localRevision ~= localRevision or entry.libraryRevision ~= entry.pagesRevision
		entry.error = nil
		return true, nil
	end
	if newPages then
		removePages(newPages) -- (never referenced: this save didn't land)
	end
	entry.dirty = true
	entry.error = if ok then "Spells changed in another session. Rejoin before saving; no stored data was overwritten."
		else "Spell save failed; the in-session copy is still available."
	if RunService:IsStudio() and not ok then entry.error = tostring(result) end
	if ok then entry.available = false end
	warn(`[SpellStore] save failed for {player.UserId}: {tostring(result)}`)
	return false, entry.error
end

--------------------------------------------------------------------------------
-- Changes
--------------------------------------------------------------------------------

local function ready(player: Player): (Entry?, string?)
	local entry = entries[player]
	if not entry or not entry.loaded or not entry.available then
		return nil, entry and entry.error or "Spell data has not loaded."
	end
	if entry.saving then
		return nil, "A spell save is already in progress."
	end
	return entry, nil
end

local function validSlot(slot: any): boolean
	return typeof(slot) == "number" and slot % 1 == 0 and slot >= 1 and slot <= SLOT_COUNT
end

-- A library change: saved right away.
local function libraryChanged(player: Player, entry: Entry)
	entry.libraryRevision += 1
	entry.localRevision += 1
	entry.dirty = true
	local ok, err = SpellStore.Save(player)
	return ok, err, publicState(entry)
end

-- A loadout / selection change: authoritative in the server cache at once;
-- persisted shortly after (coalesced), with the autosave / leave / shutdown
-- flush as backstops.
local function selectionChanged(player: Player, entry: Entry)
	entry.localRevision += 1
	entry.dirty = true
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

local function compileOrError(graph: any): (any?, string?)
	local compiled, errors, normalized = SpellCompiler.Compile(graph)
	if not compiled then
		return nil, errors[1] and errors[1].message or "Invalid spell graph."
	end
	return normalized, nil
end

-- Saves a library spell: `id` overwrites that one, nil adds a new one.
-- Returns ok, error, state, id.
function SpellStore.SaveSpell(player: Player, id: string?, name: string, graph: any)
	local entry, err = ready(player)
	if not entry then return false, err end
	if id ~= nil and not entry.data.library[id] then
		return false, "That spell isn't in your library any more."
	end
	local normalized, compileError = compileOrError(graph)
	if not normalized then return false, compileError end
	local spellId = id or newId()
	normalized.name = name
	local previous = entry.data.library[spellId]
	entry.data.library[spellId] = { name = name, graph = copy(normalized), savedAt = os.time(), folder = previous and previous.folder }
	local ok, saveError, state = libraryChanged(player, entry)
	return ok, saveError, state, spellId
end

-- The editor's "save to slot": overwrites the library spell in that slot
-- (or adds a new one there when the slot is empty or holds an Encyclopedia
-- spell).
function SpellStore.PutSlot(player: Player, slot: number, name: string, graph: any)
	local entry, err = ready(player)
	if not entry then return false, err end
	if not validSlot(slot) then return false, `Slot must be from 1 to {SLOT_COUNT}.` end
	local ref = entry.data.loadout[tostring(slot)]
	local id = if ref and string.sub(ref, 1, 2) == "c:" and entry.data.library[string.sub(ref, 3)] then string.sub(ref, 3) else nil
	local normalized, compileError = compileOrError(graph)
	if not normalized then return false, compileError end
	local spellId: string = id or newId()
	normalized.name = name
	local previous = entry.data.library[spellId]
	entry.data.library[spellId] = { name = name, graph = copy(normalized), savedAt = os.time(), folder = previous and previous.folder }
	entry.data.loadout[tostring(slot)] = "c:" .. spellId
	return libraryChanged(player, entry)
end

-- Takes a spell off a hotbar slot (it stays in the library).
function SpellStore.DeleteSlot(player: Player, slot: number)
	local entry, err = ready(player)
	if not entry then return false, err end
	if not validSlot(slot) then return false, `Slot must be from 1 to {SLOT_COUNT}.` end
	entry.data.loadout[tostring(slot)] = nil
	if entry.data.activeSlot == slot then
		entry.data.activeSlot = nil
	end
	return selectionChanged(player, entry)
end

-- Deletes a library spell for good (and takes it off the hotbar).
function SpellStore.DeleteSpell(player: Player, id: string)
	local entry, err = ready(player)
	if not entry then return false, err end
	if not entry.data.library[id] then return false, "That spell isn't in your library." end
	entry.data.library[id] = nil
	for slot = 1, SLOT_COUNT do
		if entry.data.loadout[tostring(slot)] == "c:" .. id then
			entry.data.loadout[tostring(slot)] = nil
			if entry.data.activeSlot == slot then
				entry.data.activeSlot = nil
			end
		end
	end
	return libraryChanged(player, entry)
end

-- Puts a spell (a ref: "c:<id>" or "e:<id>") on a hotbar slot.
function SpellStore.Equip(player: Player, slot: number, ref: string)
	local entry, err = ready(player)
	if not entry then return false, err end
	if not validSlot(slot) then return false, `Slot must be from 1 to {SLOT_COUNT}.` end
	if not validRef(ref) then return false, "Unknown spell." end
	local record = resolve(entry.data, ref)
	if not record then
		return false, if string.sub(ref, 1, 1) == "e" then "You don't own that spell yet." else "That spell isn't in your library."
	end
	if record.invalid then return false, "This spell no longer compiles; edit it first." end
	-- (one spell, one slot: equipping it elsewhere moves it)
	for other = 1, SLOT_COUNT do
		if other ~= slot and entry.data.loadout[tostring(other)] == ref then
			entry.data.loadout[tostring(other)] = nil
			if entry.data.activeSlot == other then
				entry.data.activeSlot = slot
			end
		end
	end
	entry.data.loadout[tostring(slot)] = ref
	return selectionChanged(player, entry)
end

-- Swaps two hotbar slots (either may be empty); the selection follows its
-- spell.
function SpellStore.SwapSlots(player: Player, a: number, b: number)
	local entry, err = ready(player)
	if not entry then return false, err end
	if not validSlot(a) or not validSlot(b) or a == b then return false, "Pick two different slots." end
	local loadout = entry.data.loadout
	loadout[tostring(a)], loadout[tostring(b)] = loadout[tostring(b)], loadout[tostring(a)]
	if entry.data.activeSlot == a then
		entry.data.activeSlot = b
	elseif entry.data.activeSlot == b then
		entry.data.activeSlot = a
	end
	return selectionChanged(player, entry)
end

local MAX_FOLDERS = 200

function SpellStore.CreateFolder(player: Player, name: string)
	local entry, err = ready(player)
	if not entry then return false, err end
	for _, existing in entry.data.folders do
		if existing:lower() == name:lower() then return false, "You already have a folder by that name." end
	end
	if #entry.data.folders >= MAX_FOLDERS then return false, `You can have up to {MAX_FOLDERS} folders.` end
	table.insert(entry.data.folders, name)
	return selectionChanged(player, entry)
end

-- Deletes a folder; its spells become unfiled (they're kept).
function SpellStore.DeleteFolder(player: Player, name: string)
	local entry, err = ready(player)
	if not entry then return false, err end
	local index = table.find(entry.data.folders, name)
	if not index then return false, "No folder by that name." end
	table.remove(entry.data.folders, index)
	for _, record in entry.data.library do
		if record.folder == name then
			record.folder = nil
		end
	end
	return selectionChanged(player, entry)
end

-- Files a library spell in a folder (nil: unfiled). Only the main record
-- changes, so no pages are rewritten.
function SpellStore.MoveToFolder(player: Player, id: string, folder: string?)
	local entry, err = ready(player)
	if not entry then return false, err end
	local record = entry.data.library[id]
	if not record then return false, "That spell isn't in your library." end
	if folder ~= nil and not table.find(entry.data.folders, folder) then return false, "No folder by that name." end
	record.folder = folder
	return selectionChanged(player, entry)
end

-- Swaps a hotbar slot with its neighbour (direction -1 / 1); the selection
-- follows its spell.
function SpellStore.MoveSlot(player: Player, slot: number, direction: number)
	local entry, err = ready(player)
	if not entry then return false, err end
	local other = slot + (if direction < 0 then -1 else 1)
	if not validSlot(slot) or not validSlot(other) then return false, "Can't move that way." end
	local loadout = entry.data.loadout
	loadout[tostring(slot)], loadout[tostring(other)] = loadout[tostring(other)], loadout[tostring(slot)]
	if entry.data.activeSlot == slot then
		entry.data.activeSlot = other
	elseif entry.data.activeSlot == other then
		entry.data.activeSlot = slot
	end
	return selectionChanged(player, entry)
end

-- nil deselects (no spell equipped).
function SpellStore.SetActive(player: Player, slot: number?)
	local entry, err = ready(player)
	if not entry then return false, err end
	if slot ~= nil then
		if not validSlot(slot) then return false, "That spell card does not exist." end
		local record = resolve(entry.data, entry.data.loadout[tostring(slot)])
		if not record then return false, "That spell card does not exist." end
		if record.invalid then return false, "This saved spell no longer compiles; its original graph has been preserved." end
	end
	entry.data.activeSlot = slot
	return selectionChanged(player, entry)
end

local function findLoadout(data: any, name: string): number?
	for index, saved in data.loadouts do
		if saved.name:lower() == name:lower() then
			return index
		end
	end
	return nil
end

-- Saves the current hotbar as a named loadout (replacing one of that name).
function SpellStore.SaveLoadout(player: Player, name: string)
	local entry, err = ready(player)
	if not entry then return false, err end
	local index = findLoadout(entry.data, name)
	local saved = { name = name, slots = copy(entry.data.loadout) }
	if index then
		entry.data.loadouts[index] = saved
	else
		if #entry.data.loadouts >= MAX_LOADOUTS then
			return false, `You can save up to {MAX_LOADOUTS} loadouts.`
		end
		table.insert(entry.data.loadouts, saved)
	end
	return selectionChanged(player, entry)
end

-- Puts a saved loadout on the hotbar (skipping spells no longer available).
function SpellStore.LoadLoadout(player: Player, name: string)
	local entry, err = ready(player)
	if not entry then return false, err end
	local index = findLoadout(entry.data, name)
	if not index then return false, "No loadout by that name." end
	local loadout = {}
	for slot, ref in entry.data.loadouts[index].slots do
		local record = resolve(entry.data, ref)
		if record and not record.invalid then
			loadout[slot] = ref
		end
	end
	entry.data.loadout = loadout
	if entry.data.activeSlot and not loadout[tostring(entry.data.activeSlot)] then
		entry.data.activeSlot = nil
	end
	return selectionChanged(player, entry)
end

function SpellStore.DeleteLoadout(player: Player, name: string)
	local entry, err = ready(player)
	if not entry then return false, err end
	local index = findLoadout(entry.data, name)
	if not index then return false, "No loadout by that name." end
	table.remove(entry.data.loadouts, index)
	return selectionChanged(player, entry)
end

-- Encyclopedia purchase (placeholder: free entries are already owned; paid
-- ones aren't for sale yet).
function SpellStore.Purchase(player: Player, id: string)
	local entry, err = ready(player)
	if not entry then return false, err end
	local spell = Encyclopedia.Get(id)
	if not spell then return false, "Unknown spell." end
	if Encyclopedia.IsOwned(id, entry.data.owned) then return true, "You already have it.", publicState(entry) end
	return false, "Purchases aren't available yet."
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
