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
	  EffectsIntensity / ReducedFlashes / CameraShake: local cosmetics only.
	  HudScale     both HUD modes, 70..130 percent.
	  *Volume      local audio mix, 0..100 percent, multiplied by MasterVolume.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProjectileClient = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Projectile"):WaitForChild("Client"))
local Glint = require(script.Parent.SpellCastGlint)
local Presentation = require(ReplicatedStorage.Shared.ClientPresentation)
local ClientAudio = require(script.Parent.ClientAudio)
local HudScale = require(script.Parent.HudScale)

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
	Description: string?,
}

local ClientSettings = {}

-- (also the order and grouping of the Settings window)
ClientSettings.Specs = {
	{ Key = "UiMode", Label = "UI mode", Kind = "choice", Options = { "Mode 1", "Mode 2" }, Default = "Mode 1", Section = "Interface" },
	{ Key = "HudScale", Label = "HUD scale (%)", Kind = "number", Default = 100, Min = 70, Max = 130, Step = 5, Section = "Interface" },
	{ Key = "EffectsIntensity", Label = "Particle effects intensity (%)", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Section = "Effects", Description = "Reduces cosmetic particles, not projectile bodies or hit detection." },
	{ Key = "ReducedFlashes", Label = "Reduced flashes", Kind = "boolean", Default = false, Section = "Effects", Description = "Dims explosion lighting and spell circles; suppresses cast glints." },
	{ Key = "CameraShake", Label = "Explosion camera shake (%)", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Section = "Effects" },
	{ Key = "Glints", Label = "Cast glints", Kind = "boolean", Default = false, Section = "Effects" },
	{ Key = "MasterVolume", Label = "Master volume (%)", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Section = "Audio" },
	{ Key = "SpellVolume", Label = "Spell / projectile volume (%)", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Section = "Audio" },
	{ Key = "ImpactVolume", Label = "Impact / explosion volume (%)", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Section = "Audio" },
	{ Key = "UiVolume", Label = "UI volume (%)", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Section = "Audio" },
	{ Key = "MusicVolume", Label = "Music volume (%)", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Section = "Audio" },
	{ Key = "MaxDistance", Label = "Projectile render distance (studs)", Kind = "number", Default = 2048, Min = 50, Max = 10000, Step = 50, Section = "Advanced" },
	{ Key = "MaxRendered", Label = "Max rendered projectiles", Kind = "number", Default = 5000, Min = 0, Max = 50000, Step = 100, Section = "Advanced", Description = "WARNING: Projectiles rejected at this cap stay invisible but can still deal damage." },
	{ Key = "MaxSmooth", Label = "Max high-resolution projectiles (tweened)", Kind = "number", Default = 500, Min = 0, Max = 5000, Step = 25, Section = "Advanced" },
	{ Key = "MaxUpdates", Label = "Projectile updates per frame", Kind = "number", Default = 2500, Min = 100, Max = 20000, Step = 100, Section = "Advanced" },
} :: { Spec }

local values: { [string]: any } = {}
for _, spec in ClientSettings.Specs do
	values[spec.Key] = spec.Default
end

local pending: { [string]: any } = {} -- changes not saved yet
local saveQueued = false

local changedEvent = Instance.new("BindableEvent")
ClientSettings.Changed = changedEvent.Event

local function apply(key: string?)
	if not key or key == "MaxDistance" or key == "MaxRendered" or key == "MaxSmooth" or key == "MaxUpdates" then
		ProjectileClient.SetRenderSettings({
			MaxDistance = values.MaxDistance,
			MaxRendered = values.MaxRendered,
			MaxSmooth = values.MaxSmooth,
			MaxUpdates = values.MaxUpdates,
		})
	end
	Presentation.Set(values.EffectsIntensity / 100, values.ReducedFlashes == true, values.CameraShake / 100)
	Glint.SetEnabled(values.Glints == true and not values.ReducedFlashes)
	ClientAudio.SetVolumes(values.MasterVolume / 100, values.SpellVolume / 100, values.ImpactVolume / 100, values.UiVolume / 100, values.MusicVolume / 100)
	HudScale.Set(values.HudScale)
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
	apply(key)
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
			elseif spec.Kind == "number" and typeof(value) == "number" and value == value then
				values[key] = math.clamp(value, spec.Min or -math.huge, spec.Max or math.huge)
			elseif spec.Kind == "boolean" and typeof(value) == "boolean" then
				values[key] = value
			end
		end
		apply()
		changedEvent:Fire(nil, nil)
	end)
end

return ClientSettings
