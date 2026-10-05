--!strict
-- Continuous beams are ordered chains of REAL projectile beamlets. Every
-- section owns its collision, energy and impact/expiry handlers; rendering
-- receives the same authoritative endpoints that collision used.
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage").Shared
local Heartbeat = require(Shared.Heartbeat)
local ChunkManager = require(Shared.ChunkManager)
local Projectile = require(script.Parent.Projectile)
local BeamPath = require(Shared.BeamPath)

local Handler = {}
Handler.Interval = 1 / 30
Handler.MaxJoinersPerBeam = 512
Handler.MaxNewJoinersPerFrame = 128
function Handler.GetInterval(speed: number): number
	return math.max(1 / 60, math.min(Handler.Interval, (BeamPath.MaxStretch - 2) / math.max(speed, 1)))
end
local INPUT_TIMEOUT = .75
local MAX_PACKETS_PER_CHANNEL_FRAME = 2
local MAX_CHANNELS_PER_PLAYER = 32
local channels: { any } = {}
local lastInput: { [Player]: number } = {}
local nextChannelId = 0
local streams: { [number]: any } = {}
local streamOrder: { number } = {}
local streamCursor = 1
local lastJoinerStats = { Created = 0, Updated = 0, BudgetSplits = 0 }
local breakReasons = { Geometry = 0, ChannelBudget = 0, FrameBudget = 0, Quota = 0 }

