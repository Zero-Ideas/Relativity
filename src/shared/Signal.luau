--!optimize 2
--[[
	Signal.luau
	A lightweight, allocation-friendly signal used across the framework for
	entity events (Damaged, Died, ...), hitbox hits, and anything else that
	needs an event without a BindableEvent round-trip.

	API:
	 Signal.new() -> Signal
	 signal:Connect(fn) -> Connection      (Connection has :Disconnect())
	 signal:Once(fn) -> Connection
	 signal:Wait() -> ...                   (yields the calling coroutine)
	 signal:Fire(...)
	 signal:DisconnectAll()
	 signal:Destroy()

	Handlers are dispatched on fresh threads (task.spawn) so a throwing or
	yielding listener never blocks or breaks :Fire() for the others.
]]

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false
	local connections = self._signal._connections
	local index = table.find(connections, self)
	if index then
		local n = #connections
		connections[index] = connections[n]
		connections[n] = nil
	end
end
Connection.Destroy = Connection.Disconnect

function Signal.new()
	return setmetatable({ _connections = {} }, Signal)
end

function Signal:Connect(fn: (...any) -> ())
	local connection = setmetatable({
		Connected = true,
		_signal = self,
		_fn = fn,
	}, Connection)
	table.insert(self._connections, connection)
	return connection
end

function Signal:Once(fn: (...any) -> ())
	local connection
	connection = self:Connect(function(...)
		if connection.Connected then
			connection:Disconnect()
		end
		fn(...)
	end)
	return connection
end

function Signal:Wait(): ...any
	local thread = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:Fire(...)
	-- Iterate over a snapshot so listeners may disconnect (or the signal be
	-- destroyed) mid-dispatch without corrupting the loop.
	local connections = self._connections
	for i = #connections, 1, -1 do
		local connection = connections[i]
		if connection and connection.Connected then
			task.spawn(connection._fn, ...)
		end
	end
end

function Signal:DisconnectAll()
	for _, connection in self._connections do
		connection.Connected = false
	end
	table.clear(self._connections)
end

function Signal:Destroy()
	self:DisconnectAll()
end

return Signal
