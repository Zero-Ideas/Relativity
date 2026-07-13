--!optimize 2
--[[
	Viewmodel/ArmRig.luau
	R6-specific single-segment arm stretch. Confirmed via live inspection
	that this project's player characters are R6 (Torso -[Shoulder
	Motor6D]-> "Right Arm"/"Left Arm" -- ONE block part, no elbow/wrist and
	no separate Hand part at all). Stretches that single Arm part
	("telescoping" -- there's no elbow to bend anyway) from its fixed
	shoulder pivot to reach an arbitrary target grip CFrame.

	HOW THE JOINT IS DRIVEN -- Motor6D.Transform, never C0/C1:
	A Motor6D places its child as
	    Part1.CFrame = Part0.CFrame * C0 * Transform * C1:Inverse()
	and the `Transform` term is REWRITTEN BY THE ANIMATION SYSTEM every
	frame, right before RunService.Stepped fires. An earlier version of
	this file wrote Shoulder.C0 per frame instead -- the running idle/walk
	AnimationTracks kept stacking their own Transform on top of our moved
	C0, so the two systems fought each other and the arms visibly spazzed
	out. (Measured live: with animations running, Torso*C0*C1:Inverse()
	differs from the real Arm CFrame by ~1 stud -- that difference IS the
	animation's Transform.) The fix: leave C0/C1 alone entirely and write
	`Transform` itself from a Stepped callback, which runs AFTER the
	animator's write each frame, so our value simply wins while posed --
	no fighting, and Restore just zeroes Transform and the animator
	seamlessly takes back over next frame.

	Because we solve the full formula for Transform (given the world-space
	Arm CFrame we want), C1 cancels out exactly -- so unlike the old C0
	approach, C1's perpendicular seating offset needs no special quadratic
	handling. The only geometry that matters:
	 - The shoulder pivot: socket = (Torso.CFrame * C0).Position, fixed.
	 - The grip point sits GRIP_INSET studs in from the arm's far tip
	   along the bone axis (the "half a stud inside the hand" rule -- R6
	   has no separate Hand part, so the inset applies to the Arm itself).
	 - The socket sits DistFromTop studs down from the arm's near tip
	   (measured from the rig's own C1 axial offset at Capture time), so
	   the stretched arm still visually "hangs from" the shoulder.
	So the stretched length is simply
	    L = |gripPos - socket| + DistFromTop + GRIP_INSET
	and the arm's center sits (L/2 - GRIP_INSET) back from the grip along
	the (socket -> grip) direction.

	BONE AXIS: the arm's long dimension is local Y (Size = (1, 2, 1),
	confirmed live) and hangs DOWN (local -Y) from the shoulder at rest,
	so the pose aims local -Y from the socket toward the grip.
]]

local GRIP_INSET = 0.5 -- studs inward from the arm's far tip -- see module doc comment
local RESIZE_AXIS = Vector3.yAxis -- the arm's long (bone) dimension, for Size

local ArmRig = {}

-- Builds a rotation-only CFrame whose LOCAL +Y axis points along world
-- direction `yDir`, using `upHint` to resolve roll around that axis (must
-- not be near-parallel to yDir -- callers should pick a fallback hint when
-- it is, see PoseArm).
local function cframeWithLocalYAlong(yDir: Vector3, upHint: Vector3): CFrame
	yDir = yDir.Unit
	local xDir = upHint:Cross(yDir)
	if xDir.Magnitude < 1e-4 then
		xDir = (math.abs(yDir.Y) < 0.9 and Vector3.yAxis or Vector3.xAxis):Cross(yDir)
	end
	xDir = xDir.Unit
	local zDir = xDir:Cross(yDir).Unit
	return CFrame.fromMatrix(Vector3.zero, xDir, yDir, zDir)
end

export type ArmSide = {
	Shoulder: Motor6D, -- Part0 = Torso, Part1 = Arm
	Torso: BasePart,
	Arm: BasePart,
}

export type ArmCache = {
	ShoulderC0: CFrame, -- read-only reference (never rewritten by this module)
	ShoulderC1: CFrame, -- read-only reference (never rewritten by this module)
	ArmSize: Vector3,
	ArmLength: number,
	-- Axial distance from the arm's near (shoulder-end) tip to the
	-- shoulder attachment point, measured from the rig's own C1 at
	-- Capture time (= 0.5 on a standard R6 rig). Kept fixed as the arm
	-- stretches, so the shoulder end stays visually seated in the torso.
	DistFromTop: number,
	Massless: boolean,
}

