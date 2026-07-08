--!optimize 2
--[[
	Heartbeat.luau
	The heart of Relativity's time model. A single RunService.Heartbeat
	connection drives every system in the game. Each frame the real delta is
	multiplied by a global time scale (SetGlobalTimeScale) and then, per
	connection, by that connection's own TimeScale — so every system runs in
	its own flow of time and the whole world can be slowed, sped up, or frozen
	at once.

	    dilatedDt = realDt * globalTimeScale * connection.TimeScale

	Callbacks receive that dilated dt. Higher-level systems (Entity, Hitbox,
	Projectile) multiply it further by a chunk-local scale (see ChunkManager),
	giving per-region time dilation for free.

	Priority: connections run in ascending Priority order (more-negative first),
	so a system at Priority -100 resolves before one at 0. This lets, e.g.,
	chunk load state settle before entity updates read it.

	API:
	 Heartbeat.Connect(fn(dt, connection), options?) -> Connection
	 Heartbeat.ConnectInterval(interval, fn(elapsed, connection), options?) -> Connection
	 Heartbeat.Delay(seconds, fn(elapsed)) -> Connection      (dilated one-shot)
	 Heartbeat.Wait(seconds) -> elapsed                        (yields in dilated time)
	 Heartbeat.SetGlobalTimeScale(scale) / GetGlobalTimeScale() -> number
	 Heartbeat.GetStats() -> { ConnectionCount, GlobalTimeScale, AvgFrameTime }
	 Heartbeat.GetConnections() -> { Connection }

	 options: { Name?, Priority? = 0, TimeScale? = 1 }
	 Connection fields: Name, Priority, TimeScale, LocalTime, Connected
	 Connection methods: :Disconnect()
]]

local RunService = game:GetService("RunService")

local Heartbeat = {}

local connections = {} -- priority-sorted (ascending) array of Connection
local globalTimeScale = 1
local needsSort = false

-- rolling average of per-frame cost (seconds) over a fixed window
local WINDOW = 60
local frameSamples = table.create(WINDOW, 0)
local frameCostSum = 0
local sampleCursor = 1
local sampleCount = 0

--------------------------------------------------------------------------------
-- Connection
--------------------------------------------------------------------------------

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false
	local index = table.find(connections, self)
	if index then
		table.remove(connections, index) -- preserve sorted order
	end
end
Connection.Destroy = Connection.Disconnect

local function makeConnection(fn: (number, any) -> (), options)
	options = options or {}
	local connection = setmetatable({
		Connected = true,
		Callback = fn,
		Name = options.Name or "Anonymous",
		Priority = options.Priority or 0,
		TimeScale = math.max(options.TimeScale or 1, 0),
		LocalTime = 0,
		_isInterval = false,
		_interval = 0,
		_accumulator = 0,
	}, Connection)
	table.insert(connections, connection)
	needsSort = true
	return connection
end

--------------------------------------------------------------------------------
-- Public registration
--------------------------------------------------------------------------------

function Heartbeat.Connect(fn: (dt: number, connection: any) -> (), options: any?)
	return makeConnection(fn, options)
end

-- Fires roughly every `interval` dilated seconds. The callback receives the
-- accumulated dilated time since it last fired (usually ~= interval).
function Heartbeat.ConnectInterval(interval: number, fn: (elapsed: number, connection: any) -> (), options: any?)
	local connection = makeConnection(fn, options)
	connection._isInterval = true
	connection._interval = math.max(interval, 0)
	return connection
end

-- One-shot after `seconds` dilated seconds. Stretches automatically when time
-- is slowed globally or by the connection's TimeScale.
function Heartbeat.Delay(seconds: number, fn: (elapsed: number) -> (), options: any?)
	local elapsed = 0
	return Heartbeat.Connect(function(dt, connection)
		elapsed += dt
		if elapsed >= seconds then
			connection:Disconnect()
			fn(elapsed)
		end
	end, options or { Name = "Heartbeat.Delay" })
end

-- Yields the calling coroutine for `seconds` dilated seconds.
function Heartbeat.Wait(seconds: number?): number
	local thread = coroutine.running()
	Heartbeat.Delay(seconds or 0, function(elapsed)
		task.spawn(thread, elapsed)
	end)
	return coroutine.yield()
end

--------------------------------------------------------------------------------
-- Global time scale
--------------------------------------------------------------------------------

function Heartbeat.SetGlobalTimeScale(scale: number)
	globalTimeScale = math.max(scale or 1, 0)
end

function Heartbeat.GetGlobalTimeScale(): number
	return globalTimeScale
end

--------------------------------------------------------------------------------
-- Introspection
--------------------------------------------------------------------------------

function Heartbeat.GetStats()
	return {
		ConnectionCount = #connections,
		GlobalTimeScale = globalTimeScale,
		AvgFrameTime = sampleCount > 0 and frameCostSum / sampleCount or 0,
	}
end

function Heartbeat.GetConnections()
	return table.clone(connections)
end

--------------------------------------------------------------------------------
-- The one true loop
--------------------------------------------------------------------------------

local function step(realDt: number)
	if needsSort then
		table.sort(connections, function(a, b)
			return a.Priority < b.Priority
		end)
		needsSort = false
	end

	local startClock = os.clock()
	local globalDt = realDt * globalTimeScale

	-- Snapshot so a callback may connect/disconnect during the frame without
	-- skipping or double-running siblings. New connections run next frame.
	local snapshot = table.clone(connections)
	for i = 1, #snapshot do
		local connection = snapshot[i]
		if connection.Connected then
			local dilatedDt = globalDt * connection.TimeScale
			connection.LocalTime += dilatedDt

			if connection._isInterval then
				connection._accumulator += dilatedDt
				if connection._accumulator >= connection._interval then
					local elapsed = connection._accumulator
					connection._accumulator = 0
					local ok, err = pcall(connection.Callback, elapsed, connection)
					if not ok then
						warn(`[Heartbeat] "{connection.Name}" errored: {err}`)
					end
				end
			else
				local ok, err = pcall(connection.Callback, dilatedDt, connection)
				if not ok then
					warn(`[Heartbeat] "{connection.Name}" errored: {err}`)
				end
			end
		end
	end

	-- rolling frame-cost stats
	local cost = os.clock() - startClock
	frameCostSum -= frameSamples[sampleCursor]
	frameSamples[sampleCursor] = cost
	frameCostSum += cost
	sampleCursor = sampleCursor % WINDOW + 1
	sampleCount = math.min(sampleCount + 1, WINDOW)
end

RunService.Heartbeat:Connect(step)

return Heartbeat
