--!strict
--[[
	Menu keybinds, configurable in Settings (Controls tab). Each action's key
	is a ClientSettings setting of Kind "key" (a KeyCode name, or "None");
	Bind(setting, handler) gives an action its handler, and the key is
	(re)bound through ContextActionService at a high priority -- so it beats
	the default camera's own bindings (it rotates on "." for one) -- whenever
	the setting changes. Keys do nothing while a TextBox has focus or with
	Alt held (Alt+key is left to debug shortcuts).

	A handler returns false to let the key through instead (e.g. Spells while
	the spell editor covers the screen).
]]

local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

local ClientSettings = require(script.Parent.ClientSettings)

local Keybinds = {}

local PRIORITY = Enum.ContextActionPriority.High.Value + 60

-- How a key reads in the UI ("." rather than "Period").
local SHORT: { [string]: string } = {
	Period = ".", Comma = ",", Slash = "/", Semicolon = ";", Quote = "'", LeftBracket = "[",
	RightBracket = "]", BackSlash = "\\", Minus = "-", Equals = "=", Backquote = "`",
	Zero = "0", One = "1", Two = "2", Three = "3", Four = "4", Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
	LeftShift = "LShift", RightShift = "RShift", LeftControl = "LCtrl", RightControl = "RCtrl",
	LeftAlt = "LAlt", RightAlt = "RAlt", Return = "Enter", None = "—",
}

function Keybinds.Label(keyName: string?): string
	if not keyName then
		return "—"
	end
	return SHORT[keyName] or keyName
end

-- The KeyCode a key setting holds now (nil when unbound).
function Keybinds.KeyCode(setting: string): Enum.KeyCode?
	local name = ClientSettings.Get(setting)
	if typeof(name) ~= "string" or name == "None" then
		return nil
	end
	local ok, code = pcall(function()
		return (Enum.KeyCode :: any)[name]
	end)
	return if ok then code else nil
end

local handlers: { [string]: () -> boolean? } = {}
local suspended = false

-- While true (Settings is waiting for a new key) no menu key does anything.
function Keybinds.SetSuspended(on: boolean)
	suspended = on
end
local changed = Instance.new("BindableEvent")
changed.Name = "KeybindsChanged" -- (shows up by name in debugging tools)
Keybinds.Changed = changed.Event -- (setting) a key moved: update hints

local function actionName(setting: string): string
	return "Keybind_" .. setting
end

local function bind(setting: string)
	local name = actionName(setting)
	ContextActionService:UnbindAction(name)
	local code = Keybinds.KeyCode(setting)
	local handler = handlers[setting]
	if not code or not handler then
		return
	end
	ContextActionService:BindActionAtPriority(name, function(_, state: Enum.UserInputState)
		if suspended or UserInputService:GetFocusedTextBox()
			or UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt) then
			return Enum.ContextActionResult.Pass
		end
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Sink
		end
		if handler() == false then
			return Enum.ContextActionResult.Pass
		end
		return Enum.ContextActionResult.Sink
	end, false, PRIORITY, code)
end

-- Gives the action behind key setting `setting` its handler.
function Keybinds.Bind(setting: string, handler: () -> boolean?)
	handlers[setting] = handler
	bind(setting)
end

ClientSettings.Changed:Connect(function(key: string?)
	for setting in handlers do
		if key == nil or key == setting then
			bind(setting)
			changed:Fire(setting)
		end
	end
end)

return Keybinds