-- Finds the named parts/joint for one arm ("Right" or "Left") on a
-- character, or nil if any piece is missing (e.g. not an R6 rig).
function ArmRig.Find(character: Model, side: "Right" | "Left"): ArmSide?
	local torso = character:FindFirstChild("Torso") :: BasePart?
	local arm = character:FindFirstChild(side .. " Arm") :: BasePart?
	if not (torso and arm) then
		return nil
	end
	-- R6 parents the joint under Torso (the parent side), unlike R15's
	-- convention of parenting under the child limb -- check both so this
	-- doesn't silently break if that ever changes.
	local shoulder = (torso:FindFirstChild(side .. " Shoulder") or arm:FindFirstChild(side .. " Shoulder")) :: Motor6D?
	if not shoulder then
		return nil
	end
	return { Shoulder = shoulder, Torso = torso, Arm = arm }
end

-- Snapshots everything PoseArm is about to touch, so Restore can put it back
-- exactly. Call once per Equip, before the first PoseArm call.
function ArmRig.Capture(arm: ArmSide): ArmCache
	local armLength = math.max(arm.Arm.Size:Dot(RESIZE_AXIS), 1e-3)
	return {
		ShoulderC0 = arm.Shoulder.C0,
		ShoulderC1 = arm.Shoulder.C1,
		ArmSize = arm.Arm.Size,
		ArmLength = armLength,
		DistFromTop = armLength / 2 - arm.Shoulder.C1.Position.Y,
		Massless = arm.Arm.Massless,
	}
end

-- Undoes Capture -- call once when unposing (leaving first person) or on
-- Unequip. Zeroing Transform hands the joint straight back to the
-- animation system, which rewrites it next frame anyway. Safe to call on a
-- since-destroyed character's parts (property writes on a destroyed
-- Instance just no-op), so callers don't need a validity check.
function ArmRig.Restore(arm: ArmSide, cache: ArmCache)
	arm.Arm.Size = cache.ArmSize
	arm.Arm.Massless = cache.Massless
	arm.Shoulder.Transform = CFrame.identity
end

-- The actual "telescoping" stretch + aim. Call every frame from a
-- RunService.Stepped callback (NOT RenderStepped -- the write must land
-- after the animation system's per-frame Transform write, see the module
-- doc comment) while posed. Positions/orients the Arm part so the INSET
-- grip point ends up exactly at targetGripCFrame's position, stretching
-- from the fixed shoulder pivot.
--
-- Returns the world-space Arm CFrame it solved for -- callers that need to
-- place other things relative to the arm this same frame (the tool weld,
-- see Viewmodel/init.luau) must use this predicted value, NOT read
-- arm.Arm.CFrame back (which is one frame stale -- the engine applies the
-- Transform we just wrote after Stepped returns).
function ArmRig.PoseArm(arm: ArmSide, cache: ArmCache, targetGripCFrame: CFrame): CFrame
	-- 1. The fixed shoulder pivot, from the ORIGINAL (never-touched) C0.
	local socket = (arm.Torso.CFrame * cache.ShoulderC0).Position
	local gripPos = targetGripCFrame.Position
	local toGrip = gripPos - socket
	local dist = toGrip.Magnitude
	if dist < 1e-3 then
		return arm.Arm.CFrame -- grip on top of the shoulder; nothing sane to aim
	end
	local boneDir = toGrip / dist -- world direction the arm's local -Y should point

	-- 2. Stretch: socket-to-grip distance plus the fixed seatings at both
	-- ends (see module doc comment for the derivation).
	local newLength = math.max(dist + cache.DistFromTop + GRIP_INSET, 1e-3)
	local keep = Vector3.one - RESIZE_AXIS
	local newSize = cache.ArmSize * keep + RESIZE_AXIS * newLength
	if (arm.Arm.Size - newSize).Magnitude > 1e-3 then
		-- Only write when it actually changed -- Size writes are much more
		-- expensive than CFrame-ish writes (they rebuild physics geometry).
		arm.Arm.Size = newSize
	end
	-- Keep the stretched arm from changing the character's physics mass.
	arm.Arm.Massless = true

	-- 3. Aim: point the bone axis from the shoulder at the grip. Position
	-- wins over the target's own rotation (a floating gun reads as far more
	-- broken than a slightly-off wrist roll); the target's UpVector only
	-- resolves roll about the bone axis.
	local upHint = targetGripCFrame.UpVector
	if math.abs(upHint:Dot(boneDir)) > 0.99 then
		upHint = Vector3.yAxis
	end
	-- Bone axis is local -Y, so local +Y must point the opposite way.
	local armCFrame = CFrame.new(gripPos - boneDir * (newLength / 2 - GRIP_INSET))
		* cframeWithLocalYAlong(-boneDir, upHint)

	-- 4. Solve the Motor6D placement formula
	-- (Arm = Torso * C0 * Transform * C1:Inverse()) for Transform. C1
	-- cancels exactly, so no perpendicular-offset special-casing needed.
	arm.Shoulder.Transform = cache.ShoulderC0:Inverse() * arm.Torso.CFrame:Inverse() * armCFrame * cache.ShoulderC1

	return armCFrame
end

return ArmRig
