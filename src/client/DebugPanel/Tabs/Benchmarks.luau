--!optimize 2
-- Retained controls. One compact request, not one network message per projectile.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage.Shared
local Schema = require(Shared.ProjectileBenchmark)
local VisualOffload = require(Shared.VisualOffload)
local ProjectileClient = require(Shared.Projectile.Client)
local Util = require(script.Parent.Parent.Util)

return function(window)
	local tab = window:CreateTab({Name = "Benchmarks"})
	local values = Schema.Defaults()
	local controls = {}
	local status = Util.statLine(tab, "Status")
	local spawnLine = Util.statLine(tab, "Last spawn CPU / elapsed")
	local serverLine = Util.statLine(tab, "Server active / queued visuals")
	local clientLine = Util.statLine(tab, "Client visuals")
	local frameLine = Util.statLine(tab, "Client FPS / avg / worst ms")
	local serverFrame = Util.statLine(tab, "Server frame ms at spawn completion")
	status("Ready; defaults match the harmless 10k stress test")
	tab:Label({Text = "Real server projectiles; nonzero Damage affects entities. Count limit: 50,000 per run. Independent beams, not a sustained linked stream.",
		TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y})
	local function applyDefaults(overrides)
		local defaults = Schema.Defaults()
		for key, value in overrides or {} do defaults[key] = value end
		for _, f in Schema.Fields do
			values[f.Key] = defaults[f.Key]
			local control = controls[f.Key]
			if control then
				if f.Kind == "boolean" then control:SetTicked(values[f.Key])
				elseif f.Kind == "choice" then control:SetValueText(values[f.Key])
				else control:SetValue(tostring(values[f.Key])) end
			end
		end
	end
	local function run()
		local raw = table.clone(values)
		for _, f in Schema.Fields do
			if f.Kind == "number" then
				local number = tonumber(raw[f.Key])
				if not number then status("Invalid " .. f.Label); return end
				raw[f.Key] = number
			end
		end
		local checked, problem = Schema.Validate(raw)
		if not checked then status(problem or "Invalid settings"); return end
		status(`Requested {checked.Count} projectiles...`)
		VisualOffload.Fire("DebugBenchmark", {Action = "Run", Settings = raw, Target = Players.LocalPlayer:GetMouse().Hit.Position})
	end
	local actions = tab:Row()
	actions:Button({Text = "Run", Callback = run})
	actions:Button({Text = "Cancel spawning", Callback = function() VisualOffload.Fire("DebugBenchmark", {Action = "Cancel"}) end})
	actions:Button({Text = "Clear my tests", Callback = function() VisualOffload.Fire("DebugBenchmark", {Action = "Clear"}) end})
	local presets = tab:Row()
	presets:SmallButton({Text = "Reset / 10k", Callback = function() applyDefaults() end})
	presets:SmallButton({Text = "Server-only", Callback = function() applyDefaults({Visualize = false}) end})
	presets:SmallButton({Text = "Homing", Callback = function() applyDefaults({HomingEnabled = true}) end})
	presets:SmallButton({Text = "Beams", Callback = function()
		applyDefaults({Count = 1000, BeamEnabled = true, Speed = 2000, Radius = 0.35, Lifetime = 3})
	end})
	local group, canvas = nil, tab
	local headers = {}
	for _, f in Schema.Fields do
		if f.Group ~= group then
			group = f.Group
			canvas = tab:CollapsingHeader({Title = group, Collapsed = group ~= "Launch"})
			table.insert(headers, {Canvas = canvas, Collapsed = group ~= "Launch"})
		end
		local control
		if f.Kind == "boolean" then
			control = canvas:Checkbox({Label = f.Label, Value = f.Default, Callback = function(_, value) values[f.Key] = value end})
		elseif f.Kind == "choice" then
			control = canvas:Combo({Label = f.Label, Placeholder = f.Default, GetItems = function() return f.Choices end,
				Callback = function(_, value) values[f.Key] = value end})
			control:SetValueText(f.Default)
		else
			canvas:Label({Text = f.Label})
			control = canvas:InputText({Label = "", Value = tostring(f.Default), Size = UDim2.new(1, 0, 0, 19),
				Callback = function(_, value) values[f.Key] = value end})
			-- ReGui InputText does not apply its initial Value to the TextBox.
			control:SetValue(tostring(f.Default))
		end
		controls[f.Key] = control
	end
	-- ReGui measures an open header at construction, before its children exist.
	-- Refresh once after layout so Launch starts open at its actual height.
	task.defer(function()
		for _, entry in headers do entry.Canvas:SetCollapsed(entry.Collapsed) end
	end)
	tab:Button({Text = "Run configured payload", Callback = run})
	local resultConnection = VisualOffload.On("DebugBenchmarkResult", function(data)
		if typeof(data) ~= "table" then return end
		status(data.Error or data.Status or "Ready")
		if data.SpawnMs then spawnLine(string.format("%.2f / %.2f ms (%d spawned)", data.SpawnMs, data.WallMs, data.Spawned)) end
		if data.Active then serverLine(`{data.Active} (before {data.Baseline}) / {data.Pending}`) end
		if data.FrameMs then serverFrame(string.format("%.2f", data.FrameMs)) end
	end)
	local frames, elapsed, worst = 0, 0, 0
	local sampling = nil
	return {Destroy = function()
		resultConnection:Disconnect()
		if sampling then sampling:Disconnect(); sampling = nil end
	end, Active = function(active)
		if active and not sampling then
			frames, elapsed, worst = 0, 0, 0
			sampling = RunService.RenderStepped:Connect(function(dt)
				frames += 1; elapsed += dt; worst = math.max(worst, dt)
			end)
		elseif not active and sampling then sampling:Disconnect(); sampling = nil end
	end, Tick = function()
		local stats = ProjectileClient.GetStats()
		clientLine(tostring(stats.Active or stats.Visuals or 0))
		if frames > 0 and elapsed > 0 then
			frameLine(string.format("%.0f / %.2f / %.2f", frames / elapsed, elapsed / frames * 1000, worst * 1000))
		end
		frames, elapsed, worst = 0, 0, 0
	end}
end
