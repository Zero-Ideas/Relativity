--!optimize 2
--[[
	Entity.luau
	Turns any Model / BasePart / Humanoid rig — or nothing at all — into an
	entity with Entity.new(). Entities carry arbitrary custom variables and
	functions, a damage pipeline with stackable modifiers, tags, per-entity
	time scale, and automatic spatial chunk membership.

	Time model (per entity):
	   effectiveScale = Heartbeat global scale * chunk scale * entity.TimeScale
	OnUpdate callbacks receive a dt already dilated by all three. Entities in
	frozen (unloaded) chunks are skipped entirely.

	API summary:
	 Entity.new(instance?, props?) -> entity
	 Entity.Get(instance) -> entity?          (walks up ancestors)
	 Entity.GetAll() -> {entity}
	 Entity.GetTagged(tag) -> {entity}

	 entity:GetPosition() / :SetPosition(pos)   (SetPosition for data-only entities)
	 entity:OnUpdate(fn(dt, entity)) -> connection-like {Disconnect}
	 entity:SetTimeScale(scale) / :GetEffectiveTimeScale()
	 entity:AddTag(tag) / :RemoveTag(tag) / :HasTag(tag)
	 entity:AddDamageModifier(fn) / :AddOutgoingModifier(fn) -> {Disconnect}
	 entity:TakeDamage(amount, info?) -> finalAmount
	 entity:DealDamage(target, amount, info?) -> finalAmount
	 entity:Heal(amount)
	 entity:IsActive() -> boolean            (false when chunk-frozen or destroyed)
	 entity:GetChunk() -> Chunk?
	 entity:Destroy()

	 Signals: entity.Damaged(amount, info), entity.Died(info?),
	          entity.ChunkChanged(newChunk, oldChunk), entity.Destroyed()

	 Config props (all optional, passed in `props`; everything else in props is
	 copied onto the entity as custom data):
	   Health / MaxHealth (numbers)
	   HitboxRadius (number, default 2 — padding used by spatial queries)
	   TimeScale (number, default 1)
	   ScaleHumanoid (boolean — scale WalkSpeed/JumpPower with time dilation)
	   DestroyOnDeath (boolean — auto :Destroy() when Died fires)
	   Team / anything else -> stored as custom variables
]]

local Heartbeat = require(script.Parent.Heartbeat)
local ChunkManager = require(script.Parent.ChunkManager)
local Signal = require(script.Parent.Signal)

local Entity = {}
Entity.__index = Entity

local entities = {} -- flat array for fast iteration
local entityIndex = {} -- [entity] = array index (O(1) swap-remove)
local byInstance: { [Instance]: any } = {}
local byTag: { [string]: { [any]: boolean } } = {}
local nextId = 0

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local RESERVED = {
	Instance = true,
	Humanoid = true,
	Id = true,
	Damaged = true,
	Died = true,
	ChunkChanged = true,
	Destroyed = true,
}

function Entity.new(instance: Instance?, props: { [string]: any }?)
	nextId += 1
	local self = setmetatable({
		Id = nextId,
		Instance = instance,
		Humanoid = nil,
		Health = 100,
		MaxHealth = 100,
		HitboxRadius = 2,
		TimeScale = 1,
		ScaleHumanoid = false,
		DestroyOnDeath = false,
		IsDestroyed = false,

		Damaged = Signal.new(),
		Died = Signal.new(),
		ChunkChanged = Signal.new(),
		Destroyed = Signal.new(),

		_position = Vector3.zero, -- used when there is no instance
		_root = nil :: BasePart?,
		_chunk = nil,
		_updateFns = {},
		_damageModifiers = {},
		_outgoingModifiers = {},
		_tags = {},
		_baseWalkSpeed = nil,
		_baseJumpPower = nil,
		_lastHumanoidScale = 1,
		_instanceConnections = {},
	}, Entity)

	-- resolve physical root + humanoid
	if instance then
		if instance:IsA("BasePart") then
			self._root = instance
		elseif instance:IsA("Model") then
			local humanoid = instance:FindFirstChildOfClass("Humanoid")
			self._root = instance.PrimaryPart
				or (humanoid and instance:FindFirstChild("HumanoidRootPart") :: BasePart?)
				or instance:FindFirstChildWhichIsA("BasePart", true)
			if humanoid then
				self.Humanoid = humanoid
				self.Health = humanoid.Health
				self.MaxHealth = humanoid.MaxHealth
				self._baseWalkSpeed = humanoid.WalkSpeed
				self._baseJumpPower = humanoid.UseJumpPower and humanoid.JumpPower or humanoid.JumpHeight

				table.insert(
					self._instanceConnections,
					humanoid.HealthChanged:Connect(function(health)
						self.Health = health
					end)
				)
				table.insert(
					self._instanceConnections,
					humanoid.Died:Connect(function()
						self:_handleDeath(nil)
					end)
				)
			end
		end
		byInstance[instance] = self
		table.insert(
			self._instanceConnections,
			instance.Destroying:Connect(function()
				self:Destroy()
			end)
		)
	end

	-- merge custom props (variables AND functions) onto the entity
	if props then
		for key, value in props do
			if RESERVED[key] then
				warn(`[Entity] prop "{key}" is reserved and was ignored`)
			else
				self[key] = value
			end
		end
		if props.Health and not props.MaxHealth then
			self.MaxHealth = props.Health
		end
	end

	-- registry + initial chunk
	table.insert(entities, self)
	entityIndex[self] = #entities
	self._chunk = ChunkManager._addEntity(self, self:GetPosition())

	return self
