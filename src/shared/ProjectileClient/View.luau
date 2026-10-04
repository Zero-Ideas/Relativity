--!strict
--!optimize 2
--[[
	ProjectileClient/View.luau
	Calculation-visibility snapshot, refreshed once per frame. This gates Lua
	work only; Roblox retains ownership of draw culling. View.contains is then
	pure Luau dot products instead of one WorldToViewportPoint engine call per
	visual, which dominated the render loop at 10k visuals.
]]

local View = {}

local VIEWPORT_CULL_MARGIN = 128 -- pixels beyond each edge; avoids boundary flicker

local valid = false
local viewPosition = Vector3.zero
local viewRight, viewUp, viewLook = Vector3.xAxis, Vector3.yAxis, -Vector3.zAxis
local limitX, limitY = 1, 1 -- tan(half-FOV) per axis, widened by the pixel margin

function View.refresh()
	local camera = workspace.CurrentCamera
	local size = camera and camera.ViewportSize
	if not camera or not size or size.X <= 0 or size.Y <= 0 then
		valid = false
		return
	end
	local cframe = camera.CFrame
	local tanY = math.tan(math.rad(camera.FieldOfView) * 0.5)
	local tanX = tanY * size.X / size.Y
	-- A pixel margin m past an edge is 2m/size in normalized device units.
	limitX = tanX * (1 + 2 * VIEWPORT_CULL_MARGIN / size.X)
	limitY = tanY * (1 + 2 * VIEWPORT_CULL_MARGIN / size.Y)
	viewPosition = cframe.Position
	viewRight, viewUp, viewLook = cframe.RightVector, cframe.UpVector, cframe.LookVector
	valid = true
end

-- Whether `position` is on screen (with margin). Everything counts as
-- visible while no camera snapshot is available.
function View.contains(position: Vector3): boolean
	if not valid then
		return true
	end
	local offset = position - viewPosition
	local depth = offset:Dot(viewLook)
	return depth > 0 and math.abs(offset:Dot(viewRight)) <= depth * limitX and math.abs(offset:Dot(viewUp)) <= depth * limitY
end

return View
