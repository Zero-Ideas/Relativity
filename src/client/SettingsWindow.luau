--!strict
--[[
	The Settings window (ReGui; the topbar's gear): a dropdown, slider or
	checkbox for each ClientSettings setting, in Interface, Effects, Audio,
	and Advanced tabs. Changes apply at once and are saved for next time. The window
	keeps its place and follows changes made elsewhere (a reset, the saved
	settings arriving); closing hides it instead of destroying its controls.
]]

local ReGuiLoader = require(script.Parent.ReGuiLoader)
local ClientSettings = require(script.Parent.ClientSettings)

local SettingsWindow = {}

local open = false
local window: any = nil
local position: UDim2? = nil
local controls: { [string]: any } = {}
local loading = false

local function close()
	open = false
	if window then
		position = window.WindowFrame.Position
		window:SetVisible(false)
	end
end

local function build(ReGui: any)
	local created: any
	created = ReGui:TabsWindow({
		Title = "Settings",
		Size = UDim2.fromOffset(520, 400),
		NoCollapse = true,
		NoWindowRegistor = true,
		CloseCallback = function()
			close()
			return false
		end,
	})
	window = created
	created.WindowFrame.Position = position or UDim2.fromOffset(16, 70)
	local sections: {[string]: any} = {}
	for _, spec in ClientSettings.Specs do
		local section = sections[spec.Section]
		if not section then
			section = created:CreateTab({Name = spec.Section})
			sections[spec.Section] = section
		end
		local key = spec.Key
		if spec.Kind == "choice" then
			controls[key] = section:Combo({
				Label = spec.Label,
				Items = spec.Options,
				Selected = ClientSettings.Get(key),
				Placeholder = ClientSettings.Get(key),
				Callback = function(_, value: string)
					ClientSettings.Set(key, value)
				end,
			})
		elseif spec.Kind == "boolean" then
			controls[key] = section:Checkbox({
				Label = spec.Label,
				Value = ClientSettings.Get(key) == true,
				-- (ReGui also runs this on creation; Set ignores no-op changes)
				Callback = function(_, value: boolean)
					ClientSettings.Set(key, value)
				end,
			})
		else
			controls[key] = section:SliderInt({
				Label = spec.Label,
				Minimum = spec.Min,
				Maximum = spec.Max,
				Value = ClientSettings.Get(key),
				Callback = function(_, value: number)
					ClientSettings.Set(key, math.floor(value + 0.5))
				end,
			})
		end
		if spec.Description then
			section:Label({Text = spec.Description, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y})
		end
	end
	for _, section in sections do
		section:Separator()
		section:Button({ Text = "Reset all settings to defaults", Callback = ClientSettings.Reset })
	end
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
	if window then window:SetVisible(true); return end
	if loading then return end
	loading = true
	task.spawn(function()
		local ReGui = ReGuiLoader.Get()
		if ReGui and open and not window then
			build(ReGui)
		end
		loading = false
		if not ReGui then open = false end
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
