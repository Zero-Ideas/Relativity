--!strict
-- Player attributes are the replicated source of truth; Entity owns health
-- and supplies the same world/chunk/personal clock used by combat.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local FrameProfiler = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("FrameProfiler"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Entity = require(Shared.Entity)
local SpellSettings = require(Shared.SpellSettings)

-- Retire the old per-character stamina/sprint writer, preserving its source.
local dataFolder = game:GetService("StarterPlayer").StarterCharacterScripts:FindFirstChild("DataFolder")
local scripts = dataFolder and dataFolder:FindFirstChild("Scripts")
local legacy = scripts and scripts:FindFirstChild("Server")
if legacy and legacy:IsA("Script") then legacy.Disabled = true end

local Resources = {}
Resources.Settings = table.freeze({
	HealthRegen = 10, -- HP per second, passive (scaled by the player's time)
	MaxMana = 1000, ManaRegen = 25,
	MaxStamina = 1000, StaminaRegen = 25,
	SprintDrain = 15, SprintMultiplier = 1.6,
	FlipCost = 60, FlipCooldown = 1.15,
})
local settings = Resources.Settings
local remote = Instance.new("RemoteEvent")
remote.Name = "PlayerMovement"
remote.Parent = ReplicatedStorage
remote:SetAttribute("SprintMultiplier", settings.SprintMultiplier)
remote:SetAttribute("FlipCost", settings.FlipCost)
remote:SetAttribute("FlipCooldown", settings.FlipCooldown)
local lastSprintRequest: { [Player]: number } = {}
local lastFlip: { [Player]: number } = {}
local lastGrounded: { [Player]: number } = {}

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
	-- (admin game setting, on by default in Studio: casting costs nothing)
	if resource == "Mana" and SpellSettings.InfiniteMana() then return true end
	local current = player:GetAttribute(resource)
	if not finite(current) or current < amount then return false end
	player:SetAttribute(resource, current - amount)
	return true
end

-- Gives back a refund (capped at the maximum).
function Resources.Refund(player: Player, resource: string, amount: number)
	if (resource ~= "Mana" and resource ~= "Stamina") or not finite(amount) or amount <= 0 then return end
	local current, maximum = player:GetAttribute(resource), player:GetAttribute("Max" .. resource)
	if not finite(current) or not finite(maximum) then return end
	player:SetAttribute(resource, math.min(current + amount, maximum))
end

local function setSprint(player: Player, enabled: boolean)
	player:SetAttribute("Sprinting", enabled)
end

remote.OnServerEvent:Connect(function(player: Player, action: any, id: any, value: any, requestedCharacter: any)
	if action ~= "SetSprint" and action ~= "Flip" then return end
	if not finite(id) or id % 1 ~= 0 or id < 1 or id > 2^31 then return end
	local now = os.clock()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local entity = character and Entity.Get(character)
	local valid = character == requestedCharacter and humanoid ~= nil and humanoid.Health > 0
		and not humanoid.PlatformStand and entity ~= nil and entity:GetEffectiveTimeScale() > 0
	if action == "SetSprint" then
		if typeof(value) ~= "boolean" then return end
		if valid and (not lastSprintRequest[player] or now - lastSprintRequest[player] >= 0.05) then
			lastSprintRequest[player] = now
			setSprint(player, value and (player:GetAttribute("Stamina") or 0) > 0)
		end
		remote:FireClient(player, "SprintResult", id, player:GetAttribute("Sprinting") == true)
	else
		-- A predicted flip may already be airborne when this request arrives.
		-- Accept a short, server-observed ground grace; never trust a client
		-- flag or accept arbitrary client speed/cost/cooldown values.
		local grounded = humanoid and humanoid.FloorMaterial ~= Enum.Material.Air
		local recentlyGrounded = lastGrounded[player] and now - lastGrounded[player] <= 0.3
		local accepted = valid and (grounded or recentlyGrounded) and (not lastFlip[player] or now - lastFlip[player] >= settings.FlipCooldown)
			and Resources.Consume(player, "Stamina", settings.FlipCost)
		if accepted then
			lastFlip[player] = now
			lastGrounded[player] = nil
		end
		remote:FireClient(player, "FlipResult", id, accepted == true)
	end
end)

local function onPlayer(player: Player)
	Resources.Initialize(player)
	player.CharacterAdded:Connect(function()
		setSprint(player, false)
		player:SetAttribute("Stamina", player:GetAttribute("MaxStamina"))
		lastFlip[player] = nil
		lastGrounded[player] = nil
	end)
	player.CharacterRemoving:Connect(function() setSprint(player, false) end)
end
Players.PlayerAdded:Connect(onPlayer)
for _, player in Players:GetPlayers() do onPlayer(player) end
Players.PlayerRemoving:Connect(function(player)
	lastSprintRequest[player], lastFlip[player], lastGrounded[player] = nil, nil, nil
end)

local elapsed = 0
FrameProfiler.Connect(RunService.Heartbeat, "PlayerResources.Heartbeat", function(dt: number)
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
		if humanoid.FloorMaterial ~= Enum.Material.Air then lastGrounded[player] = os.clock() end
		if scaledDt <= 0 then continue end
		-- passive health regen (the place's StarterCharacterScripts "Health"
		-- script turns Roblox's own off)
		if humanoid.Health < humanoid.MaxHealth then
			entity:Heal(settings.HealthRegen * scaledDt)
		end
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
