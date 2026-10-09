--!optimize 2
--[[
	VFX tab: preview ExplosionVFX locally (nothing is sent to the server, no
	damage), and the portal / drone tech (client/Portal, client/DroneClient):
	summon or dismiss your own drone without a gun, or open a test portal in
	front of you that a drone flies out of and back into. Power is a 0..1 slider mapped exponentially onto 5..2000 so the
	whole range is reachable; the readout shows what the generator derives
	from it. The Effects section tests client/Effects: adaptive impacts on
	whatever you click, a local streaked bolt, and a fast blade swing.
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
local Effects = require(script.Parent.Parent.Parent.Effects)
local RunService = game:GetService("RunService")
local statLine = Util.statLine

local localPlayer = Players.LocalPlayer
local PLACE_ACTION = "DebugPlaceExplosion"
local IMPACT_ACTION = "DebugPlaceImpact"
local IMPACT_KINDS = { "world", "bounce", "entity", "detonate", "scrape" }
local MIN_POWER, MAX_POWER = ExplosionVFX.PowerFloor, ExplosionVFX.PowerCeiling
local SWEEP_STEPS = 6

local function powerAt(level: number): number
	return MIN_POWER * (MAX_POWER / MIN_POWER) ^ math.clamp(level, 0, 1)
end

return function(window)
	local tab = window:CreateTab({ Name = "VFX" })

	local level = 0.5
	local radiusOverride = 0
	local themeName = "Fire"
	local placing = false

	-- every element (a theme, or one derived from its colour) plus any extra themes
	local themeColors: { [string]: Color3? } = {}
	local themeNames = {}
	for name, element in SpellRunes.Elements do
		themeColors[name] = element.Color
		table.insert(themeNames, name)
	end
	for name in ExplosionVFX.Themes do
		if not table.find(themeNames, name) then
			table.insert(themeNames, name)
		end
	end
	table.sort(themeNames)

	local powerLine = statLine(tab, "Power")
	local sizeLine = statLine(tab, "Derived")
	local layersLine = statLine(tab, "Groups (emitters % / count %)")

	local function options(power: number?)
		return {
			Power = power or powerAt(level),
			Radius = if radiusOverride > 0 then radiusOverride else nil,
			Theme = themeName,
			Color = themeColors[themeName],
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
	local themePicker = tab:Combo({
		Label = "Colour theme",
		Placeholder = themeName,
		GetItems = function()
			return themeNames
		end,
		Callback = function(_, value)
			themeName = value
		end,
	})
	themePicker:SetValueText(themeName)

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

	tab:Separator({ Text = "Effects framework (impacts, swings, streaks)" })
	local effectsLine = statLine(tab, "Effects")
	local impactKind = "world"
	local impactSpeed = 400
	local swingTime = 0.12
	local placingImpacts = false
	local kindPicker = tab:Combo({
		Label = "Impact kind",
		Placeholder = impactKind,
		GetItems = function()
			return IMPACT_KINDS
		end,
		Callback = function(_, value)
			impactKind = value
		end,
	})
	kindPicker:SetValueText(impactKind)
	tab:SliderFloat({
		Label = "Shot speed (studs/s)",
		Minimum = 50,
		Maximum = 3000,
		Value = impactSpeed,
		Format = "%.0f",
		Callback = function(_, value: number)
			impactSpeed = value
		end,
	})
	tab:SliderFloat({
		Label = "Test swing duration",
		Minimum = 0.03,
		Maximum = 0.6,
		Value = swingTime,
		Format = "%.2f s",
		Callback = function(_, value: number)
			swingTime = value
		end,
	})

	local function mouseRay(): (Vector3, Vector3, RaycastResult?)
		local camera = workspace.CurrentCamera :: Camera
		local mouse = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { localPlayer.Character :: Instance }
		params.IgnoreWater = false
		return ray.Origin, ray.Direction, workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
	end

	local impactModeLine = statLine(tab, "Impact placing")
	local function setPlacingImpacts(on: boolean)
		placingImpacts = on
		if not on then
			ContextActionService:UnbindAction(IMPACT_ACTION)
			impactModeLine("off")
			return
		end
		impactModeLine("click surfaces (button again to stop)")
		ContextActionService:BindActionAtPriority(IMPACT_ACTION, function(_, state)
			if state == Enum.UserInputState.Begin then
				local _, direction, hit = mouseRay()
				if hit then
					Effects.Impact(hit.Position, hit.Normal, { Kind = impactKind, Velocity = direction * impactSpeed })
				end
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value + 100, Enum.UserInputType.MouseButton1)
	end

	-- A local-only bolt: flies from the camera toward the cursor with a
	-- streak, and impacts whatever it reaches.
	local function testBolt()
		local origin, direction = mouseRay()
		local velocity = direction.Unit * impactSpeed
		local bolt = Instance.new("Part")
		bolt.Name = "TestBolt"
		bolt.Shape = Enum.PartType.Ball
		bolt.Size = Vector3.one * 0.5
		bolt.Material = Enum.Material.Neon
		bolt.Color = Color3.fromRGB(120, 200, 255)
		bolt.Anchored, bolt.CanCollide, bolt.CanQuery, bolt.CanTouch = true, false, false, false
		local position = origin + direction.Unit * 4
		bolt.CFrame = CFrame.lookAt(position, position + velocity)
		bolt.Parent = workspace
		local detach = Effects.AttachStreak(bolt, CFrame.identity, function()
			return velocity
		end, bolt.Color, 0.5)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { localPlayer.Character :: Instance, bolt }
		params.IgnoreWater = false
		local age = 0
		local connection
		connection = RunService.Heartbeat:Connect(function(dt)
			age += dt
			local move = velocity * dt
			local hit = workspace:Raycast(position, move, params)
			if hit or age > 3 then
				connection:Disconnect()
				detach()
				bolt:Destroy()
				if hit then
					Effects.Impact(hit.Position, hit.Normal, { Kind = "world", Velocity = velocity, Color = bolt.Color })
				end
				return
			end
			position += move
			bolt.CFrame = CFrame.lookAt(position, position + velocity)
		end)
	end

	-- A sword-sized blade swept 270 degrees down through the ground in front
	-- of you in `swingTime` seconds: arcs stay round at any speed, and where
	-- it drags through the floor it throws that floor's sparks / dust.
	local function testSwing()
		local character = localPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not (root and root:IsA("BasePart")) then
			return
		end
		local pivot = root.CFrame * CFrame.new(1.5, 0.5, -3)
		local blade = Instance.new("Part")
		blade.Name = "TestBlade"
		blade.Size = Vector3.new(0.25, 0.08, 5)
		blade.Material = Enum.Material.Metal
		blade.Color = Color3.fromRGB(200, 205, 215)
		blade.Anchored, blade.CanCollide, blade.CanQuery, blade.CanTouch = true, false, false, false
		local function pose(alpha: number): CFrame
			-- sweep about the pivot's right axis, blade pointing out along -Z
			local angle = math.rad(-60 - 270 * alpha)
			return pivot * CFrame.Angles(angle, 0, math.rad(-25)) * CFrame.new(0, 0, -3.2)
		end
		blade.CFrame = pose(0)
		blade.Parent = workspace
		local handle = Effects.Swing({ Part = blade, Ignore = { character :: Instance } })
		local elapsed = 0
		local name = "DebugTestSwing" .. tostring(blade:GetDebugId())
		RunService:BindToRenderStep(name, Enum.RenderPriority.Camera.Value + 5, function(dt)
			elapsed += dt
			local alpha = math.min(elapsed / swingTime, 1)
			blade.CFrame = pose(alpha)
			if alpha >= 1 then
				RunService:UnbindFromRenderStep(name)
				handle:Stop()
				task.delay(0.6, blade.Destroy, blade)
			end
		end)
	end

	local effectsRow = tab:Row()
	effectsRow:Button({
		Text = "Impact at cursor",
		Callback = function()
			setPlacingImpacts(not placingImpacts)
		end,
	})
	effectsRow:Button({
		Text = "Fire test bolt at cursor",
		Callback = testBolt,
	})
	effectsRow:Button({
		Text = "Test swing",
		Callback = testSwing,
	})

	local tabActive = false
	task.spawn(function()
		while true do
			if tabActive then
				local st = Effects.GetStats()
				effectsLine(string.format(
					"impacts %d (merged %d, reduced %d, skipped %d) · emitters %d · debris %d · marks %d · lights %d · swings %d (%d arcs) · streaks %d/%d",
					st.Impacts, st.Merged, st.Reduced, st.Skipped, st.Emitters, st.Debris, st.Marks, st.Lights,
					st.Swings, st.SwingSegments, st.StreaksActive, st.Streaks))
			end
			task.wait(0.5)
		end
	end)

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
	setPlacingImpacts(false)
	return {
		Active = function(active: boolean)
			tabActive = active
			if not active and placing then
				setPlacing(false) -- never leave world clicks captured behind a hidden tab
			end
			if not active and placingImpacts then
				setPlacingImpacts(false)
			end
		end,
	}
end
