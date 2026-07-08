--!optimize 2
--[[
	Hitbox.luau
	Damage volumes that respect chunk time dilation. Two flavours:

	 1. Hitbox.Explode(position, config) — instantaneous radial damage with
	    linear falloff, optional knockback and a cosmetic Explosion.

	 2. Hitbox.new(config):Start() — a persistent volume (box or sphere) that
	    can Follow an entity and ticks over a dilated Lifetime. Great for melee
	    swing windows, auras, and lingering hazards. Fires .OnHit(entity, damage).

	All entity lookups go through the ChunkManager grid, so hitboxes never scan
	frozen (unloaded) chunks. Everything ticks in the local time of the chunk
	the hitbox currently occupies: a sword swung inside a slow zone lingers.

	Hitbox.new config:
	  Shape     = "Box" | "Sphere"     (default "Box")
	  Size      = Vector3               (Sphere uses Size.X as diameter)
	  Follow    = entity | BasePart     (tracks its position each tick)
	  Offset    = CFrame                (relative to Follow, default identity)
	  Position  = Vector3 | CFrame      (static placement when no Follow)
	  Damage    = number
	  Source    = entity                (deals damage through its outgoing modifiers)
	  HitOnce   = boolean               (default true — each target once per activation)
	  RehitInterval = number?           (if HitOnce is false, seconds between re-hits)
	  Lifetime  = number?               (dilated seconds before auto-Stop)
	  Filter    = (entity) -> boolean
	  Info      = table                 (damage info; default { Type = "Melee" })
]]

local Signal = require(script.Parent.Signal)
local Heartbeat = require(script.Parent.Heartbeat)
local ChunkManager = require(script.Parent.ChunkManager)

local Hitbox = {}
Hitbox.__index = Hitbox

--------------------------------------------------------------------------------
-- Shared helpers
--------------------------------------------------------------------------------

local function applyKnockback(entity, direction: Vector3, force: number)
	if force <= 0 then
		return
	end
	local root = entity._root
	if root and root.Parent and not root.Anchored then
		root.AssemblyLinearVelocity += direction * force
	elseif entity._gravityVelocity ~= nil then
		-- data/gravity-driven entity: feed the Gravity integrator
		entity._gravityVelocity += direction * force
	end
end

--------------------------------------------------------------------------------
-- Instant explosion
--------------------------------------------------------------------------------

export type ExplodeConfig = {
	Radius: number,
	Damage: number,
	MinDamage: number?, -- damage at the edge (default = Damage, i.e. no falloff)
	Knockback: number?,
	Source: any?,
	Visual: boolean?, -- cosmetic Roblox Explosion (pressure 0)
	Filter: ((entity: any) -> boolean)?,
	Type: string?, -- damage type tag (default "Explosion")
}

function Hitbox.Explode(position: Vector3, config: ExplodeConfig)
	local radius = config.Radius or 10
	local maxDamage = config.Damage or 0
	local minDamage = config.MinDamage or maxDamage
	local knockback = config.Knockback or 0
	local source = config.Source
	local damageType = config.Type or "Explosion"

	local hitList = {}
	local targets = ChunkManager.GetEntitiesInRadius(position, radius, { Filter = config.Filter })
	for _, entity in targets do
		if entity ~= source and not entity.IsDestroyed then
			local offset = entity:GetPosition() - position
			local distance = offset.Magnitude
			local alpha = radius > 0 and math.clamp(1 - distance / radius, 0, 1) or 1
			local damage = minDamage + (maxDamage - minDamage) * alpha

			if damage > 0 then
				local info = { Type = damageType, Source = source, Position = position }
				if source and source.DealDamage then
					source:DealDamage(entity, damage, info)
				else
					entity:TakeDamage(damage, info)
				end
			end

			local direction = distance > 1e-3 and offset.Unit or Vector3.yAxis
			applyKnockback(entity, direction, knockback)
			table.insert(hitList, entity)
		end
	end

	if config.Visual then
		local explosion = Instance.new("Explosion")
		explosion.Position = position
		explosion.BlastRadius = radius
		explosion.BlastPressure = 0 -- cosmetic only; damage is handled above
		explosion.DestroyJointRadiusPercent = 0
		explosion.Parent = workspace
	end

	return hitList
