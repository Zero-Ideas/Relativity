--[[
	DummyManager (server)
	Owns the Workspace "Dummy" NPC:
	 - registers it as an Entity (so bullets damage it and homing can find it),
	 - tags it "Enemy" (the shooter's homing locks onto this tag),
	 - respawns a fresh rig a few seconds after it dies.

	A pristine clone is taken at startup and used as the respawn template.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Entity = require(Shared.Entity)

local SPAWN_CFRAME = CFrame.new(24, 5, 24)
local RESPAWN_DELAY = 3
local MAX_HEALTH = 100

local template: Model? = nil
local spawnDummy -- forward declaration

local function registerDummy(model: Model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.MaxHealth = MAX_HEALTH
		humanoid.Health = MAX_HEALTH
	end

	local entity = Entity.new(model, {
		Team = "Undead",
		ScaleHumanoid = true, -- moves/reacts in dilated time inside slow chunks
	})
	entity:AddTag("Enemy") -- homing targets this tag

	entity.Died:Connect(function()
		task.delay(RESPAWN_DELAY, function()
			if model.Parent then
				model:Destroy() -- clear the corpse
			end
			spawnDummy()
		end)
	end)

	return entity
end

function spawnDummy()
	if not template then
		return
	end
	local model = template:Clone()
	model.Name = "Dummy"
	model:PivotTo(SPAWN_CFRAME)
	model.Parent = workspace
	registerDummy(model)
end

local existing = workspace:WaitForChild("Dummy", 10)
if not existing or not existing:IsA("Model") then
	warn("[Relativity] DummyManager: no Dummy rig found in Workspace")
	return
end

-- keep a pristine copy for respawns, then start a fresh managed instance
template = existing:Clone()
existing:Destroy()
spawnDummy()

print("[Relativity] dummy manager online")
