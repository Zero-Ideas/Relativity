--!strict
-- Reuses the world circle's GUI drawing primitives. A fixed-size canvas is
-- scaled into the card so pixel strokes and rune text retain their proportions.
-- Only cooling-down cards animate; ready cards have no per-frame Lua work.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Compiler = require(Shared.SpellCompiler)
local Layout = require(Shared.SpellCircleLayout)
local Circles = require(script.Parent.SpellCircleVFX)
local Preview = {}
Preview.__index = Preview
local active: { [any]: boolean } = {}
local connection: RBXScriptConnection? = nil
local RELEASE = 0.22

function Preview.new(parent: GuiObject): any
	local frame = Instance.new("Frame")
	frame.Name = "SpellCirclePreview"
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BorderSizePixel = 0
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.48)
	frame.Size = UDim2.fromScale(0.95, 0.64)
	frame.ClipsDescendants = true
	frame.ZIndex = 3
	frame.Parent = parent
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.Parent = frame
	local canvas = Instance.new("Frame")
	canvas.Name = "CircleCanvas"
	canvas.Size = UDim2.fromOffset(512, 512)
	canvas.BackgroundTransparency = 1
	canvas.ZIndex = 4
	canvas.Parent = frame
	local scale = Instance.new("UIScale")
	scale.Parent = canvas
	local resize = frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() scale.Scale = frame.AbsoluteSize.X / 512 end)
	scale.Scale = frame.AbsoluteSize.X / 512
	local timer = Instance.new("TextLabel")
	timer.Name = "Cooldown"
	timer.BackgroundTransparency = 1
	timer.Size = UDim2.fromScale(1, 1)
	timer.Font = Enum.Font.GothamBold
	timer.TextSize = 14
	timer.TextColor3 = Color3.new(1, 1, 1)
	timer.TextStrokeTransparency = 0
	timer.ZIndex = 7
	timer.Visible = false
	timer.Parent = frame
	return setmetatable({ Frame = frame, Canvas = canvas, Timer = timer, Resize = resize, Deadline = 0, FireAt = nil }, Preview)
end

function Preview.SetProgress(self: any, progress: number, visible: number)
	if not self.Builder then return end
	for _, item in self.Builder.Items do
		local value = if item.Over then 0 else progress
		local reveal = math.clamp((value - item.Start) / (item.Finish - item.Start), 0, 1)
		if reveal ~= item.LastR or visible ~= item.LastV then
			item.LastR, item.LastV = reveal, visible
			item.Set(reveal, visible)
		end
	end
end

function Preview.SetGraph(self: any, graph: any?)
	local signature = if graph then HttpService:JSONEncode(graph) else ""
	if self.Signature == signature then return end
	self.Signature = signature
	for _, child in self.Canvas:GetChildren() do
		if child:IsA("GuiObject") then child:Destroy() end
	end
	self.Builder = nil
	local compiled = graph and Compiler.Compile(graph)
	if not compiled then self.Frame.Visible = false; return end
	self.Frame.Visible = true
	self.Builder = Circles.BuildPreview(self.Canvas, Layout.Build(compiled))
	-- BuildPreview also uses Frames for layout. Keep the entire drawing above
	-- the card artwork, but below its selection button and cooldown text.
	for _, object in self.Canvas:GetDescendants() do
		if object:IsA("GuiObject") then object.ZIndex = 4 end
	end
	self:Step(workspace:GetServerTimeNow())
end

function Preview.Step(self: any, now: number): boolean
	if not self.Frame.Parent then return false end
	local remaining = math.max(self.Deadline - now, 0)
	local age = self.FireAt and now - self.FireAt or math.huge
	if age < RELEASE then
		local t = age / RELEASE
		self.Canvas.Rotation = t * t * 90
		self:SetProgress(1, 1 - t * t)
	else
		self.Canvas.Rotation = 0
		local span = math.max(self.Deadline - (self.RedrawAt or now), 0.001)
		self:SetProgress(if remaining > 0 then math.clamp(1 - remaining / span, 0, 1) else 1, 1)
	end
	self.Timer.Visible = remaining > 0
	if remaining > 0 then
		local text = string.format("%.1f", remaining)
		if self.Timer.Text ~= text then self.Timer.Text = text end
	end
	return remaining > 0
end

function Preview.Cooldown(self: any, deadline: number, fired: boolean)
	local now = workspace:GetServerTimeNow()
	self.Deadline = deadline
	self.FireAt = if fired then now else nil
	self.RedrawAt = now + (if fired then RELEASE else 0)
	self:Step(now)
	if deadline <= now then return end
	active[self] = true
	if connection then return end
	connection = RunService.RenderStepped:Connect(function()
		local time = workspace:GetServerTimeNow()
		for preview in active do if not preview:Step(time) then active[preview] = nil end end
		if next(active) == nil and connection then connection:Disconnect(); connection = nil end
	end)
end

function Preview.Destroy(self: any)
	active[self] = nil
	self.Resize:Disconnect()
	self.Frame:Destroy()
end

return Preview
