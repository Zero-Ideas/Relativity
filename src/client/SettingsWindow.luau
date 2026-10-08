--!strict
--[[
	The Settings window (ReGui; the topbar's gear): a dropdown, slider or
	checkbox for each ClientSettings setting, grouped into sections (the UI
	mode is under Interface), and Reset to
	defaults. Changes apply at once and are saved for next time. The window
	keeps its place and follows changes made elsewhere (a reset, the saved
	settings arriving).
]]

local ReGuiLoader = require(script.Parent.ReGuiLoader)
local ClientSettings = require(script.Parent.ClientSettings)

local SettingsWindow = {}

local open = false
local window: any = nil
local position: UDim2? = nil
local controls: { [string]: any } = {}

local function close()
	open = false
	if window then
		position = window.WindowFrame.Position
		window:Remove()
		window = nil
	end
	table.clear(controls)
end

local function build(ReGui: any)
	local created: any
	created = ReGui:Window({
		Title = "Settings",
		Size = UDim2.fromOffset(440, 330),
		NoCollapse = true,
		NoWindowRegistor = true,
		CloseCallback = function()
			if window == created then
				position = created.WindowFrame.Position
				window = nil
				table.clear(controls)
			end
			open = false
			return true
		end,
	})
	window = created
	created.WindowFrame.Position = position or UDim2.fromOffset(16, 70)
	local section = nil
	for _, spec in ClientSettings.Specs do
		if spec.Section ~= section then
			section = spec.Section
			created:Separator({ Text = section })
		end
		local key = spec.Key
		if spec.Kind == "choice" then
			controls[key] = created:Combo({
				Label = spec.Label,
				Items = spec.Options,
				Selected = ClientSettings.Get(key),
				Placeholder = ClientSettings.Get(key),
				Callback = function(_, value: string)
					ClientSettings.Set(key, value)
				end,
			})
		elseif spec.Kind == "boolean" then
			controls[key] = created:Checkbox({
				Label = spec.Label,
				Value = ClientSettings.Get(key) == true,
				-- (ReGui also runs this on creation; Set ignores no-op changes)
				Callback = function(_, value: boolean)
					ClientSettings.Set(key, value)
				end,
			})
		else
			controls[key] = created:SliderInt({
				Label = spec.Label,
				Minimum = spec.Min,
				Maximum = spec.Max,
				Value = ClientSettings.Get(key),
				Callback = function(_, value: number)
					ClientSettings.Set(key, math.floor(value + 0.5))
				end,
			})
		end
	end
	created:Separator()
	created:Button({ Text = "Reset to defaults", Callback = ClientSettings.Reset })
end

-- Follows changes made elsewhere (reset, saved settings loading).
ClientSettings.Changed:Connect(function()
	for _, spec in ClientSettings.Specs do
		local control = controls[spec.Key]
		if not control then
			continue
		end
		local value = ClientSettings.Get(spec.Key)
		pcall(function()
			if spec.Kind == "choice" then
				if control.Value ~= value then
					control:SetValue(value)
				end
			elseif spec.Kind == "boolean" then
				if control.Value ~= value then
					control:SetTicked(value == true)
				end
			elseif control.Value ~= value then
				control:SetValue(value)
			end
		end)
	end
end)

function SettingsWindow.Open()
	if open then
		return
	end
	open = true
	task.spawn(function()
		local ReGui = ReGuiLoader.Get()
		if ReGui and open and not window then
			build(ReGui)
		end
	end)
end

function SettingsWindow.Close()
	close()
end

function SettingsWindow.Toggle()
	if open then
		close()
	else
		SettingsWindow.Open()
	end
end

return SettingsWindow
