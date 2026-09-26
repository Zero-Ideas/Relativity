--!optimize 2
-- Studio-only configuration panel for the DilationBubble test tool.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VisualOffload = require(ReplicatedStorage:WaitForChild("Shared").VisualOffload)

local DilationBubbleGui = {}

local fields = {
	{ Key = "Scale", Label = "Time scale", Min = 0, Max = 3, Value = 0.25 },
	{ Key = "Radius", Label = "Radius", Min = 8, Max = 256, Value = 64 },
	{ Key = "Duration", Label = "Duration (s)", Min = 0.25, Max = 30, Value = 8 },
}

local started = false
local screenGui: ScreenGui? = nil

function DilationBubbleGui.GetConfig()
	local result = {}
	for _, field in fields do
		result[field.Key] = field.Value
	end
	return result
end

function DilationBubbleGui.SetVisible(visible: boolean)
	if screenGui then
		screenGui.Enabled = visible
	end
end

local function build()
	local screen = Instance.new("ScreenGui")
	screen.Name = "DilationBubbleGui"
	screen.ResetOnSpawn = false
	screen.Enabled = false
	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	screenGui = screen

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = UDim2.new(0, 12, 0.5, 0)
	panel.Size = UDim2.fromOffset(250, 210)
	panel.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
	panel.BackgroundTransparency = 0.08
	panel.BorderSizePixel = 0
	panel.Parent = screen
	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 10)
	panelCorner.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(14, 9)
	title.Size = UDim2.new(1, -28, 0, 22)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 15
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(235, 240, 255)
	title.Text = "Dilation Bubble (Studio)"
	title.Parent = panel

	local help = Instance.new("TextLabel")
	help.BackgroundTransparency = 1
	help.Position = UDim2.fromOffset(14, 31)
	help.Size = UDim2.new(1, -28, 0, 28)
	help.Font = Enum.Font.Gotham
	help.TextSize = 12
	help.TextWrapped = true
	help.TextXAlignment = Enum.TextXAlignment.Left
	help.TextColor3 = Color3.fromRGB(165, 175, 195)
	help.Text = "Equip, then click the world to place a zone."
	help.Parent = panel

	for index, field in fields do
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Position = UDim2.fromOffset(14, 62 + (index - 1) * 32)
		row.Size = UDim2.new(1, -28, 0, 26)
		row.Parent = panel

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(0.55, 0, 1, 0)
		label.Font = Enum.Font.Gotham
		label.TextSize = 13
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextColor3 = Color3.fromRGB(210, 216, 230)
		label.Text = field.Label
		label.Parent = row

		local box = Instance.new("TextBox")
		box.AnchorPoint = Vector2.new(1, 0.5)
		box.Position = UDim2.new(1, 0, 0.5, 0)
		box.Size = UDim2.new(0.4, 0, 0, 23)
		box.BackgroundColor3 = Color3.fromRGB(38, 42, 56)
		box.BorderSizePixel = 0
		box.ClearTextOnFocus = false
		box.Font = Enum.Font.GothamMedium
		box.TextSize = 13
		box.TextColor3 = Color3.fromRGB(235, 240, 255)
		box.Text = tostring(field.Value)
		box.Parent = row
		local boxCorner = Instance.new("UICorner")
		boxCorner.CornerRadius = UDim.new(0, 5)
		boxCorner.Parent = box

		box.FocusLost:Connect(function()
			local value = tonumber(box.Text)
			if value and value == value then
				field.Value = math.clamp(value, field.Min, field.Max)
			end
			box.Text = tostring(field.Value)
		end)
	end

	local clear = Instance.new("TextButton")
	clear.Position = UDim2.fromOffset(14, 166)
	clear.Size = UDim2.new(1, -28, 0, 30)
	clear.BackgroundColor3 = Color3.fromRGB(116, 54, 74)
	clear.BorderSizePixel = 0
	clear.Font = Enum.Font.GothamBold
	clear.TextSize = 13
	clear.TextColor3 = Color3.fromRGB(255, 235, 240)
	clear.Text = "Clear My Bubbles"
	clear.Parent = panel
	local clearCorner = Instance.new("UICorner")
	clearCorner.CornerRadius = UDim.new(0, 6)
	clearCorner.Parent = clear
	clear.Activated:Connect(function()
		VisualOffload.Fire("DilationBubbleTest", { Action = "Clear" })
	end)
end

function DilationBubbleGui.Start()
	if started or not RunService:IsStudio() then
		return
	end
	started = true
	build()
end

return DilationBubbleGui
