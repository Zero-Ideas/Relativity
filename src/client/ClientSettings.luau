--!strict
--[[
	The player's own settings: defaults, applying them, and saving them
	(server/ClientSettings keeps them in a DataStore). The Settings window
	(SettingsWindow) edits them.

	  UiMode       the HUD: "Mode 1" (GameHud) or "Mode 2" (the authored
	               MainGui) -- UiMode follows it
	  MaxDistance  projectiles farther than this (studs) aren't drawn
	  MaxRendered  hard cap on admitted projectile visuals; excess creation
	               events are dropped, not simulated in the background
	  MaxSmooth    the nearest this many tween every frame ("high resolution")
	  MaxUpdates   projectile redraws per frame (purely visual: positions come
	               from elapsed time, so a visual left waiting catches up
	               exactly when next redrawn -- never out of sync)
	  Glints       the cast glint on spell circles (off by default)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProjectileClient = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Projectile"):WaitForChild("Client"))
local Glint = require(script.Parent.SpellCastGlint)

local remote = ReplicatedStorage:WaitForChild("ClientSettings") :: RemoteFunction

export type Spec = {
	Key: string,
	Label: string,
	Kind: "number" | "boolean" | "choice",
	Options: { string }?, -- (choice)
	Default: any,
	Min: number?,
	Max: number?,
	Step: number?,
	Section: string,
}

local ClientSettings = {}

-- (also the order and grouping of the Settings window)
ClientSettings.Specs = {
	{ Key = "UiMode", Label = "UI mode", Kind = "choice", Options = { "Mode 1", "Mode 2" }, Default = "Mode 1", Section = "Interface" },
	{ Key = "MaxDistance", Label = "Projectile render distance (studs)", Kind = "number", Default = 2048, Min = 50, Max = 10000, Step = 50, Section = "Projectiles" },
	{ Key = "MaxRendered", Label = "Max rendered projectiles", Kind = "number", Default = 5000, Min = 0, Max = 50000, Step = 100, Section = "Projectiles" },
	{ Key = "MaxSmooth", Label = "Max high-resolution projectiles (tweened)", Kind = "number", Default = 500, Min = 0, Max = 5000, Step = 25, Section = "Projectiles" },
	{ Key = "MaxUpdates", Label = "Projectile updates per frame", Kind = "number", Default = 2500, Min = 100, Max = 20000, Step = 100, Section = "Projectiles" },
	{ Key = "Glints", Label = "Cast glints", Kind = "boolean", Default = false, Section = "Effects" },
} :: { Spec }

local values: { [string]: any } = {}
for _, spec in ClientSettings.Specs do
	values[spec.Key] = spec.Default
end

local pending: { [string]: any } = {} -- changes not saved yet
local saveQueued = false

local changedEvent = Instance.new("BindableEvent")
ClientSettings.Changed = changedEvent.Event

local function apply()
	ProjectileClient.SetRenderSettings({
		MaxDistance = values.MaxDistance,
		MaxRendered = values.MaxRendered,
		MaxSmooth = values.MaxSmooth,
		MaxUpdates = values.MaxUpdates,
	})
	Glint.SetEnabled(values.Glints == true)
end

local function specOf(key: string): Spec?
	for _, spec in ClientSettings.Specs do
		if spec.Key == key then
			return spec
		end
	end
	return nil
end

function ClientSettings.Get(key: string): any
	return values[key]
end

-- Changes one setting: applied at once, saved shortly after.
function ClientSettings.Set(key: string, value: any)
	local spec = specOf(key)
	if not spec then
		return
	end
	if spec.Kind == "boolean" then
		value = value == true
	elseif spec.Kind == "choice" then
		if not table.find(spec.Options or {}, value) then
			return
		end
	else
		if typeof(value) ~= "number" or value ~= value then
			return
		end
		value = math.clamp(value, spec.Min or -math.huge, spec.Max or math.huge)
	end
	if values[key] == value then
		return
	end
	values[key] = value
	apply()
	changedEvent:Fire(key, value)
	-- (saved shortly after: dragging a slider changes it every frame)
	pending[key] = value
	if not saveQueued then
		saveQueued = true
		task.delay(1, function()
			saveQueued = false
			local batch = pending
			pending = {}
			pcall(remote.InvokeServer, remote, "Set", batch)
		end)
	end
end

function ClientSettings.Reset()
	for _, spec in ClientSettings.Specs do
		ClientSettings.Set(spec.Key, spec.Default)
	end
end

-- Applies the defaults now, then the saved settings once they've loaded.
function ClientSettings.start()
	apply()
	task.spawn(function()
		local ok, saved = pcall(remote.InvokeServer, remote, "Get")
		if not ok or typeof(saved) ~= "table" then
			return
		end
		for key, value in saved do
			local spec = specOf(key)
			if not spec then
				continue
			end
			if spec.Kind == "choice" then
				if table.find(spec.Options or {}, value) then
					values[key] = value
				end
			elseif typeof(value) == spec.Kind then
				values[key] = value
			end
		end
		apply()
		changedEvent:Fire(nil, nil)
	end)
end

return ClientSettings
