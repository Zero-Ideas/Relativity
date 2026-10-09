--!strict
--[[
	Portal (client, purely visual)
	A round hole hanging in mid-air that you can see into. It's a real part
	in the world -- an invisible thin panel at the portal's CFrame -- with a
	SurfaceGui on its front face (kept in PlayerGui and adorning the panel:
	ViewportFrames don't draw in a SurfaceGui parented under a part) holding a round ViewportFrame (UICorner): the
	"inside". What's inside lives in that ViewportFrame in WORLD
	coordinates behind the portal's plane (an illuminated concrete bay, plus
	whatever goes in portal.Inside -- e.g. a drone about to fly out).

	The window effect: every frame the ViewportFrame's camera is put where
	the real camera is, looking at the portal's centre (upright along the
	portal), with a field of view that just spans the opening. So the image
	painted on the opening is what the real camera would see through a hole
	there: things deeper inside move with parallax as you walk around it.
	Being a SurfaceGui on a part (not AlwaysOnTop), it's hidden by whatever
	stands in front of it like any other object.

	It's one-sided: from behind there's nothing. Opening / closing grows /
	shrinks the circle (with a little overshoot).

	  local portal = Portal.new(cframe, radius)  -- front = cframe.LookVector
	  portal.Inside        -- Model: put parts here (world coordinates)
	  portal:SetCFrame(cf) -- move it (e.g. following a character)
	  portal:Open(seconds) / portal:Close(seconds, destroyAfter?)
	  portal:Destroy()
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local FrameProfiler = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("FrameProfiler"))
local TweenService = game:GetService("TweenService")

local Portal = {}
Portal.__index = Portal

local VOID = Color3.fromRGB(65, 68, 72)
local CYAN = Color3.fromRGB(110, 230, 255)
local PIXELS_PER_STUD = 60
local MARGIN = 1.05 -- the panel is a little bigger than the opening (overshoot room)

export type Portal = typeof(setmetatable({} :: {
	CFrame: CFrame,
	Radius: number,
	Scale: number,
	Inside: Model,
	_panel: Part,
	_surface: SurfaceGui,
	_view: ViewportFrame,
	_camera: Camera,
	_room: Model,
	_users: number,
	_tween: Tween?,
	_value: NumberValue,
	_dead: boolean,
}, Portal))

local live: { Portal } = {}
local stepping: RBXScriptConnection? = nil

