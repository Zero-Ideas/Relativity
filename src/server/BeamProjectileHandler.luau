--!strict
-- Beam-specific launch/channel policy. Physics and damage events still use
-- Projectile's authoritative swept-radius pipeline; there is no second ray
-- simulation racing it. One bounded loop owns all channel state.
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage").Shared
local Heartbeat = require(Shared.Heartbeat)
local ChunkManager = require(Shared.ChunkManager)
local Projectile = require(script.Parent.Projectile)
local BeamPath = require(Shared.BeamPath)

local Handler = {}
Handler.Interval = 1 / 30
local INPUT_TIMEOUT = .75
local MAX_PACKETS_PER_CHANNEL_FRAME = 2
local MAX_CHANNELS_PER_PLAYER = 32
local channels: { any } = {}
local lastInput: { [Player]: number } = {}
local nextChannelId = 0
local streams: { [number]: any } = {}

function Handler.Launch(config: any): any
	local beamConfig = table.clone(config)
	beamConfig.Beam = table.clone(config.Beam or {})
	local id = beamConfig.Beam.ChannelId
	local stream = id and streams[id]
	if id and not stream then stream = { nodes = {}, last = nil }; streams[id] = stream end
	local previous = stream and stream.last
	if previous then beamConfig.Beam.PreviousId = previous.projectile.Id end
	-- No vessel-imposed range: normal lifetime/real-lifetime safety bounds
	-- apply, as they do for every other flying projectile.
	local p = Projectile.new(beamConfig)
	if stream then
		p._beamPrevious = previous and previous.projectile
		local node = { projectile = p, previous = previous, position = p.Position }
		table.insert(stream.nodes, node)
		stream.last = node
		p.OnDestroy:Connect(function(info)
			-- Keep the exact stopped front as the end of the next linked span.
			-- It must not join to a predicted point behind/through the surface.
			node.position = info.Position
			p.Position = info.Position
		end)
	end
	return p
end

Projectile.SetBeamSpanStep(function(globalDt: number)
	for id, stream in streams do
		local living = false
		for _, node in stream.nodes do
			local p = node.projectile
			if p.Dead then continue end
			living = true
			node.position = p.Position
		end
		if not living then streams[id] = nil; continue end
		if globalDt <= 0 then continue end
		-- Front to back: contact/bounce corrections are available before a
		-- younger section queries its older front. Work touches beam nodes only,
		-- never scans the 10k ordinary projectile stress-test population.
		for _, node in stream.nodes do
			local p, previous = node.projectile, node.previous
			if p.Dead or not previous then continue end
			local front = previous.projectile
			local points = BeamPath.Connect(p.Position, previous.position, p._beamTurns, front._beamTurns)
			if points then p:ResolveBeamSpan(points) end
			node.position = p.Position
		end
	end
end)

function Handler.IsActive(player: Player): boolean
	for _, channel in channels do if channel.Player == player then return true end end
	return false
end

function Handler.Stop(player: Player)
	for index = #channels, 1, -1 do
		if channels[index].Player == player then table.remove(channels, index) end
	end
	lastInput[player] = nil
end

-- KeepAlive cannot begin a cast or modify its duration/stats. Only the
-- server's validated SpellCast path can call Start.
function Handler.KeepAlive(player: Player)
	if lastInput[player] then lastInput[player] = os.clock() end
end

function Handler.BeginCast(player: Player)
	lastInput[player] = os.clock()
end

function Handler.Start(options: any): boolean
	if not lastInput[options.Player] or os.clock() - lastInput[options.Player] > INPUT_TIMEOUT then return false end
	local count = 0
	for _, channel in channels do if channel.Player == options.Player then count += 1 end end
	if count >= MAX_CHANNELS_PER_PLAYER then return false end
	local channel = table.clone(options)
	nextChannelId += 1
	channel.Id = nextChannelId
	channel.Remaining = options.Duration
	channel.NextEmit = options.Delay or 0
	channel.Started = os.clock()
	if channel.NextEmit == 0 then
		local slice = math.min(Handler.Interval, channel.Remaining)
		channel.Emit(slice / options.Duration, channel.Id)
		channel.Remaining -= slice
		channel.NextEmit = Handler.Interval
	end
	table.insert(channels, channel)
	return true
end

Heartbeat.Connect(function(globalDt: number)
	local now = os.clock()
	for index = #channels, 1, -1 do
		local channel = channels[index]
		local player, character = channel.Player, channel.Character
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local tool = character:FindFirstChild("SpellAssembler")
		if channel.Remaining <= 1e-8 or not player.Parent or player.Character ~= character
			or not humanoid or humanoid.Health <= 0 or not tool or not tool:IsA("Tool")
			or now - (lastInput[player] or 0) > INPUT_TIMEOUT or now - channel.Started >= 60 then
			table.remove(channels, index)
			continue
		end
		local caster = channel.Caster
		if caster and (caster.IsDestroyed or caster.Health <= 0) then
			table.remove(channels, index)
			continue
		end
		local scale = ChunkManager.GetTimeScaleAt(channel.Origin()) * (caster and caster.TimeScale or 1)
		if scale <= 0 then continue end
		channel.NextEmit -= globalDt * scale
		local emitted = 0
		while channel.NextEmit <= 0 and channel.Remaining > 1e-8 and emitted < MAX_PACKETS_PER_CHANNEL_FRAME do
			local slice = math.min(Handler.Interval, channel.Remaining)
			channel.Emit(slice / channel.Duration, channel.Id)
			channel.Remaining -= slice
			channel.NextEmit += Handler.Interval
			emitted += 1
		end
	end
end, { Name = "BeamProjectileHandler.Channel", Priority = 4 })

Players.PlayerRemoving:Connect(Handler.Stop)
return Handler
