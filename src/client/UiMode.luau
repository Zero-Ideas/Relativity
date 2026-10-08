--!strict
--[[
	Topbar (TopbarPlus) and the switch between the three client UI layouts:

	- Ours: GameHud -- resource bars, spell cards, party panel.
	- Dev: the other developer's authored MainGui (MainHud.luau).
	- Mode3 (default): GameHud with the authored UI's centered deck/resource layout,
	  portrait spell cards with names on-card, and the unchanged tech hotbar.

	Either way Roblox's Backpack stays hidden and spells cast without a Tool.
	Topbar icons:
	  Region  (left, first) -- where the server is (server/ServerRegion);
	                     opens the server browser (ServerBrowser.luau)
	  Menu    (left)  -- dropdown: show/hide the party panel, Credits
	  Party   (left)  -- the Party window (PartyWindow: Invite, Parties,
	                     Friends and Settings tabs)
	  Spells  (left)  -- the Spells window (SpellLibrary: loadout, library,
	                     encyclopedia; Edit / New spell open the editor)
	  Bell    (left)  -- the Messages window (Notifications.luau); a new
	                     actionable notification (invite, join request) while
	                     it's closed badges and rings the bell and plays a ping
	  Debug   (left)  -- the debug panel, for players allowed to use it
	  Gear    (right) -- the Settings window (SettingsWindow)
	The spell editor's Library button opens the Spells window (SpellLibrary).
	Every menu (and the spell editor, and the spells / items hotbar switch)
	also has a key, set in Settings > Controls (Keybinds); the icons show it.
	Which UI shows is the player's "UI mode" setting (Settings window,
	Interface: Mode 1 = Ours, Mode 2 = Dev), saved with their settings. The
	current mode is also the LocalPlayer's "UiMode" attribute (client-only)
	for other UI. Either HUD hides while the spell editor is open (its glass
	is see-through), and the editor's look follows the "Spell editor
	opacity" / "background blur" settings.
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
local CreditsWindow = require(script.Parent.CreditsWindow)
local Notifications = require(script.Parent.Notifications)
local DebugPanel = require(script.Parent.DebugPanel)
local SpellAssemblerGui = require(script.Parent.SpellAssemblerGui)
local Keybinds = require(script.Parent.Keybinds)

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

-- "Roblox Bell Notifications Icon" (Creator Store decal 129757130172668),
-- shown through its thumbnail since a decal id isn't an image id
local BELL_IMAGE = "rbxthumb://type=Asset&id=129757130172668&w=150&h=150"
-- "Settings Gear Icon (GOOD)" (Creator Store decal 83508141054406, same
-- maker as the bell), shown through its thumbnail
local GEAR_IMAGE = "rbxthumb://type=Asset&id=83508141054406&w=150&h=150"
local PING_SOUND = "rbxasset://sounds/electronicpingshort.wav"

export type Mode = "Ours" | "Dev" | "Mode3"

local UiMode = {}
local mode: Mode = "Mode3"
local inboxIcon: any = nil
local hintIcons: { [string]: any } = {} -- key setting -> the topbar icon showing it
local editorOpen = false -- (the HUD hides behind the editor's glass)

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
	local ours = mode ~= "Dev"
	GameHud.SetLayout(if mode == "Mode3" then "Mode 3" else "Mode 1")
	MainHud.SetEnabled(not ours and not editorOpen)
	GameHud.SetEnabled(ours and not editorOpen)
	-- (GameHud has its own controls; the compact casting panel is the dev UI's)
	SpellAssemblerGui.SetCompactHudEnabled(not ours)
	player:SetAttribute("UiMode", mode)
end

function UiMode.Get(): Mode
	return mode
end

-- (the setting's names for the two modes)
local SETTING_FOR: { [Mode]: string } = { Ours = "Mode 1", Dev = "Mode 2", Mode3 = "Mode 3" }

local function follow()
	SpellAssemblerGui.SetAppearance(ClientSettings.Get("EditorOpacity"), ClientSettings.Get("EditorBlur"))
	local setting = ClientSettings.Get("UiMode")
	local wanted: Mode = if setting == "Mode 2" then "Dev" elseif setting == "Mode 3" then "Mode3" else "Ours"
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
	local creditsItem = Icon.new():setName("Credits"):setLabel("Credits"):oneClick()
	creditsItem.selected:Connect(CreditsWindow.Toggle)
	Icon.new()
		:setName("Menu")
		:setLabel("Menu")
		:setDropdown({ panelItem, creditsItem })

	-- Party: the Party window (Invite / Parties / Whitelist tabs)
	local party = Icon.new():setName("Party"):setLabel("Party"):oneClick()
	hintIcons.KeyParty = party
	party.selected:Connect(function()
		PartyWindow.Toggle()
	end)

	-- Spell assembler
	local spells = Icon.new():setName("Spells"):setLabel("Spells"):oneClick()
	hintIcons.KeySpells = spells
	spells.selected:Connect(function()
		SpellLibrary.Toggle() -- (its Edit / New spell open the editor)
	end)

	-- Notification centre: badged with how many arrived since it was last
	-- opened
	local inbox = Icon.new()
		:setName("Notifications")
		:setImage(BELL_IMAGE)
		:setLabel("Notifications")
		:oneClick()
	hintIcons.KeyNotifications = inbox
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
	hintIcons.KeyDebug = debugIcon
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
		:oneClick()
	hintIcons.KeySettings = settingsIcon
	settingsIcon.selected:Connect(SettingsWindow.Toggle)
end

-- The menu keys (Settings > Controls; see Keybinds). While the spell editor
-- covers the screen only its own key works; the rest let the key through.
local function bindKeys()
	local function menu(open: () -> ()): () -> boolean?
		return function()
			if editorOpen then
				return false
			end
			open()
			return true
		end
	end
	Keybinds.Bind("KeySpells", menu(SpellLibrary.Toggle))
	Keybinds.Bind("KeyParty", menu(function() PartyWindow.Toggle() end))
	Keybinds.Bind("KeyNotifications", menu(function()
		if inboxIcon then
			inboxIcon:clearNotices()
		end
		Notifications.Toggle()
	end))
	Keybinds.Bind("KeySettings", menu(SettingsWindow.Toggle))
	Keybinds.Bind("KeyDebug", menu(DebugPanel.Toggle))
	Keybinds.Bind("KeyEditor", function()
		SpellAssemblerGui.ToggleEditor()
		return true
	end)
	Keybinds.Bind("KeyHotbar", function()
		if editorOpen then return false end
		return GameHud.ToggleHotbar()
	end)

	-- the topbar icons show their key
	local function refreshHints()
		for setting, icon in hintIcons do
			local code = Keybinds.KeyCode(setting)
			pcall(function()
				icon:setCaptionHint(code)
			end)
		end
	end
	Keybinds.Changed:Connect(refreshHints)
	refreshHints()
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
	SpellAssemblerGui.OpenChanged:Connect(function(isOpen: boolean)
		editorOpen = isOpen
		apply()
	end)
	apply()
	-- the UI mode is a setting (Settings window, Interface)
	follow()
	ClientSettings.Changed:Connect(follow)
end

return UiMode
