--!strict
--[[
	Saves each player's client settings (client/ClientSettings: the Settings
	window) in a DataStore, so they follow the player between sessions.

	RemoteFunction "ClientSettings" (ReplicatedStorage):
	  ("Get")         -> the saved settings (only known keys)
	  ("Set", values) -> saves the known keys among `values` (numbers clamped
	                     to their range, booleans as they are)
	Saves are coalesced (SAVE_DELAY) and flushed when the player leaves.
	Without DataStore access (e.g. Studio without API access) settings last
	for the session only.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SAVE_DELAY = 3

-- known settings: { min, max } for numbers, "boolean" for toggles, a list
-- of strings for a choice
local SCHEMA: { [string]: any } = {
	MaxDistance = { 50, 10000 },
	MaxRendered = { 0, 50000 },
	MaxSmooth = { 0, 5000 },
	MaxUpdates = { 100, 20000 },
	Glints = "boolean",
	UiMode = { "Mode 1", "Mode 2" }, -- (a choice)
	HudScale = { 70, 130 },
	EffectsIntensity = { 0, 100 },
	ReducedFlashes = "boolean",
	CameraShake = { 0, 100 },
	MasterVolume = { 0, 100 },
	SpellVolume = { 0, 100 },
	ImpactVolume = { 0, 100 },
	UiVolume = { 0, 100 },
	MusicVolume = { 0, 100 },
}

local store: DataStore? = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore("ClientSettings_v1")
	end)
	store = if ok then result else nil
end

local remote = Instance.new("RemoteFunction")
remote.Name = "ClientSettings"
remote.Parent = ReplicatedStorage

local settings: { [Player]: { [string]: any } } = {}
local loaded: { [Player]: boolean } = {}
local saveQueued: { [Player]: boolean } = {}

local function clean(values: any): { [string]: any }
	local result = {}
	if typeof(values) ~= "table" then
		return result
	end
	for key, rule in SCHEMA do
		local value = values[key]
		if rule == "boolean" then
			if typeof(value) == "boolean" then
				result[key] = value
			end
		elseif typeof(rule[1]) == "string" then
			if typeof(value) == "string" and table.find(rule, value) then
				result[key] = value
			end
		elseif typeof(value) == "number" and value == value then
			result[key] = math.clamp(value, rule[1], rule[2])
		end
	end
	return result
end

local function key(player: Player): string
	return `user_{player.UserId}`
end

local function save(player: Player)
	local values = settings[player]
	if not store or not values then
		return
	end
	pcall(function()
		(store :: DataStore):SetAsync(key(player), values)
	end)
end

local function load(player: Player)
	local values = {}
	if store then
		local ok, data = pcall(function()
			return (store :: DataStore):GetAsync(key(player))
		end)
		if ok then
			values = clean(data)
		end
	end
	if player.Parent == Players then
		-- (anything set before the load finished wins)
		for name, value in settings[player] or {} do
			values[name] = value
		end
		settings[player] = values
		loaded[player] = true
	end
end

remote.OnServerInvoke = function(player: Player, action: any, values: any): any
	if action == "Get" then
		local started = os.clock()
		while not loaded[player] and os.clock() - started < 10 and player.Parent do
			task.wait(0.1)
		end
		return table.clone(settings[player] or {})
	elseif action == "Set" then
		local current = settings[player] or {}
		settings[player] = current
		for name, value in clean(values) do
			current[name] = value
		end
		if not saveQueued[player] then
			saveQueued[player] = true
			task.delay(SAVE_DELAY, function()
				saveQueued[player] = nil
				if player.Parent == Players then
					save(player)
				end
			end)
		end
		return table.clone(current)
	end
	return nil
end

Players.PlayerAdded:Connect(load)
for _, player in Players:GetPlayers() do
	task.spawn(load, player)
end
Players.PlayerRemoving:Connect(function(player)
	save(player)
	settings[player], loaded[player], saveQueued[player] = nil, nil, nil
end)
