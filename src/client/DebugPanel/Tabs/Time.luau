--!optimize 2
--[[
	Time tab: your personal time ratio. Drives TimeControlGui headless, so
	the apply/throttle/server-reconcile logic stays in one place.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(script.Parent.Parent.Util)
local Heartbeat = require(Shared.Heartbeat)
local TimeControlGui = require(script.Parent.Parent.Parent.TimeControlGui)
local statLine = Util.statLine

return function(window)
	local tab = window:CreateTab({ Name = "Time" })
	-- SliderBase fires its callback from SetValue (including at creation);
	-- only forward changes that differ from what TimeControlGui already has.
	local slider = tab:SliderFloat({
		Label = "Your time",
		Minimum = TimeControlGui.MinRatio,
		Maximum = TimeControlGui.MaxRatio,
		Value = TimeControlGui.GetRatio(),
		Format = "x%.2f",
		Callback = function(_, value: number)
			if math.abs(value - TimeControlGui.GetRatio()) > 1e-4 then
				TimeControlGui.SetRatio(value)
			end
		end,
	})

	local presets = tab:Row()
	for _, preset in TimeControlGui.Presets do
		presets:Button({
			Text = if preset == 0 then "Freeze" else string.format("x%.2g", preset),
			Callback = function()
				TimeControlGui.SetRatio(preset)
			end,
		})
	end

	local globalLine = statLine(tab, "World time")
	TimeControlGui.OnChanged(function(ratio)
		if math.abs((slider.Value or 0) - ratio) > 1e-4 then
			slider:SetValue(ratio)
		end
	end)
	return {
		Tick = function()
			globalLine(string.format("x%.2f", Heartbeat.GetGlobalTimeScale()))
		end,
	}
end
