--!optimize 2
--[[
	TimeControlGui.luau  (client)
	A small on-screen panel to scrub YOUR OWN personal time ratio -- it only
	ever affects this player's own movement and the bullets they fire, live,
	even ones already in flight (see MovementController.SetPersonalTimeScale
	and Projectile.luau's Step, which reads Source.TimeScale every tick), never
	the world or anyone else. Dragging the slider (or clicking a preset) does
	two things:
	  • applies the ratio locally right away (MovementController.
	    SetPersonalTimeScale) so the client feels responsive, and
	  • requests it from the server (VisualOffload "RequestPersonalTimeScale"),
	    which is authoritative, clamps it, applies it to this player's Entity,
	    and replies with the clamped value on "PersonalTimeScale" (to this
	    player only -- nobody else needs to know it).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)
local MovementController = require(script.Parent.MovementController)

local TimeControlGui = {}

local MIN_RATIO = 0
local MAX_RATIO = 3
local PRESETS = { 0, 0.25, 0.5, 1, 2 }

local started = false
local dragging = false
local currentRatio = 1
-- os.clock() of the last locally-initiated change; server echoes of older
-- throttled sends are ignored for a moment after it (both sides clamp to the
-- same range, so the echo never carries new information mid-drag)
local lastLocalChange = 0
local ECHO_GRACE = 0.3
local listeners: { (number) -> () } = {}

-- throttle network sends during a drag (local apply stays instant)
local SEND_INTERVAL = 0.05
local lastSent = 0
local pendingSend: number? = nil

-- built lazily in start(); nil when started headless (see DebugPanel.luau)
local track: Frame?
local fill: Frame?
local handle: Frame?
local valueLabel: TextLabel?

local function ratioToAlpha(ratio: number): number
	return math.clamp((ratio - MIN_RATIO) / (MAX_RATIO - MIN_RATIO), 0, 1)
end

local function render(ratio: number)
	if fill and handle and valueLabel then
		local alpha = ratioToAlpha(ratio)
		fill.Size = UDim2.new(alpha, 0, 1, 0)
		handle.Position = UDim2.new(alpha, 0, 0.5, 0)
		valueLabel.Text = string.format("Your Time  x%.2f", ratio)
	end
	for _, listener in listeners do
		task.spawn(listener, ratio)
	end
end

-- Throttled request to the authoritative server. Coalesces rapid drag updates
-- and always flushes the final value (see the flush loop in start()).
local function requestServer(ratio: number)
	local now = os.clock()
	if now - lastSent >= SEND_INTERVAL then
		lastSent = now
		pendingSend = nil
		VisualOffload.Fire("RequestPersonalTimeScale", ratio)
	else
		pendingSend = ratio
	end
end

-- Apply locally + tell the server. `fromNetwork` avoids echoing the server's
-- own reply back at it.
local function applyRatio(ratio: number, fromNetwork: boolean?)
	ratio = math.clamp(ratio, MIN_RATIO, MAX_RATIO)
	currentRatio = ratio
	render(ratio)
	if not fromNetwork then
		lastLocalChange = os.clock()
		MovementController.SetPersonalTimeScale(ratio) -- instant local feedback
		requestServer(ratio)
	end
end

local function alphaFromInput(inputX: number): number
	assert(track)
	local left = track.AbsolutePosition.X
	local width = track.AbsoluteSize.X
	if width <= 0 then
		return 0
	end
	return math.clamp((inputX - left) / width, 0, 1)
end

local function setFromInput(inputX: number)
	local alpha = alphaFromInput(inputX)
	applyRatio(MIN_RATIO + alpha * (MAX_RATIO - MIN_RATIO))
end

local function build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "TimeControlGui"
	screen.ResetOnSpawn = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -16)
	panel.Size = UDim2.fromOffset(360, 92)
	panel.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.Parent = screen
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.Parent = panel

	valueLabel = Instance.new("TextLabel")
	valueLabel.Name = "Value"
	valueLabel.BackgroundTransparency = 1
	valueLabel.Size = UDim2.new(1, 0, 0, 20)
	valueLabel.Font = Enum.Font.GothamBold
	valueLabel.TextSize = 15
	valueLabel.TextColor3 = Color3.fromRGB(235, 240, 255)
	valueLabel.TextXAlignment = Enum.TextXAlignment.Left
	valueLabel.Parent = panel

	-- slider track
	track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.new(0, 0, 0, 30)
	track.Size = UDim2.new(1, 0, 0, 8)
	track.BackgroundColor3 = Color3.fromRGB(45, 50, 65)
	track.BorderSizePixel = 0
	track.Parent = panel
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track

	fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0.33, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(90, 170, 255)
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	handle = Instance.new("Frame")
	handle.Name = "Handle"
	handle.AnchorPoint = Vector2.new(0.5, 0.5)
	handle.Position = UDim2.new(0.33, 0, 0.5, 0)
	handle.Size = UDim2.fromOffset(18, 18)
	handle.BackgroundColor3 = Color3.fromRGB(235, 240, 255)
	handle.BorderSizePixel = 0
	handle.ZIndex = 2
	handle.Parent = track
	local handleCorner = Instance.new("UICorner")
	handleCorner.CornerRadius = UDim.new(1, 0)
	handleCorner.Parent = handle

	-- preset buttons
	local presetRow = Instance.new("Frame")
	presetRow.Name = "Presets"
	presetRow.BackgroundTransparency = 1
	presetRow.Position = UDim2.new(0, 0, 0, 48)
	presetRow.Size = UDim2.new(1, 0, 0, 24)
	presetRow.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.Padding = UDim.new(0, 6)
	layout.Parent = presetRow

	for _, preset in PRESETS do
		local button = Instance.new("TextButton")
		button.Name = `Preset_{preset}`
		button.Size = UDim2.fromOffset(62, 24)
		button.BackgroundColor3 = Color3.fromRGB(38, 42, 56)
		button.BorderSizePixel = 0
		button.Font = Enum.Font.GothamMedium
		button.TextSize = 13
		button.TextColor3 = Color3.fromRGB(220, 226, 240)
		button.Text = preset == 0 and "Freeze" or string.format("x%.2g", preset)
		button.Parent = presetRow
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 6)
		bc.Parent = button
		button.Activated:Connect(function()
			applyRatio(preset)
		end)
	end

	-- drag handling
	local function beginDrag(input)
		dragging = true
		setFromInput(input.Position.X)
	end
	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			beginDrag(input)
		end
	end)
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			beginDrag(input)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromInput(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

TimeControlGui.MinRatio = MIN_RATIO
TimeControlGui.MaxRatio = MAX_RATIO
TimeControlGui.Presets = PRESETS

-- Same path as dragging the built-in slider: applies locally and requests it
-- from the server (throttled).
function TimeControlGui.SetRatio(ratio: number)
	applyRatio(ratio)
end

function TimeControlGui.GetRatio(): number
	return currentRatio
end

-- fn(ratio) after every change, local or server-confirmed.
function TimeControlGui.OnChanged(fn: (number) -> ())
	table.insert(listeners, fn)
end

-- options.Headless skips the built-in on-screen panel; another UI drives it
-- through SetRatio/OnChanged instead.
function TimeControlGui.start(options: { Headless: boolean? }?)
	if started then
		return
	end
	started = true

	if not (options and options.Headless) then
		build()
	end
	applyRatio(MovementController.GetPersonalTimeScale(), true)

	-- flush any coalesced send shortly after the last drag update
	task.spawn(function()
		while started do
			if pendingSend and os.clock() - lastSent >= SEND_INTERVAL then
				local value = pendingSend
				pendingSend = nil
				lastSent = os.clock()
				VisualOffload.Fire("RequestPersonalTimeScale", value)
			end
			task.wait(SEND_INTERVAL)
		end
	end)

	-- reconcile against the server's authoritative (possibly clamped) value;
	-- this only ever targets this player (see example/init.server.luau), never
	-- broadcast, since it's personal
	VisualOffload.On("PersonalTimeScale", function(scale)
		if not dragging and typeof(scale) == "number" and os.clock() - lastLocalChange > ECHO_GRACE then
			applyRatio(scale, true)
		end
	end)
end

return TimeControlGui
