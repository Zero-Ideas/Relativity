--!strict
--[[
	The Settings window's Lighting tab: the player's own overrides of
	Lighting and everything under it (Atmosphere, Sky, post effects...),
	applied on this client only and saved with their settings (the
	"Lighting" entry of server/ClientSettings), plus the lens flare toggle
	(the "LensFlare" setting: PlayerGui.Lensflare.Frame, where all the flare
	lives).

	Overrides are kept as { ["<object>.<Property>"] = value }, where <object>
	is "@" for Lighting itself or the name of a child of Lighting; colours
	are saved as { r, g, b } (0..1). Anything not overridden keeps whatever
	the place (or a server script) sets. An overridden property is put back
	whenever something else changes it, so e.g. a day/night script can't
	undo the player's ClockTime -- reset it to hand it back.

	API:
	  LightingSettings.Load(saved)       -- the saved overrides (once, at start)
	  LightingSettings.Build(tab)        -- fills the Settings window's tab
	  LightingSettings.SetLensFlare(on)  -- show / hide the lens flare
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LightingSettings = {}

type Property = { name: string, kind: "number" | "boolean" | "color" | "text", min: number?, max: number? }

local function n(name: string, min: number, max: number): Property
	return { name = name, kind = "number", min = min, max = max }
end
local function b(name: string): Property
	return { name = name, kind = "boolean" }
end
local function c(name: string): Property
	return { name = name, kind = "color" }
end

-- What can be tuned, by class (Roblox has no property reflection at run
-- time). Any other post effect under Lighting still gets its Enabled box.
local PROPERTIES: { [string]: { Property } } = {
	Lighting = {
		n("ClockTime", 0, 24), { name = "TimeOfDay", kind = "text" }, n("GeographicLatitude", -90, 90),
		n("Brightness", 0, 10), n("ExposureCompensation", -3, 3),
		n("EnvironmentDiffuseScale", 0, 1), n("EnvironmentSpecularScale", 0, 1),
		b("GlobalShadows"), n("ShadowSoftness", 0, 1),
		c("Ambient"), c("OutdoorAmbient"), c("ColorShift_Top"), c("ColorShift_Bottom"),
		c("FogColor"), n("FogStart", 0, 10000), n("FogEnd", 0, 100000),
	},
	Atmosphere = { n("Density", 0, 1), n("Offset", 0, 1), c("Color"), c("Decay"), n("Glare", 0, 10), n("Haze", 0, 10) },
	Sky = { b("CelestialBodiesShown"), n("StarCount", 0, 5000), n("SunAngularSize", 0, 60), n("MoonAngularSize", 0, 60) },
	BloomEffect = { b("Enabled"), n("Intensity", 0, 5), n("Size", 0, 56), n("Threshold", 0, 4) },
	BlurEffect = { b("Enabled"), n("Size", 0, 56) },
	ColorCorrectionEffect = { b("Enabled"), n("Brightness", -1, 1), n("Contrast", -1, 1), n("Saturation", -1, 1), c("TintColor") },
	DepthOfFieldEffect = { b("Enabled"), n("FarIntensity", 0, 1), n("FocusDistance", 0, 200), n("InFocusRadius", 0, 50), n("NearIntensity", 0, 1) },
	SunRaysEffect = { b("Enabled"), n("Intensity", 0, 1), n("Spread", 0, 1) },
}

local function propertiesOf(object: Instance): { Property }?
	local list = PROPERTIES[object.ClassName]
	if list then
		return list
	end
	if object:IsA("PostEffect") then
		return { b("Enabled") }
	end
	return nil
end

local overrides: { [string]: any } = {}
local defaults: { [string]: any } = {} -- the value before the player's override
local writing = false -- (our own writes don't count as "something else changed it")
local watched: { [string]: boolean } = {}
local saveQueued = false

local function objectKey(object: Instance): string
	return if object == Lighting then "@" else object.Name
end

local function objectFor(name: string): Instance?
	if name == "@" then
		return Lighting
	end
	return Lighting:FindFirstChild(name)
end

local function encode(value: any): any
	if typeof(value) == "Color3" then
		return { value.R, value.G, value.B }
	end
	return value
end

local function decode(kind: string, value: any): any
	if kind == "color" then
		if typeof(value) == "table" and typeof(value[1]) == "number" and typeof(value[2]) == "number"
			and typeof(value[3]) == "number" then
			return Color3.new(math.clamp(value[1], 0, 1), math.clamp(value[2], 0, 1), math.clamp(value[3], 0, 1))
		end
		return nil
	elseif kind == "number" then
		return if typeof(value) == "number" and value == value then value else nil
	elseif kind == "boolean" then
		return if typeof(value) == "boolean" then value else nil
	end
	return if typeof(value) == "string" then value else nil
end

local function same(a: any, b: any): boolean
	if typeof(a) == "number" and typeof(b) == "number" then
		return math.abs(a - b) < 1e-4
	elseif typeof(a) == "Color3" and typeof(b) == "Color3" then
		return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B) < 1e-3
	end
	return a == b
end

local function propertyFor(object: Instance, name: string): Property?
	for _, property in propertiesOf(object) or {} do
		if property.name == name then
			return property
		end
	end
	return nil
end

local function write(object: Instance, name: string, value: any)
	writing = true
	pcall(function()
		(object :: any)[name] = value
	end)
	writing = false
end

local function read(object: Instance, name: string): any
	local ok, value = pcall(function()
		return (object :: any)[name]
	end)
	return if ok then value else nil
end

local function queueSave()
	if saveQueued then
		return
	end
	saveQueued = true
	task.delay(1, function()
		saveQueued = false
		local saved = {}
		for key, value in overrides do
			saved[key] = encode(value)
		end
		local remote = ReplicatedStorage:FindFirstChild("ClientSettings")
		if remote and remote:IsA("RemoteFunction") then
			pcall(remote.InvokeServer, remote, "Set", { Lighting = saved })
		end
	end)
end

-- Keeps an overridden property overridden when something else changes it.
local function watch(object: Instance, name: string)
	local key = objectKey(object) .. "." .. name
	if watched[key] then
		return
	end
	watched[key] = true
	local ok, signal = pcall(object.GetPropertyChangedSignal, object, name)
	if not ok then
		return
	end
	signal:Connect(function()
		if writing then
			return
		end
		local override = overrides[key]
		if override == nil then
			return
		end
		defaults[key] = read(object, name) -- (what it would be without us)
		write(object, name, override)
	end)
end

-- Overrides `object`'s `name` with `value` (nil or its own default: hand it back).
local function set(object: Instance, name: string, value: any)
	local key = objectKey(object) .. "." .. name
	if defaults[key] == nil then
		defaults[key] = read(object, name)
	end
	if value == nil or same(value, defaults[key]) then
		if overrides[key] ~= nil then
			overrides[key] = nil
			write(object, name, defaults[key])
			queueSave()
		end
		return
	end
	if overrides[key] ~= nil and same(overrides[key], value) then
		return
	end
	overrides[key] = value
	watch(object, name)
	write(object, name, value)
	queueSave()
end

-- Applies the saved overrides that belong to `object`.
local function applyTo(object: Instance)
	local prefix = objectKey(object) .. "."
	for key, value in overrides do
		if string.sub(key, 1, #prefix) == prefix then
			local name = string.sub(key, #prefix + 1)
			if defaults[key] == nil then
				defaults[key] = read(object, name)
			end
			watch(object, name)
			write(object, name, value)
		end
	end
end

function LightingSettings.Load(saved: any)
	if typeof(saved) ~= "table" then
		return
	end
	for key, value in saved do
		if typeof(key) ~= "string" then
			continue
		end
		local objectName, name = string.match(key, "^(.-)%.([%w_]+)$")
		if not objectName or not name then
			continue
		end
		local object = objectFor(objectName)
		local property = object and propertyFor(object, name)
		-- (a child that hasn't replicated yet: keep it as saved, decode on arrival)
		local decoded = if property then decode(property.kind, value) else value
		if decoded ~= nil then
			overrides[key] = decoded
		end
	end
	applyTo(Lighting)
	for _, child in Lighting:GetChildren() do
		applyTo(child)
	end
end

Lighting.ChildAdded:Connect(function(child)
	-- (decode anything loaded before it existed)
	local prefix = child.Name .. "."
	for key, value in overrides do
		if string.sub(key, 1, #prefix) == prefix then
			local property = propertyFor(child, string.sub(key, #prefix + 1))
			overrides[key] = if property then decode(property.kind, value) else nil
		end
	end
	applyTo(child)
end)

--------------------------------------------------------------------------------
-- The tab
--------------------------------------------------------------------------------

local function title(object: Instance): string
	if object == Lighting then
		return "Lighting"
	end
	return if object.Name == object.ClassName then object.Name else `{object.Name} ({object.ClassName})`
end

local function addGroup(tab: any, object: Instance)
	local properties = propertiesOf(object)
	if not properties then
		return
	end
	local header = tab:CollapsingHeader({ Title = title(object), Collapsed = object ~= Lighting })
	local controls: { [string]: any } = {}
	local building = true -- (ReGui runs callbacks on creation: not a change)
	local function current(property: Property): any
		local key = objectKey(object) .. "." .. property.name
		local value = overrides[key]
		if value == nil then
			value = read(object, property.name)
		end
		return value
	end
	for _, property in properties do
		local name = property.name
		local value = current(property)
		if value == nil then
			continue -- (not a property of this one after all)
		end
		local function change(newValue: any)
			if not building then
				set(object, name, newValue)
			end
		end
		if property.kind == "number" then
			controls[name] = header:SliderFloat({
				Label = name,
				Minimum = property.min,
				Maximum = property.max,
				Value = math.clamp(value, property.min or value, property.max or value),
				Format = "%.2f",
				Callback = function(_, v: number)
					change(v)
				end,
			})
		elseif property.kind == "boolean" then
			controls[name] = header:Checkbox({
				Label = name,
				Value = value == true,
				Callback = function(_, v: boolean)
					change(v)
				end,
			})
		elseif property.kind == "color" then
			controls[name] = header:SliderColor3({
				Label = name,
				Value = value,
				Callback = function(_, v: Color3)
					change(v)
				end,
			})
		else
			controls[name] = header:InputText({
				Label = name,
				Value = tostring(value),
				Callback = function(_, v: string)
					change(v)
				end,
			})
		end
	end
	header:Button({
		Text = "Reset " .. title(object),
		Callback = function()
			building = true
			for _, property in properties do
				set(object, property.name, nil)
				local control = controls[property.name]
				local value = read(object, property.name)
				if control and value ~= nil then
					pcall(function()
						if property.kind == "boolean" then
							control:SetTicked(value == true)
						else
							control:SetValue(if property.kind == "text" then tostring(value) else value)
						end
					end)
				end
			end
			building = false
		end,
	})
	building = false
end

function LightingSettings.Build(tab: any)
	tab:Label({
		Text = "Changes apply to your screen only and are saved with your settings.",
		TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
	})
	addGroup(tab, Lighting)
	for _, child in Lighting:GetChildren() do
		addGroup(tab, child)
	end
	-- (effects added later get their group at the end)
	Lighting.ChildAdded:Connect(function(child)
		addGroup(tab, child)
	end)
end

--------------------------------------------------------------------------------
-- Lens flare
--------------------------------------------------------------------------------

local LENS_FLARE = "lensflare" -- (the ScreenGui, any capitalisation)
local flareOn = true
local flareFrame: GuiObject? = nil
local flareConnection: RBXScriptConnection? = nil

local function applyFlare()
	local frame = flareFrame
	if frame then
		local visible = flareOn
		if frame.Visible ~= visible then
			frame.Visible = visible
		end
	end
end

local function findFlare(playerGui: Instance)
	for _, child in playerGui:GetChildren() do
		if child:IsA("ScreenGui") and string.lower(child.Name) == LENS_FLARE then
			local frame = child:FindFirstChild("Frame")
			if frame and frame:IsA("GuiObject") and frame ~= flareFrame then
				flareFrame = frame
				if flareConnection then
					flareConnection:Disconnect()
				end
				-- (switched off: keep it off whatever its own script does)
				flareConnection = frame:GetPropertyChangedSignal("Visible"):Connect(function()
					if not flareOn and frame.Visible then
						frame.Visible = false
					end
				end)
				applyFlare()
			end
			return
		end
	end
end

task.spawn(function()
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	findFlare(playerGui)
	-- (a respawn can re-copy it from StarterGui; its Frame can stream in later)
	playerGui.DescendantAdded:Connect(function(descendant)
		if descendant.Name == "Frame" or string.lower(descendant.Name) == LENS_FLARE then
			task.defer(findFlare, playerGui)
		end
	end)
end)

function LightingSettings.SetLensFlare(on: boolean)
	flareOn = on
	applyFlare()
end

return LightingSettings
