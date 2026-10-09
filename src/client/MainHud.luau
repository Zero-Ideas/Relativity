--!strict
-- Adapter for the authored MainGui. No legacy cache/remotes or polling loop.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local FrameProfiler = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("FrameProfiler"))
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local SpellEditor = require(script.Parent.SpellAssemblerGui)
local SpellCardPreview = require(script.Parent.SpellCardPreview)
local player = Players.LocalPlayer

local Hud = {}
local started = false
local enabled = false -- UiMode explicitly grants input ownership to this HUD.
local gui: ScreenGui? = nil
local uiConnections: { RBXScriptConnection } = {}
local characterConnections: { RBXScriptConnection } = {}
local animatorConnection: RBXScriptConnection? = nil
local humanoid: Humanoid? = nil
type Bar = { fill: Frame, label: TextLabel, value: number, target: number }
local bars: { [string]: Bar } = {}
local slots: { any } = {}

local function disconnect(list: { RBXScriptConnection })
	for _, connection in list do connection:Disconnect() end
	table.clear(list)
end

local function animate()
	if animatorConnection then return end
	animatorConnection = FrameProfiler.Connect(RunService.RenderStepped, "MainHud.RenderStepped", function(dt)
		local unfinished = false
		local alpha = 1 - math.exp(-14 * dt)
		for _, bar in bars do
			if bar.value == bar.target then continue end
			bar.value += (bar.target - bar.value) * alpha
			if math.abs(bar.target - bar.value) < 0.001 then bar.value = bar.target else unfinished = true end
			bar.fill.Size = UDim2.fromScale(bar.value, 1)
		end
		if not unfinished and animatorConnection then animatorConnection:Disconnect(); animatorConnection = nil end
	end)
end

local function refreshStats()
	for name, bar in bars do
		local current = if name == "Health" then (humanoid and humanoid.Health or 0) else player:GetAttribute(name)
		local maximum = if name == "Health" then (humanoid and humanoid.MaxHealth or 0) else player:GetAttribute("Max" .. name)
		current = if typeof(current) == "number" then current else 0
		maximum = if typeof(maximum) == "number" then maximum else 0
		local text = string.format("%s: %d / %d", name, math.floor(current), math.floor(maximum))
		if bar.label.Text ~= text then bar.label.Text = text end
		local target = if maximum > 0 then math.clamp(current / maximum, 0, 1) else 0
		if target ~= bar.target then bar.target = target; animate() end
	end
end

local function refreshCards()
	local state = SpellEditor.GetState()
	for index, slot in slots do
		local record = state.slots and (state.slots[index] or state.slots[tostring(index)])
		-- Hide the layout item itself so UIListLayout closes the gap. Keep the
		-- original slot number/shortcut and independent cooldown when hidden.
		slot.frame.Visible = record ~= nil
		if not record then
			for _, preview in slot.previews do preview:Destroy() end
			table.clear(slot.previews)
			continue
		end
		local selected = SpellEditor.GetSelectedSlot() == index
		slot.visual.Size = UDim2.fromScale(if selected then 1.1 else 1, if selected then 1.1 else 1)
		slot.visual.AnchorPoint = if selected then slot.anchor else Vector2.zero
		for _, card in slot.visual:GetChildren() do
			if not card:IsA("Frame") then continue end
			local preview = slot.previews[card]
			if not preview then
				card.BackgroundColor3 = Color3.new(0, 0, 0)
				for _, object in card:GetChildren() do
					if object:IsA("ImageLabel") then object.Visible = false end
					if object:IsA("TextLabel") then object.ZIndex = 8 end
					if object:IsA("GuiButton") then object.ZIndex = 10 end
				end
				preview = SpellCardPreview.new(card, true)
				slot.previews[card] = preview
			end
			preview:SetSpell(record)
			preview:SetSelected(selected)
			local deadline = player:GetAttribute("SpellCooldownEndsAt" .. index) or 0
			if deadline > workspace:GetServerTimeNow() and preview.Deadline ~= deadline then preview:Cooldown(deadline, false) end
			local outline = card:FindFirstChild("OverlayStroke")
			if outline and outline:IsA("UIStroke") then outline.Enabled = false end
			local title, caption = card:FindFirstChild("TopText"), card:FindFirstChild("BtmText")
			if title and title:IsA("TextLabel") then title.Text = record.name end
			if caption and caption:IsA("TextLabel") then caption.Text = if selected then "Active spell" else "Select spell" end
		end
	end
end

local function sound(name: string)
	local instance = gui and gui:FindFirstChild(name)
	if instance and instance:IsA("Sound") then instance:Play() end
end

