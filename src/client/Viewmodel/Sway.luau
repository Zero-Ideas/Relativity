--!optimize 2
--[[
	Viewmodel/Sway.luau
	Procedural (non-keyframed) motion layered on top of the attachment-solved
	base grip pose: mouse-look sway, walk-cycle bob, and idle breathing. Pure
	offset generator -- returns a CFrame meant to be composed onto the solved
	target hand CFrame (targetHandCFrame * offset), never touches the rig
	directly, so it has no idea ArmRig/Motor6Ds even exist.

	Deliberately driven by REAL (undilated) dt, not this game's dilated
	Heartbeat clock -- this is camera-relative rendering polish, not gameplay
	simulation, and should feel the same regardless of the world/personal
	time ratio (unlike e.g. walk speed, which this game deliberately DOES
	dilate -- see MovementController.luau).
]]

local UserInputService = game:GetService("UserInputService")

local Sway = {}
Sway.__index = Sway

-- Tuning -- studs/radians. Untested against the actual game feel; retune
-- once this is visible in Studio.
local MOUSE_SWAY_STRENGTH = 0.006 -- radians of tilt per pixel of mouse delta
local MOUSE_SWAY_SMOOTHING = 8 -- higher = snappier follow, lower = floatier lag
local BOB_WALK_FREQUENCY = 8 -- bob cycles per second at full walk speed
local BOB_WALK_AMPLITUDE = 0.03 -- studs
local BOB_FADE_IN_SPEED = 16 -- studs/s of movement to reach full bob amplitude
local BREATH_FREQUENCY = 0.35 -- cycles per second
local BREATH_AMPLITUDE = 0.015 -- studs

function Sway.new()
	return setmetatable({
		_smoothedSway = Vector2.zero, -- current smoothed mouse-sway tilt
		_bobPhase = 0,
	}, Sway)
end

export type Sway = typeof(Sway.new())

-- dt: real (undilated) seconds since last call. Returns a CFrame to compose
-- onto the base grip pose (basePose * sway:Update(...)).
function Sway:Update(dt: number, humanoid: Humanoid?): CFrame
	-- Mouse-look sway: tilt opposite the recent mouse delta, smoothed so it
	-- springs back to center instead of snapping frame-to-frame.
	local delta = UserInputService:GetMouseDelta()
	local targetSway = Vector2.new(-delta.Y, -delta.X) * MOUSE_SWAY_STRENGTH
	local alpha = math.clamp(MOUSE_SWAY_SMOOTHING * dt, 0, 1)
	self._smoothedSway = self._smoothedSway:Lerp(targetSway, alpha)

	-- Walk bob: advance a phase accumulator at a rate proportional to actual
	-- move speed (not just "are we moving"), and fade amplitude in/out with
	-- speed too so starting/stopping isn't a hard cut.
	local speed = 0
	if humanoid then
		speed = humanoid.MoveDirection.Magnitude * humanoid.WalkSpeed
	end
	self._bobPhase += dt * BOB_WALK_FREQUENCY
	local bobStrength = math.clamp(speed / BOB_FADE_IN_SPEED, 0, 1)
	local bobY = math.sin(self._bobPhase * math.pi * 2) * BOB_WALK_AMPLITUDE * bobStrength
	local bobX = math.cos(self._bobPhase * math.pi) * BOB_WALK_AMPLITUDE * 0.5 * bobStrength

	-- Idle breathing: always-on, tiny, so the viewmodel never looks
	-- perfectly frozen even standing still.
	local breath = math.sin(os.clock() * BREATH_FREQUENCY * math.pi * 2) * BREATH_AMPLITUDE

	return CFrame.Angles(self._smoothedSway.X, self._smoothedSway.Y, 0) * CFrame.new(bobX, bobY + breath, 0)
end

return Sway