end

--------------------------------------------------------------------------------
-- Persistent hitbox
--------------------------------------------------------------------------------

function Hitbox.new(config)
	return setmetatable({
		Shape = config.Shape or "Box",
		Size = config.Size or (Vector3.one * 4),
		Follow = config.Follow,
		Offset = config.Offset or CFrame.identity,
		Position = config.Position,
		Damage = config.Damage or 0,
		Source = config.Source,
		HitOnce = config.HitOnce ~= false, -- default true
		RehitInterval = config.RehitInterval,
		Lifetime = config.Lifetime,
		Filter = config.Filter,
		Info = config.Info,

		OnHit = Signal.new(),
		Active = false,

		_hitTimes = {}, -- [entity] = localTime it was last hit
		_connection = nil,
		_elapsed = 0,
	}, Hitbox)
end

function Hitbox:_getCFrame(): CFrame
	local follow = self.Follow
	if follow ~= nil then
		if typeof(follow) == "Instance" then
			if follow:IsA("BasePart") then
				return follow.CFrame * self.Offset
			elseif follow:IsA("Model") then
				return follow:GetPivot() * self.Offset
			end
		else
			-- an Entity
			local root = follow._root
			if root and root.Parent then
				return root.CFrame * self.Offset
			end
			if follow.GetPosition then
				return CFrame.new(follow:GetPosition()) * self.Offset
			end
		end
	end

	local placement = self.Position
	if placement then
		if typeof(placement) == "CFrame" then
			return placement
		end
		return CFrame.new(placement)
	end
	return CFrame.identity
end

function Hitbox:_query()
	local cframe = self:_getCFrame()
	local entities
	if self.Shape == "Sphere" or self.Shape == "Ball" then
		local sphereRadius = self.Size.X / 2
		entities = ChunkManager.GetEntitiesInRadius(cframe.Position, sphereRadius, { Filter = self.Filter })
	else
		entities = ChunkManager.GetEntitiesInBox(cframe, self.Size, { Filter = self.Filter })
	end

	local now = self._elapsed
	for _, entity in entities do
		if entity ~= self.Source and not entity.IsDestroyed then
			local lastHit = self._hitTimes[entity]
			local allowed
			if self.HitOnce then
				allowed = lastHit == nil
			elseif self.RehitInterval then
				allowed = lastHit == nil or (now - lastHit) >= self.RehitInterval
			else
				allowed = true -- tick every frame
			end

			if allowed then
				self._hitTimes[entity] = now
				local info = self.Info or { Type = "Melee", Source = self.Source }
				local dealt
				if self.Source and self.Source.DealDamage then
					dealt = self.Source:DealDamage(entity, self.Damage, info)
				else
					dealt = entity:TakeDamage(self.Damage, info)
				end
				self.OnHit:Fire(entity, dealt)
			end
		end
	end
end

function Hitbox:Start()
	if self.Active then
		return self
	end
	self.Active = true
	self._elapsed = 0
	table.clear(self._hitTimes)

	self._connection = Heartbeat.Connect(function(dt)
		local position = self:_getCFrame().Position
		-- dt is already global-scaled; fold in the chunk-local scale.
		local localDt = ChunkManager.ScaleDt(dt, position)
		self._elapsed += localDt

		if ChunkManager.IsActiveAt(position) and localDt > 0 then
			self:_query()
		end

		if self.Lifetime and self._elapsed >= self.Lifetime then
			self:Stop()
		end
	end, { Name = "Hitbox", Priority = 10 })

	return self
end

function Hitbox:Stop()
	if not self.Active then
		return
	end
	self.Active = false
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
end

-- Clears the per-target hit memory so a HitOnce box can strike again
-- (e.g. the next swing) without recreating it.
function Hitbox:Reset()
	table.clear(self._hitTimes)
	self._elapsed = 0
end

function Hitbox:Destroy()
	self:Stop()
	self.OnHit:Destroy()
end

return Hitbox
