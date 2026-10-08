--!strict
--[[
	Topbar (TopbarPlus) and the switch between the two client UIs:

	- Ours (default): GameHud -- resource bars, spell cards, party panel.
	- Dev: the other developer's authored MainGui (MainHud.luau).

	Either way Roblox's Backpack stays hidden and spells cast without a Tool.
	Topbar icons:
	  Region  (left, first) -- where the server is (server/ServerRegion);
	                     opens the server browser (ServerBrowser.luau)
	  Menu    (left)  -- dropdown: show/hide the party panel
	  Party   (left)  -- the Party window (PartyWindow: Invite, Parties,
	                     Friends and Settings tabs)
	  Spells  (left)  -- the Spells window (SpellLibrary: loadout, library,
	                     encyclopedia; Edit / New spell open the editor)
	  Bell    (left)  -- the Messages window (Notifications.luau; key N); a new
	                     actionable notification (invite, join request) while
	                     it's closed badges and rings the bell and plays a ping
	  Debug   (left)  -- the debug panel (F2), for players allowed to use it
	  Gear    (right) -- the Settings window (SettingsWindow; key . )
	The spell editor's Library button opens the Spells window (SpellLibrary).
	Which UI shows is the player's "UI mode" setting (Settings window,
	Interface: Mode 1 = Ours, Mode 2 = Dev), saved with their settings. The
	current mode is also the LocalPlayer's "UiMode" attribute (client-only)
	for other UI.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Icon = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("TopbarPlus"))
local MainHud = require(script.Parent.MainHud)
local GameHud = require(script.Parent.GameHud)
local PartyWindow = require(script.Parent.PartyWindow)
local ServerBrowser = require(script.Parent.ServerBrowser)
local SpellLibrary = require(script.Parent.SpellLibrary)
local ClientSettings = require(script.Parent.ClientSettings)
local SettingsWindow = require(script.Parent.SettingsWindow)
local Notifications = require(script.Parent.Notifications)
local DebugPanel = require(script.Parent.DebugPanel)
local SpellAssemblerGui = require(script.Parent.SpellAssemblerGui)

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

-- "Roblox Bell Notifications Icon" (Creator Store decal 129757130172668),
-- shown through its thumbnail since a decal id isn't an image id
local BELL_IMAGE = "rbxthumb://type=Asset&id=129757130172668&w=150&h=150"
-- "Settings Gear Icon (GOOD)" (Creator Store decal 83508141054406, same
-- maker as the bell), shown through its thumbnail
local GEAR_IMAGE = "rbxthumb://type=Asset&id=83508141054406&w=150&h=150"
local PING_SOUND = "rbxasset://sounds/electronicpingshort.wav"

export type Mode = "Ours" | "Dev"

local UiMode = {}
local mode: Mode = "Ours"
local inboxIcon: any = nil

-- SetCoreGuiEnabled errors until the CoreScripts have registered it.
local function hideBackpack()
	task.spawn(function()
		for _ = 1, 20 do
			if pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack, false) then
				return
			end
			task.wait(0.25)
		end
	end)
end

