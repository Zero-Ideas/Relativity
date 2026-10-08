--!optimize 2
--[[
	VFX tab: preview ExplosionVFX locally (nothing is sent to the server, no
	damage), and the portal / drone tech (client/Portal, client/DroneClient):
	summon or dismiss your own drone without a gun, or open a test portal in
	front of you that a drone flies out of and back into. Power is a 0..1 slider mapped exponentially onto 5..2000 so the
	whole range is reachable; the readout shows what the generator derives
	from it.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local SpellRunes = require(Shared.SpellRunes)
local Util = require(script.Parent.Parent.Util)
local ExplosionVFX = require(script.Parent.Parent.Parent.ExplosionVFX)
local DroneClient = require(script.Parent.Parent.Parent.DroneClient)
local statLine = Util.statLine

local localPlayer = Players.LocalPlayer
local PLACE_ACTION = "DebugPlaceExplosion"
local MIN_POWER, MAX_POWER = ExplosionVFX.PowerFloor, ExplosionVFX.PowerCeiling
local SWEEP_STEPS = 6

local function powerAt(level: number): number
	return MIN_POWER * (MAX_POWER / MIN_POWER) ^ math.clamp(level, 0, 1)
end

return function(window)
	local tab = window:CreateTab({ Name = "VFX" })

	local level = 0.5
	local radiusOverride = 0
	local tintName = "Heat only"
	local placing = false

	local tints: { [string]: Color3? } = { ["Heat only"] = nil }
	local tintNames = { "Heat only" }
	for name, element in SpellRunes.Elements do
		tints[name] = element.Color
		table.insert(tintNames, name)
	end
	table.sort(tintNames, function(a, b)
		return a == "Heat only" or (b ~= "Heat only" and a < b)
	end)

	local powerLine = statLine(tab, "Power")
	local sizeLine = statLine(tab, "Derived")
	local layersLine = statLine(tab, "Groups (emitters % / count %)")

	local function options(power: number?)
		return {
			Power = power or powerAt(level),
			Radius = if radiusOverride > 0 then radiusOverride else nil,
			Color = tints[tintName],
		}
	end

	local GROUP_ORDER = { "Energy", "Sparks", "Smoke", "Dust", "Wind", "Debris", "Shockwaves", "GroundCrack" }
	local function refreshReadout()
		local power = powerAt(level)
		local spec = ExplosionVFX.Describe(power, if radiusOverride > 0 then radiusOverride else nil)
		powerLine(string.format("%.0f  (intensity %.2f)", power, spec.Intensity))
		sizeLine(string.format("radius %.1f studs  ·  template x%.2f", spec.Radius, spec.Scale))
		local layers = {}
		for _, group in GROUP_ORDER do
			local factor = spec.Groups[group]
			if factor then
				local share = spec.Shares and spec.Shares[group] or 1
				table.insert(layers, string.format("%s %d%%/%d%%", group, math.floor(share * 100 + 0.5), math.floor(factor * 100 + 0.5)))
			end
		end
		if spec.Shake > 0 then
			table.insert(layers, string.format("shake %d%%", math.floor(spec.Shake * 100 + 0.5)))
		end
		layersLine(table.concat(layers, ", "))
	end

	tab:SliderFloat({
		Label = "Power level",
		Minimum = 0,
		Maximum = 1,
		Value = level,
		Format = "%.2f",
		Callback = function(_, value: number)
			level = value
			refreshReadout()
		end,
	})
	tab:InputInt({
		Label = "Radius override (0 = auto)",
		Value = 0,
		Increment = 2,
		Callback = function(_, value)
			radiusOverride = math.max(tonumber(value) or 0, 0)
			refreshReadout()
		end,
	})
	local tintPicker = tab:Combo({
		Label = "Tint",
		Placeholder = tintName,
		GetItems = function()
			return tintNames
		end,
		Callback = function(_, value)
			tintName = value
		end,
	})
	tintPicker:SetValueText(tintName)

	local function inFront(distance: number): Vector3?
		local character = localPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return root.Position + root.CFrame.LookVector * distance
		end
		return nil
	end

	local function pointUnderMouse(): Vector3?
		local camera = workspace.CurrentCamera
		if not camera then
			return nil
		end
		local mouse = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { localPlayer.Character :: Instance }
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
		return hit and hit.Position + hit.Normal * 1.5
	end

	local modeLine = statLine(tab, "Mode")
	local function setPlacing(on: boolean)
		placing = on
		if not on then
			ContextActionService:UnbindAction(PLACE_ACTION)
			modeLine("off")
			return
		end
		modeLine("placing: click the world (button again to stop)")
		ContextActionService:BindActionAtPriority(PLACE_ACTION, function(_, state)
			if state == Enum.UserInputState.Begin then
				local point = pointUnderMouse()
				if point then
					ExplosionVFX.Play(point, options())
				end
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value + 100, Enum.UserInputType.MouseButton1)
	end

	local row = tab:Row()
	row:Button({
		Text = "Spawn in front of me",
		Callback = function()
			local spec = ExplosionVFX.Describe(powerAt(level), if radiusOverride > 0 then radiusOverride else nil)
			local point = inFront(spec.Radius * 1.5 + 8)
			if point then
				ExplosionVFX.Play(point, options())
			end
		end,
	})
	row:Button({
		Text = "Place at cursor",
		Callback = function()
			setPlacing(not placing)
		end,
	})
	tab:Button({
		Text = `Power sweep ({SWEEP_STEPS} blasts, weakest to strongest)`,
		Callback = function()
			local character = localPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not (root and root:IsA("BasePart")) then
				return
			end
			-- A row across your view, spaced so the biggest doesn't swallow the rest.
			local biggest = ExplosionVFX.Describe(MAX_POWER).Radius
			local center = root.Position + root.CFrame.LookVector * (biggest * 2.5 + 20)
			local spacing = biggest * 3.5
			for index = 1, SWEEP_STEPS do
				local t = (index - 1) / (SWEEP_STEPS - 1)
				local offset = root.CFrame.RightVector * spacing * (index - (SWEEP_STEPS + 1) / 2)
				task.delay(t * 1.6, ExplosionVFX.Play, center + offset, options(powerAt(t)))
			end
		end,
	})

	tab:Separator({ Text = "Portal / drone" })
	local portalRadius = 3
	tab:SliderFloat({
		Label = "Test portal radius",
		Minimum = 1,
		Maximum = 8,
		Value = portalRadius,
		Format = "%.1f studs",
		Callback = function(_, value: number)
			portalRadius = value
		end,
	})
	tab:Button({
		Text = "Open a portal in front of me (a drone flies out)",
		Callback = function()
			local character = localPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not (root and root:IsA("BasePart")) then
				return
			end
			local centre = root.Position + root.CFrame.LookVector * (portalRadius * 3 + 10) + Vector3.new(0, portalRadius * 0.6 + 1, 0)
			DroneClient.Demo(CFrame.lookAt(centre, root.Position + Vector3.new(0, 1.5, 0)), portalRadius)
		end,
	})
	local droneRow = tab:Row()
	droneRow:Button({
		Text = "Summon my drone",
		Callback = function()
			if localPlayer.Character then
				DroneClient.Summon(localPlayer.Character)
			end
		end,
	})
	droneRow:Button({
		Text = "Dismiss it",
		Callback = function()
			if localPlayer.Character then
				DroneClient.Dismiss(localPlayer.Character)
			end
		end,
	})

	refreshReadout()
	setPlacing(false)
	return {
		Active = function(active: boolean)
			if not active and placing then
				setPlacing(false) -- never leave world clicks captured behind a hidden tab
			end
		end,
	}
end
