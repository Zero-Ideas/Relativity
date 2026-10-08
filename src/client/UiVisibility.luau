--!strict
-- Hide unintegrated/WIP interfaces without destroying them or changing the
-- active HUD's own visibility rules. Event-driven; no per-frame scans.
-- New integrated ScreenGuis can opt in with RelativityUiIntegrated = true.
-- Set it false to explicitly mark a UI as WIP, including a MainGui panel.
local Players = game:GetService("Players")

local UiVisibility = {}
local enabled = true
local started = false
local playerGui: PlayerGui

local INTEGRATED: { [string]: boolean } = {
	GameHud = true, MainGui = true,
	ReGuiWindows = true, ReGuiOverlays = true,
	TopbarStandard = true, TopbarCentered = true,
	TopbarStandardClipped = true, TopbarCenteredClipped = true,
	SpellCircleEditor = true, SpellCharge = true,
	SpellPreview = true, SpellTooltip = true,
	ShooterConfigGui = true, DilationBubbleGui = true, TimeControlGui = true,
	-- A world-camera effect, not an unfinished menu.
	Lensflare = true,
	-- Roblox's touch movement controls live in PlayerGui, not CoreGui.
	TouchGui = true,
}

type Entry = {
	object: Instance, property: string, requested: boolean, suppressed: boolean,
	connections: { RBXScriptConnection },
}
local entries: { [Instance]: Entry } = {}

local function read(entry: Entry): boolean
	return (entry.object :: any)[entry.property]
end

local function write(entry: Entry, value: boolean)
	if read(entry) ~= value then (entry.object :: any)[entry.property] = value end
end

local function integrated(object: Instance): boolean
	local override = object:GetAttribute("RelativityUiIntegrated")
	if typeof(override) == "boolean" then return override end
	if object:IsA("ScreenGui") then return INTEGRATED[object.Name] == true end
	-- Keep only the authored Mode 2 branches actually wired into MainHud.
	local parent = object.Parent
	if not parent then return true end
	if parent:IsA("ScreenGui") and parent.Name == "MainGui" then
		return object.Name == "Hotbar" or object.Name == "Controls"
	elseif parent.Name == "Controls" and parent.Parent and parent.Parent.Name == "MainGui" then
		return object.Name == "NavButtonContainer"
	elseif parent.Name == "NavButtonContainer" and parent.Parent and parent.Parent.Name == "Controls" then
		return object.Name == "BottomButtons"
	elseif parent.Name == "BottomButtons" and parent.Parent and parent.Parent.Name == "NavButtonContainer" then
		return object.Name == "SpellMenuButton" or object.Name == "b5"
	end
	return true
end

local function refresh(entry: Entry)
	local suppress = enabled and entry.object:IsDescendantOf(playerGui) and not integrated(entry.object)
	if suppress then
		if not entry.suppressed then entry.requested = read(entry) end
		entry.suppressed = true
		write(entry, false)
	elseif entry.suppressed then
		entry.suppressed = false
		write(entry, entry.requested)
	end
end

local function refreshAll()
	for _, entry in entries do refresh(entry) end
end

local function watch(object: Instance)
	if entries[object] then return end
	local property: string
	if object:IsA("ScreenGui") then
		property = "Enabled"
	elseif object:IsA("GuiObject") then
		local screen = object:FindFirstAncestorWhichIsA("ScreenGui")
		if not screen or screen.Name ~= "MainGui" then return end
		-- Watch integration boundaries, not every card, ornament and text label.
		local parent = object.Parent
		if parent ~= screen and parent and parent.Name ~= "Controls"
			and parent.Name ~= "NavButtonContainer" and parent.Name ~= "BottomButtons"
			and object:GetAttribute("RelativityUiIntegrated") == nil then return end
		property = "Visible"
	else
		return
	end
	local entry: Entry = {
		object = object, property = property, requested = (object :: any)[property],
		suppressed = false, connections = {},
	}
	entries[object] = entry
	table.insert(entry.connections, object:GetPropertyChangedSignal(property):Connect(function()
		if entry.suppressed then
			-- Remember attempts to show WIP UI; prevent scripts reopening it.
			-- Ignore our own false write, including deferred signal delivery.
			if read(entry) then entry.requested = true; write(entry, false) end
		else
			entry.requested = read(entry)
		end
	end))
	table.insert(entry.connections, object:GetAttributeChangedSignal("RelativityUiIntegrated"):Connect(function() refresh(entry) end))
	table.insert(entry.connections, object:GetPropertyChangedSignal("Name"):Connect(refreshAll))
	table.insert(entry.connections, object.AncestryChanged:Connect(function() refresh(entry) end))
	table.insert(entry.connections, object.Destroying:Connect(function()
		entries[object] = nil
		for _, connection in entry.connections do connection:Disconnect() end
	end))
	refresh(entry)
end

function UiVisibility.start()
	if started then return end
	started = true
	playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	playerGui.DescendantAdded:Connect(watch)
	for _, object in playerGui:GetDescendants() do watch(object) end
end

function UiVisibility.SetEnabled(on: boolean)
	enabled = on
	UiVisibility.start()
	refreshAll()
end

return UiVisibility
