--!optimize 2
--[[
	StatusEffectSys.luau
	A duration/stack-based status effect system for Entity.luau entities (buffs,
	debuffs, DoTs/HoTs, anything with a timer and an optional stack count).
	Effect *behavior* is defined once via Register(); ApplyEffect/RemoveEffect
	then just reference it by name, matching how Entity's tags work.

	Time model: ticking (duration countdown + OnTick) rides the same per-entity
	dilated dt as entity:OnUpdate -- already scaled by global * chunk * the
	entity's own TimeScale -- so a Poison stack burns slower inside a slow-mo
	zone for free, same as everything else in this framework.

	Stacking: one active instance per (entity, effect name). Reapplying an
	already-active effect does NOT reset it -- the new duration is ADDED to
	whatever time remains, and the new potency is added to the current stack
	count (capped at the definition's MaxStacks, default unlimited). An effect
	ends the moment either Duration or Potency reaches 0 (whichever first).

	API:
	 StatusEffectSys.Register(name, definition: EffectDefinition)
	 StatusEffectSys:ApplyEffect(entity, name, duration, potency?) -> ActiveEffect?
	 StatusEffectSys:RemoveEffect(entity, name, duration?, potency?)
	   -- duration/potency each: a number subtracts that much from the
	   -- respective field; omitted (nil) leaves that field untouched. Omitting
	   -- BOTH is a shorthand for removing the effect entirely right now. So
	   -- RemoveEffect(entity, "Poison") removes it outright; RemoveEffect(
	   -- entity, "Poison", nil, 2) strips 2 stacks and leaves the remaining
	   -- duration alone; RemoveEffect(entity, "Poison", 3) shaves 3 seconds off
	   -- the remaining duration and leaves stacks alone.
	 StatusEffectSys:HasEffect(entity, name) -> boolean
	 StatusEffectSys:GetEffect(entity, name) -> ActiveEffect?
	 StatusEffectSys:GetEffects(entity) -> { ActiveEffect }

	 EffectDefinition (all optional except nothing is required):
	   OnApply(entity, effect)                 -- fires once: 0 -> active
	   OnStack(entity, effect, addedDuration, addedPotency) -- fires on every
	                                            -- reapplication while already active
	   OnTick(entity, effect, dt)               -- fires every TickInterval
	                                            -- dilated seconds while active
	   OnExpire(entity, effect)                 -- fires once the effect ends,
	                                            -- however it ended (natural
	                                            -- countdown, RemoveEffect, or
	                                            -- the entity being destroyed)
	   TickInterval: number?                    -- omitted/0 = OnTick never fires
	   MaxStacks: number?                       -- default unlimited

	 ActiveEffect (returned by ApplyEffect/GetEffect, read freely -- e.g. for a
	 debuff timer UI): { Name, Definition, Duration, Potency }
]]

local StatusEffectSys = {}

export type EffectDefinition = {
	OnApply: ((entity: any, effect: any) -> ())?,
	OnStack: ((entity: any, effect: any, addedDuration: number, addedPotency: number) -> ())?,
	OnTick: ((entity: any, effect: any, dt: number) -> ())?,
	OnExpire: ((entity: any, effect: any) -> ())?,
	TickInterval: number?,
	MaxStacks: number?,
}

local definitions: { [string]: EffectDefinition } = {}
local activeEffects: { [any]: { [string]: any } } = {} -- [entity] = { [name] = ActiveEffect }
local hasDriver: { [any]: boolean } = {} -- [entity] = true once its OnUpdate driver is wired up

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

function StatusEffectSys.Register(name: string, definition: EffectDefinition)
	definitions[name] = definition
end

--------------------------------------------------------------------------------
-- Internals
--------------------------------------------------------------------------------

local function expireEffect(entity, name: string, effect)
	local effects = activeEffects[entity]
	if effects then
		effects[name] = nil
	end
	local onExpire = effect.Definition.OnExpire
	if onExpire then
		onExpire(entity, effect)
	end
end

-- Lazily wires one entity:OnUpdate driver per entity (reusing Entity's existing
-- dilated-time loop instead of a second Heartbeat connection) plus a Destroyed
-- hook so activeEffects never leaks an entry for a dead entity.
local function ensureDriver(entity)
	if hasDriver[entity] then
		return
	end
	hasDriver[entity] = true
	activeEffects[entity] = activeEffects[entity] or {}

	entity:OnUpdate(function(dt: number)
		local effects = activeEffects[entity]
		if not effects then
			return
		end
		for name, effect in effects do
			effect.Duration -= dt

			local interval = effect.Definition.TickInterval
			if interval and interval > 0 then
				effect._tickAccumulator += dt
				if effect._tickAccumulator >= interval then
					effect._tickAccumulator = 0
					local onTick = effect.Definition.OnTick
					if onTick then
						onTick(entity, effect, interval)
					end
				end
			end

			if effect.Duration <= 0 or effect.Potency <= 0 then
				expireEffect(entity, name, effect)
			end
		end
	end)

	entity.Destroyed:Connect(function()
		activeEffects[entity] = nil
		hasDriver[entity] = nil
	end)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function StatusEffectSys:ApplyEffect(entity, name: string, duration: number, potency: number?)
	local definition = definitions[name]
	if not definition then
		warn(`[StatusEffectSys] "{name}" is not registered -- call StatusEffectSys.Register() first`)
		return nil
	end
	potency = potency or 1

	ensureDriver(entity)
	local effects = activeEffects[entity]
	local effect = effects[name]
	local maxStacks = definition.MaxStacks or math.huge

	if effect then
		effect.Duration += duration
		local before = effect.Potency
		effect.Potency = math.min(effect.Potency + potency, maxStacks)
		local onStack = definition.OnStack
		if onStack then
			onStack(entity, effect, duration, effect.Potency - before)
		end
	else
		effect = {
			Name = name,
			Definition = definition,
			Duration = duration,
			Potency = math.min(potency, maxStacks),
			_tickAccumulator = 0,
		}
		effects[name] = effect
		local onApply = definition.OnApply
		if onApply then
			onApply(entity, effect)
		end
	end

	return effect
end

function StatusEffectSys:RemoveEffect(entity, name: string, duration: number?, potency: number?)
	local effects = activeEffects[entity]
	local effect = effects and effects[name]
	if not effect then
		return
	end

	-- Neither amount given: shorthand for "remove it entirely, right now."
	if duration == nil and potency == nil then
		expireEffect(entity, name, effect)
		return
	end

	if duration then
		effect.Duration -= duration
	end
	if potency then
		effect.Potency -= potency
	end

	if effect.Duration <= 0 or effect.Potency <= 0 then
		expireEffect(entity, name, effect)
	end
end

function StatusEffectSys:HasEffect(entity, name: string): boolean
	local effects = activeEffects[entity]
	return effects ~= nil and effects[name] ~= nil
end

function StatusEffectSys:GetEffect(entity, name: string)
	local effects = activeEffects[entity]
	return effects and effects[name]
end

function StatusEffectSys:GetEffects(entity)
	local effects = activeEffects[entity]
	if not effects then
		return {}
	end
	local result = {}
	for _, effect in effects do
		table.insert(result, effect)
	end
	return result
end

return StatusEffectSys
