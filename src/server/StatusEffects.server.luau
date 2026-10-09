--!optimize 2
--[[
	StatusEffects (server)
	Registers the shared status effect DEFINITIONS this game actually uses
	with StatusEffectSys (see src/shared/StatusEffectSys.luau for the
	generic duration/stack engine) -- this is the one place that knows what
	each named effect actually DOES; callers elsewhere just reference it by
	name (e.g. Weapons/Railgun.luau's OnHitFunction calls
	StatusEffectSys:ApplyEffect(entity, "Stun", duration)).

	StatusEffectSys.Register just populates an in-memory table, so this
	script must run before anything applies an effect by name -- in
	practice that's guaranteed, since every top-level server Script's main
	chunk finishes running well before a player can equip/fire a weapon.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local StatusEffectSys = require(Shared.StatusEffectSys)
local Ragdoll = require(script.Parent.Ragdoll)
local Entity = require(Shared.Entity)

Entity.SetDeathHandler(function(entity)
	local character = entity.Instance
	if character and character:IsA("Model") and character:FindFirstChildOfClass("Humanoid") then
		Ragdoll.SetRagdoll(character, true)
		Ragdoll.Tip(character, 2.6)
	end
end)

-- Stun: ragdolls the entity's character for the effect's Duration, then
-- restores normal Motor6D-driven animation the instant it expires --
-- however it ends (natural countdown, an early StatusEffectSys:
-- RemoveEffect, or a fresh ApplyEffect extending it -- see
-- StatusEffectSys's own doc comment on stacking), OnExpire covers all of
-- those uniformly, so this never needs its own timer. Reapplying while
-- already active just ADDS to the remaining duration (stock
-- StatusEffectSys stacking behavior), but never past STUN_MAX seconds left:
-- repeated hits can keep someone down, not lock them out for good.
local STUN_MAX = 5
StatusEffectSys.Register("Stun", {
	MaxDuration = STUN_MAX,
	OnApply = function(entity)
		local character = entity.Instance
		if character and character:IsA("Model") then
			Ragdoll.SetRagdoll(character, true)
			Ragdoll.Tip(character, 2.2)
		end
	end,
	OnExpire = function(entity)
		local character = entity.Instance
		if character and character:IsA("Model") then
			Ragdoll.SetRagdoll(character, false)
		end
	end,
})

-- Burn: Potency is the damage still to be dealt and Duration the time left
-- to deal it, so each tick deals its proportional share and the final tick
-- deals the remainder. Reapplying stacks both (stock stacking), extending the
-- burn and adding to the pool. effect.Source (set by the applier -- see
-- SpellRuntime's Fire element) gets the kill credit.
StatusEffectSys.Register("Burn", {
	TickInterval = 0.5,
	OnTick = function(entity, effect, interval)
		local amount = effect.Potency * math.min(interval / math.max(effect.Duration, interval), 1)
		effect.Potency -= amount
		local info = { Type = "Burn", Element = "Fire", Source = effect.Source }
		local source = effect.Source
		if source and not source.IsDestroyed and source.DealDamage then
			source:DealDamage(entity, amount, info)
		else
			entity:TakeDamage(amount, info)
		end
	end,
})

print("[Relativity] status effects registered")