local function apply()
	local ours = mode == "Ours"
	MainHud.SetEnabled(not ours)
	GameHud.SetEnabled(ours)
	-- (GameHud has its own controls; the compact casting panel is the dev UI's)
	SpellAssemblerGui.SetCompactHudEnabled(not ours)
	player:SetAttribute("UiMode", mode)
end

function UiMode.Get(): Mode
	return mode
end

-- (the setting's names for the two modes)
local SETTING_FOR: { [Mode]: string } = { Ours = "Mode 1", Dev = "Mode 2" }

local function follow()
	local wanted: Mode = if ClientSettings.Get("UiMode") == "Mode 2" then "Dev" else "Ours"
	if mode ~= wanted then
		mode = wanted
		apply()
	end
end

-- Switches the UI (saved as the player's "UI mode" setting).
function UiMode.Set(newMode: Mode)
	ClientSettings.Set("UiMode", SETTING_FOR[newMode])
end

local function buildTopbar()
	-- Server region (first): from server/ServerRegion; opens the server
	-- browser (join another server, or the best one in a region)
	local region = Icon.new():setName("ServerRegion"):oneClick()
	region.selected:Connect(ServerBrowser.Toggle)
	local function refreshRegion()
		local text = ReplicatedStorage:GetAttribute("ServerRegion")
		region:setLabel("🌐 " .. (if typeof(text) == "string" then text else "Locating…"))
	end
	ReplicatedStorage:GetAttributeChangedSignal("ServerRegion"):Connect(refreshRegion)
	refreshRegion()

	-- Menu dropdown (view options)
	local panelItem = Icon.new()
		:setLabel("Hide party panel")
		:setLabel("Show party panel", "Selected")
	panelItem.selected:Connect(function() GameHud.SetPartyPanelVisible(false) end)
	panelItem.deselected:Connect(function() GameHud.SetPartyPanelVisible(true) end)
	Icon.new()
		:setName("Menu")
		:setLabel("Menu")
		:setDropdown({ panelItem })

	-- Party: the Party window (Invite / Parties / Whitelist tabs)
	local party = Icon.new():setName("Party"):setLabel("Party"):oneClick()
	party.selected:Connect(function()
		PartyWindow.Toggle()
	end)

	-- Spell assembler
	local spells = Icon.new():setName("Spells"):setLabel("Spells"):oneClick()
	spells.selected:Connect(function()
		SpellLibrary.Toggle() -- (its Edit / New spell open the editor)
	end)

	-- Notification centre: badged with how many arrived since it was last
	-- opened
	local inbox = Icon.new()
		:setName("Notifications")
		:setImage(BELL_IMAGE)
		:setLabel("Notifications")
		:setCaptionHint(Enum.KeyCode.N)
		:oneClick()
	inbox.selected:Connect(function()
		inbox:clearNotices()
		Notifications.Toggle()
	end)
	inboxIcon = inbox
	-- a new notification while the window is closed: a count badge on the
	-- bell, the bell rings (wiggles) and a soft ping plays
	local ping = Instance.new("Sound")
	ping.SoundId = PING_SOUND
	ping.Volume = 0.35
	ping.Parent = script
	Notifications.Added:Connect(function(options)
		-- only ones that need an answer (buttons: invites, join requests)
		local actionable = options.Buttons ~= nil and #options.Buttons > 0
		if not actionable or Notifications.IsOpen() then
			return
		end
		inbox:notify()
		SoundService:PlayLocalSound(ping)
		local image = inbox:getInstance("IconImage")
		if image and image:IsA("GuiObject") then
			task.spawn(function()
				for _, angle in { 18, -16, 12, -8, 4, 0 } do
					local tween = TweenService:Create(image, TweenInfo.new(0.07, Enum.EasingStyle.Sine), { Rotation = angle })
					tween:Play()
					tween.Completed:Wait()
				end
			end)
		end
	end)

	-- Debug panel (F2 too), for players allowed to use it
	local debugIcon = Icon.new():setName("Debug"):setLabel("Debug"):oneClick()
	debugIcon.selected:Connect(DebugPanel.Toggle)
	local function refreshDebug()
		debugIcon:setEnabled(DebugPanel.IsAllowed())
	end
	DebugPanel.AccessChanged:Connect(refreshDebug)
	refreshDebug()

	-- Settings (gear): the player's own settings (SettingsWindow)
	local settingsIcon = Icon.new()
		:setName("Settings")
		:align("Right")
		:setImage(GEAR_IMAGE)
		:setLabel("Settings")
		:setCaptionHint(Enum.KeyCode.Period)
		:oneClick()
	settingsIcon.selected:Connect(SettingsWindow.Toggle)
end

-- N: Messages, . : Settings (not while typing)
local function bindKeys()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == Enum.KeyCode.N then
			if inboxIcon then
				inboxIcon:clearNotices()
			end
			Notifications.Toggle()
		elseif input.KeyCode == Enum.KeyCode.Period then
			SettingsWindow.Toggle()
		end
	end)
end

function UiMode.start()
	hideBackpack()
	ClientSettings.start() -- (defaults now, saved settings once loaded)
	task.spawn(MainHud.start) -- (waits for the authored MainGui)
	GameHud.start()
	buildTopbar()
	bindKeys()
	-- the spell editor's Library button
	SpellAssemblerGui.SetLibraryOpener(SpellLibrary.Open)
	apply()
	-- the UI mode is a setting (Settings window, Interface)
	follow()
	ClientSettings.Changed:Connect(follow)
end

return UiMode