local function nodeFor(p: any, previous: any): any
	p._beamPrevious = previous and previous.projectile
	if p.Beam then p.Beam.PreviousId = previous and previous.projectile.Id end
	return { projectile = p, previous = previous, everLinked = false,
		tail = {p.Position}, tailTurns = #(p._beamTurns or {}) }
end

-- Break ONLY this link. Surviving siblings keep their identities, motion and
-- triggers. A disconnected section keeps a finite body, never an immortal dot
-- or a resurrected old trajectory spur.
local function unlink(node: any)
	local p = node.projectile
	local path = p._beamSpan
	local offset = path and path[2] and path[2]-path[1]
	if not offset or offset.Magnitude < 1e-4 then
		offset = if p.Velocity.Magnitude > 1e-4 then p.Velocity.Unit * math.min(p.Beam.Length, BeamPath.MaxStretch) else nil
	end
	if offset and offset.Magnitude > BeamPath.MaxStretch then offset = offset.Unit * BeamPath.MaxStretch end
	node.fragment = offset
	node.previous, node.everLinked = nil, true
	p:ClearBeamPrevious()
end

local function initialPath(node: any): { Vector3 }
	local p = node.projectile
	if node.incoming then return { p.Position } end
	if node.fragment then return { p.Position, p.Position + node.fragment } end
	if node.everLinked then
		if p.Velocity.Magnitude > 1e-4 then
			return { p.Position, p.Position + p.Velocity.Unit * math.min(p.Beam.Length, BeamPath.MaxStretch) }
		end
		return { p.Position }
	end
	local tail = node.tail
	for index = node.tailTurns + 1, #(p._beamTurns or {}) do table.insert(tail, p._beamTurns[index]) end
	node.tailTurns = #(p._beamTurns or {})
	if (tail[#tail]-p.Position).Magnitude > 1e-4 then table.insert(tail, p.Position) end
	local length, cap = 0, math.min(p.Beam.Length, BeamPath.MaxStretch)
	for index = #tail, 2, -1 do
		local span = (tail[index]-tail[index-1]).Magnitude
		if length + span > cap then
			tail[index-1] = tail[index]:Lerp(tail[index-1], (cap-length)/span)
			for _ = 1, index-2 do table.remove(tail, 1) end
			break
		end
		length += span
	end
	while #tail > 9 do table.remove(tail, 1) end
	local reverse = {}
	for index = #tail, 1, -1 do table.insert(reverse, tail[index]) end
	return reverse
end

function Handler.Launch(config: any): any
	local beamConfig = table.clone(config)
	beamConfig.Beam = table.clone(config.Beam or {})
	local id = beamConfig.Beam.ChannelId
	local stream = id and streams[id]
	if id and not stream then
		stream = { nodes = {}, last = nil, joinerCount = 0 }
		streams[id] = stream
		table.insert(streamOrder, id)
	end
	local previous = stream and stream.last
	if previous and previous.projectile.Dead then previous = nil end
	if previous then beamConfig.Beam.PreviousId = previous.projectile.Id end
	local p = Projectile.new(beamConfig)
	if stream then
		local node = nodeFor(p, previous)
		table.insert(stream.nodes, node)
		stream.last = node
	end
	return p
end

local function resolve(node: any, points: { Vector3 }, dt: number)
	local p = node.projectile
	p._beamSpan = p:ResolveBeamSpan(points, dt > 0)
end

Projectile.SetBeamSpanStep(function(globalDt: number)
	local created, updated, budgetSplits = 0, 0, 0
	local orderCount = #streamOrder
	if orderCount == 0 then
		lastJoinerStats = { Created = 0, Updated = 0, BudgetSplits = 0 }
		return
	end
	for offset = 0, orderCount - 1 do
		local id = streamOrder[(streamCursor + offset - 1) % orderCount + 1]
		local stream = streams[id]
		if not stream then continue end
		local live, count = {}, 0
		for _, node in stream.nodes do
			node.incoming = false
			if not node.projectile.Dead then
				table.insert(live, node)
				if node.projectile._beamJoiner then count += 1; updated += 1 end
			end
		end
		if #live == 0 then streams[id] = nil; continue end
		stream.nodes, stream.joinerCount = live, count
		for _, node in live do
			if node.previous and not node.previous.projectile.Dead then node.previous.incoming = true end
		end
		local originalCount = #live
		for index = 1, originalCount do
			local node = live[index]
			local p, previous = node.projectile, node.previous
			if p.Dead then continue end
			if previous and previous.projectile.Dead and not previous.projectile._beamJoinerWorldStop then
				unlink(node); previous = nil
			end
			if not previous then resolve(node, initialPath(node), globalDt); continue end
			local front = previous.projectile
			local corners, needed = BeamPath.Plan(p.Position, front.Position, p._beamTurns, front._beamTurns)
			local reason = if not corners then "Geometry"
				elseif stream.joinerCount + needed > Handler.MaxJoinersPerBeam then "ChannelBudget"
				elseif created + needed > Handler.MaxNewJoinersPerFrame then "FrameBudget"
				elseif needed > 0 and p._beamReserveChildren and not p._beamReserveChildren(needed) then "Quota"
				else nil
			if reason then
				breakReasons[reason] += 1
				budgetSplits += 1
				unlink(node)
				resolve(node, initialPath(node), globalDt)
				continue
			end
			-- Refine EVERY adjacent link every frame, including child-to-child
			-- links. New children enter the ordinary simulation once next frame;
			-- their bodies can collide immediately at their insertion positions.
			local chain = {node}
			local behind, ahead = p._beamTurns or {}, front._beamTurns or {}
			for leg = 1, #corners-1 do
				local from, to = corners[leg], corners[leg+1]
				local pieces = math.max(1, math.ceil((to-from).Magnitude / BeamPath.MaxStretch))
				local phase = math.min(#behind+leg-1, #ahead)
				for piece = 1, pieces-1 do
					local t = piece/pieces
					local prototype = if phase == #ahead then front else p
					local velocity = if #behind == #ahead then p.Velocity:Lerp(front.Velocity,t)
						elseif phase == #behind then p.Velocity
						elseif phase == #ahead then front.Velocity
						else (to-from).Unit * p.Velocity.Magnitude * p.Restitution^(phase-#behind)
					local turns = {}
					for turn = 1, phase do turns[turn] = ahead[turn] end
					local child = Projectile.CreateBeamSample(prototype, from:Lerp(to,t), velocity, turns)
					child.Age = p.Age + (front.Age-p.Age)*t
					-- Spell callbacks are bound synchronously, before any hit.
					child.Damage = p.Damage / (needed+1)
					if p._beamBindChild then p._beamBindChild(child, 1/(needed+1)) end
					local childNode = nodeFor(child, nil)
					childNode.everLinked = true
					table.insert(chain, childNode)
					table.insert(live, childNode)
				end
			end
			if needed > 0 then
				if p._beamScaleEnergy then p._beamScaleEnergy(1/(needed+1))
				else p.Damage /= needed+1 end
			end
			table.insert(chain, previous)
			for link = 1, #chain-1 do
				local back, aheadNode = chain[link], chain[link+1]
				back.previous, back.everLinked = aheadNode, true
				aheadNode.everLinked, aheadNode.incoming = true, true
				local bp, fp = back.projectile, aheadNode.projectile
				bp._beamPrevious, bp.Beam.PreviousId = fp, fp.Id
				local path = BeamPath.Connect(bp.Position, fp.Position, bp._beamTurns, fp._beamTurns)
				if path then resolve(back, path, globalDt)
				else unlink(back); resolve(back, initialPath(back), globalDt) end
				if link > 1 then Projectile.PublishBeamSample(bp) end
			end
			-- The front's incoming section is its geometry, not a private tail.
			-- Do not wipe a stopped front's already-clipped impact snapshot.
			if not front.Dead and not previous.previous then front._beamSpan = { front.Position } end
			stream.joinerCount += needed
			created += needed
		end
	end
	streamCursor = streamCursor % orderCount + 1
	local liveOrder = {}
	for offset = 0, orderCount - 1 do
		local id = streamOrder[(streamCursor + offset - 1) % orderCount + 1]
		if streams[id] then table.insert(liveOrder, id) end
	end
	for index = orderCount + 1, #streamOrder do
		local id = streamOrder[index]
		if streams[id] then table.insert(liveOrder, id) end
	end
	streamOrder, streamCursor = liveOrder, 1
	lastJoinerStats = { Created = created, Updated = updated, BudgetSplits = budgetSplits }
end)

function Handler.GetJoinerStats()
	local count = 0
	for _, stream in streams do
		for _, node in stream.nodes do
			if node.projectile._beamJoiner and not node.projectile.Dead then count += 1 end
		end
	end
	return { Active = count, Created = lastJoinerStats.Created, Updated = lastJoinerStats.Updated,
		BudgetSplits = lastJoinerStats.BudgetSplits, MaxPerBeam = Handler.MaxJoinersPerBeam,
		MaxNewPerFrame = Handler.MaxNewJoinersPerFrame, BreakReasons = table.clone(breakReasons) }
end

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
	channel.Interval = Handler.GetInterval(options.Speed or 2000)
	channel.Remaining = options.Duration
	channel.NextEmit = options.Delay or 0
	channel.Started = os.clock()
	if channel.NextEmit == 0 then
		local slice = math.min(channel.Interval, channel.Remaining)
		channel.Emit(slice / options.Duration, channel.Id)
		channel.Remaining -= slice
		channel.NextEmit = channel.Interval
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
			local slice = math.min(channel.Interval, channel.Remaining)
			channel.Emit(slice / channel.Duration, channel.Id)
			channel.Remaining -= slice
			channel.NextEmit += channel.Interval
			emitted += 1
		end
	end
end, { Name = "BeamProjectileHandler.Channel", Priority = 4 })

Players.PlayerRemoving:Connect(Handler.Stop)
return Handler
