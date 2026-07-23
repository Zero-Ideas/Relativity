--!optimize 2
--[[
	Viewmodel/ArmRig.luau
	R6-specific single-segment arm stretch. Confirmed via live inspection
	that this project's player characters are R6 (Torso -[Shoulder
	Motor6D]-> "Right Arm"/"Left Arm" -- ONE block part, no elbow/wrist and
	no separate Hand part at all). Stretches that single Arm part
	("telescoping" -- there's no elbow to bend anyway) from a fixed
	body-relative pivot to reach an arbitrary target grip CFrame.

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
	 - The virtual shoulder anchor the two-bone elbow solve hangs from:
	   normally a caller-supplied CAMERA-hung point (PoseArm's anchorPos --
	   see Viewmodel.RightShoulderOffset), falling back to the rig's real
	   shoulder socket (Torso.CFrame * C0).Position -- see FOREARM below.
	 - The grip point sits GRIP_INSET studs in from the arm's far tip
	   along the bone axis (the "half a stud inside the hand" rule -- R6
	   has no separate Hand part, so the inset applies to the Arm itself).
	 - The socket sits DistFromTop studs down from the arm's near tip
	   (measured from the rig's own C1 axial offset at Capture time), so
	   the stretched arm still visually "hangs from" the shoulder.
	So the base stretched length is simply
	    L = |gripPos - elbowPos| + DistFromTop + GRIP_INSET
	(then possibly extended further to hide the near tip off-screen -- see
	PoseArm's hideNearTipFrom) and the arm's center sits (L/2 - GRIP_INSET)
	back from the grip along the bone direction. Any length works: the grip
	end always lands exactly on target, extra length only pushes the unseen
	near end further back.

	THE ARM IS TREATED AS A FOREARM, WITH A TWO-BONE IK ELBOW: a whole
	2-stud arm pivoting rigidly at a fixed point reads as a stiff,
	straight-armed point -- and glitches badly looking down, when the grip
	drops far below the fixed pivot and the brick swings near-vertical. So
	PoseArm runs the standard two-segment viewmodel solve instead: a
	virtual BICEP (VIRTUAL_BICEP_LENGTH, never rendered) from the virtual
	shoulder anchor to an elbow, a virtual FOREARM (VIRTUAL_FOREARM_LENGTH)
	from that elbow to the grip, elbow position solved by law of cosines and
	bent toward a caller-supplied pole vector -- and then renders ONLY the
	forearm segment with the single R6 brick. The bicep's whole job is
	deciding where the elbow is, so the forearm's angle changes naturally
	as the grip moves (looking down bends the elbow instead of producing a
	vertical full-arm point). When the grip is out of reach the forearm
	segment stretches to cover the difference, keeping the solve valid at
	any distance. The driven joint is still the Shoulder Motor6D (R6 has
	no elbow joint) -- the "elbow" exists only in the math. On top of the
	IK, PoseArm's elbowOffset parameter (dynamic, per-frame) shifts the
	virtual shoulder anchor (position) and/or swings the posed forearm
	around the planted hand (rotation).

	BONE AXIS: the arm's long dimension is local Y (Size = (1, 2, 1),
	confirmed live) and hangs DOWN (local -Y) from the shoulder at rest,
	so the pose aims local -Y from the socket toward the grip.
]]

local GRIP_INSET = 0.5 -- studs inward from the arm's far tip -- see module doc comment
local RESIZE_AXIS = Vector3.yAxis -- the arm's long (bone) dimension, for Size

-- Cross-section thickness (studs) the posed arm is forced to in first
-- person, overriding the rig's native (1, _, 1) girth -- purely cosmetic,
-- doesn't affect the IK/length solve above. Applied on both non-bone axes
-- (X and Z) in the resize step below.
local ARM_THICKNESS = 0.75

-- Two-bone IK segment lengths (studs): the virtual bicep (shoulder ->
-- elbow, never rendered) and the virtual forearm (elbow -> grip; the
-- rendered brick's nominal reach -- it stretches beyond this when the grip
-- is farther than both segments combined). Their sum is the arm's
-- comfortable reach. TUNE ME by feel: longer bicep = the elbow swings
-- wider as you look around; longer forearm = straighter-looking hold.
local VIRTUAL_BICEP_LENGTH = 1.25
local VIRTUAL_FOREARM_LENGTH = 1.75

