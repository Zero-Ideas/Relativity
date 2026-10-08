--!strict
--[[
	Shared look and small Instance helpers for the spell editor: a cyan
	holographic display -- glass panels over the game world, glowing cyan
	edges and fading cyan rules.

	Glass: every see-through surface is registered with a layer, and one
	opacity (the "Spell editor opacity" setting, SpellAssemblerGui.
	SetAppearance -> Theme.SetOpacity) sets how see-through each layer is:
	  backdrop -- the editor behind everything        1 - o
	  panel    -- top bar, side panels, overlays      (1 - o) x 0.6
	  card     -- runes, buttons, fields, rows        (1 - o) x 0.35
	so text-bearing surfaces stay legible at the lowest opacity. Registered
	frames follow opacity changes live; frames rebuilt on every render read
	the current value when they're made.
]]

local TweenService = game:GetService("TweenService")

local Theme = {}

Theme.Colors = {
	background = Color3.fromRGB(4, 10, 18),
	board = Color3.fromRGB(6, 14, 24),
	grid = Color3.fromRGB(90, 220, 255),
	panel = Color3.fromRGB(7, 18, 30),
	panel2 = Color3.fromRGB(10, 26, 42),
	panel3 = Color3.fromRGB(16, 40, 62),
	line = Color3.fromRGB(90, 220, 255),
	text = Color3.fromRGB(220, 245, 255),
	muted = Color3.fromRGB(120, 175, 200),
	accent = Color3.fromRGB(110, 230, 255),
	good = Color3.fromRGB(100, 255, 190),
	bad = Color3.fromRGB(255, 95, 120),
	warn = Color3.fromRGB(255, 200, 90),
	selection = Color3.fromRGB(255, 255, 255),
}

Theme.Font = Enum.Font.Gotham
Theme.FontMedium = Enum.Font.GothamMedium
Theme.FontBold = Enum.Font.GothamBold

Theme.GridTransparency = 0.86
local EDGE_TRANSPARENCY = 0.45 -- a glass surface's glowing edge
local BUTTON_EDGE, BUTTON_EDGE_HOVER = 0.65, 0.15
local CORNER = 4

-- Instance.new + property table + parent in one call.
function Theme.make(className: string, props: { [string]: any }?, parent: Instance?): any
	local instance = Instance.new(className)
	if props then
		for key, value in props do
			(instance :: any)[key] = value
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

--------------------------------------------------------------------------------
-- Glass
--------------------------------------------------------------------------------

export type Layer = "backdrop" | "panel" | "card"

Theme.Opacity = 0.6 -- 0.2..1, from the player's setting
-- (strong keys: an Instance's Lua wrapper can be collected while the
-- Instance lives on, so a weak table would forget frames; each one leaves
-- when it's destroyed instead)
local glassFrames: { [GuiObject]: Layer } = {}

-- BackgroundTransparency of a glass layer at the current opacity.
function Theme.transparency(layer: Layer): number
	local clear = 1 - Theme.Opacity
	if layer == "backdrop" then
		return clear
	elseif layer == "panel" then
		return clear * 0.6
	end
	return clear * 0.35
end

-- Makes `object` a glass surface of `layer` (its transparency follows the
-- opacity setting). `sheen` adds the faint brightening toward its top edge.
function Theme.glass(object: GuiObject, layer: Layer, sheen: boolean?): GuiObject
	object.BackgroundTransparency = Theme.transparency(layer)
	if not glassFrames[object] then
		object.Destroying:Once(function()
			glassFrames[object] = nil
		end)
	end
	glassFrames[object] = layer
	if sheen then
		Theme.make("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(150, 160, 170)),
		}, object)
	end
	return object
end

-- A panel: glass with a sheen and a glowing cyan edge.
function Theme.panel(object: GuiObject, layer: Layer?): GuiObject
	object.BackgroundColor3 = object.BackgroundColor3:Lerp(Theme.Colors.line, 0.06)
	Theme.glass(object, layer or "panel", true)
	Theme.stroke(object, Theme.Colors.line, 1, EDGE_TRANSPARENCY)
	return object
