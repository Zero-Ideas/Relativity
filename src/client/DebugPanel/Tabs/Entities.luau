--!optimize 2
--[[
	Entities tab: pick any Entity -- highlight + viewport preview, live HP /
	effects / tools, set HP, apply status effects, give tools.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)
local Util = require(script.Parent.Parent.Util)
local State = require(script.Parent.Parent.State)
local statLine = Util.statLine
local STATS_INTERVAL = Util.STATS_INTERVAL

-- Viewport preview: a static, anchored, script-free copy of the entity,
-- re-snapshotted every VIEWPORT_REFRESH while the tab is showing.
local VIEWPORT_REFRESH = 1

local function previewCopy(instance: Instance): Instance?
	local ok, copy = pcall(function()
		-- characters are non-Archivable; flip it locally just for the clone
		local archivable = instance.Archivable
		instance.Archivable = true
		local clone = instance:Clone()
		instance.Archivable = archivable
		return clone
	end)
	if not ok or not copy then
		return nil
	end
	for _, descendant in copy:GetDescendants() do
		if descendant:IsA("BaseScript") or descendant:IsA("Sound") or descendant:IsA("LayerCollector") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
	if copy:IsA("BasePart") then
		copy.Anchored = true
	end
	return copy
end

return function(window)
	local tab = window:CreateTab({ Name = "Entities" })

	local entries: { [string]: { Id: number, Instance: Instance? } } = {}
	local entryNames: { string } = {}
	local effectNames: { string } = {}
	local selectedId: number? = nil
	local selectedInstance: Instance? = nil
	local selectedEffect: string? = nil
	local selectedTool: string? = nil
	local active = false
	local prefill = false
	local sinceViewport = math.huge

	local highlight = Instance.new("Highlight")
	highlight.Name = "DebugEntityHighlight"
	highlight.FillColor = Color3.fromRGB(255, 196, 64)
	highlight.FillTransparency = 0.7
	highlight.OutlineColor = Color3.fromRGB(255, 226, 140)
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Enabled = false
	highlight.Parent = workspace

	local function act(action: string, extra: { [string]: any }?)
		if not selectedId then
			return
		end
		local data = extra or {}
		data.Id, data.Action = selectedId, action
		VisualOffload.Fire("DebugEntityAction", data)
	end

	local controls = tab:Row()
	controls:Button({
		Text = "Refresh list",
		Callback = function()
			VisualOffload.Fire("DebugRequestEntities")
		end,
	})
	local select -- forward-declared: the picker and Deselect call it
	controls:Button({
		Text = "Deselect",
		Callback = function()
			select(nil, nil)
		end,
	})
	local picker = tab:Combo({
		Label = "Entity",
		Placeholder = "Select an entity",
		GetItems = function()
			return entryNames
		end,
		Callback = function(_, value)
			local entry = entries[value]
			if entry then
				select(entry.Id, entry.Instance)
			end
		end,
	})
	local viewport = tab:Viewport({ Size = UDim2.new(1, 0, 0, 170) })

	local nameLine = statLine(tab, "Entity")
	local healthLine = statLine(tab, "HP")
	local stateLine = statLine(tab, "State")
	local positionLine = statLine(tab, "Position")
	local effectsLine = statLine(tab, "Effects")
	local toolsLine = statLine(tab, "Tools")

	local function refreshViewport()
		sinceViewport = 0
		local world = viewport.WorldModel
		local instance = selectedInstance
		if not instance or not instance.Parent then
			world:ClearAllChildren()
			return
		end
		local copy = previewCopy(instance)
		if not copy then
			return
		end
		viewport:SetModel(copy)
		local frame, size
		if copy:IsA("Model") then
			frame, size = copy:GetBoundingBox()
			local primary = copy.PrimaryPart
			if primary then
				frame = CFrame.lookAt(frame.Position, frame.Position + primary.CFrame.LookVector)
			end
		elseif copy:IsA("BasePart") then
			frame, size = copy.CFrame, copy.Size
		else
			return
		end
		local focus = frame.Position
		local direction = (frame.LookVector + Vector3.new(0, 0.3, 0)).Unit
		viewport.Camera.CFrame = CFrame.lookAt(focus + direction * (size.Magnitude * 0.85 + 2), focus)
	end

	local function setInstance(instance: Instance?)
		selectedInstance = instance
		highlight.Adornee = instance
		highlight.Enabled = active and instance ~= nil
		refreshViewport()
	end

	function select(id: number?, instance: Instance?)
		selectedId = id
		prefill = id ~= nil
		setInstance(instance)
		if not id then
			picker:SetValueText("Select an entity")
			for _, line in { nameLine, healthLine, stateLine, positionLine, effectsLine, toolsLine } do
				line("-")
			end
		end
		if active then
			VisualOffload.Fire("DebugEntityWatch", id)
		end
	end

	tab:Separator({ Text = "Health" })
	local healthInput = tab:InputInt({ Label = "HP", Value = 100, NoButtons = true })
	local maxInput = tab:InputInt({ Label = "Max HP", Value = 100, NoButtons = true })
	local healthRow = tab:Row()
	healthRow:Button({
		Text = "Set HP",
		Callback = function()
			act("SetHealth", { Value = healthInput.Value })
		end,
	})
	healthRow:Button({
		Text = "Set max",
		Callback = function()
			act("SetMaxHealth", { Value = maxInput.Value })
		end,
	})
	healthRow:Button({
		Text = "Full heal",
		Callback = function()
			act("Heal")
		end,
	})
	healthRow:Button({
		Text = "Kill",
		Callback = function()
			act("Kill")
		end,
	})

	tab:Separator({ Text = "Status effects" })
	tab:Combo({
		Label = "Effect",
		Placeholder = "Select an effect",
		GetItems = function()
			return effectNames
		end,
		Callback = function(_, value)
			selectedEffect = value
		end,
	})
	local durationInput = tab:InputInt({ Label = "Duration (s)", Value = 5 })
	local potencyInput = tab:InputInt({ Label = "Potency", Value = 1 })
	local effectRow = tab:Row()
	effectRow:Button({
		Text = "Apply",
		Callback = function()
			if selectedEffect then
				act("ApplyEffect", { Name = selectedEffect, Duration = durationInput.Value, Potency = potencyInput.Value })
			end
		end,
	})
	effectRow:Button({
		Text = "Remove",
		Callback = function()
			if selectedEffect then
				act("RemoveEffect", { Name = selectedEffect })
			end
		end,
	})

	tab:Separator({ Text = "Tools" })
	tab:Combo({
		Label = "Tool",
		Placeholder = "Select a tool",
		GetItems = function()
			return State.ToolNames
		end,
		Callback = function(_, value)
			selectedTool = value
		end,
	})
	local toolRow = tab:Row()
	toolRow:Button({
		Text = "Give",
		Callback = function()
			if selectedTool then
				act("GiveTool", { Name = selectedTool })
			end
		end,
	})
	toolRow:Button({
		Text = "Clear tools",
		Callback = function()
			act("ClearTools")
		end,
	})

	VisualOffload.On("DebugEntities", function(data)
		if typeof(data) ~= "table" then
			return
		end
		table.clear(entries)
		entryNames = {}
		for _, entry in data.Entities or {} do
			local label = `{entry.Name}  #{entry.Id}`
			entries[label] = { Id = entry.Id, Instance = entry.Instance }
			table.insert(entryNames, label)
		end
		effectNames = data.Effects or {}
	end)

	VisualOffload.On("DebugEntityState", function(state)
		if typeof(state) ~= "table" or state.Id ~= selectedId then
			return
		end
		if state.Gone then
			nameLine(`#{state.Id} (destroyed)`)
			if selectedInstance then
				setInstance(nil)
			end
			return
		end
		if state.Instance ~= selectedInstance then
			setInstance(state.Instance) -- e.g. a player respawned
		end
		picker:SetValueText(`{state.Name}  #{state.Id}`)
		nameLine(`{state.Name}  #{state.Id}{if state.Instance then "" else "  (no replicated instance)"}`)
		healthLine(string.format("%.1f / %.1f", state.Health, state.MaxHealth))
		stateLine(`{if state.Dead then "dead" else "alive"}  ·  time x{string.format("%.2f", state.TimeScale)}`
			.. (if state.Team then `  ·  team {state.Team}` else ""))
		local p = state.Position
		positionLine(string.format("%.1f, %.1f, %.1f", p.X, p.Y, p.Z))
		local effects = {}
		for _, effect in state.Effects do
			table.insert(effects, string.format("%s (%.1fs, x%g)", effect.Name, effect.Duration, effect.Potency))
		end
		effectsLine(if #effects > 0 then table.concat(effects, ", ") else "none")
		toolsLine(if #state.Tools > 0 then table.concat(state.Tools, ", ") else "none")
		if prefill then
			prefill = false
			healthInput:SetValue(math.floor(state.Health + 0.5))
			maxInput:SetValue(math.floor(state.MaxHealth + 0.5))
		end
	end)

	local function setActive(isActive: boolean)
		active = isActive
		highlight.Enabled = isActive and selectedInstance ~= nil
		VisualOffload.Fire("DebugEntityWatch", if isActive then selectedId else nil)
		if isActive then
			VisualOffload.Fire("DebugRequestEntities")
			if #State.ToolNames == 0 then
				VisualOffload.Fire("DebugRequestTools")
			end
		end
	end

	local function tick()
		sinceViewport += STATS_INTERVAL
		if sinceViewport >= VIEWPORT_REFRESH then
		refreshViewport()
		end
	end

	select(nil, nil)
	return { Active = setActive, Tick = tick }
end
