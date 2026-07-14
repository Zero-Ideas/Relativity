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

-- Stun: ragdolls the entity's character for the effect's Duration, then
-- restores normal Motor6D-driven animation the instant it expires --
-- however it ends (natural countdown, an early StatusEffectSys:
-- RemoveEffect, or a fresh ApplyEffect extending it -- see
-- StatusEffectSys's own doc comment on stacking), OnExpire covers all of
-- those uniformly, so this never needs its own timer. Reapplying while
-- already active just ADDS to the remaining duration (stock
-- StatusEffectSys stacking behavior) -- handy for chaining stun-locks from
-- repeated hits.
StatusEffectSys.Register("Stun", {
	OnApply = function(entity)
		local character = entity.Instance
		if character and character:IsA("Model") then
			Ragdoll.SetRagdoll(character, true)
		end
	end,
	OnExpire = function(entity)
		local character = entity.Instance
		if character and character:IsA("Model") then
			Ragdoll.SetRagdoll(character, false)
		end
	end,
})

print("[Relativity] status effects registered")
