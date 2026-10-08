--!strict
-- Scale each anchored HUD region, not the whole screen coordinate system.
local Players = game:GetService("Players")
local HudScale = {}
local value = 1
local started = false
local watched: {[Instance]: boolean} = setmetatable({}, {__mode = "k"}) :: any
local scales: {[UIScale]: boolean} = setmetatable({}, {__mode = "k"}) :: any

local function region(instance: Instance)
	if not instance:IsA("GuiObject") then return end
	local scale = instance:FindFirstChild("PlayerHudScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "PlayerHudScale"
		scale.Parent = instance
	end
	if scale:IsA("UIScale") then scale.Scale = value; scales[scale] = true end
end

local function screen(instance: Instance)
	if not instance:IsA("ScreenGui") or (instance.Name ~= "GameHud" and instance.Name ~= "MainGui") or watched[instance] then return end
	watched[instance] = true
	instance.ChildAdded:Connect(region)
	for _, child in instance:GetChildren() do region(child) end
end

function HudScale.Set(percent: number)
	local nextValue = math.clamp(percent / 100, 0.7, 1.3)
	if started and value == nextValue then return end
	value = nextValue
	for scale in scales do
		if scale.Parent then scale.Scale = value else scales[scale] = nil end
	end
	if started then return end
	started = true
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	playerGui.ChildAdded:Connect(screen)
	for _, child in playerGui:GetChildren() do screen(child) end
end

return HudScale
