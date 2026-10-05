--!optimize 2
--[[
	DebugPanel.luau  (client, Studio only)
	ReGui window (toggle with F2) with six tabs:
	  Tools    -- give any Tool the server can find (see DebugService.server.luau)
	              or clear your backpack.
	  Time     -- your personal time ratio; drives TimeControlGui headless, so the
	              apply/throttle/server-reconcile logic stays in one place.
	  Stats    -- client and server stats, refreshed every STATS_INTERVAL.
	  Entities -- pick any Entity: highlight + viewport preview, live HP /
	              effects / tools, set HP, apply status effects, give tools.
	  Chunks   -- minimap of chunks / time zones / players (drag to pan, click
	              to select); per-chunk, radius and global time scale, chunk
	              load state.
	  Dummies  -- spawn test dummies (model, HP) at the cursor or in front of
	              you; pick one of yours from a dropdown to move (to the cursor
	              or to you), delete, or clear all (replaces the old
	              DummySpawner tool).

	Cost when idle: one 0.5s visibility check. Stats sampling, the server's
	stats/entity streams, the highlight and the viewport refresh only run while
	their tab is actually showing; labels are only written when their text
	changes.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)
local Heartbeat = require(Shared.Heartbeat)
local ChunkManager = require(Shared.ChunkManager)
local ProjectileClient = require(Shared.ProjectileClient)
local TimeControlGui = require(script.Parent.TimeControlGui)

local DebugPanel = {}

local TOGGLE_KEY = Enum.KeyCode.F2
local STATS_INTERVAL = 0.5

local started = false
local localPlayer = Players.LocalPlayer
local toolNames: { string } = {} -- latest DebugTools list, shared by Tools/Entities

local function readStat(name: string): number?
	local ok, value = pcall(function()
		return (Stats :: any)[name]
	end)
	return if ok and typeof(value) == "number" then value else nil
end

local function fmt(pattern: string, value: number?): string
	return if value == nil then "-" else string.format(pattern, value)
end

-- A label whose text is only written when it changes (avoids re-layout).
local function statLine(canvas, name: string)
	local label = canvas:Label({ Text = name .. ": -" })
	local last = ""
	return function(value: string)
		if value ~= last then
			last = value
			label.Text = `{name}: {value}`
		end
	end
end

local function tabShowing(window, name: string): boolean
	if not window.Visible or window.Collapsed then
		return false
	end
	for _, entry in window.WindowTabSelector.Tabs do
		if entry.Name == name then
			return entry.IsSelected == true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------

local function buildToolsTab(window)
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
		toolNames = {}
		empty.Text = if #names == 0 then "No tools found" else ""
		empty.Visible = #names == 0
		for _, name in names do
			if typeof(name) == "string" then
				table.insert(toolNames, name)
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
end

local function buildTimeTab(window)
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
	return function()
		globalLine(string.format("x%.2f", Heartbeat.GetGlobalTimeScale()))
	end
end

local function buildStatsTab(window)
	local tab = window:CreateTab({ Name = "Stats" })

	tab:Separator({ Text = "Client" })
	local cFps = statLine(tab, "FPS")
	local cFrame = statLine(tab, "Frame ms (avg / worst)")
	local cPing = statLine(tab, "Ping")
	local cNet = statLine(tab, "Data in / out")
	local cMemory = statLine(tab, "Memory")
	local cInstances = statLine(tab, "Instances")
	local cVisuals = statLine(tab, "Projectile visuals")

	tab:Separator({ Text = "Server" })
	local sFps = statLine(tab, "Heartbeat FPS")
	local sFrame = statLine(tab, "Frame ms (avg / worst)")
	local sStep = statLine(tab, "Heartbeat / physics ms")
	local sPing = statLine(tab, "Ping (server-side)")
	local sNet = statLine(tab, "Data out / in")
	local sMemory = statLine(tab, "Memory")
	local sInstances = statLine(tab, "Instances")
	local sProjectiles = statLine(tab, "Projectiles")
	local sQueues = statLine(tab, "Visual queue (spawn / hit)")
	local sBeams = statLine(tab, "Beam pose updates (total)")
	local sEntities = statLine(tab, "Entities")
	local sChunks = statLine(tab, "Chunks (loaded / total)")
	local sPlayers = statLine(tab, "Players / world time")

	VisualOffload.On("DebugServerStats", function(s)
		if typeof(s) ~= "table" then
			return
		end
		sFps(fmt("%.0f", s.Fps))
		sFrame(`{fmt("%.2f", s.FrameMs)} / {fmt("%.2f", s.WorstFrameMs)}`)
		sStep(`{fmt("%.2f", s.HeartbeatMs)} / {fmt("%.2f", s.PhysicsMs)}`)
		sPing(fmt("%.0f ms", s.PingMs))
		sNet(`{fmt("%.1f", s.SendKbps)} / {fmt("%.1f", s.ReceiveKbps)} KB/s`)
		sMemory(fmt("%.0f MB", s.MemoryMb))
		sInstances(fmt("%d", s.Instances))
		sProjectiles(fmt("%d", s.Projectiles))
		sQueues(`{fmt("%d", s.PendingSpawns)} / {fmt("%d", s.PendingHits)}`)
		sBeams(fmt("%d", s.BeamPoseUpdates))
		sEntities(fmt("%d", s.Entities))
		sChunks(`{fmt("%d", s.LoadedChunks)} / {fmt("%d", s.Chunks)}`)
		sPlayers(`{fmt("%d", s.Players)} / {fmt("x%.2f", s.GlobalTimeScale)}`)
	end)

	-- Client frame sampling; only connected while the tab is showing.
	local frames, frameTime, worstFrame = 0, 0, 0
	local connection: RBXScriptConnection? = nil

	local function setActive(active: boolean)
		if active and not connection then
			frames, frameTime, worstFrame = 0, 0, 0
			connection = RunService.RenderStepped:Connect(function(dt)
				frames += 1
				frameTime += dt
				if dt > worstFrame then
					worstFrame = dt
				end
			end)
		elseif not active and connection then
			connection:Disconnect()
			connection = nil
		end
		VisualOffload.Fire("DebugStats", active)
	end

	local function sample()
		local averageMs = if frames > 0 then frameTime / frames * 1000 else nil
		cFps(fmt("%.0f", if frameTime > 0 then frames / frameTime else nil))
		cFrame(`{fmt("%.2f", averageMs)} / {fmt("%.2f", worstFrame * 1000)}`)
		frames, frameTime, worstFrame = 0, 0, 0
		cPing(fmt("%.0f ms", localPlayer:GetNetworkPing() * 1000))
		cNet(`{fmt("%.1f", readStat("DataReceiveKbps"))} / {fmt("%.1f", readStat("DataSendKbps"))} KB/s`)
		cMemory(fmt("%.0f MB", Stats:GetTotalMemoryUsageMb()))
		cInstances(fmt("%d", readStat("InstanceCount")))
		cVisuals(fmt("%d", ProjectileClient.GetStats().Visuals))
	end

	return setActive, sample
end

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

local function buildEntitiesTab(window)
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
			return toolNames
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
			if #toolNames == 0 then
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
	return setActive, tick
end

-- Chunks tab: a minimap of every chunk the server tracks (non-default time
-- scale, unloaded, or occupied) plus time zones and players. Left-drag paints
-- a selection (Shift adds to it), right-drag pans; actions apply to every
-- selected chunk. The map redraws at MAP_REFRESH while showing.
local MAP_REFRESH = 0.1
local MAP_HEIGHT = 260
local MIN_ZOOM, MAX_ZOOM = 128, 8192 -- studs across the map's width
local PAN_ACTION = "DebugMinimapPan"
local PAN_PRIORITY = Enum.ContextActionPriority.High.Value + 100 -- above the camera's bindings

-- Same encoding as ChunkVisualizer: blue = slow, teal ~ 1x, amber/red = fast.
local function colorForScale(scale: number): Color3
	if scale < 1 then
		return Color3.fromRGB(40, 120, 255):Lerp(Color3.fromRGB(60, 220, 200), math.clamp(scale, 0, 1))
	end
	return Color3.fromRGB(255, 200, 60):Lerp(Color3.fromRGB(255, 70, 60), math.clamp(scale - 1, 0, 1))
end

-- Grows a pool of GuiObjects on demand; hide() parks everything past `used`.
local function pool(parent: GuiObject, make: () -> GuiObject)
	local items: { GuiObject } = {}
	local used = 0
	local self = {}
	function self.take(): GuiObject
		used += 1
		local item = items[used]
		if not item then
		item = make()
		item.Parent = parent
		items[used] = item
		end
		item.Visible = true
		return item
	end
	function self.reset()
		used = 0
	end
	function self.hide()
		for index = used + 1, #items do
		items[index].Visible = false
		end
	end
	return self
end

local function buildChunksTab(window, ReGui)
	local tab = window:CreateTab({ Name = "Chunks" })

	local data: any = nil -- latest DebugChunks snapshot
	local byKey: { [Vector3]: any } = {}
	local selected: { [Vector3]: true } = {}
	local selectedCount = 0
	local anchorKey: Vector3? = nil -- first chunk of the current selection; radius center
	local follow = true
	local viewCenter = Vector2.zero -- world XZ at the map's center
	local zoom = 768
	local chunkScaleValue, globalScaleValue = 1, 1
	local connection: RBXScriptConnection? = nil
	local sinceRedraw = 0

	local function act(action: string, extra: { [string]: any }?)
		local payload = extra or {}
		payload.Action = action
		VisualOffload.Fire("DebugChunkAction", payload)
	end

	local controls = tab:Row()
	controls:Button({
		Text = "Recenter",
		Callback = function()
		follow = true
		end,
	})
	controls:Button({
		Text = "Zoom in",
		Callback = function()
		zoom = math.max(zoom / 1.5, MIN_ZOOM)
		end,
	})
	controls:Button({
		Text = "Zoom out",
		Callback = function()
		zoom = math.min(zoom * 1.5, MAX_ZOOM)
		end,
	})

	local map = tab:Image({ Image = "", Size = UDim2.new(1, 0, 0, MAP_HEIGHT) })
	-- The Image prefab is AutomaticSize XY with padding: grid lines drawn past
	-- its edge grew it, which raised pixels-per-stud, which drew further out --
	-- a runaway zoom. The map must keep a fixed size.
	map.AutomaticSize = Enum.AutomaticSize.None
	map.Size = UDim2.new(1, 0, 0, MAP_HEIGHT)
	local padding = map:FindFirstChildOfClass("UIPadding")
	if padding then
		padding:Destroy()
	end
	map.ImageTransparency = 1
	map.AutoButtonColor = false
	map.BackgroundTransparency = 0
	map.BackgroundColor3 = Color3.fromRGB(14, 16, 22)
	map.ClipsDescendants = true

	local function frame(color: Color3?, transparency: number?, round: boolean?): Frame
		local item = Instance.new("Frame")
		item.BorderSizePixel = 0
		item.BackgroundColor3 = color or Color3.new(1, 1, 1)
		item.BackgroundTransparency = transparency or 0
		if round then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = item
		end
		return item
	end

	local gridPool = pool(map, function()
		return frame(Color3.fromRGB(60, 66, 84), 0.5)
	end)
	local cellPool = pool(map, function()
		local cell = frame(nil, 0.35)
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(255, 80, 80)
		stroke.Thickness = 1
		stroke.Parent = cell
		local count = Instance.new("TextLabel")
		count.Name = "Count"
		count.BackgroundTransparency = 1
		count.Size = UDim2.fromScale(1, 1)
		count.Font = Enum.Font.GothamBold
		count.TextScaled = true
		count.TextColor3 = Color3.new(1, 1, 1)
		count.TextStrokeTransparency = 0.5
		count.Parent = cell
		local cap = Instance.new("UITextSizeConstraint")
		cap.MaxTextSize = 16
		cap.Parent = count
		return cell
	end)
	local zonePool = pool(map, function()
		local zone = frame(nil, 0.8, true)
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1.5
		stroke.Parent = zone
		return zone
	end)
	local playerPool = pool(map, function()
		local dot = frame(Color3.fromRGB(230, 230, 240), 0, true)
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Size = UDim2.fromOffset(6, 6)
		dot.ZIndex = 4
		return dot
	end)
	local selectionPool = pool(map, function()
		local outline = frame(Color3.new(1, 1, 1), 0.85)
		outline.ZIndex = 3
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(1, 1, 1)
		stroke.Thickness = 1.5
		stroke.Parent = outline
		return outline
	end)
	local me = frame(Color3.fromRGB(255, 230, 90), 0, true)
	me.AnchorPoint = Vector2.new(0.5, 0.5)
	me.Size = UDim2.fromOffset(9, 9)
	me.ZIndex = 6
	me.Parent = map
	local facing = frame(Color3.fromRGB(255, 230, 90), 0)
	facing.AnchorPoint = Vector2.new(0, 0.5)
	facing.Size = UDim2.fromOffset(14, 2)
	facing.ZIndex = 5
	facing.Parent = map

	local legend = statLine(tab, "Map")
	tab:Separator({ Text = "Selection  (left-drag paint, Shift adds, right-drag pans)" })
	local keyLine = statLine(tab, "Chunk")
	local scaleLine = statLine(tab, "Time scale")
	local flagsLine = statLine(tab, "State")

	tab:SliderFloat({
		Label = "Chunk time",
		Minimum = 0,
		Maximum = 3,
		Value = 1,
		Format = "x%.2f",
		Callback = function(_, value: number)
		chunkScaleValue = value
		end,
	})
	local function selectedKeys(): { Vector3 }
		local keys = {}
		for key in selected do
		table.insert(keys, key)
		end
		return keys
	end

	local updateSelectionInfo -- defined below; the buttons only run later
	local function clearSelection()
		table.clear(selected)
		selectedCount, anchorKey = 0, nil
	end

	local chunkRow = tab:Row()
	chunkRow:Button({
		Text = "Apply",
		Callback = function()
		if selectedCount > 0 then
			act("SetScale", { Keys = selectedKeys(), Scale = chunkScaleValue })
		end
		end,
	})
	chunkRow:Button({
		Text = "Reset",
		Callback = function()
		if selectedCount > 0 then
			act("SetScale", { Keys = selectedKeys(), Scale = 1 })
		end
		end,
	})
	chunkRow:Button({
		Text = "Toggle loaded",
		Callback = function()
		if selectedCount == 0 then
			return
		end
		-- any loaded chunk in the selection -> unload all, else load all
		local anyLoaded = false
		for key in selected do
			local chunk = byKey[key]
			if chunk == nil or chunk.Loaded then
				anyLoaded = true
				break
			end
		end
		act("SetLoaded", { Keys = selectedKeys(), Loaded = not anyLoaded })
		end,
	})
	chunkRow:Button({
		Text = "Deselect",
		Callback = function()
		clearSelection()
		updateSelectionInfo()
		end,
	})
	local radiusInput = tab:InputInt({ Label = "Radius (studs)", Value = 128, Increment = 32 })
	tab:Button({
		Text = "Apply chunk time in radius of first selected",
		Callback = function()
		if anchorKey then
			act("SetScaleRadius", { Key = anchorKey, Scale = chunkScaleValue, Radius = radiusInput.Value })
		end
		end,
	})

	tab:Separator({ Text = "World" })
	local worldLine = statLine(tab, "World")
	tab:SliderFloat({
		Label = "Global time",
		Minimum = 0,
		Maximum = 3,
		Value = Heartbeat.GetGlobalTimeScale(),
		Format = "x%.2f",
		Callback = function(_, value: number)
		globalScaleValue = value
		end,
	})
	local worldRow = tab:Row()
	worldRow:Button({
		Text = "Apply global",
		Callback = function()
		act("SetGlobalScale", { Scale = globalScaleValue })
		end,
	})
	worldRow:Button({
		Text = "Reset all chunks",
		Callback = function()
		act("ResetAll")
		end,
	})
	worldRow:Button({
		Text = "Clear zones",
		Callback = function()
		act("ClearZones")
		end,
	})

	local function chunkSize(): number
		return if data then data.ChunkSize else ChunkManager.ChunkSize
	end

	local function localRoot(): BasePart?
		local character = localPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		return if root and root:IsA("BasePart") then root else nil
	end

	local function center(): Vector2
		local root = localRoot()
		if follow and root then
		viewCenter = Vector2.new(root.Position.X, root.Position.Z)
		end
		return viewCenter
	end

	function updateSelectionInfo()
		if selectedCount == 0 then
		keyLine("left-drag on the map")
		scaleLine("-")
		flagsLine("-")
		return
		end
		if selectedCount == 1 then
		local key = next(selected) :: Vector3
		local chunk = byKey[key]
		local size = chunkSize()
		keyLine(string.format("(%d, %d)  origin %d, %d", key.X, key.Z, key.X * size, key.Z * size))
		scaleLine(string.format("x%.2f", if chunk then chunk.TimeScale else 1))
		flagsLine(if chunk
			then `{if chunk.Loaded then "loaded" else "UNLOADED"}  ·  {chunk.Entities} entities{if chunk.Persistent then "  ·  persistent" else ""}`
			else "untracked (default)")
		return
		end
		local low, high, unloaded, entities = math.huge, -math.huge, 0, 0
		for key in selected do
		local chunk = byKey[key]
		local scale = if chunk then chunk.TimeScale else 1
		low, high = math.min(low, scale), math.max(high, scale)
		if chunk then
			entities += chunk.Entities
			if not chunk.Loaded then
				unloaded += 1
			end
		end
		end
		keyLine(`{selectedCount} chunks selected`)
		scaleLine(if low == high then string.format("x%.2f", low) else string.format("x%.2f - x%.2f", low, high))
		flagsLine(`{selectedCount - unloaded} loaded, {unloaded} unloaded  ·  {entities} entities`)
	end

	local function redraw()
		local size = map.AbsoluteSize
		if size.X <= 0 or not data then
		return
		end
		local mid = center()
		local pixelsPerStud = size.X / zoom
		local half = size / 2
		local function toMap(x: number, z: number): Vector2
		return Vector2.new((x - mid.X) * pixelsPerStud + half.X, (z - mid.Y) * pixelsPerStud + half.Y)
		end
		local studs = chunkSize()
		local cellPixels = studs * pixelsPerStud

		gridPool.reset()
		if cellPixels >= 6 then
		local left, top = mid.X - half.X / pixelsPerStud, mid.Y - half.Y / pixelsPerStud
		for x = math.floor(left / studs) * studs, left + size.X / pixelsPerStud, studs do
			local line = gridPool.take()
			line.Position = UDim2.fromOffset(toMap(x, 0).X, 0)
			line.Size = UDim2.new(0, 1, 1, 0)
		end
		for z = math.floor(top / studs) * studs, top + size.Y / pixelsPerStud, studs do
			local line = gridPool.take()
			line.Position = UDim2.fromOffset(0, toMap(0, z).Y)
			line.Size = UDim2.new(1, 0, 0, 1)
		end
		end
		gridPool.hide()

		cellPool.reset()
		for _, chunk in data.Chunks do
		local corner = toMap(chunk.Key.X * studs, chunk.Key.Z * studs)
		if corner.X > size.X or corner.Y > size.Y or corner.X + cellPixels < 0 or corner.Y + cellPixels < 0 then
			continue
		end
		local cell = cellPool.take()
		cell.Position = UDim2.fromOffset(corner.X, corner.Y)
		cell.Size = UDim2.fromOffset(math.max(cellPixels, 2), math.max(cellPixels, 2))
		cell.BackgroundColor3 = if chunk.TimeScale == 1 then Color3.fromRGB(70, 80, 100) else colorForScale(chunk.TimeScale)
		cell.BackgroundTransparency = if chunk.TimeScale == 1 then 0.6 else 0.3
		local stroke = cell:FindFirstChildOfClass("UIStroke") :: UIStroke
		stroke.Enabled = not chunk.Loaded
		local count = cell:FindFirstChild("Count") :: TextLabel
		count.Visible = cellPixels >= 18 and chunk.Entities > 0
		count.Text = tostring(chunk.Entities)
		end
		cellPool.hide()

		zonePool.reset()
		for _, zone in data.Zones do
		local at = toMap(zone.Position.X, zone.Position.Z)
		local diameter = zone.Radius * 2 * pixelsPerStud
		local item = zonePool.take()
		item.Position = UDim2.fromOffset(at.X - diameter / 2, at.Y - diameter / 2)
		item.Size = UDim2.fromOffset(diameter, diameter)
		item.BackgroundColor3 = colorForScale(zone.Scale)
		local stroke = item:FindFirstChildOfClass("UIStroke") :: UIStroke
		stroke.Color = colorForScale(zone.Scale)
		end
		zonePool.hide()

		playerPool.reset()
		for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if player ~= localPlayer and root and root:IsA("BasePart") then
			local at = toMap(root.Position.X, root.Position.Z)
			playerPool.take().Position = UDim2.fromOffset(at.X, at.Y)
		end
		end
		playerPool.hide()

		local root = localRoot()
		me.Visible, facing.Visible = root ~= nil, root ~= nil
		if root then
		local at = toMap(root.Position.X, root.Position.Z)
		me.Position = UDim2.fromOffset(at.X, at.Y)
		facing.Position = me.Position
		local look = root.CFrame.LookVector
		facing.Rotation = math.deg(math.atan2(look.Z, look.X))
		end

		selectionPool.reset()
		for key in selected do
		local corner = toMap(key.X * studs, key.Z * studs)
		if corner.X > size.X or corner.Y > size.Y or corner.X + cellPixels < 0 or corner.Y + cellPixels < 0 then
			continue
		end
		local outline = selectionPool.take()
		outline.Position = UDim2.fromOffset(corner.X, corner.Y)
		outline.Size = UDim2.fromOffset(math.max(cellPixels, 3), math.max(cellPixels, 3))
		end
		selectionPool.hide()

		legend(string.format("%d studs across  ·  %s", zoom, if follow then "following you" else "panned (Recenter)"))
	end

	-- Left button paints a selection. ReGui:ConnectDrag (as its sliders use)
	-- also blocks the window from dragging while the map is being painted.
	local function keyAt(position: Vector2): Vector3
		local size = map.AbsoluteSize
		local offset = position - map.AbsolutePosition - size / 2
		local world = center() + offset / (size.X / zoom)
		local studs = chunkSize()
		return Vector3.new(math.floor(world.X / studs), 0, math.floor(world.Y / studs))
	end

	local function paintAt(position: Vector2)
		local low, high = map.AbsolutePosition, map.AbsolutePosition + map.AbsoluteSize
		if position.X < low.X or position.Y < low.Y or position.X > high.X or position.Y > high.Y then
		return -- dragged off the map
		end
		local key = keyAt(position)
		if not selected[key] then
		selected[key] = true
		selectedCount += 1
		anchorKey = anchorKey or key
		end
	end

	local lastPaint: Vector2? = nil
	ReGui:ConnectDrag(map, {
		DragStart = function(position: Vector2)
		local adding = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		if not adding then
			clearSelection()
		end
		paintAt(position)
		lastPaint = position
		updateSelectionInfo()
		redraw()
		end,
		DragMovement = function(position: Vector2)
		if not lastPaint then
			return
		end
		-- sample the path at half-cell spacing so fast drags skip nothing
		local step = math.max(chunkSize() * map.AbsoluteSize.X / zoom * 0.5, 1)
		local delta = position - lastPaint
		local samples = math.max(math.ceil(delta.Magnitude / step), 1)
		for index = 1, samples do
			paintAt(lastPaint + delta * (index / samples))
		end
		lastPaint = position
		updateSelectionInfo()
		redraw()
		end,
		DragEnd = function()
		lastPaint = nil
		end,
	})

	-- Right button pans. GUI buttons don't stop the default camera from
	-- treating right-drag as "rotate", so while the cursor is over the map a
	-- high-priority action claims (sinks) MouseButton2 before the camera.
	local panStart: Vector2? = nil
	local panCenter = Vector2.zero
	local hovering = false
	local function panAction(_, state: Enum.UserInputState, input: InputObject)
		if state == Enum.UserInputState.Begin then
		panStart = Vector2.new(input.Position.X, input.Position.Y)
		panCenter = center()
		else
		panStart = nil
		if not hovering then
			ContextActionService:UnbindAction(PAN_ACTION)
		end
		end
		return Enum.ContextActionResult.Sink
	end
	map.MouseEnter:Connect(function()
		hovering = true
		ContextActionService:BindActionAtPriority(PAN_ACTION, panAction, false, PAN_PRIORITY, Enum.UserInputType.MouseButton2)
	end)
	map.MouseLeave:Connect(function()
		hovering = false
		if not panStart then
		ContextActionService:UnbindAction(PAN_ACTION)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if panStart and input.UserInputType == Enum.UserInputType.MouseMovement then
		local delta = Vector2.new(input.Position.X, input.Position.Y) - panStart
		if follow and delta.Magnitude < 3 then
			return
		end
		follow = false
		viewCenter = panCenter - delta / (map.AbsoluteSize.X / zoom)
		redraw()
		end
	end)

	VisualOffload.On("DebugChunks", function(snapshot)
		if typeof(snapshot) ~= "table" then
		return
		end
		data = snapshot
		table.clear(byKey)
		local dilated = 0
		for _, chunk in snapshot.Chunks do
		byKey[chunk.Key] = chunk
		if chunk.TimeScale ~= 1 then
			dilated += 1
		end
		end
		worldLine(string.format("global x%.2f  ·  %d chunks tracked, %d dilated  ·  %d zones",
		snapshot.GlobalScale, #snapshot.Chunks, dilated, #snapshot.Zones))
		updateSelectionInfo()
		redraw()
	end)

	local function setActive(active: boolean)
		VisualOffload.Fire("DebugChunkWatch", active)
		if active and not connection then
		VisualOffload.Fire("DebugRequestChunks")
		connection = RunService.RenderStepped:Connect(function(dt)
			sinceRedraw += dt
			if sinceRedraw >= MAP_REFRESH then
				sinceRedraw = 0
				redraw()
			end
		end)
		elseif not active and connection then
		connection:Disconnect()
		connection = nil
		end
	end

	updateSelectionInfo()
	return setActive
end

-- Dummies tab: replaces the old DummySpawner tool. Spawning/moving/deleting
-- stays server-side in DummySpawner.server.luau ("DummySpawner" channel);
-- this only picks the model/HP and turns world clicks into requests.
local PLACE_ACTION = "DebugPlaceDummy"
local SELECTED_OUTLINE = Color3.fromRGB(80, 225, 255)

local function buildDummiesTab(window)
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
	return setActive, refreshList
end

--------------------------------------------------------------------------------

local PREFABS_TIMEOUT = 30

local function build()
	-- ReGui only waits 2s for its prefabs, but this ~400-instance ScreenGui
	-- can take longer than that to replicate, so wait for it here instead.
	local module = Shared:WaitForChild("ReGui")
	local prefabs = module:WaitForChild("ReGui-Prefabs", PREFABS_TIMEOUT)
	if not prefabs then
		warn("[DebugPanel] ReGui-Prefabs never replicated; panel disabled")
		return
	end
	local ReGui = require(module)
	-- ReGui probes gethui()/CoreGui before PlayerGui (executor leftovers); the
	-- CoreGui probe passes in a playtest but the real parent assignment then
	-- fails silently, leaving the container parentless, so pin it.
	ReGui:Init({
		Prefabs = prefabs,
		ContainerParent = localPlayer:WaitForChild("PlayerGui"),
	})
	-- ReGui's container is a Folder holding two ScreenGuis, and a respawn
	-- clears everything in PlayerGui except ResetOnSpawn=false ScreenGuis --
	-- folder included. ReGui only ever indexes Container.Windows/.Overlays,
	-- so lift both ScreenGuis out and point Container at them directly.
	local folder = ReGui.Container
	local playerGui = localPlayer.PlayerGui
	local lifted = {}
	for _, name in { "Windows", "Overlays" } do
		local gui = folder:FindFirstChild(name) :: ScreenGui
		gui.ResetOnSpawn = false
		gui.Name = "ReGui" .. name
		gui.Parent = playerGui
		lifted[name] = gui
	end
	ReGui.Container = lifted
	folder:Destroy()

	local window = ReGui:TabsWindow({
		Title = "Debug  [F2]",
		Size = UDim2.fromOffset(360, 520),
		Position = UDim2.fromOffset(16, 160),
		-- the close button hides instead of destroying, so F2 can reopen it
		CloseCallback = function(self)
		self:SetVisible(false)
		return false
		end,
	})

	buildToolsTab(window)
	local refreshTime = buildTimeTab(window)
	local setStatsActive, sampleStats = buildStatsTab(window)
	local setEntitiesActive, tickEntities = buildEntitiesTab(window)
	local setChunksActive = buildChunksTab(window, ReGui)
	local setDummiesActive, tickDummies = buildDummiesTab(window)

	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == TOGGLE_KEY and not processed then
		window:SetVisible(not window.Visible)
		end
	end)

	local statsActive, entitiesActive, chunksActive, dummiesActive = false, false, false, false
	local function tick()
		local stats = tabShowing(window, "Stats")
		if stats ~= statsActive then
			statsActive = stats
			setStatsActive(stats)
		end
		local entities = tabShowing(window, "Entities")
		if entities ~= entitiesActive then
			entitiesActive = entities
			setEntitiesActive(entities)
		end
		local chunks = tabShowing(window, "Chunks")
		if chunks ~= chunksActive then
			chunksActive = chunks
			setChunksActive(chunks)
		end
		local dummies = tabShowing(window, "Dummies")
		if dummies ~= dummiesActive then
			dummiesActive = dummies
			setDummiesActive(dummies)
		end
		if stats then
			sampleStats()
		elseif entities then
			tickEntities()
		elseif dummies then
			tickDummies()
		elseif window.Visible then
			refreshTime()
		end
	end
	task.spawn(function()
		local lastError = nil
		while true do
			task.wait(STATS_INTERVAL)
			-- One tab's bug must not kill every other tab's updates; report each
			-- distinct error once instead of every tick.
			local ok, err = xpcall(tick, debug.traceback)
			if not ok and err ~= lastError then
				lastError = err
				warn("[DebugPanel] tick failed:", err)
			end
		end
	end)
end

function DebugPanel.start()
	if started or not RunService:IsStudio() then
		return
	end
	started = true
	-- never block (or break) the rest of client startup
	task.spawn(function()
		local ok, err = xpcall(build, debug.traceback)
		if not ok then
			warn("[DebugPanel] failed to build:", err)
		end
	end)
end

return DebugPanel
