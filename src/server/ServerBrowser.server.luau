--!strict
--[[
	Server browser: every live server publishes itself -- JobId, region
	(ServerRegion), player count and capacity -- to a shared MemoryStore
	sorted map, refreshed every PUBLISH_INTERVAL and expiring EXPIRY seconds
	after its last refresh, so dead servers drop out on their own. (A
	MemoryStore rather than a DataStore: it's meant for fast-changing shared
	state like this, and doesn't eat DataStore write limits.)

	RemoteFunction "ServerBrowser" (ReplicatedStorage):
	  ("List")          -> { Servers = { { JobId, Region, Players, MaxPlayers,
	                         Current } }, Studio = boolean }
	  ("Join", jobId)   -> { Ok, Message? }  teleports you to that server
	  ("JoinRegion", region) -> { Ok, Message? }  the busiest other server
	                       in that region that isn't full
	Studio play sessions and private / reserved servers don't publish, and
	teleports don't work in Studio.
]]

local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local PUBLISH_INTERVAL = 15
local EXPIRY = 60
local LIST_CACHE = 5 -- seconds a fetched list is reused
local MAX_LISTED = 200
local JOIN_INTERVAL = 3

local map: MemoryStoreSortedMap? = nil
do
	local ok, result = pcall(function()
		return MemoryStoreService:GetSortedMap("ServerBrowser_v1")
	end)
	map = if ok then result else nil
end

local studio = RunService:IsStudio()
local publishes = game.JobId ~= "" and game.PrivateServerId == "" and not studio

local remote = Instance.new("RemoteFunction")
remote.Name = "ServerBrowser"
remote.Parent = ReplicatedStorage

local function region(): string
	local value = ReplicatedStorage:GetAttribute("ServerRegion")
	return if typeof(value) == "string" then value else "Unknown"
end

local function publish()
	if not map or not publishes then return end
	local entry = {
		Region = region(),
		Players = #Players:GetPlayers(),
		MaxPlayers = Players.MaxPlayers,
		Updated = os.time(),
	}
	pcall(function()
		(map :: MemoryStoreSortedMap):SetAsync(game.JobId, entry, EXPIRY)
	end)
end

if publishes then
	task.spawn(function()
		while true do
			publish()
			task.wait(PUBLISH_INTERVAL)
		end
	end)
	-- (counts change: publish soon after joins / leaves, not just on the timer)
	local pending = false
	local function soon()
		if pending then return end
		pending = true
		task.delay(2, function()
			pending = false
			publish()
		end)
	end
	Players.PlayerAdded:Connect(soon)
	Players.PlayerRemoving:Connect(soon)
	ReplicatedStorage:GetAttributeChangedSignal("ServerRegion"):Connect(soon)
	game:BindToClose(function()
		if map then
			pcall(function()
				(map :: MemoryStoreSortedMap):RemoveAsync(game.JobId)
			end)
		end
	end)
end

type Server = { JobId: string, Region: string, Players: number, MaxPlayers: number, Current: boolean }
local cached: { Server }? = nil
local cachedAt = 0

local function fetch(): { Server }
	if cached and os.clock() - cachedAt < LIST_CACHE then
		return cached
	end
	local servers: { Server } = {}
	if map then
		local ok, items = pcall(function()
			return (map :: MemoryStoreSortedMap):GetRangeAsync(Enum.SortDirection.Ascending, MAX_LISTED)
		end)
		if ok and items then
			for _, item in items do
				local value = item.value
				if typeof(value) == "table" then
					table.insert(servers, {
						JobId = item.key,
						Region = tostring(value.Region or "Unknown"),
						Players = tonumber(value.Players) or 0,
						MaxPlayers = tonumber(value.MaxPlayers) or 0,
						Current = item.key == game.JobId,
					})
				end
			end
		end
	end
	table.sort(servers, function(a, b)
		if a.Region ~= b.Region then
			return a.Region < b.Region
		end
		return a.Players > b.Players
	end)
	cached, cachedAt = servers, os.clock()
	return servers
end

local lastJoin: { [Player]: number } = {}

local function teleport(player: Player, jobId: string): (boolean, string?)
	if studio then
		return false, "Teleports don't work in Studio."
	end
	if jobId == game.JobId then
		return false, "You're already in that server."
	end
	local now = os.clock()
	if lastJoin[player] and now - lastJoin[player] < JOIN_INTERVAL then
		return false, "Please wait a moment."
	end
	lastJoin[player] = now
	local options = Instance.new("TeleportOptions")
	options.ServerInstanceId = jobId
	local ok, err = pcall(TeleportService.TeleportAsync, TeleportService, game.PlaceId, { player }, options)
	if not ok then
		return false, `Couldn't join: {tostring(err)}`
	end
	return true, nil
end

remote.OnServerInvoke = function(player: Player, action: any, a: any): any
	if action == "List" then
		return { Servers = fetch(), Studio = studio }
	elseif action == "Join" then
		if typeof(a) ~= "string" then
			return { Ok = false, Message = "Pick a server." }
		end
		for _, server in fetch() do
			if server.JobId == a then
				if server.MaxPlayers > 0 and server.Players >= server.MaxPlayers then
					return { Ok = false, Message = "That server is full." }
				end
				local ok, message = teleport(player, a)
				return { Ok = ok, Message = message }
			end
		end
		return { Ok = false, Message = "That server isn't listed any more." }
	elseif action == "JoinRegion" then
		if typeof(a) ~= "string" then
			return { Ok = false, Message = "Pick a region." }
		end
		-- the busiest other server there that still has room
		local best: Server? = nil
		for _, server in fetch() do
			local full = server.MaxPlayers > 0 and server.Players >= server.MaxPlayers
			if server.Region == a and not server.Current and not full then
				if not best or server.Players > best.Players then
					best = server
				end
			end
		end
		if not best then
			return { Ok = false, Message = `No other open server in {a}.` }
		end
		local ok, message = teleport(player, best.JobId)
		return { Ok = ok, Message = message }
	end
	return nil
end

Players.PlayerRemoving:Connect(function(player)
	lastJoin[player] = nil
end)
