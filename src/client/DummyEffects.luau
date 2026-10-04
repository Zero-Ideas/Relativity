--!strict
-- Damage feedback is local presentation; the server replicates a monotonic
-- pulse counter, letting repeated hits restart one tween per dummy.
local TweenService = game:GetService("TweenService")
local watched: { [Model]: boolean } = {}

local function watch(instance: Instance)
	if not instance:IsA("Model") or watched[instance] then return end
	watched[instance] = true
	local tween: Tween? = nil
	local pulseConnection: RBXScriptConnection? = nil
	local function flash()
		local pulse = instance:GetAttribute("DamagePulse")
		if typeof(pulse) ~= "number" or pulse <= 0 then return end
		local outline = instance:FindFirstChild("TestDummyOutline")
		if not outline or not outline:IsA("Highlight") then return end
		if tween then tween:Cancel(); tween:Destroy() end
		outline.FillColor = Color3.fromRGB(255, 40, 40)
		outline.FillTransparency = 0
		tween = TweenService:Create(outline, TweenInfo.new(0.15, Enum.EasingStyle.Linear), { FillTransparency = 1 })
		tween:Play()
	end
	pulseConnection = instance:GetAttributeChangedSignal("DamagePulse"):Connect(flash)
	instance.Destroying:Once(function()
		if pulseConnection then pulseConnection:Disconnect() end
		if tween then tween:Cancel(); tween:Destroy() end
		watched[instance] = nil
	end)
end

local function attach(folder: Instance)
	folder.ChildAdded:Connect(watch)
	for _, instance in folder:GetChildren() do watch(instance) end
end

local folder = workspace:FindFirstChild("SpawnedTestDummies")
if folder then
	attach(folder)
else
	local added: RBXScriptConnection? = nil
	added = workspace.ChildAdded:Connect(function(instance)
		if instance.Name == "SpawnedTestDummies" then
			if added then added:Disconnect() end
			attach(instance)
		end
	end)
end

return {}
