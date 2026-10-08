--!strict
-- Shared look and small Instance helpers for the spell editor.

local Theme = {}

Theme.Colors = {
	background = Color3.fromRGB(13, 11, 22),
	board = Color3.fromRGB(17, 15, 28),
	grid = Color3.fromRGB(38, 33, 58),
	panel = Color3.fromRGB(24, 20, 38),
	panel2 = Color3.fromRGB(33, 28, 51),
	panel3 = Color3.fromRGB(46, 39, 70),
	line = Color3.fromRGB(120, 92, 180),
	text = Color3.fromRGB(238, 232, 255),
	muted = Color3.fromRGB(150, 140, 178),
	accent = Color3.fromRGB(176, 120, 255),
	good = Color3.fromRGB(96, 222, 150),
	bad = Color3.fromRGB(255, 96, 116),
	warn = Color3.fromRGB(255, 190, 80),
	selection = Color3.fromRGB(255, 255, 255),
}

Theme.Font = Enum.Font.Gotham
Theme.FontMedium = Enum.Font.GothamMedium
Theme.FontBold = Enum.Font.GothamBold

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

function Theme.corner(parent: Instance, radius: number?)
	Theme.make("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, parent)
end

function Theme.stroke(parent: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	return Theme.make("UIStroke", {
		Color = color or Theme.Colors.line,
		Thickness = thickness or 1,
		Transparency = transparency or 0.3,
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
	Theme.corner(button, 6)
	if props then
		for key, value in props do
			(button :: any)[key] = value
		end
	end
	return button
end

function Theme.list(parent: Instance, padding: number?, horizontal: boolean?): UIListLayout
	return Theme.make("UIListLayout", {
		Padding = UDim.new(0, padding or 6),
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, parent)
end

return Theme
