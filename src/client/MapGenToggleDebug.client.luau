--[[
	MapGenToggleDebug.client.luau
	Press G to show/hide the MapGen debug overlay (tinted regions, room size
	labels) against the real built geometry from MapGen.Builder. Fires a
	RemoteEvent so the server -- which owns the Visualizer instance -- can
	reparent the shared debug folder for everyone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

-- Looked up per press: the remote only exists while MapGenDemo is enabled,
-- and waiting for it at startup yielded forever whenever it wasn't.
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.G then
		local event = ReplicatedStorage:FindFirstChild("MapGenToggleDebug")
		if event and event:IsA("RemoteEvent") then
			event:FireServer()
		end
	end
end)
