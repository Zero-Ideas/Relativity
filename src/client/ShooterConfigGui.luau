--!optimize 2
--[[
	ShooterConfigGui (client)
	A side panel to tune the bullets the ShooterController fires: speed, damage,
	gravity, bounces, pierces, homing, etc. It just holds a config table; the
	ShooterController reads getConfig() when firing and sends it to the server,
	which clamps and applies it. Nothing here is authoritative.
]]

local Players = game:GetService("Players")

local ShooterConfigGui = {}

-- Field spec: order + metadata drives both the UI and the defaults.
-- kind "number" -> TextBox (clamped to min/max), "bool" -> toggle button.
local FIELDS = {
	{ key = "Speed", label = "Speed", kind = "number", min = 10, max = math.huge, default = 220 },
	{ key = "Acceleration", label = "Acceleration", kind = "number", min = -20000, max = math.huge, default = 0 },
	{ key = "MinSpeed", label = "Min speed", kind = "number", min = 0, max = 1000, default = 0 },
	{ key = "MaxSpeed", label = "Max speed", kind = "number", min = 0, max = math.huge, default = 1000 },
	{ key = "Damage", label = "Damage", kind = "number", min = 0, max = math.huge, default = 20 },
	{ key = "Lifetime", label = "Lifetime (s)", kind = "number", min = 0.1, max = math.huge, default = 4 },
	{ key = "Gravity", label = "Gravity", kind = "number", min = 0, max = 500, default = 0 },
	{ key = "Radius", label = "Radius (sphere)", kind = "number", min = 0, max = math.huge, default = 0 },
	{ key = "Bounces", label = "Bounces", kind = "number", min = 0, max = math.huge, default = 0 },
	{ key = "Restitution", label = "Restitution", kind = "number", min = 0, max = math.huge, default = 0.5 },
	{ key = "Pierces", label = "Pierces", kind = "number", min = 0, max = 10, default = 0 },
	{ key = "PierceFalloff", label = "Pierce falloff", kind = "number", min = 0, max = 1, default = 0.2 },
	{ key = "Homing", label = "Homing", kind = "bool", default = false },
	{ key = "Permalock", label = "Permalock", kind = "bool", default = false },
	{ key = "TurnRate", label = "Turn rate (deg)", kind = "number", min = 0, max = 360, default = 140 },
	{ key = "AcquireRadius", label = "Acquire radius", kind = "number", min = 0, max = math.huge, default = 60 },
}

local config = {}
for _, field in FIELDS do
	config[field.key] = field.default
end

local started = false

function ShooterConfigGui.getConfig()
	return table.clone(config)
end

local function makeRow(parent: Instance, field, layoutOrder: number)
	local row = Instance.new("Frame")
	row.Name = field.key
	row.Size = UDim2.new(1, 0, 0, 26)
	row.BackgroundTransparency = 1
	row.LayoutOrder = layoutOrder
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(0.58, 0, 1, 0)
	label.Font = Enum.Font.Gotham
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(210, 216, 230)
	label.Text = field.label
	label.Parent = row

	if field.kind == "number" then
		local box = Instance.new("TextBox")
		box.AnchorPoint = Vector2.new(1, 0.5)
		box.Position = UDim2.new(1, 0, 0.5, 0)
		box.Size = UDim2.new(0.4, 0, 0, 22)
		box.BackgroundColor3 = Color3.fromRGB(38, 42, 56)
		box.BorderSizePixel = 0
		box.Font = Enum.Font.GothamMedium
		box.TextSize = 13
		box.TextColor3 = Color3.fromRGB(235, 240, 255)
		box.ClearTextOnFocus = false
		box.Text = tostring(config[field.key])
		box.Parent = row
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 5)
		corner.Parent = box

		box.FocusLost:Connect(function()
			local n = tonumber(box.Text)
			if n then
				n = math.clamp(n, field.min, field.max)
				config[field.key] = n
			end
			box.Text = tostring(config[field.key])
		end)
	else -- bool
		local toggle = Instance.new("TextButton")
		toggle.AnchorPoint = Vector2.new(1, 0.5)
		toggle.Position = UDim2.new(1, 0, 0.5, 0)
		toggle.Size = UDim2.new(0.4, 0, 0, 22)
		toggle.BorderSizePixel = 0
		toggle.Font = Enum.Font.GothamMedium
		toggle.TextSize = 13
		toggle.Parent = row
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 5)
		corner.Parent = toggle

		local function render()
			local on = config[field.key] == true
			toggle.Text = on and "ON" or "OFF"
			toggle.BackgroundColor3 = on and Color3.fromRGB(70, 170, 90) or Color3.fromRGB(60, 64, 78)
			toggle.TextColor3 = Color3.fromRGB(240, 245, 255)
		end
		render()
		toggle.Activated:Connect(function()
			config[field.key] = not config[field.key]
			render()
		end)
	end
end

local function build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "ShooterConfigGui"
	screen.ResetOnSpawn = false
	screen.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 0.5)
	panel.Position = UDim2.new(1, -12, 0.5, 0)
	panel.Size = UDim2.fromOffset(240, 400)
	panel.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.Parent = screen
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(14, 8)
	title.Size = UDim2.new(1, -28, 0, 22)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 15
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(235, 240, 255)
	title.Text = "Shooter Settings"
	title.Parent = panel

	local list = Instance.new("ScrollingFrame")
	list.Position = UDim2.fromOffset(12, 36)
	list.Size = UDim2.new(1, -24, 1, -48)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	for i, field in FIELDS do
		makeRow(list, field, i)
	end
end

function ShooterConfigGui.start()
	if started then
		return
	end
	started = true
	build()
end

return ShooterConfigGui
