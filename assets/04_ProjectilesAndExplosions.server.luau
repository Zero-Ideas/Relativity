--[[
	Example 2 — Entities with custom variables, functions, and damage scaling
	Any Model/Humanoid becomes an entity with Entity.new(). Custom props are
	merged straight onto the entity, including functions.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Entity = require(Shared.Entity)

-- Every player character becomes an entity automatically.
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		local entity = Entity.new(character, {
			-- custom variables
			Team = "Blue",
			Armor = 0.25,
			Level = 5,
			ScaleHumanoid = true, -- walk/jump dilate with local time

			-- custom function: crit-capable attack that scales with Level
			Attack = function(self, target, baseDamage, options)
				local damage = baseDamage * (1 + self.Level * 0.1)
				if options and options.Crit then
					damage *= 2
				end
				return self:DealDamage(target, damage, { Type = options and options.Type or "Melee" })
			end,
		})

		-- incoming damage scaling: armor reduces everything but fire
		entity:AddDamageModifier(function(amount, info)
			if info.Type == "Fire" then
				return amount
			end
			return amount * (1 - entity.Armor)
		end)

		-- outgoing damage scaling: +50% while berserk
		entity:AddOutgoingModifier(function(amount)
			return entity.Berserk and amount * 1.5 or amount
		end)

		entity.Damaged:Connect(function(amount, info)
			print(`{player.Name} took {amount} ({info.Type or "?"}) damage`)
		end)
		entity.Died:Connect(function()
			print(`{player.Name} died`)
		end)
	end)
end)

-- A pure-data entity (no instance) — e.g. an abstract objective.
local crystal = Entity.new(nil, {
	Health = 500,
	Regen = 5,
})
crystal:SetPosition(Vector3.new(0, 10, 0))

-- Regenerate using dilated time: regen slows inside slow chunks.
crystal:OnUpdate(function(dt, self)
	self:Heal(self.Regen * dt)
end)

-- NPC example: give every rig tagged "Zombie" in Workspace an entity.
for _, model in workspace:GetChildren() do
	if model:IsA("Model") and model.Name == "Zombie" then
		local zombie = Entity.new(model, { Team = "Undead", DestroyOnDeath = true })
		zombie:AddTag("Zombie")
	end
end
print(#Entity.GetTagged("Zombie"), "zombies registered")
