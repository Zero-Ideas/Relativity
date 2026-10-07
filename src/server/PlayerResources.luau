--!strict
-- Player attributes are the replicated source of truth; Entity owns health
-- and supplies the same world/chunk/personal clock used by combat.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Entity = require(Shared.Entity)

-- Retire the old per-character stamina/sprint writer, preserving its source.
local dataFolder = game:GetService("StarterPlayer").StarterCharacterScripts:FindFirstChild("DataFolder")
local scripts = dataFolder and dataFolder:FindFirstChild("Scripts")
local legacy = scripts and scripts:FindFirstChild("Server")
if legacy and legacy:IsA("Script") then legacy.Disabled = true end

local Resources = {}
Resources.Settings = table.freeze({
	MaxMana = 1000, ManaRegen = 25,
	MaxStamina = 1000, StaminaRegen = 25,
	SprintDrain = 15, SprintMultiplier = 1.6,
	FlipCost = 60, FlipCooldown = 1.15,
})
local settings = Resources.Settings
local remote = Instance.new("RemoteEvent")
remote.Name = "PlayerMovement"
remote.Parent = ReplicatedStorage
local lastRequest: { [Player]: number } = {}
local lastFlip: { [Player]: number } = {}

local function finite(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

function Resources.Initialize(player: Player)
	if player:GetAttribute("MaxMana") == nil then
		player:SetAttribute("MaxMana", settings.MaxMana)
		player:SetAttribute("Mana", settings.MaxMana)
		player:SetAttribute("MaxStamina", settings.MaxStamina)
		player:SetAttribute("Stamina", settings.MaxStamina)
		player:SetAttribute("Sprinting", false)
	end
end

function Resources.Consume(player: Player, resource: string, amount: number): boolean
	if (resource ~= "Mana" and resource ~= "Stamina") or not finite(amount) or amount < 0 then return false end
	local current = player:GetAttribute(resource)
	if not finite(current) or current < amount then return false end
	player:SetAttribute(resource, current - amount)
	return true
end

local function setSprint(player: Player, enabled: boolean)
	player:SetAttribute("Sprinting", enabled)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then humanoid:SetAttribute("SprintMultiplier", if enabled then settings.SprintMultiplier else 1) end
	local entity = character and Entity.Get(character)
	if entity then entity._lastHumanoidScale = nil end
end

remote.OnServerEvent:Connect(function(player: Player, action: any)
	if action ~= "ToggleSprint" and action ~= "Flip" then return end
	local now = os.clock()
	if lastRequest[player] and now - lastRequest[player] < 0.1 then return end
	lastRequest[player] = now
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local entity = character and Entity.Get(character)
	if not humanoid or humanoid.Health <= 0 or not entity or entity:GetEffectiveTimeScale() <= 0 then return end
	if action == "ToggleSprint" then
		setSprint(player, player:GetAttribute("Sprinting") ~= true and (player:GetAttribute("Stamina") or 0) > 0)
	elseif humanoid.FloorMaterial ~= Enum.Material.Air
		and (not lastFlip[player] or now - lastFlip[player] >= settings.FlipCooldown)
		and Resources.Consume(player, "Stamina", settings.FlipCost) then
		lastFlip[player] = now
		remote:FireClient(player, "Flip", entity:GetEffectiveTimeScale())
	end
end)

local function onPlayer(player: Player)
	Resources.Initialize(player)
	player.CharacterAdded:Connect(function()
		setSprint(player, false)
		player:SetAttribute("Stamina", player:GetAttribute("MaxStamina"))
		lastFlip[player] = nil
	end)
	player.CharacterRemoving:Connect(function() setSprint(player, false) end)
end
Players.PlayerAdded:Connect(onPlayer)
for _, player in Players:GetPlayers() do onPlayer(player) end
Players.PlayerRemoving:Connect(function(player)
	lastRequest[player], lastFlip[player] = nil, nil
end)

local elapsed = 0
RunService.Heartbeat:Connect(function(dt: number)
	elapsed += dt
	if elapsed < 0.1 then return end
	local interval = elapsed
	elapsed = 0
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local entity = character and Entity.Get(character)
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not entity or not humanoid or humanoid.Health <= 0 then
			if player:GetAttribute("Sprinting") then setSprint(player, false) end
			continue
		end
		local scaledDt = interval * entity:GetEffectiveTimeScale()
		if scaledDt <= 0 then continue end
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local moving = root and root:IsA("BasePart") and (root.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude > 0.5
		local draining = player:GetAttribute("Sprinting") == true and moving
		for _, resource in { "Mana", "Stamina" } do
			local current, maximum = player:GetAttribute(resource), player:GetAttribute("Max" .. resource)
			if not finite(current) or not finite(maximum) then continue end
			local rate = if resource == "Mana" then settings.ManaRegen
				elseif draining then -settings.SprintDrain else settings.StaminaRegen
			local nextValue = math.clamp(current + rate * scaledDt, 0, math.max(maximum, 0))
			if nextValue ~= current then player:SetAttribute(resource, nextValue) end
		end
		if (player:GetAttribute("Stamina") or 0) <= 0 then setSprint(player, false) end
	end
end)

return Resources
