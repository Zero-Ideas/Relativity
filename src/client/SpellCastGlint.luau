--!strict
-- Screen-space cast tell. Retained glyphs and one render connection while active.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ManaTier = require(game:GetService("ReplicatedStorage").Shared.SpellManaTier)
local Glint = {}
local active: {any} = {}
local pools: {[number]: {CanvasGroup}} = {}
local screen: ScreenGui? = nil
local connection: RBXScriptConnection? = nil

local function glyph(tier: number): CanvasGroup
	if not screen then
		local gui = Instance.new("ScreenGui")
		gui.Name = "SpellCastIndicators"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 40
		gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
		screen = gui
	end
	local root = Instance.new("CanvasGroup")
	root.Name = "Tier" .. tier
	root.AnchorPoint = Vector2.one * 0.5
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromOffset(160, 160)
	root.Visible = false
	root.Parent = screen
	local color = ManaTier.GetColor(tier * 200)
	local function shape(size: Vector2, position: Vector2, rotation: number, stroke: boolean, round: boolean?)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.one * 0.5
		f.Size = UDim2.fromScale(size.X, size.Y)
		f.Position = UDim2.fromScale(position.X, position.Y)
		f.Rotation = rotation
		f.BackgroundColor3 = color
		f.BackgroundTransparency = if stroke then 1 else 0
		f.BorderSizePixel = 0
		f.Parent = root
		if stroke then
			local edge = Instance.new("UIStroke")
			edge.Color = color
			edge.Thickness = 1.5
			edge.Parent = f
		end
		if round then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0.5, 0)
			corner.Parent = f
		end
	end
	shape(Vector2.new(0.025, 0.46), Vector2.one * 0.5, 0, false)
	shape(Vector2.new(0.025, 0.46), Vector2.one * 0.5, 90, false)
	for ring = 1, 1 + math.floor(tier / 2) do
		shape(Vector2.one * (0.28 + ring * 0.14), Vector2.one * 0.5, 0, true, true)
	end
	if tier >= 1 then shape(Vector2.one * 0.32, Vector2.one * 0.5, 45, true) end
	if tier >= 3 then shape(Vector2.one * 0.44, Vector2.one * 0.5, 0, true) end
	local count = 4 + tier * 2
	for index = 1, count do
		local angle = index / count * math.pi * 2
		local position = Vector2.one * 0.5 + Vector2.new(math.cos(angle), math.sin(angle)) * 0.39
		shape(Vector2.new(0.018, 0.07 + tier * 0.005), position, math.deg(angle) + 90, false)
		if tier >= 4 then shape(Vector2.one * 0.035, position, 45, true) end
	end
	return root
end

local function recycle(entry: any)
	entry.ui.Visible = false
	local pool = pools[entry.tier]
	if not pool then pool = {}; pools[entry.tier] = pool end
	if #pool < 2 then table.insert(pool, entry.ui) else entry.ui:Destroy() end
end

local function step()
	local camera = workspace.CurrentCamera
	for index = #active, 1, -1 do
		local entry = active[index]
		local t = (os.clock() - entry.began) / 0.42
		if t >= 1 or not entry.head.Parent or not entry.caster.Parent then
			recycle(entry); table.remove(active, index)
			continue
		end
		local origin = entry.head.Position - Vector3.new(0, 0.3, 0)
		local aim = if entry.target then entry.target - origin else entry.caster:GetPivot().LookVector
		local facing = if aim.Magnitude > 0.001 then aim.Unit else entry.caster:GetPivot().LookVector
		local point, visible = Vector3.zero, false
		if camera then point, visible = camera:WorldToViewportPoint(origin + facing * 5) end
		entry.ui.Visible = visible and point.Z > 0
		entry.ui.Position = UDim2.fromOffset(point.X, point.Y)
		local size = (90 + entry.tier * 9) * (0.55 + 0.65 * (1 - (1 - t)^3))
		entry.ui.Size = UDim2.fromOffset(size, size)
		entry.ui.Rotation = (if entry.tier >= 3 then 18 else 8) * t
		entry.ui.GroupTransparency = t * t
	end
	if #active == 0 and connection then connection:Disconnect(); connection = nil end
end

function Glint.Play(caster: Model, manaCost: number, target: Vector3?)
	local head = caster:FindFirstChild("Head") or caster.PrimaryPart
	if not head or not head:IsA("BasePart") then return end
	local tier = ManaTier.GetTier(manaCost)
	local pool = pools[tier]
	local ui = if pool and #pool > 0 then table.remove(pool) else glyph(tier)
	if #active >= 24 then recycle(table.remove(active, 1)) end
	table.insert(active, {ui = ui, tier = tier, caster = caster, head = head, target = target, began = os.clock()})
	step() -- visible on the input frame
	if not connection then connection = RunService.RenderStepped:Connect(step) end
end
return Glint