-- Default arm offset (see PoseArm's elbowOffset parameter). Identity: the
-- two-bone solve already produces the natural dropped-elbow forearm look
-- on its own, so this is purely an artistic override -- reassign
-- Viewmodel.RightElbowOffset / .LeftElbowOffset (read every frame) to
-- shift the virtual shoulder anchor (position) or swing the posed forearm
-- around the planted hand (rotation).
local DEFAULT_ELBOW_OFFSET = CFrame.identity

-- How far behind the hide camera's view plane the arm's near tip must sit
-- (see PoseArm's hideNearTipFrom) -- generous enough that the 1-stud-wide
-- tip face can't clip through the near plane at the screen edges.
local HIDE_NEAR_TIP_MARGIN = 0.5

-- Never stretch past this, even to hide the near tip -- an arm nearly
-- perpendicular to the view direction would otherwise ask for an absurd
-- (toward-infinite) length.
local MAX_ARM_LENGTH = 20

-- Solved lengths are rounded UP to this step. The grip end lands exactly on
-- target for ANY length (only the hidden near tip moves), so quantizing
-- costs nothing visually -- and it stops the per-frame sway/bob length
-- wobble from forcing a Size write (a physics-geometry rebuild) every
-- single frame.
local LENGTH_QUANTUM = 0.1

local ArmRig = {}

ArmRig.DEFAULT_ELBOW_OFFSET = DEFAULT_ELBOW_OFFSET

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
-- from the fixed elbow pivot (forearm treatment -- see module doc comment).
--
-- Returns the world-space Arm CFrame it solved for -- callers that need to
-- place other things relative to the arm this same frame (the tool weld,
-- see Viewmodel/init.luau) must use this predicted value, NOT read
-- arm.Arm.CFrame back (which is one frame stale -- the engine applies the
-- Transform we just wrote after Stepped returns).
-- elbowOffset (optional, defaults to DEFAULT_ELBOW_OFFSET): fully dynamic --
-- pass a different value any frame. Its POSITION shifts the virtual SHOULDER
-- anchor the two-bone solve hangs from; its ROTATION is applied about the
-- GRIP POINT, so the hand stays planted on the weapon while the elbow end
-- swings -- an artistic override on top of the IK.
--
-- poleDir (optional, world-space): the IK pole vector -- which way the
-- virtual elbow bends when the arm isn't straight. Defaults to torso-down;
-- callers should pass a down-and-outward hint per arm (see
-- Viewmodel.RightElbowPole / .LeftElbowPole).
--
-- hideNearTipFrom (optional, pass the camera's CFrame): when given, the arm
-- is stretched extra far back so its near (cut) tip always sits behind that
-- view plane -- off-screen no matter how the pivot/angles work out.
--
-- anchorPos (optional, world-space): where the virtual shoulder hangs. The
-- viewmodel passes a CAMERA-hung point at forearm height (see
-- Viewmodel.RightShoulderOffset) so the rendered forearm visibly rises from
-- LOW on the screen and follows the camera's pitch -- anchoring at the rig's
-- real shoulder socket made the arms appear to originate up at shoulder/body
-- height instead of at the solved elbow. When nil, falls back to that real
-- socket. NOTE: when anchorPos is given, the caller is expected to have
-- already baked elbowOffset.Position into it (camera-locally -- see
-- Viewmodel/init.luau); only the fallback path applies it here (torso-local).
function ArmRig.PoseArm(
	arm: ArmSide,
	cache: ArmCache,
	targetGripCFrame: CFrame,
	elbowOffset: CFrame?,
	poleDir: Vector3?,
	hideNearTipFrom: CFrame?,
	anchorPos: Vector3?
): CFrame
	local offset = elbowOffset or DEFAULT_ELBOW_OFFSET

	-- 1. The virtual shoulder anchor: the caller's camera-hung point, or the
	-- rig's real shoulder socket (from the ORIGINAL, never-touched C0) plus
	-- the caller's torso-local shift.
	local shoulderPos = if anchorPos
		then anchorPos
		else (arm.Torso.CFrame * cache.ShoulderC0).Position
			+ arm.Torso.CFrame:VectorToWorldSpace(offset.Position)
	local gripPos = targetGripCFrame.Position
	local toGrip = gripPos - shoulderPos
	local dist = toGrip.Magnitude
	if dist < 1e-3 then
		return arm.Arm.CFrame -- grip on top of the shoulder; nothing sane to solve
	end
	local reachDir = toGrip / dist

	-- 2. Two-bone IK for the virtual elbow (law of cosines, the standard
	-- two-segment viewmodel solve -- see module doc comment): the elbow
	-- sits `a` along the shoulder->grip axis and `h` off it, bent toward
	-- the pole. When the grip is out of reach the virtual forearm STRETCHES
	-- (to dist - bicep), which collapses h to 0 -- a straight arm -- rather
	-- than the solve failing.
	local bicep = VIRTUAL_BICEP_LENGTH
	local forearm = math.max(VIRTUAL_FOREARM_LENGTH, dist - bicep)
	local a = math.clamp((bicep * bicep - forearm * forearm + dist * dist) / (2 * dist), -bicep, bicep)
	local h = math.sqrt(math.max(bicep * bicep - a * a, 0))
	local elbowPos = shoulderPos + reachDir * a
	if h > 1e-4 then
		local pole = poleDir or -arm.Torso.CFrame.UpVector
		local bend = pole - reachDir * pole:Dot(reachDir) -- pole, perpendicular to the reach axis
		if bend.Magnitude > 1e-3 then
			elbowPos += bend.Unit * h
		end
	end

	-- 3. The rendered brick is the FOREARM only, elbow -> grip (the bicep
	-- is never drawn; its whole job was deciding where the elbow is).
	local toGripFromElbow = gripPos - elbowPos
	local forearmDist = toGripFromElbow.Magnitude
	if forearmDist < 1e-3 then
		return arm.Arm.CFrame -- grip on top of the elbow; degenerate
	end
	local aimDir = toGripFromElbow / forearmDist

	-- 4. Aim: point the bone axis from the elbow at the grip (position wins
	-- over the target's own rotation -- a floating gun reads as far more
	-- broken than a slightly-off wrist roll; the target's UpVector only
	-- resolves roll). Then apply the elbow offset's rotation ON TOP, about
	-- the grip point.
	local upHint = targetGripCFrame.UpVector
	if math.abs(upHint:Dot(aimDir)) > 0.99 then
		upHint = Vector3.yAxis
	end
	-- Bone axis is local -Y, so local +Y must point opposite the aim.
	local rotation = cframeWithLocalYAlong(-aimDir, upHint) * offset.Rotation
	local boneDir = -rotation.YVector -- where local -Y ACTUALLY points after the offset

	-- 5. Length: elbow-to-grip distance plus the fixed seatings at both
	-- ends (see module doc comment), then extended as needed to bury the
	-- near tip behind the hide view plane, capped, and rounded up to
	-- LENGTH_QUANTUM (the grip end is exact for any length -- only the
	-- hidden near end moves).
	local newLength = forearmDist + cache.DistFromTop + GRIP_INSET
	if hideNearTipFrom then
		local look = hideNearTipFrom.LookVector
		local along = boneDir:Dot(look)
		if along > 1e-2 then
			-- Near tip sits (L - GRIP_INSET) back from the grip along
			-- -boneDir; solve its depth along `look` <= -MARGIN for L.
			local gripDepth = (gripPos - hideNearTipFrom.Position):Dot(look)
			local hideLength = GRIP_INSET + (gripDepth + HIDE_NEAR_TIP_MARGIN) / along
			newLength = math.max(newLength, hideLength)
		end
	end
	newLength = math.clamp(newLength, 1e-3, MAX_ARM_LENGTH)
	newLength = math.ceil(newLength / LENGTH_QUANTUM) * LENGTH_QUANTUM

	-- 6. Resize -- only when it actually changed (Size writes are much more
	-- expensive than CFrame-ish writes: they rebuild physics geometry;
	-- that's what LENGTH_QUANTUM is for) -- and keep the stretched arm from
	-- changing the character's physics mass.
	local keep = Vector3.one - RESIZE_AXIS
	local newSize = Vector3.new(ARM_THICKNESS, 0, ARM_THICKNESS) * keep + RESIZE_AXIS * newLength
	if (arm.Arm.Size - newSize).Magnitude > 1e-3 then
		arm.Arm.Size = newSize
	end
	arm.Arm.Massless = true

	-- 7. Place: grip point exactly on target, the rest of the arm running
	-- back along the final (offset-rotated) bone direction.
	local armCFrame = CFrame.new(gripPos - boneDir * (newLength / 2 - GRIP_INSET)) * rotation

	-- 8. Solve the Motor6D placement formula
	-- (Arm = Torso * C0 * Transform * C1:Inverse()) for Transform. C1
	-- cancels exactly, so no perpendicular-offset special-casing needed.
	arm.Shoulder.Transform = cache.ShoulderC0:Inverse() * arm.Torso.CFrame:Inverse() * armCFrame * cache.ShoulderC1

	return armCFrame
end

return ArmRig
