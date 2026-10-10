--!strict
--!optimize 2
-- Filter lifetime follows resident slots. Idle entries get a grace period so
-- bursts share their params without retaining every respawn for the server's life.
local Registry = {}
Registry.__index = Registry

function Registry.new(send: (string, ...any) -> ())
	return setmetatable({ Send = send, Trie = {}, Records = {}, Ids = {}, Cursor = 1, NextId = 0,
		ByParams = setmetatable({}, { __mode = "k" }), NextCollection = 0 }, Registry)
end

function Registry:Ready(id: number?, frame: number): boolean
	local record = id and self.Records[id]
	return record ~= nil and record.Ready <= frame
end

function Registry:Get(params: RaycastParams, frame: number): number?
	local known = self.ByParams[params]
	local record = known and self.Records[known]
	if record then
		record.LastUsed = os.clock()
		return if record.Ready <= frame then known else nil
	end
	local instances = params.FilterDescendantsInstances
	local node = self.Trie
	local path = { node }
	for _, instance in instances do
		local child = node[instance]
		if not child then child = {}; node[instance] = child end
		node = child
		table.insert(path, node)
	end
	local flags = `{params.IgnoreWater}|{params.CollisionGroup}`
	local id = node[flags]
	if not id then
		self.NextId += 1
		id = self.NextId
		node[flags] = id
		self.Records[id] = { Ready = frame + 1, References = 0, LastUsed = os.clock(),
			Path = path, Instances = instances, Flags = flags }
		table.insert(self.Ids, id)
		self.Send("Filter", id, instances, params.IgnoreWater, params.CollisionGroup)
	else
		self.Records[id].LastUsed = os.clock()
	end
	self.ByParams[params] = id
	return if self:Ready(id, frame) then id else nil
end

function Registry:Retain(id: number)
	self.Records[id].References += 1
end

function Registry:Release(id: number)
	local record = self.Records[id]
	assert(record and record.References > 0, "unbalanced projectile filter release")
	record.References -= 1
	if record.References == 0 then record.LastUsed = os.clock() end
end

function Registry:Collect(now: number)
	if now < self.NextCollection then return end
	local retired = {}
	local index = self.Cursor
	-- Bounded maintenance: even adversarial ignore-list churn cannot turn a
	-- periodic collection into a full-table hitch on one server frame.
	for _ = 1, 64 do
		if index > #self.Ids then break end
		local id = self.Ids[index]
		local record = self.Records[id]
		if record.References == 0 and now - record.LastUsed >= 60 then
			local path = record.Path
			path[#path][record.Flags] = nil
			for index = #record.Instances, 1, -1 do
				if next(path[index + 1]) ~= nil then break end
				path[index][record.Instances[index]] = nil
			end
			self.Records[id] = nil
			local last = #self.Ids
			self.Ids[index] = self.Ids[last]
			self.Ids[last] = nil
			table.insert(retired, id)
		else
			index += 1
		end
	end
	if index > #self.Ids then
		self.Cursor = 1
		self.NextCollection = now + 5
	else
		self.Cursor = index
	end
	if #retired > 0 then self.Send("RetireFilters", retired) end
end

function Registry:Reset()
	table.clear(self.Trie)
	table.clear(self.Records)
	table.clear(self.Ids)
	self.Cursor = 1
	table.clear(self.ByParams)
	-- IDs remain monotonic: stale handle metadata can never alias a new filter.
	self.Send("ResetFilters")
end

return Registry
