--!strict
--[[
	BarrierWatch.luau (client)
	Runs the server's barrier shape check (shared/BarrierShapes) on the spell
	barriers this client can see, as they appear and as they move -- barriers
	that follow an entity can come together into a shape long after the
	server judged them on creation. A flagged group is hidden here at once
	(LocalTransparencyModifier: nothing is changed for anyone else) and one
	barrier of it is reported to the server (SpellRemotes.BarrierReport),
	which judges the group itself from its own state and dissolves it for
	everyone if it agrees (server/SpellWorld, "Client reports").

	Each barrier model carries what the check needs (server/SpellWorld):
	BarrierId, BarrierShape and BarrierSize attributes, and on one panel a
	BarrierFrame attribute (the barrier's frame relative to that panel).

	Cost: one pass over the watched barriers every CHECK_INTERVAL; groups are
	only clustered and judged when one of their barriers appeared or moved,
	at most MAX_JUDGE_PER_CHECK a pass (the rest wait for the next). A
	flagged group is reported again only after REPORT_REPEAT seconds (the
	server ignores duplicates anyway).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BarrierShapes = require(Shared:WaitForChild("BarrierShapes"))

local BarrierWatch = {}

local CHECK_INTERVAL = 0.2
local MOVE_EPSILON = 0.25 -- studs a barrier moves before its group is judged again
local MAX_JUDGE_PER_CHECK = 4
local REPORT_REPEAT = 5
local MAX_REPORT_IDS = 8 -- (the server reads no more)

type Watched = {
	model: Model,
	id: number,
	shape: string,
	size: Vector3,
	panel: BasePart?,
	offset: CFrame?,
	lastFrame: CFrame?, -- where it was when its group was last judged
	hidden: boolean,
}

local watched: { [Model]: Watched } = {}
local reportedAt: { [number]: number } = {}
local started = false

local function watch(model: Instance)
	if not model:IsA("Model") or watched[model] then
		return
	end
	local id = model:GetAttribute("BarrierId")
	local shape = model:GetAttribute("BarrierShape")
	local size = model:GetAttribute("BarrierSize")
	if typeof(id) ~= "number" or typeof(shape) ~= "string" or typeof(size) ~= "Vector3" then
		return
	end
	watched[model] = { model = model, id = id, shape = shape, size = size, panel = nil, offset = nil, lastFrame = nil, hidden = false }
end

local function setHidden(entry: Watched, hidden: boolean)
	entry.hidden = hidden
	for _, part in entry.model:GetDescendants() do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = if hidden then 1 else 0
		end
	end
end

-- Where the barrier is now, from its tagged panel.
local function primitiveOf(entry: Watched): BarrierShapes.Primitive?
	local panel = entry.panel
	if not panel or panel.Parent ~= entry.model then
		panel = nil
		for _, child in entry.model:GetChildren() do
			local offset = child:GetAttribute("BarrierFrame")
			if child:IsA("BasePart") and typeof(offset) == "CFrame" then
				panel, entry.offset = child, offset
				break
			end
		end
		entry.panel = panel
	end
	if not panel or not entry.offset then
		return nil
	end
	return { Frame = panel.CFrame * entry.offset, Shape = entry.shape, Size = entry.size }
end

local function moved(entry: Watched, frame: CFrame): boolean
	local last = entry.lastFrame
	return not last or (frame.Position - last.Position).Magnitude > MOVE_EPSILON
		or frame.LookVector:Dot(last.LookVector) < 0.999 or frame.UpVector:Dot(last.UpVector) < 0.999
end

local function check(remote: RemoteEvent)
	local list: { Watched } = {}
	local primitives: { BarrierShapes.Primitive } = {}
	local dirty: { [number]: boolean } = {}
	for model, entry in watched do
		if not model.Parent then
			watched[model] = nil
			continue
		end
		local primitive = primitiveOf(entry)
		if not primitive then
			continue
		end
		table.insert(list, entry)
		table.insert(primitives, primitive)
		if moved(entry, primitive.Frame) then
			dirty[#list] = true
		end
	end
	if next(dirty) == nil then
		return
	end

	local now = os.clock()
	local report: { number } = {}
	local judged = 0
	for _, members in BarrierShapes.Clusters(primitives) do
		local changed = false
		for _, index in members do
			if dirty[index] then
				changed = true
				break
			end
		end
		if not changed then
			continue
		end
		if judged >= MAX_JUDGE_PER_CHECK then
			continue -- (still dirty next pass: lastFrame isn't updated)
		end
		judged += 1
		for _, index in members do
			list[index].lastFrame = primitives[index].Frame
		end
		local flagged = false
		if #members >= BarrierShapes.MIN_PARTS then
			local cluster = table.create(#members)
			for _, index in members do
				table.insert(cluster, primitives[index])
			end
			flagged = (BarrierShapes.Analyze(cluster))
		end
		local recent = false
		for _, index in members do
			local entry = list[index]
			if entry.hidden ~= flagged then
				setHidden(entry, flagged)
			end
			local at = reportedAt[entry.id]
			if at and now - at < REPORT_REPEAT then
				recent = true
			end
		end
		if flagged and not recent and #report < MAX_REPORT_IDS then
			for _, index in members do
				reportedAt[list[index].id] = now
			end
			table.insert(report, list[members[1]].id)
		end
	end
	if #report > 0 then
		remote:FireServer(report)
	end
	for id, at in reportedAt do
		if now - at > REPORT_REPEAT then
			reportedAt[id] = nil
		end
	end
end

function BarrierWatch.start()
	if started then
		return
	end
	started = true
	task.spawn(function()
		local root = workspace:WaitForChild("SpellBarriers")
		local remote = ReplicatedStorage:WaitForChild("SpellRemotes"):WaitForChild("BarrierReport") :: RemoteEvent
		for _, descendant in root:GetDescendants() do
			watch(descendant)
		end
		root.DescendantAdded:Connect(watch)
		root.DescendantRemoving:Connect(function(descendant)
			if descendant:IsA("Model") then
				watched[descendant] = nil
			end
		end)
		while true do
			task.wait(CHECK_INTERVAL)
			if next(watched) ~= nil then
				local ok, err = pcall(check, remote)
				if not ok then
					warn(`[BarrierWatch] check failed: {tostring(err)}`)
				end
			end
		end
	end)
end

return BarrierWatch
