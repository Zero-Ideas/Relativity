--!optimize 2
--[[
	Dummies tab: spawn test dummies (model, HP) at the cursor or in front of
	you; pick one of yours to move (to the cursor or to you), delete, or
	clear all. Replaces the old DummySpawner tool; spawning stays server-side
	in DummySpawner.server.luau.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)
local Util = require(script.Parent.Parent.Util)
local statLine = Util.statLine

local localPlayer = Players.LocalPlayer

-- Dummies tab: replaces the old DummySpawner tool. Spawning/moving/deleting
-- stays server-side in DummySpawner.server.luau ("DummySpawner" channel);
-- this only picks the model/HP and turns world clicks into requests.
local PLACE_ACTION = "DebugPlaceDummy"
local SELECTED_OUTLINE = Color3.fromRGB(80, 225, 255)

return function(window)
	local tab = window:CreateTab({ Name = "Dummies" })

	local models: { string } = { "Dummy" }
	local modelName = "Dummy"
	local mode: "Off" | "Place" | "Move" = "Off"
	local selected: Model? = nil
	local originalOutline: Color3? = nil

	local function folder(): Instance?
		return workspace:FindFirstChild("SpawnedTestDummies")
	end

	local modeLine = statLine(tab, "Mode")
	local picker = tab:Combo({
		Label = "Model",
		Placeholder = modelName,
		GetItems = function()
		return models
		end,
		Callback = function(_, value)
		modelName = value
		end,
	})
	local healthInput = tab:InputInt({ Label = "HP", Value = 1000, Increment = 100 })

	-- World point under the mouse, ignoring you and existing dummies.
	local function pointUnderMouse(): Vector3?
		local camera = workspace.CurrentCamera
		if not camera then
		return nil
		end
		local mouse = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local ignored: { Instance } = {}
		if localPlayer.Character then
		table.insert(ignored, localPlayer.Character)
		end
		local dummies = folder()
		if dummies then
		table.insert(ignored, dummies)
		end
		params.FilterDescendantsInstances = ignored
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
		return hit and hit.Position
	end

	local function deselect()
		local outline = selected and selected:FindFirstChild("TestDummyOutline")
		if outline and outline:IsA("Highlight") and originalOutline then
		outline.OutlineColor = originalOutline
		end
		selected, originalOutline = nil, nil
	end

	local refreshList -- defined below

	local function setMode(newMode: "Off" | "Place" | "Move")
		mode = newMode
		if mode == "Off" then
		ContextActionService:UnbindAction(PLACE_ACTION)
		modeLine("off")
		return
		end
		modeLine(if mode == "Place" then "placing: click the world (button again to stop)" else "moving: click where it goes")
		-- Claim world clicks (GUI clicks never reach this) so a held tool
		-- doesn't also fire.
		ContextActionService:BindActionAtPriority(PLACE_ACTION, function(_, state)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Sink
		end
		local point = pointUnderMouse()
		if point then
			if mode == "Move" and selected then
				VisualOffload.Fire("DummySpawner", { Action = "Move", Position = point, Dummy = selected })
				setMode("Off")
			elseif mode == "Place" then
				VisualOffload.Fire("DummySpawner", {
					Action = "Spawn", Position = point, Model = modelName, Health = healthInput.Value,
				})
			end
		end
		return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value + 100, Enum.UserInputType.MouseButton1)
	end

	local placeRow = tab:Row()
	placeRow:Button({
		Text = "Place at cursor",
		Callback = function()
		setMode(if mode == "Place" then "Off" else "Place")
		end,
	})
	placeRow:Button({
		Text = "Spawn in front of me",
		Callback = function()
		local character = localPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			VisualOffload.Fire("DummySpawner", {
				Action = "Spawn", Position = root.Position + root.CFrame.LookVector * 12,
				Model = modelName, Health = healthInput.Value,
			})
		end
		end,
	})

	tab:Separator({ Text = "Your dummies" })
	local entries: { [string]: Model } = {}
	local entryNames: { string } = {}
	local select -- forward-declared: the dropdown calls it
	local dummyPicker = tab:Combo({
		Label = "Dummy",
		Placeholder = "Select a dummy",
		GetItems = function()
		return entryNames
		end,
		Callback = function(_, value)
		local model = entries[value]
		if model then
			select(model)
		end
		end,
	})
	local infoLine = statLine(tab, "Selected")
	local manageRow = tab:Row()
	manageRow:Button({
		Text = "Move to cursor",
		Callback = function()
		if selected then
			setMode("Move")
		end
		end,
	})
	manageRow:Button({
		Text = "Bring to me",
		Callback = function()
		local character = localPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if selected and root and root:IsA("BasePart") then
			VisualOffload.Fire("DummySpawner", {
				Action = "Move", Position = root.Position + root.CFrame.LookVector * 8, Dummy = selected,
			})
		end
		end,
	})
	manageRow:Button({
		Text = "Delete",
		Callback = function()
		if selected then
			local dummy = selected
			deselect()
			VisualOffload.Fire("DummySpawner", { Action = "Delete", Dummy = dummy })
		end
		end,
	})
	tab:Button({
		Text = "Clear all my dummies",
		Callback = function()
		deselect()
		setMode("Off")
		VisualOffload.Fire("DummySpawner", { Action = "Clear" })
		end,
	})

	local function labelFor(model: Model, index: number): string
		return `{index}. {model.Name}`
	end

	-- Re-reads your dummies (dropdown entries + selected dummy's live stats).
	function refreshList()
		local mine = {}
		local dummies = folder()
		for _, model in if dummies then dummies:GetChildren() else {} do
		if model:IsA("Model") and model:GetAttribute("SpawnedBy") == localPlayer.UserId then
			table.insert(mine, model)
		end
		end
		if selected and not table.find(mine, selected) then
		deselect()
		if mode == "Move" then
			setMode("Off")
		end
		end
		table.clear(entries)
		entryNames = {}
		for index, model in mine do
		local label = labelFor(model, index)
		entries[label] = model
		table.insert(entryNames, label)
		end
		if not selected then
		dummyPicker:SetValueText(if #mine == 0 then "None yet" else "Select a dummy")
		infoLine("-")
		return
		end
		local index = table.find(mine, selected) :: number
		dummyPicker:SetValueText(labelFor(selected, index))
		local humanoid = selected:FindFirstChildOfClass("Humanoid")
		local root = selected.PrimaryPart
		local character = localPlayer.Character
		local me = character and character:FindFirstChild("HumanoidRootPart")
		infoLine(string.format("%s  ·  %d dmg in %d hits%s",
		if humanoid then string.format("%.0f/%.0f HP", humanoid.Health, humanoid.MaxHealth) else "no humanoid",
		selected:GetAttribute("TotalDamage") or 0, selected:GetAttribute("HitCount") or 0,
		if root and me and me:IsA("BasePart") then string.format("  ·  %.0f studs away", (root.Position - me.Position).Magnitude) else ""))
	end

	function select(model: Model)
		deselect()
		selected = model
		local outline = model:FindFirstChild("TestDummyOutline")
		if outline and outline:IsA("Highlight") then
		originalOutline = outline.OutlineColor
		outline.OutlineColor = SELECTED_OUTLINE
		end
		refreshList()
	end

	VisualOffload.On("DummyModels", function(data)
		if typeof(data) == "table" and typeof(data.Models) == "table" and #data.Models > 0 then
		models = data.Models
		if not table.find(models, modelName) then
			modelName = data.Default or models[1]
		end
		picker:SetValueText(modelName)
		end
	end)

	local function setActive(active: boolean)
		if active then
		VisualOffload.Fire("DummySpawner", { Action = "Models" })
		refreshList()
		elseif mode ~= "Off" then
		setMode("Off") -- never leave world clicks captured behind a hidden tab
		end
	end

	setMode("Off")
	return { Active = setActive, Tick = refreshList }
end
