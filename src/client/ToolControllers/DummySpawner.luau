--!strict
local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local VisualOffload = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").VisualOffload)

local Controller = {}
local activation: RBXScriptConnection? = nil
local CLEAR_ACTION = "ClearSpawnedTestDummies"
local SELECT_ACTION = "SelectSpawnedTestDummy"
local lastActivation = -math.huge
local selected: Model? = nil
local selectionConnection: RBXScriptConnection? = nil
local originalOutline: Color3? = nil

local function deselect()
	if selectionConnection then selectionConnection:Disconnect(); selectionConnection = nil end
	local outline = selected and selected:FindFirstChild("TestDummyOutline")
	if outline and outline:IsA("Highlight") and originalOutline then outline.OutlineColor = originalOutline end
	selected = nil
	originalOutline = nil
end

local function selectNearest(mouse: Mouse)
	if selected then deselect(); return end
	local camera = workspace.CurrentCamera
	local folder = workspace:FindFirstChild("SpawnedTestDummies")
	if not camera or not folder then return end
	local nearest: Model? = nil
	local distance = math.huge
	for _, model in folder:GetChildren() do
		if model:IsA("Model") and model.PrimaryPart and model:GetAttribute("SpawnedBy") == Players.LocalPlayer.UserId then
			-- WorldToScreenPoint matches Mouse.X/Y (including the GUI inset).
			local point, visible = camera:WorldToScreenPoint(model.PrimaryPart.Position)
			if visible then
				local offset = Vector2.new(point.X - mouse.X, point.Y - mouse.Y)
				local squared = offset:Dot(offset)
				if squared < distance then nearest = model; distance = squared end
			end
		end
	end
	selected = nearest
	if nearest then
		local outline = nearest:FindFirstChild("TestDummyOutline")
		if outline and outline:IsA("Highlight") then
			originalOutline = outline.OutlineColor
			outline.OutlineColor = Color3.fromRGB(80, 225, 255)
		end
		selectionConnection = nearest.Destroying:Connect(deselect)
	end
end

function Controller.Unequip(_tool: Tool, _character: Model)
	if activation then activation:Disconnect(); activation = nil end
	ContextActionService:UnbindAction(CLEAR_ACTION)
	ContextActionService:UnbindAction(SELECT_ACTION)
	deselect()
end

function Controller.Equip(tool: Tool, character: Model)
	Controller.Unequip(tool, character)
	local mouse = Players.LocalPlayer:GetMouse()
	activation = tool.Activated:Connect(function()
		local now = os.clock()
		if now - lastActivation < 0.25 then return end
		lastActivation = now
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local ignored: { Instance } = { character }
		local folder = workspace:FindFirstChild("SpawnedTestDummies")
		if folder then table.insert(ignored, folder) end
		params.FilterDescendantsInstances = ignored
		local ray = mouse.UnitRay
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
		if not hit then return end
		VisualOffload.Fire("DummySpawner", {
			Action = if selected then "Move" else "Spawn",
			Position = hit.Position,
			Dummy = selected,
		})
	end)
	ContextActionService:BindActionAtPriority(SELECT_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin then selectNearest(mouse) end
		return Enum.ContextActionResult.Sink
	end, true, Enum.ContextActionPriority.High.Value, Enum.KeyCode.E)
	ContextActionService:SetTitle(SELECT_ACTION, "Select dummy")
	ContextActionService:BindAction(CLEAR_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin then
			local dummy = selected
			deselect()
			VisualOffload.Fire("DummySpawner", { Action = if dummy then "Delete" else "Clear", Dummy = dummy })
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.KeyCode.R)
	ContextActionService:SetTitle(CLEAR_ACTION, "Remove / clear")
end

return Controller
