--!optimize 2
-- Client controller for the Studio-only DilationBubble test tool.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VisualOffload = require(ReplicatedStorage:WaitForChild("Shared").VisualOffload)
local Gui = require(script.Parent.Parent.DilationBubbleGui)

local Controller = {}
local activationConnection: RBXScriptConnection? = nil

function Controller.Equip(tool: Tool, _character: Model)
	if activationConnection then
		activationConnection:Disconnect()
	end
	Gui.Start()
	Gui.SetVisible(true)
	local mouse = Players.LocalPlayer:GetMouse()
	activationConnection = tool.Activated:Connect(function()
		local config = Gui.GetConfig()
		VisualOffload.Fire("DilationBubbleTest", {
			Action = "Create",
			Position = mouse.Hit.Position,
			Scale = config.Scale,
			Radius = config.Radius,
			Duration = config.Duration,
		})
	end)
end

function Controller.Unequip(_tool: Tool, _character: Model)
	if activationConnection then
		activationConnection:Disconnect()
		activationConnection = nil
	end
	Gui.SetVisible(false)
end

return Controller
