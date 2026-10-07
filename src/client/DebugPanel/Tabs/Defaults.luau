--!optimize 2
--[[
	Defaults tab (listed players only -- DebugPanel hides it from everyone
	else, and the server re-checks): forced spawn stats for every player
	character -- max health, walk speed, jump power (server/PlayerDefaults).
	Forcing is OFF by default (characters spawn as the game makes them); the
	checkbox turns it on for everyone alive and everyone who spawns, and off
	again restores the game's own defaults. While on, a change applies at once
	(health keeps its fraction of the old maximum). Per server: a new server
	starts off, at 100 / 16 / 50.

	Values follow ReplicatedStorage's "DefaultMaxHealth" / "DefaultWalkSpeed"
	/ "DefaultJumpPower" attributes. ReGui's InputInt fires its callback on
	every SetValue (typing, +/-, and the ones made here to follow the server),
	so a change is only sent when it differs from the server's value.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)

-- { stat, label, step, min, max } -- limits mirror server/PlayerDefaults.
local FIELDS = {
	{ "MaxHealth", "Max health", 10, 1, 1000000 },
	{ "WalkSpeed", "Walk speed", 1, 0, 500 },
	{ "JumpPower", "Jump power", 5, 0, 1000 },
}

local function serverValue(stat: string): number?
	local value = ReplicatedStorage:GetAttribute("Default" .. stat)
	return if typeof(value) == "number" then value else nil
end

return function(window)
	local tab = window:CreateTab({ Name = "Defaults" })

	local function forcing(): boolean
		return ReplicatedStorage:GetAttribute("DefaultsEnabled") == true
	end
	local forceBox = tab:Checkbox({
		Label = "Force these stats on every player",
		Value = forcing(),
		Callback = function(_, value: boolean)
			-- ReGui fires this on every SetTicked too; only send real changes
			if value ~= forcing() then
				VisualOffload.Fire("DebugSetDefaults", { Enabled = value })
			end
		end,
	})
	local status = tab:Label({ Text = "" })
	local function refreshForcing()
		if forceBox.Value ~= forcing() then
			forceBox:SetTicked(forcing())
		end
		status.Text = if forcing()
			then "ON: everyone has these stats now, and spawns with them."
			else "OFF: players spawn with the game's own stats. Values below are kept for when it's on."
	end
	ReplicatedStorage:GetAttributeChangedSignal("DefaultsEnabled"):Connect(refreshForcing)
	refreshForcing()

	local inputs: { [string]: any } = {}
	for _, field in FIELDS do
		local stat, label, step, minimum, maximum = field[1], field[2], field[3], field[4], field[5]
		inputs[stat] = tab:InputInt({
			Label = label,
			Value = serverValue(stat) or 0,
			Increment = step,
			Minimum = minimum,
			Maximum = maximum,
			Callback = function(_, value: number)
				if typeof(value) == "number" and value ~= serverValue(stat) then
					VisualOffload.Fire("DebugSetDefaults", { [stat] = value })
				end
			end,
		})
	end

	tab:Button({
		Text = "Reset to 100 HP / 16 speed / 50 jump",
		Callback = function()
			VisualOffload.Fire("DebugSetDefaults", { Reset = true })
		end,
	})

	-- follow the server (another admin's change, or a clamped value)
	for _, field in FIELDS do
		local stat = field[1]
		local function refresh()
			local value = serverValue(stat)
			local input = inputs[stat]
			if value and input.Value ~= value then
				input:SetValue(value)
			end
		end
		ReplicatedStorage:GetAttributeChangedSignal("Default" .. stat):Connect(refresh)
		refresh()
	end
	return {}
end
