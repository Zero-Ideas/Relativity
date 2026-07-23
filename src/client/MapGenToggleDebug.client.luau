--[[
	MapGenToggleDebug.client.luau
	Press G to show/hide the MapGen debug overlay (tinted regions, room size
	labels) against the real built geometry from MapGen.Builder. Fires a
	RemoteEvent so the server -- which owns the Visualizer instance -- can
	reparent the shared debug folder for everyone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local event = ReplicatedStorage:WaitForChild("MapGenToggleDebug")

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.G then
		event:FireServer()
	end
end)
