--!optimize 2
--[[
	ProjectileClient/Impact.luau
	Hit-effect visuals -- a short neon flash + spreading ring at the impact
	point, color-coded by what was struck. Games can swap this out entirely
	via Impact.SetHandler(fn(position, normal, model, kind)).
]]

local TweenService = game:GetService("TweenService")

local Impact = {}

-- Custom impact hook: fn(position, normal, model?, kind). When set, it replaces
-- the built-in effect below. (model is nil for impacts; kind is
-- "entity" | "world" | "bounce".)
local impactHandler: ((Vector3, Vector3, Instance?, string?) -> ())? = nil

function Impact.SetHandler(fn)
	impactHandler = fn
end

local IMPACT_COLORS = {
	entity = Color3.fromRGB(255, 80, 80), -- hit a damageable target
	world = Color3.fromRGB(255, 225, 150), -- hit geometry
	bounce = Color3.fromRGB(120, 220, 255), -- ricochet
}

local function defaultImpact(position: Vector3, normal: Vector3, kind: string?)
	local color = IMPACT_COLORS[kind or "world"] or IMPACT_COLORS.world
	local big = kind ~= "bounce"
	local info = TweenInfo.new(big and 0.28 or 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	-- expanding core flash
	local burst = Instance.new("Part")
	burst.Shape = Enum.PartType.Ball
	burst.Size = Vector3.one * (big and 0.6 or 0.3)
	burst.CFrame = CFrame.new(position)
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanQuery = false
	burst.CanTouch = false
	burst.CastShadow = false
	burst.Material = Enum.Material.Neon
	burst.Color = color
	burst.Transparency = 0.1
	burst.Parent = workspace
	TweenService:Create(burst, info, { Size = Vector3.one * (big and 3.5 or 1.5), Transparency = 1 }):Play()

	-- flat ring spreading along the surface (Cylinder's length runs along local X,
	-- so aim X down the normal and keep it thin there)
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.12, 0.5, 0.5)
	local n = normal.Magnitude > 1e-3 and normal.Unit or Vector3.yAxis
	ring.CFrame = CFrame.new(position, position + n) * CFrame.Angles(0, math.rad(90), 0)
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.2
	ring.Parent = workspace
	local ringSpan = big and 4 or 2
	TweenService:Create(ring, info, { Size = Vector3.new(0.12, ringSpan, ringSpan), Transparency = 1 }):Play()

	task.delay(info.Time, function()
		burst:Destroy()
		ring:Destroy()
	end)
end

function Impact.Play(position: Vector3, normal: Vector3?, kind: string?)
	local n = normal or Vector3.yAxis
	if impactHandler then
		task.spawn(impactHandler, position, n, nil, kind)
	else
		defaultImpact(position, n, kind)
	end
end

return Impact
