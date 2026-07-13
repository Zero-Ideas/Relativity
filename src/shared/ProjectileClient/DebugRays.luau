--!optimize 2
--[[
	ProjectileClient/DebugRays.luau
	Draws one raycast segment as a thin fading line, colored by resolution --
	receives ProjRay events streamed while the server's Projectile.SetDebugRays
	is on (see example/init.server.luau's "SetProjectileDebug" handler).
]]

local TweenService = game:GetService("TweenService")

local DebugRays = {}

-- Red = coarse cast through an empty chunk; green = fine cast near entities.
local RAY_LOWRES_COLOR = Color3.fromRGB(255, 70, 70)
local RAY_HIGHRES_COLOR = Color3.fromRGB(90, 255, 140)

function DebugRays.Draw(from: Vector3, to: Vector3, lowRes: boolean?)
	local delta = to - from
	local dist = delta.Magnitude
	if dist < 1e-3 then
		return
	end
	local line = Instance.new("Part")
	line.Anchored = true
	line.CanCollide = false
	line.CanQuery = false
	line.CanTouch = false
	line.CastShadow = false
	line.Material = Enum.Material.Neon
	line.Color = lowRes and RAY_LOWRES_COLOR or RAY_HIGHRES_COLOR
	line.Size = Vector3.new(0.08, 0.08, dist)
	line.CFrame = CFrame.lookAt((from + to) * 0.5, to)
	line.Transparency = 0.15
	line.Parent = workspace
	TweenService:Create(line, TweenInfo.new(0.3, Enum.EasingStyle.Linear), { Transparency = 1 }):Play()
	task.delay(0.3, function()
		line:Destroy()
	end)
end

return DebugRays