-- Points the portal's inside camera through its opening from the real camera.
local function fit(portal: Portal, camera: Camera)
	local frame = portal.CFrame
	local panel = portal._panel
	panel.CFrame = frame
	local radius = portal.Radius * portal.Scale
	local view = portal._view
	view.Size = UDim2.fromScale(portal.Scale / MARGIN, portal.Scale / MARGIN)
	view.Visible = radius > 0.02
	local eye = camera.CFrame.Position
	local toEye = eye - frame.Position
	-- (from behind there's nothing to see inside)
	local facing = toEye:Dot(frame.LookVector) > 0.05
	portal._room.Parent = if facing then view else nil
	portal.Inside.Parent = if facing then view else nil
	if not facing or radius <= 0.02 then
		return
	end
	local distance = toEye.Magnitude
	-- upright along the portal, so the image lines up with its surface
	portal._camera.CFrame = CFrame.lookAt(eye, frame.Position, frame.UpVector)
	portal._camera.FieldOfView = math.clamp(math.deg(2 * math.atan(radius / math.max(distance, 0.1))), 1, 120)
end

local function step(dt: number)
	local camera = workspace.CurrentCamera
	for index = #live, 1, -1 do
		local portal = live[index]
		if portal._dead then
			table.remove(live, index)
		elseif camera then
			fit(portal, camera)
		end
	end
	if #live == 0 and stepping then
		stepping:Disconnect()
		stepping = nil
	end
end

local function concreteBay(radius: number): Model
	local model = Instance.new("Model")
	model.Name = "ConcreteDroneBay"
	local half, depth = radius * 1.35, math.max(12, radius * 5)
	local concrete = Color3.fromRGB(125, 128, 132)
	local function panel(name: string, size: Vector3, position: Vector3, luminous: boolean?)
		local part = Instance.new("Part")
		part.Name, part.Size, part.Position = name, size, position
		part.Anchored = true
		part.CanCollide, part.CanQuery, part.CanTouch, part.CastShadow = false, false, false, false
		part.Material = if luminous then Enum.Material.Neon else Enum.Material.Concrete
		part.Color = if luminous then Color3.fromRGB(255, 244, 220) else concrete
		part.Parent = model
	end
	panel("Floor", Vector3.new(half * 2, 0.3, depth), Vector3.new(0, -half, depth / 2))
	panel("Ceiling", Vector3.new(half * 2, 0.3, depth), Vector3.new(0, half, depth / 2))
	panel("LeftWall", Vector3.new(0.3, half * 2, depth), Vector3.new(-half, 0, depth / 2))
	panel("RightWall", Vector3.new(0.3, half * 2, depth), Vector3.new(half, 0, depth / 2))
	panel("BackWall", Vector3.new(half * 2, half * 2, 0.3), Vector3.new(0, 0, depth))
	for _, z in {2.5, depth / 2, depth - 2} do
		panel("CeilingLight", Vector3.new(half * 1.45, 0.06, 0.35), Vector3.new(0, half - 0.18, z), true)
	end
	model.WorldPivot = CFrame.new()
	return model
end

function Portal.new(cframe: CFrame, radius: number): Portal
	-- the panel the opening is painted on (its Front face is -Z: LookVector)
	local side = radius * 2 * MARGIN
	local panel = Instance.new("Part")
	panel.Name = "Portal"
	panel.Anchored = true
	panel.CanCollide = false
	panel.CanQuery = false
	panel.CanTouch = false
	panel.CastShadow = false
	panel.Transparency = 1
	panel.Size = Vector3.new(side, side, 0.05)
	panel.CFrame = cframe

	local surface = Instance.new("SurfaceGui")
	surface.Name = "Opening"
	surface.Face = Enum.NormalId.Front
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.PixelsPerStud = PIXELS_PER_STUD
	surface.LightInfluence = 0
	surface.Brightness = 1.4
	surface.AlwaysOnTop = false
	surface.ClipsDescendants = true
	surface.ResetOnSpawn = false
	-- (a ViewportFrame only draws in a SurfaceGui that lives in PlayerGui,
	-- adorning its part -- one parented under the part shows nothing)
	surface.Adornee = panel
	surface.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- the opening: a round ViewportFrame
	local view = Instance.new("ViewportFrame")
	view.Name = "Inside"
	view.AnchorPoint = Vector2.new(0.5, 0.5)
	view.Position = UDim2.fromScale(0.5, 0.5)
	view.Size = UDim2.fromScale(0, 0)
	view.BackgroundColor3 = VOID
	view.BackgroundTransparency = 0
	view.BorderSizePixel = 0
	-- Viewports use their own ambient/directional light, not PointLights.
	view.Ambient = Color3.fromRGB(175, 175, 170)
	view.LightColor = Color3.fromRGB(255, 244, 220)
	view.LightDirection = Vector3.new(-0.3, -1, -0.4)
	view.Parent = surface
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = view
	local camera = Instance.new("Camera")
	camera.Parent = view
	view.CurrentCamera = camera

	local room = concreteBay(radius)
	room:PivotTo(cframe)
	room.Parent = view
	local inside = Instance.new("Model")
	inside.Name = "Contents"
	inside.Parent = view

	local light = Instance.new("PointLight")
	light.Color = CYAN
	light.Range = radius * 4
	light.Brightness = 1.5
	light.Parent = panel

	local value = Instance.new("NumberValue")
	value.Value = 0
	panel.Parent = workspace

	local portal = setmetatable({
		CFrame = cframe,
		Radius = radius,
		Scale = 0,
		Inside = inside,
		_panel = panel,
		_surface = surface,
		_view = view,
		_camera = camera,
		_room = room,
		_users = 0,
		_tween = nil,
		_value = value,
		_dead = false,
	}, Portal)
	value.Changed:Connect(function(scale)
		portal.Scale = scale
	end)
	table.insert(live, portal)
	if not stepping then
		stepping = FrameProfiler.Connect(RunService.RenderStepped, "Portal.RenderStepped", step)
	end
	return portal
end

function Portal.SetCFrame(self: Portal, cframe: CFrame)
	if self.CFrame ~= cframe then self._room:PivotTo(cframe) end
	self.CFrame = cframe
end

-- During a weapon swap the departing and arriving drones share one opening.
-- Neither may close/destroy it while the other is still passing through.
function Portal.Retain(self: Portal)
	assert(not self._dead, "Cannot retain a destroyed portal")
	self._users += 1
end

function Portal.Release(self: Portal, seconds: number?)
	if self._dead then return end
	self._users = math.max(0, self._users - 1)
	if self._users == 0 then self:Close(seconds, true) end
end

-- Grows the opening from nothing (a little overshoot, like it tears open).
function Portal.Open(self: Portal, seconds: number?)
	if self._tween then
		self._tween:Cancel()
	end
	local tween = TweenService:Create(self._value, TweenInfo.new(seconds or 0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Value = 1 })
	self._tween = tween
	tween:Play()
end

function Portal.Close(self: Portal, seconds: number?, destroyAfter: boolean?)
	if self._tween then
		self._tween:Cancel()
	end
	local tween = TweenService:Create(self._value, TweenInfo.new(seconds or 0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Value = 0 })
	self._tween = tween
	tween:Play()
	if destroyAfter then
		tween.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed then
				self:Destroy()
			end
		end)
	end
end

function Portal.Destroy(self: Portal)
	if self._dead then
		return
	end
	self._dead = true
	if self._tween then
		self._tween:Cancel()
	end
	self._panel:Destroy()
	-- fit can temporarily unparent these when viewed from behind.
	self._room:Destroy()
	self.Inside:Destroy()
	self._surface:Destroy()
	self._value:Destroy()
end

return Portal
