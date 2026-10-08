--!strict
--[[
	Spell game settings, live: admins change them from the debug panel's
	Admin tab ("Game settings"; server/DebugService), and they reach every
	client as ReplicatedStorage attributes:
	  InfiniteMana  boolean -- casting costs no mana
	  SpellCooldown number  -- seconds between casts of one card (0: none)
	Defaults (server/DebugService sets them at startup): in Studio, infinite
	mana and no cooldown; on live servers, normal mana and CastCooldown.

	The cooldown is real time, per spell-card slot, not shared between cards.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SpellSettings = {}

SpellSettings.CastCooldown = 2.5 -- the live default
SpellSettings.MaxCooldown = 60

function SpellSettings.GetCooldown(): number
	local value = ReplicatedStorage:GetAttribute("SpellCooldown")
	return if typeof(value) == "number" and value >= 0 then value else SpellSettings.CastCooldown
end

function SpellSettings.InfiniteMana(): boolean
	return ReplicatedStorage:GetAttribute("InfiniteMana") == true
end

return SpellSettings