end

-- Finds the entity owning `instance`, walking up the ancestor chain
-- (so a raycast hitting a limb resolves to the character's entity).
function Entity.Get(instance: Instance?)
	while instance do
		local entity = byInstance[instance]
		if entity then
			return entity
		end
		instance = instance.Parent
	end
	return nil
end

function Entity.GetAll()
	return table.clone(entities)
end

function Entity.GetTagged(tag: string)
	local result = {}
	local set = byTag[tag]
	if set then
		for entity in set do
			table.insert(result, entity)
		end
	end
	return result
end

--------------------------------------------------------------------------------
-- Position & chunks
--------------------------------------------------------------------------------

function Entity:GetPosition(): Vector3
	local root = self._root
	if root and root.Parent then
		return root.Position
	end
	local instance = self.Instance
	if instance and instance:IsA("Model") and instance.Parent then
		return instance:GetPivot().Position
	end
	return self._position
end

function Entity:SetPosition(position: Vector3)
	if self._root then
		self._root.Position = position
	else
		self._position = position
	end
end

function Entity:GetChunk()
	return self._chunk
end

function Entity:IsActive(): boolean
	if self.IsDestroyed then
		return false
	end
	local chunk = self._chunk
	return chunk == nil or ChunkManager.IsChunkActive(chunk)
end

--------------------------------------------------------------------------------
-- Time dilation
--------------------------------------------------------------------------------

function Entity:SetTimeScale(scale: number)
	self.TimeScale = math.max(scale, 0)
	self:_refreshHumanoidScale()
end

function Entity:GetEffectiveTimeScale(): number
	local chunk = self._chunk
	local chunkScale = chunk and chunk.TimeScale or 1
	return Heartbeat.GetGlobalTimeScale() * chunkScale * self.TimeScale
end

function Entity:_refreshHumanoidScale()
	if not self.ScaleHumanoid then
		return
	end
	local humanoid = self.Humanoid
	if not humanoid or not humanoid.Parent then
		return
	end
	local scale = self:GetEffectiveTimeScale()
	if scale == self._lastHumanoidScale then
		return
	end
	self._lastHumanoidScale = scale
	humanoid.WalkSpeed = (self._baseWalkSpeed or 16) * scale
	if humanoid.UseJumpPower then
		humanoid.JumpPower = (self._baseJumpPower or 50) * scale
	else
		-- jump height scales with time² (h = v²/2g with both v and g dilated)
		humanoid.JumpHeight = (self._baseJumpPower or 7.2) * scale * scale
	end
end

--------------------------------------------------------------------------------
-- Tags
--------------------------------------------------------------------------------

function Entity:AddTag(tag: string)
	if self._tags[tag] then
		return
	end
	self._tags[tag] = true
	local set = byTag[tag]
	if not set then
		set = {}
		byTag[tag] = set
	end
	set[self] = true
end

function Entity:RemoveTag(tag: string)
	if not self._tags[tag] then
		return
	end
	self._tags[tag] = nil
	local set = byTag[tag]
	if set then
		set[self] = nil
	end
end

function Entity:HasTag(tag: string): boolean
	return self._tags[tag] == true
end

--------------------------------------------------------------------------------
-- Damage pipeline
--------------------------------------------------------------------------------

local function addModifier(list, fn)
	table.insert(list, fn)
	return {
		Disconnect = function()
			local idx = table.find(list, fn)
			if idx then
				table.remove(list, idx)
			end
		end,
	}
end

-- Incoming: fn(amount, info, entity) -> newAmount. Runs on :TakeDamage().
function Entity:AddDamageModifier(fn: (amount: number, info: any, entity: any) -> number)
	return addModifier(self._damageModifiers, fn)
end

-- Outgoing: fn(amount, info, entity, target) -> newAmount. Runs on :DealDamage().
function Entity:AddOutgoingModifier(fn: (amount: number, info: any, entity: any, target: any) -> number)
	return addModifier(self._outgoingModifiers, fn)
end

-- info is a free-form table (e.g. { Type = "Fire", Source = attacker, Crit = true }).
function Entity:TakeDamage(amount: number, info: any?): number
	if self.IsDestroyed or self.Health <= 0 then
		return 0
	end
	info = info or {}

	for _, modifier in self._damageModifiers do
		amount = modifier(amount, info, self)
		if amount <= 0 then
			return 0
		end
	end

	local humanoid = self.Humanoid
	if humanoid and humanoid.Parent then
		local before = humanoid.Health
		humanoid:TakeDamage(amount) -- respects ForceFields
		amount = before - humanoid.Health
		self.Health = humanoid.Health
	else
		amount = math.min(amount, self.Health)
		self.Health -= amount
	end

	if amount > 0 then
		self.Damaged:Fire(amount, info)
	end
	if self.Health <= 0 and not humanoid then
		self:_handleDeath(info)
	end
	return amount
end

function Entity:DealDamage(target: any, amount: number, info: any?): number
	info = info or {}
	info.Source = info.Source or self
	for _, modifier in self._outgoingModifiers do
		amount = modifier(amount, info, self, target)
		if amount <= 0 then
			return 0
		end
	end
	return target:TakeDamage(amount, info)
end

function Entity:Heal(amount: number)
	local humanoid = self.Humanoid
	if humanoid and humanoid.Parent then
		humanoid.Health = math.min(humanoid.Health + amount, humanoid.MaxHealth)
		self.Health = humanoid.Health
	else
		self.Health = math.min(self.Health + amount, self.MaxHealth)
	end
end

function Entity:_handleDeath(info: any?)
	if self._dead then
		return
	end
	self._dead = true
	self.Died:Fire(info)
	if self.DestroyOnDeath then
		self:Destroy()
	end
end

--------------------------------------------------------------------------------
-- Per-entity update callbacks (driven by one shared heartbeat connection)
--------------------------------------------------------------------------------

function Entity:OnUpdate(fn: (dt: number, entity: any) -> ())
	local fns = self._updateFns
	table.insert(fns, fn)
	return {
		Disconnect = function()
			local idx = table.find(fns, fn)
			if idx then
				local n = #fns
				fns[idx] = fns[n]
				fns[n] = nil
			end
		end,
	}
end

--------------------------------------------------------------------------------
-- Destruction
--------------------------------------------------------------------------------

function Entity:Destroy()
	if self.IsDestroyed then
		return
	end
	self.IsDestroyed = true

	local idx = entityIndex[self]
	if idx then
		local last = #entities
		local moved = entities[last]
		entities[idx] = moved
		entities[last] = nil
		entityIndex[moved] = idx ~= last and idx or nil
		entityIndex[self] = nil
	end

	ChunkManager._removeEntity(self, self._chunk)
	self._chunk = nil

	for tag in self._tags do
		local set = byTag[tag]
		if set then
			set[self] = nil
		end
	end

	if self.Instance then
		byInstance[self.Instance] = nil
	end
	for _, connection in self._instanceConnections do
		connection:Disconnect()
	end
	table.clear(self._instanceConnections)
	table.clear(self._updateFns)

	self.Destroyed:Fire()
	self.Damaged:Destroy()
	self.Died:Destroy()
	self.ChunkChanged:Destroy()
	self.Destroyed:Destroy()
end

--------------------------------------------------------------------------------
-- System loops
--------------------------------------------------------------------------------

-- Frame loop: run OnUpdate callbacks with fully-dilated dt.
-- dt here is already global-scaled by the Heartbeat.
Heartbeat.Connect(function(dt)
	for i = 1, #entities do
		local entity = entities[i]
		local fns = entity._updateFns
		if #fns > 0 then
			local chunk = entity._chunk
			if chunk == nil or ChunkManager.IsChunkActive(chunk) then
				local scale = (chunk and chunk.TimeScale or 1) * entity.TimeScale
				if scale > 0 then
					local entityDt = dt * scale
					for j = 1, #fns do
						fns[j](entityDt, entity)
					end
				end
			end
		end
	end
end, { Name = "EntitySystem.Update", Priority = 0 })

-- Slow loop: re-bucket moved entities into chunks, refresh humanoid dilation.
Heartbeat.ConnectInterval(0.1, function()
	for i = 1, #entities do
		local entity = entities[i]
		local newChunk, changed = ChunkManager._updateEntity(entity, entity._chunk, entity:GetPosition())
		if changed then
			local oldChunk = entity._chunk
			entity._chunk = newChunk
			entity.ChunkChanged:Fire(newChunk, oldChunk)
		end
		entity:_refreshHumanoidScale()
	end
end, { Name = "EntitySystem.ChunkTracking", Priority = -50 })

return Entity
