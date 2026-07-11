--!optimize 2
--[[
	VisualOffload.luau
	A thin publish/subscribe layer over a single RemoteEvent. The server stays
	authoritative over simulation but offloads *cosmetic* work to clients:
	 - ChunkManager mirrors chunk + global time scales so client-side visual
	   simulation dilates identically to the server.
	 - Projectile streams spawn/hit events so clients render tracers instead of
	   the server replicating a moving part per bullet.

	Messages are addressed by a string channel. Handlers registered with :On
	fire for every message on that channel.

	API:
	 VisualOffload.Fire(channel, payload)            -- server -> all clients (or client -> server)
	 VisualOffload.FireClient(player, channel, payload)   -- server only
	 VisualOffload.On(channel, handler) -> { Disconnect }
	     server handler: handler(payload, player)
	     client handler: handler(payload)
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local REMOTE_NAME = "VisualOffloadRemote"

local VisualOffload = {}

local handlers: { [string]: { (any, any?) -> () } } = {}
local remote: RemoteEvent? = nil
local listening = false

local function getRemote(): RemoteEvent
	if remote then
		return remote
	end
	if RunService:IsServer() then
		local existing = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
		if existing and existing:IsA("RemoteEvent") then
			remote = existing
		else
			local created = Instance.new("RemoteEvent")
			created.Name = REMOTE_NAME
			created.Parent = ReplicatedStorage
			remote = created
		end
	else
		remote = ReplicatedStorage:WaitForChild(REMOTE_NAME) :: RemoteEvent
	end
	return remote :: RemoteEvent
end

local function dispatch(channel: string, payload: any, player: Player?)
	local list = handlers[channel]
	if not list then
		return
	end
	for _, fn in list do
		task.spawn(fn, payload, player)
	end
end

local function ensureListening()
	if listening then
		return
	end
	listening = true
	local r = getRemote()
	if RunService:IsServer() then
		r.OnServerEvent:Connect(function(player, channel, payload)
			if typeof(channel) == "string" then
				dispatch(channel, payload, player)
			end
		end)
	else
		r.OnClientEvent:Connect(function(channel, payload)
			if typeof(channel) == "string" then
				dispatch(channel, payload)
			end
		end)
	end
end

function VisualOffload.Fire(channel: string, payload: any?)
	
	local r = getRemote()
	if RunService:IsServer() then
		r:FireAllClients(channel, payload)
	else
		r:FireServer(channel, payload)
	end
end

function VisualOffload.FireClient(player: Player, channel: string, payload: any?)
	assert(RunService:IsServer(), "VisualOffload.FireClient is server-only")
	getRemote():FireClient(player, channel, payload)
	print("Fired",payload)
end

function VisualOffload.On(channel: string, handler: (any, any?) -> ())
	ensureListening()
	local list = handlers[channel]
	if not list then
		list = {}
		handlers[channel] = list
	end
	table.insert(list, handler)
	return {
		Disconnect = function()
			local index = table.find(list, handler)
			if index then
				table.remove(list, index)
			end
		end,
	}
end

return VisualOffload
