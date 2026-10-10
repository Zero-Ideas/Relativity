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
	  MaxDetailed  projectiles with full effects (particles, lights, glow);
	               farther ones get fewer or none
	  (MaxDistance / MaxRendered / MaxUpdates also apply to beams; see
	  Projectile/Client BeamVisual and BeamChainVisual)
	  Glints       the cast glint on spell circles (off by default)
	  LensFlare    the sun's lens flare (PlayerGui.Lensflare.Frame). The
	               rest of the Lighting tab is LightingSettings: per-property
	               overrides of Lighting, saved as the "Lighting" entry.
	  EffectsIntensity / ReducedFlashes / CameraShake: local cosmetics only.
	  HudScale     both HUD modes, 70..130 percent.
	  SmoothAvatars  straight R15 limbs drawn as one smooth R6 piece each
	               (SmoothLimbs); local only.
	  EditorOpacity / EditorBlur  the spell editor's holographic glass: how
	               opaque it is (20..100 percent) and how much the world
	               behind it blurs (0 = off). UiMode hands them to the editor.
	  *Volume      local audio mix, 0..100 percent, multiplied by MasterVolume.
	  Key*         menu keybinds (Kind "key": a KeyCode name or "None"; see
	               Keybinds). Giving one action another's key swaps them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Signal"))

local ProjectileClient = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Projectile"):WaitForChild("Client"))
local Glint = require(script.Parent.SpellCastGlint)
local Presentation = require(ReplicatedStorage.Shared.ClientPresentation)
local ClientAudio = require(script.Parent.ClientAudio)
local HudScale = require(script.Parent.HudScale)
local LightingSettings = require(script.Parent.LightingSettings)
local Effects = require(script.Parent.Effects)
local UiVisibility = require(script.Parent.UiVisibility)
local SmoothLimbs = require(script.Parent.SmoothLimbs)

local remote = ReplicatedStorage:WaitForChild("ClientSettings") :: RemoteFunction

export type Spec = {
	Key: string,
	Label: string,
	Kind: "number" | "boolean" | "choice" | "key",
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
	{ Key = "UiMode", Label = "UI mode", Kind = "choice", Options = { "Mode 1", "Mode 2", "Mode 3" }, Default = "Mode 3", Section = "Interface" },
	{ Key = "HideUnintegratedUi", Label = "Hide everything not part of the UI", Kind = "boolean", Default = true, Section = "Interface", Description = "Hides unfinished and unintegrated interfaces. Keeps the active HUD, menus, effects, and tool controls. Turn off to preview WIP UI." },
	{ Key = "HudScale", Label = "HUD scale (%)", Kind = "number", Default = 100, Min = 70, Max = 130, Step = 5, Section = "Interface" },
	{ Key = "EditorOpacity", Label = "Spell editor opacity (%)", Kind = "number", Default = 60, Min = 20, Max = 100, Step = 5, Section = "Interface", Description = "How solid the spell editor's holographic panels are; lower shows more of the world behind." },
	{ Key = "EditorBlur", Label = "Spell editor background blur", Kind = "number", Default = 8, Min = 0, Max = 24, Step = 1, Section = "Interface", Description = "Blurs the world behind the spell editor (0 = off)." },
	{ Key = "EffectsIntensity", Label = "Particle effects intensity (%)", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Section = "Effects", Description = "Reduces cosmetic particles, not projectile bodies or hit detection." },
	{ Key = "ReducedFlashes", Label = "Reduced flashes", Kind = "boolean", Default = false, Section = "Effects", Description = "Dims explosion lighting and spell circles; suppresses cast glints." },
	{ Key = "CameraShake", Label = "Explosion camera shake (%)", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Section = "Effects" },
	{ Key = "SurfaceImpacts", Label = "Surface impact effects", Kind = "boolean", Default = true, Section = "Effects", Description = "Sparks, dust, splinters, splashes and debris that match what a shot or blade hit." },
	{ Key = "ProjectileStreaks", Label = "Fast projectile streaks", Kind = "boolean", Default = true, Section = "Effects", Description = "A motion streak behind very fast projectiles (supersonic: 1225+ studs/s, like the Railgun; the nearest 64)." },
	{ Key = "BladeTrails", Label = "Blade swing trails", Kind = "boolean", Default = true, Section = "Effects" },
	{ Key = "SmoothAvatars", Label = "Smooth avatar limbs", Kind = "boolean", Default = true, Section = "Effects", Description = "Draws straight R15 arms, legs and torsos as one smooth piece (no ridges at the joints); real R15 segments come back while an animation bends them." },
	{ Key = "Glints", Label = "Cast glints", Kind = "boolean", Default = false, Section = "Effects" },
	{ Key = "LensFlare", Label = "Lens flare", Kind = "boolean", Default = true, Section = "Lighting", Description = "The sun's lens flare. Everything under Lighting can be tuned below." },
	{ Key = "KeySpells", Label = "Spells menu", Kind = "key", Default = "B", Section = "Controls" },
	{ Key = "KeyEditor", Label = "Spell editor", Kind = "key", Default = "V", Section = "Controls" },
	{ Key = "KeyHotbar", Label = "Switch hotbar (spells / items)", Kind = "key", Default = "E", Section = "Controls" },
	{ Key = "KeyParty", Label = "Party", Kind = "key", Default = "P", Section = "Controls" },
	{ Key = "KeyNotifications", Label = "Notifications", Kind = "key", Default = "N", Section = "Controls" },
	{ Key = "KeySettings", Label = "Settings", Kind = "key", Default = "Period", Section = "Controls" },
	{ Key = "KeyDebug", Label = "Debug panel", Kind = "key", Default = "F2", Section = "Controls", Description = "Click a key, then press the new one (Esc cancels, Backspace unbinds)." },
	{ Key = "MasterVolume", Label = "Master volume (%)", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Section = "Audio" },
	{ Key = "SpellVolume", Label = "Spell / projectile volume (%)", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Section = "Audio" },
	{ Key = "ImpactVolume", Label = "Impact / explosion volume (%)", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Section = "Audio" },
	{ Key = "UiVolume", Label = "UI volume (%)", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Section = "Audio" },
	{ Key = "MusicVolume", Label = "Music volume (%)", Kind = "number", Default = 100, Min = 0, Max = 100, Step = 5, Section = "Audio" },
	{ Key = "MaxDistance", Label = "Projectile render distance (studs)", Kind = "number", Default = 2048, Min = 50, Max = 10000, Step = 50, Section = "Advanced", Description = "Beams too: the parts of a beam past this distance aren't drawn." },
	{ Key = "MaxRendered", Label = "Max rendered projectiles", Kind = "number", Default = 5000, Min = 0, Max = 50000, Step = 100, Section = "Advanced", Description = "WARNING: Projectiles rejected at this cap stay invisible but can still deal damage. Also caps the pieces drawn for sustained beams." },
	{ Key = "MaxSmooth", Label = "Max high-resolution projectiles (tweened)", Kind = "number", Default = 500, Min = 0, Max = 5000, Step = 25, Section = "Advanced" },
	{ Key = "MaxDetailed", Label = "Projectiles with full effects", Kind = "number", Default = 48, Min = 0, Max = 1000, Step = 8, Section = "Advanced", Description = "The nearest this many on screen get full particles, lights and glow; a few times as many farther ones get some; the rest none. Lower it if crowds of spells slow you down." },
	{ Key = "MaxUpdates", Label = "Projectile updates per frame", Kind = "number", Default = 2500, Min = 100, Max = 20000, Step = 100, Section = "Advanced", Description = "Sustained beams count each piece; past this they redraw in turns." },
} :: { Spec }

