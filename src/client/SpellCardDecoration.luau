--!strict
-- Static, code-drawn filigree. Cached per tier; selection only changes strokes.
local Decoration = {}
local TweenService = game:GetService("TweenService")
Decoration.__index = Decoration
local ManaTier = require(game:GetService("ReplicatedStorage").Shared.SpellManaTier)
local COLORS = ManaTier.Colors

function Decoration.GetTier(cost: number): number
	return ManaTier.GetTier(cost)
end

function Decoration.GetColor(cost: number): Color3
	return COLORS[Decoration.GetTier(cost) + 1]
end

local function frame(parent: Instance, name: string, x: number, y: number, w: number, h: number): Frame
	local object = Instance.new("Frame")
	object.Name = name
	object.BackgroundTransparency = 1
	object.BorderSizePixel = 0
	object.Position = UDim2.fromScale(x, y)
	object.Size = UDim2.fromScale(w, h)
	object.ZIndex = 6
	object.Parent = parent
	return object
end

local function outline(object: Frame, color: Color3, thickness: number, transparency: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency or 0
	stroke.Parent = object
	return stroke
end

local function line(parent: Frame, color: Color3, x: number, y: number, w: number, h: number, rotation: number?)
	local object = frame(parent, "Filigree", x, y, w, h)
	object.BackgroundTransparency = 0
	object.BackgroundColor3 = color
	object.Rotation = rotation or 0
end

local function diamond(parent: Frame, color: Color3, x: number, y: number, size: number)
	local object = frame(parent, "Gem", x, y, size, size)
	object.AnchorPoint = Vector2.new(0.5, 0.5)
	object.Rotation = 45
	object.BackgroundColor3 = color
	object.BackgroundTransparency = 0.25
	outline(object, color, 1)
end

local function build(root: Frame, tier: number): Frame
	local color = COLORS[tier + 1]
	local group = frame(root, "Tier" .. tier, 0, 0, 1, 1)
	if tier == 0 then return group end
	local inset = frame(group, "InsetBorder", 0.045, 0.035, 0.91, 0.93)
	outline(inset, color, 1, 0.55)
	for _, corner in { { 0, 0, 0 }, { 1, 0, 90 }, { 1, 1, 180 }, { 0, 1, 270 } } do
		local motif = frame(group, "Corner", corner[1], corner[2], 0.25, 0.25)
		motif.AnchorPoint = Vector2.new(0.5, 0.5)
		motif.Rotation = corner[3]
		local aspect = Instance.new("UIAspectRatioConstraint")
		aspect.Parent = motif
		line(motif, color, 0.5, 0.5, 0.5, 0.055)
		line(motif, color, 0.5, 0.5, 0.055, 0.5)
		if tier >= 2 then
			diamond(motif, color, 0.65, 0.65, 0.19)
			line(motif, color, 0.72, 0.72, 0.28, 0.035, -45)
		end
		if tier >= 3 then
			line(motif, color, 0.5, 0.35, 0.4, 0.035)
			line(motif, color, 0.35, 0.5, 0.035, 0.4)
			diamond(motif, color, 0.48, 0.48, 0.10)
		end
		if tier >= 4 then
			line(motif, color, 0.62, 0.88, 0.3, 0.035, -35)
			line(motif, color, 0.88, 0.62, 0.035, 0.3, 35)
			diamond(motif, color, 0.91, 0.91, 0.12)
		end
	end
	if tier >= 3 then
		for _, edge in { { 0.5, 0, 0 }, { 0.5, 1, 180 } } do
			local crest = frame(group, "Crest", edge[1], edge[2], 0.32, 0.32)
			crest.AnchorPoint = Vector2.new(0.5, 0.5)
			crest.Rotation = edge[3]
			local aspect = Instance.new("UIAspectRatioConstraint")
			aspect.Parent = crest
			diamond(crest, color, 0.5, 0.5, 0.15)
			line(crest, color, 0.1, 0.52, 0.26, 0.025, 20)
			line(crest, color, 0.64, 0.52, 0.26, 0.025, -20)
			if tier >= 5 then
				for index = 1, 3 do
					diamond(crest, color, 0.25 * index, 0.7, if index == 2 then 0.14 else 0.08)
				end
				line(crest, color, 0.18, 0.82, 0.64, 0.035)
			end
		end
	end
	return group
end

function Decoration.new(parent: GuiObject): any
	local root = frame(parent, "SpellCardFiligree", 0.025, 0.02, 0.95, 0.96)
	local border = outline(root, COLORS[1], 1.2)
	local glow = outline(root, COLORS[1], 4, 0.8)
	glow.Enabled = false
	local glint = frame(root, "CastGlint", 0, 0, 1, 1)
	glint.BackgroundTransparency = 0
	glint.ZIndex = 7
	glint.Visible = false
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 25
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.4, 1),
		NumberSequenceKeypoint.new(0.5, 0.65), NumberSequenceKeypoint.new(0.6, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = glint
	return setmetatable({ Root = root, Border = border, Glow = glow, Groups = {}, Tier = nil,
		Glint = glint, GlintGradient = gradient, FlashId = 0 }, Decoration)
end

function Decoration.Flash(self: any, manaSpent: number)
	self.FlashId += 1
	local id = self.FlashId
	if self.GlintTween then self.GlintTween:Cancel() end
	self.Glint.BackgroundColor3 = Decoration.GetColor(manaSpent):Lerp(Color3.new(1, 1, 1), 0.35)
	-- Start inside the card so the flash is visible on the acceptance frame.
	self.GlintGradient.Offset = Vector2.new(-0.35, 0)
	self.Glint.Visible = true
	local tween = TweenService:Create(self.GlintGradient, TweenInfo.new(0.28, Enum.EasingStyle.Linear), { Offset = Vector2.new(1, 0) })
	self.GlintTween = tween
	tween.Completed:Once(function()
		if self.FlashId == id then self.Glint.Visible = false; self.GlintTween = nil end
		tween:Destroy()
	end)
	tween:Play()
end

function Decoration.Update(self: any, cost: number?, selected: boolean)
	self.Root.Visible = cost ~= nil
	if cost == nil then return end
	local tier = Decoration.GetTier(cost)
	if self.Tier ~= tier then
		if self.Tier ~= nil then self.Groups[self.Tier].Visible = false end
		if not self.Groups[tier] then self.Groups[tier] = build(self.Root, tier) end
		self.Groups[tier].Visible = true
		self.Tier = tier
	end
	local color = COLORS[tier + 1]
	self.Border.Color = if selected then color:Lerp(Color3.new(1, 1, 1), 0.3) else color
	self.Border.Thickness = if selected then 2.2 else 1.2
	self.Glow.Color = color
	self.Glow.Enabled = selected
end

function Decoration.Destroy(self: any)
	self.FlashId += 1
	if self.GlintTween then self.GlintTween:Cancel(); self.GlintTween = nil end
	self.Root:Destroy()
end

return Decoration
