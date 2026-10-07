--!strict
--[[
	DebugStream (server, Studio only)
	Streams debug data to a local WebSocket receiver (tools/stats_server.py,
	ws://127.0.0.1:8765), which writes it to logs/stream.jsonl and
	logs/latest.json: DebugService's stats snapshot every stats interval, and
	every server log line (print / warn / error). Connects only in Studio with
	HTTP requests enabled, and quietly retries while no receiver is running.

	DebugStream.Send(kind, data)   -- sends { kind = kind, time = ..., ...data }
	DebugStream.IsConnected() -> boolean
	DebugStream.OnCommand(name, fn) -- the receiver can send { cmd = name, ... }
	                                -- (tools/send_command.py): fn(message)
]]

local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local RunService = game:GetService("RunService")

local DebugStream = {}

local URL = "ws://127.0.0.1:8765"
local RETRY_SECONDS = 5

local client: any = nil
local connected = false
local commands: { [string]: (any) -> () } = {}

function DebugStream.OnCommand(name: string, handler: (any) -> ())
	commands[name] = handler
end

local function connect()
	if client then
		return
	end
	local ok, created = pcall(function()
		return HttpService:CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, { Url = URL })
	end)
	if not ok or not created then
		return
	end
	client = created
	created.Opened:Connect(function()
		connected = true
	end)
	local function lost()
		if client == created then
			client, connected = nil, false
		end
	end
	created.Closed:Connect(lost)
	created.Error:Connect(lost)
	created.MessageReceived:Connect(function(raw: string)
		local ok, message = pcall(HttpService.JSONDecode, HttpService, raw)
		local handler = ok and typeof(message) == "table" and commands[message.cmd]
		if handler then
			task.spawn(function()
				local done, err = pcall(handler, message)
				DebugStream.Send("ack", { cmd = message.cmd, ok = done, error = if done then nil else tostring(err) })
			end)
		end
	end)
end

function DebugStream.IsConnected(): boolean
	return connected
end

function DebugStream.Send(kind: string, data: { [string]: any }?)
	if not connected or not client then
		return
	end
	local message = if data then table.clone(data) else {}
	message.kind = kind
	message.serverTime = workspace:GetServerTimeNow()
	message.clock = os.clock()
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, message)
	if ok then
		pcall(function()
			client:Send(encoded)
		end)
	end
end

if RunService:IsStudio() and HttpService.HttpEnabled then
	task.spawn(function()
		while true do
			if not client then
				connect()
			end
			task.wait(RETRY_SECONDS)
		end
	end)
	LogService.MessageOut:Connect(function(message, messageType)
		DebugStream.Send("log", { text = message, level = messageType.Name })
	end)
end

return DebugStream