end

function Theme.SetOpacity(opacity: number)
	Theme.Opacity = math.clamp(opacity, 0.2, 1)
	for object, layer in glassFrames do
		if object.Parent then
			object.BackgroundTransparency = Theme.transparency(layer)
		else
			glassFrames[object] = nil -- (removed without being destroyed)
		end
	end
end

-- Fades every live glass surface in from nothing (the boot animation).
function Theme.FadeInGlass(seconds: number)
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for object, layer in glassFrames do
		if object.Parent then
			object.BackgroundTransparency = 1
			TweenService:Create(object, info, { BackgroundTransparency = Theme.transparency(layer) }):Play()
		end
	end
end

-- A cyan rule that fades out at both ends (like the HUD's lines).
function Theme.fadeLine(parent: Instance, props: { [string]: any }?): Frame
	local line = Theme.make("Frame", {
		BackgroundColor3 = Theme.Colors.line,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
	}, parent)
	Theme.make("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.18, 0),
			NumberSequenceKeypoint.new(0.82, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, line)
	if props then
		for key, value in props do
			(line :: any)[key] = value
		end
	end
	return line
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

function Theme.corner(parent: Instance, radius: number?)
	Theme.make("UICorner", { CornerRadius = UDim.new(0, radius or CORNER) }, parent)
end

function Theme.stroke(parent: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	return Theme.make("UIStroke", {
		Color = color or Theme.Colors.line,
		Thickness = thickness or 1,
		Transparency = transparency or EDGE_TRANSPARENCY,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

function Theme.padding(parent: Instance, all: number)
	local pad = UDim.new(0, all)
	Theme.make("UIPadding", { PaddingTop = pad, PaddingBottom = pad, PaddingLeft = pad, PaddingRight = pad }, parent)
end

function Theme.label(parent: Instance, text: string, size: number?, props: { [string]: any }?): TextLabel
	local label = Theme.make("TextLabel", {
		BackgroundTransparency = 1,
		Font = Theme.Font,
		Text = text,
		TextColor3 = Theme.Colors.text,
		TextSize = size or 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, parent)
	if props then
		for key, value in props do
			(label :: any)[key] = value
		end
	end
	return label
end

-- A glass button with a cyan edge that lights up under the mouse. (One given
-- its own BackgroundTransparency keeps it.)
function Theme.button(parent: Instance, text: string, props: { [string]: any }?): TextButton
	local button = Theme.make("TextButton", {
		AutoButtonColor = true,
		BackgroundColor3 = Theme.Colors.panel3,
		BorderSizePixel = 0,
		Font = Theme.FontMedium,
		Text = text,
		TextColor3 = Theme.Colors.text,
		TextSize = 13,
	}, parent)
	Theme.corner(button)
	if props then
		for key, value in props do
			(button :: any)[key] = value
		end
	end
	if not (props and props.BackgroundTransparency ~= nil) then
		Theme.glass(button, "card")
		local edge = Theme.stroke(button, Theme.Colors.line, 1, BUTTON_EDGE)
		button.MouseEnter:Connect(function() edge.Transparency = BUTTON_EDGE_HOVER end)
		button.MouseLeave:Connect(function() edge.Transparency = BUTTON_EDGE end)
	end
	return button
end

-- A text field: glass with a faint edge.
function Theme.field(box: TextBox): TextBox
	Theme.glass(box, "card")
	Theme.stroke(box, Theme.Colors.line, 1, BUTTON_EDGE)
	return box
end

function Theme.list(parent: Instance, padding: number?, horizontal: boolean?): UIListLayout
	return Theme.make("UIListLayout", {
		Padding = UDim.new(0, padding or 6),
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, parent)
end

return Theme
