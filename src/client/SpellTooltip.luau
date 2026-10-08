--!strict
-- One retained tooltip for all spell cards. No frame connection while idle.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local GuiService = game:GetService("GuiService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Compiler = require(Shared.SpellCompiler)
local Runes = require(Shared.SpellRunes)
local Encyclopedia = require(Shared.SpellEncyclopedia)
local Decoration = require(script.Parent.SpellCardDecoration)
local Tooltip = {}
local bindings: { [GuiObject]: any } = {}
local active: any = nil
local connection: RBXScriptConnection? = nil
local screen: ScreenGui? = nil
local panel: Frame? = nil
local title: TextLabel? = nil
local body: TextLabel? = nil
local stroke: UIStroke? = nil
local cache: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any

function Tooltip.Describe(record: any): (string, number)
	local cached = cache[record]
	if cached then return cached.text, cached.cost end
	local graph = record.graph
	local compiled = graph and Compiler.Compile(graph)
	local cost = if compiled then compiled.manaCost else 0
	local id = record.encyclopedia
	if not id and typeof(record.ref) == "string" and string.sub(record.ref, 1, 2) == "e:" then id = string.sub(record.ref, 3) end
	local preset = id and Encyclopedia.Get(id)
	local description = record.description or (preset and preset.Description)
	if typeof(description) ~= "string" or description == "" then
		local elements, vessels, modifiers, triggers, seen = {}, {}, {}, {}, {}
		for _, rune in (graph and graph.runes) or {} do
			local def = Runes.Get(rune.rune)
			if not def or seen[def.Id] then continue end
			seen[def.Id] = true
			if Runes.Elements[def.Id] then table.insert(elements, def.Name)
			elseif def.Vessel then table.insert(vessels, def.Name)
			elseif def.Category == "Modifier" then table.insert(modifiers, def.Name)
			elseif def.Category == "Trigger" then table.insert(triggers, def.Name) end
		end
		description = (if #elements > 0 then table.concat(elements, "/") .. " " else "")
			.. (if #vessels > 0 then table.concat(vessels, " + ") else "Custom spell") .. "."
		if #modifiers > 0 then description ..= "\nModifiers: " .. table.concat(modifiers, ", ") .. "." end
		if #triggers > 0 then description ..= "\nTriggers: " .. table.concat(triggers, ", ") .. "." end
	end
	local text = description .. (if compiled then string.format("\n\nCost: %.0f mana", cost) else "\n\nThis spell does not currently compile.")
	cache[record] = { text = text, cost = cost }
	return text, cost
end

local function hide()
	active = nil
	if panel then panel.Visible = false end
	if connection then connection:Disconnect(); connection = nil end
end

local function visible(target: GuiObject): boolean
	local current: Instance? = target
	while current do
		if current:IsA("GuiObject") and not current.Visible then return false end
		if current:IsA("ScreenGui") and not current.Enabled then return false end
		if current == Players.LocalPlayer.PlayerGui then return true end
		current = current.Parent
	end
	return false
end

local function position()
	if not active or not visible(active.target) then hide(); return end
	local camera = workspace.CurrentCamera
	if not camera or not panel then return end
	local viewport = camera.ViewportSize
	local target = active.target
	local origin = target.AbsolutePosition
	local owner = target:FindFirstAncestorWhichIsA("ScreenGui")
	if owner and not owner.IgnoreGuiInset then origin += GuiService:GetGuiInset() end
	local size = panel.AbsoluteSize
	local x = math.clamp(origin.X + target.AbsoluteSize.X / 2 - size.X / 2, 8, math.max(8, viewport.X - size.X - 8))
	local y = origin.Y - size.Y - 12
	if y < 8 then y = origin.Y + target.AbsoluteSize.Y + 12 end
	panel.Position = UDim2.fromOffset(x, math.clamp(y, 8, math.max(8, viewport.Y - size.Y - 8)))
end

local function build()
	if screen then return end
	local gui = Instance.new("ScreenGui")
	gui.Name = "SpellTooltip"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 120
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	screen = gui
	local root = Instance.new("Frame")
	root.Name = "Panel"
	root.BackgroundColor3 = Color3.fromRGB(12, 14, 22)
	root.BackgroundTransparency = 0.04
	root.BorderSizePixel = 0
	root.Visible = false
	root.Parent = gui
	panel = root
	local border = Instance.new("UIStroke")
	border.Thickness = 1
	border.Parent = root
	stroke = border
	local name = Instance.new("TextLabel")
	name.Name = "SpellName"
	name.BackgroundTransparency = 1
	name.Position = UDim2.fromOffset(12, 10)
	name.Size = UDim2.new(1, -24, 0, 22)
	name.Font = Enum.Font.GothamBold
	name.TextSize = 16
	name.TextColor3 = Color3.fromRGB(245, 245, 250)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Parent = root
	title = name
	local description = Instance.new("TextLabel")
	description.Name = "Description"
	description.BackgroundTransparency = 1
	description.Position = UDim2.fromOffset(12, 38)
	description.Font = Enum.Font.Gotham
	description.TextSize = 13
	description.TextColor3 = Color3.fromRGB(193, 199, 213)
	description.TextXAlignment = Enum.TextXAlignment.Left
	description.TextYAlignment = Enum.TextYAlignment.Top
	description.TextWrapped = true
	description.Parent = root
	body = description
end

function Tooltip.Refresh(target: GuiObject)
	if not active or active.target ~= target then return end
	local record = active.getRecord()
	if not record or not visible(target) then hide(); return end
	build()
	local text, cost = Tooltip.Describe(record)
	local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800, 600)
	local width = math.min(292, math.max(100, viewport.X - 24))
	local height = math.min(240, TextService:GetTextSize(text, 13, Enum.Font.Gotham, Vector2.new(width - 24, 1000)).Y)
	local root, name, description, border = panel :: Frame, title :: TextLabel, body :: TextLabel, stroke :: UIStroke
	root.Size = UDim2.fromOffset(width, height + 50)
	name.Text = record.name or "Spell"
	description.Text = text
	description.Size = UDim2.new(1, -24, 0, height)
	border.Color = Decoration.GetColor(cost)
	root.Visible = true
	position()
end

function Tooltip.Bind(target: GuiObject, getRecord: () -> any): () -> ()
	local existing = bindings[target]
	if existing then
		existing.getRecord = getRecord
		Tooltip.Refresh(target)
		return existing.cleanup
	end
	local binding: any = { target = target, getRecord = getRecord, connections = {} }
	local function cleanup()
		if active == binding then hide() end
		for _, event in binding.connections do event:Disconnect() end
		table.clear(binding.connections)
		bindings[target] = nil
	end
	binding.cleanup = cleanup
	bindings[target] = binding
	table.insert(binding.connections, target.MouseEnter:Connect(function()
		active = binding
		Tooltip.Refresh(target)
		if active and not connection then connection = RunService.RenderStepped:Connect(position) end
	end))
	table.insert(binding.connections, target.MouseLeave:Connect(function() if active == binding then hide() end end))
	table.insert(binding.connections, target.Destroying:Connect(cleanup))
	return cleanup
end

return Tooltip