local values: { [string]: any } = {}
for _, spec in ClientSettings.Specs do
	values[spec.Key] = spec.Default
end

local pending: { [string]: any } = {} -- changes not saved yet
local saveQueued = false

local changedEvent = Signal.new()
ClientSettings.Changed = changedEvent

local function apply(key: string?)
	if not key or key == "HideUnintegratedUi" then
		UiVisibility.SetEnabled(values.HideUnintegratedUi == true)
	end
	if not key or key == "MaxDistance" or key == "MaxRendered" or key == "MaxSmooth" or key == "MaxUpdates"
		or key == "MaxDetailed" then
		ProjectileClient.SetRenderSettings({
			MaxDistance = values.MaxDistance,
			MaxRendered = values.MaxRendered,
			MaxSmooth = values.MaxSmooth,
			MaxUpdates = values.MaxUpdates,
			MaxDetailed = values.MaxDetailed,
		})
	end
	Presentation.Set(values.EffectsIntensity / 100, values.ReducedFlashes == true, values.CameraShake / 100)
	Glint.SetEnabled(values.Glints == true and not values.ReducedFlashes)
	Effects.Configure({
		SurfaceImpacts = values.SurfaceImpacts ~= false,
		ProjectileStreaks = values.ProjectileStreaks ~= false,
		BladeTrails = values.BladeTrails ~= false,
	})
	ClientAudio.SetVolumes(values.MasterVolume / 100, values.SpellVolume / 100, values.ImpactVolume / 100, values.UiVolume / 100, values.MusicVolume / 100)
	HudScale.Set(values.HudScale)
	LightingSettings.SetLensFlare(values.LensFlare ~= false)
	SmoothLimbs.SetEnabled(values.SmoothAvatars ~= false)
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

-- Is `value` a key setting's value: a KeyCode name or "None"?
function ClientSettings.IsKeyName(value: any): boolean
	if typeof(value) ~= "string" then
		return false
	end
	if value == "None" then
		return true
	end
	local ok, code = pcall(function()
		return (Enum.KeyCode :: any)[value]
	end)
	return ok and code ~= nil
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
	elseif spec.Kind == "key" then
		if not ClientSettings.IsKeyName(value) then
			return
		end
		-- (one key, one action: whoever had it takes this one's old key)
		if value ~= "None" and values[key] ~= value then
			for _, other in ClientSettings.Specs do
				if other.Kind == "key" and other.Key ~= key and values[other.Key] == value then
					local previous = values[key]
					values[key] = value -- (so the swap below doesn't bounce back)
					ClientSettings.Set(other.Key, previous)
					values[key] = previous
				end
			end
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
		LightingSettings.Load(saved.Lighting)
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
			elseif spec.Kind == "key" and ClientSettings.IsKeyName(value) then
				values[key] = value
			end
		end
		apply()
		changedEvent:Fire(nil, nil)
	end)
end

return ClientSettings