local function bindGui(screen: ScreenGui)
	if gui == screen then return end
	disconnect(uiConnections)
	if animatorConnection then animatorConnection:Disconnect(); animatorConnection = nil end
	table.clear(bars)
	for _, slot in slots do for _, preview in slot.previews do preview:Destroy() end end
	table.clear(slots)
	gui = screen
	screen.ResetOnSpawn = false
	screen.Enabled = enabled
	local legacy = screen:FindFirstChild("Display")
	if legacy and legacy:IsA("LocalScript") then legacy.Disabled = true end
	local hotbar = screen:FindFirstChild("Hotbar")
	if hotbar then
		for _, name in { "Health", "Mana", "Stamina" } do
			local frame = hotbar:FindFirstChild(name)
			local fill = frame and frame:FindFirstChild("Overlay")
			local label = frame and frame:FindFirstChild("Display_Text")
			if fill and fill:IsA("Frame") and label and label:IsA("TextLabel") then
				bars[name] = { fill = fill, label = label, value = fill.Size.X.Scale, target = fill.Size.X.Scale }
			end
		end
		local deck = hotbar:FindFirstChild("Deck")
		for index = 1, 5 do
			local slot = deck and deck:FindFirstChild("Slot" .. index)
			local visual = slot and slot:FindFirstChild("Visual")
			local selector = visual and visual:FindFirstChild("Selector")
			if slot and visual and visual:IsA("Frame") and selector and selector:IsA("GuiButton") then
				local ax, ay = slot:FindFirstChild("apX"), slot:FindFirstChild("apY")
				selector.ZIndex = 10
				slots[index] = { frame = slot, visual = visual, previews = {}, anchor = Vector2.new(if ax and ax:IsA("NumberValue") then ax.Value else 0.5, if ay and ay:IsA("NumberValue") then ay.Value else 1) }
				table.insert(uiConnections, selector.Activated:Connect(function() sound("Select"); SpellEditor.SelectSlot(index) end))
				table.insert(uiConnections, visual.MouseEnter:Connect(function() sound("Hover") end))
			end
		end
	end
	local controls = screen:FindFirstChild("Controls")
	local nav = controls and controls:FindFirstChild("NavButtonContainer")
	local buttons = nav and nav:FindFirstChild("BottomButtons")
	if buttons then
		for _, frame in buttons:GetChildren() do
			local selector = frame:FindFirstChild("Selector")
			if not selector or not selector:IsA("GuiButton") then continue end
			local stroke = frame:FindFirstChildOfClass("UIStroke")
			table.insert(uiConnections, selector.MouseEnter:Connect(function() sound("Hover"); if stroke then stroke.Color = Color3.new(1, 1, 1) end end))
			table.insert(uiConnections, selector.MouseLeave:Connect(function() if stroke then stroke.Color = Color3.new(0, 0, 0) end end))
			if frame.Name == "SpellMenuButton" or frame.Name == "b5" then
				frame.Name = "SpellMenuButton"
				local hint = frame:FindFirstChild("Hint")
				if hint and hint:IsA("TextLabel") then hint.Text = "Spells [V]" end
				table.insert(uiConnections, selector.Activated:Connect(function() sound("Select"); SpellEditor.Toggle() end))
			end
		end
	end
	refreshStats()
	refreshCards()
end

local function bindCharacter(character: Model)
	disconnect(characterConnections)
	humanoid = nil
	local found = character:WaitForChild("Humanoid", 10)
	if player.Character ~= character or not found or not found:IsA("Humanoid") then return end
	humanoid = found
	table.insert(characterConnections, found.HealthChanged:Connect(refreshStats))
	table.insert(characterConnections, found:GetPropertyChangedSignal("MaxHealth"):Connect(refreshStats))
	refreshStats()
end

local SLOT_KEYS = { [Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3, [Enum.KeyCode.Four] = 4, [Enum.KeyCode.Five] = 5 }

-- Own the spell-card shortcuts so Roblox's Backpack cannot equip a weapon
-- on the same keypress. Weapons remain selectable from the Backpack UI.
local function bindSlotKeys()
	ContextActionService:BindActionAtPriority("MainHudSpellSlots", function(_, state, input)
		if UserInputService:GetFocusedTextBox() or SpellEditor.IsOpen() then return Enum.ContextActionResult.Pass end
		if state == Enum.UserInputState.Begin then task.spawn(SpellEditor.SelectSlot, SLOT_KEYS[input.KeyCode]) end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 50, Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five)
end

-- Shows or hides the HUD and its 1-5 card shortcuts. Locomotion is separate.
function Hud.SetEnabled(on: boolean)
	if enabled == on then return end
	enabled = on
	if gui then gui.Enabled = on end
	if not started then return end
	if on then
		bindSlotKeys()
		refreshStats()
		refreshCards()
	else
		ContextActionService:UnbindAction("MainHudSpellSlots")
	end
end

function Hud.start()
	if started then return end
	started = true
	SpellEditor.start()
	for _, name in { "Mana", "MaxMana", "Stamina", "MaxStamina" } do player:GetAttributeChangedSignal(name):Connect(refreshStats) end
	SpellEditor.StateChanged:Connect(refreshCards)
	SpellEditor.SpellFired:Connect(function(data)
		local slot = slots[data.Slot]
		if slot then for _, preview in slot.previews do preview:Cooldown(data.EndsAt, true, data.ManaSpent) end end
	end)
	player.CharacterAdded:Connect(bindCharacter)
	player.CharacterRemoving:Connect(function() disconnect(characterConnections); humanoid = nil; refreshStats() end)
	if player.Character then task.spawn(bindCharacter, player.Character) end
	if enabled then bindSlotKeys() end
	local playerGui = player:WaitForChild("PlayerGui")
	playerGui.ChildAdded:Connect(function(child) if child.Name == "MainGui" and child:IsA("ScreenGui") then bindGui(child) end end)
	local screen = playerGui:FindFirstChild("MainGui")
	if screen and screen:IsA("ScreenGui") then bindGui(screen) end
end

return Hud
