--!optimize 2
--[[
	Tools tab: give any Tool the server can find (DebugService.server.luau)
	or clear your backpack. Publishes the list to State.ToolNames.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)
local State = require(script.Parent.Parent.State)

return function(window)
	local tab = window:CreateTab({ Name = "Tools" })
	local buttons: { Instance } = {}

	local controls = tab:Row()
	controls:Button({
		Text = "Refresh",
		Callback = function()
			VisualOffload.Fire("DebugRequestTools")
		end,
	})
	controls:Button({
		Text = "Clear backpack",
		Callback = function()
			VisualOffload.Fire("DebugClearTools")
		end,
	})
	tab:Separator({ Text = "Click to give" })
	local empty = tab:Label({ Text = "Loading..." })

	VisualOffload.On("DebugTools", function(names)
		if typeof(names) ~= "table" then
			return
		end
		for _, button in buttons do
			button:Destroy()
		end
		table.clear(buttons)
		table.clear(State.ToolNames)
		empty.Text = if #names == 0 then "No tools found" else ""
		empty.Visible = #names == 0
		for _, name in names do
			if typeof(name) == "string" then
				table.insert(State.ToolNames, name)
				local button = tab:Button({
					Text = name,
					Callback = function()
						VisualOffload.Fire("DebugGiveTool", name)
					end,
				})
				table.insert(buttons, button)
			end
		end
	end)
	VisualOffload.Fire("DebugRequestTools")
	return {}
end
