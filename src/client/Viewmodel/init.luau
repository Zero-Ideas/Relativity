--!optimize 2
--[[
	Viewmodel (client, purely cosmetic)
	FIRST-PERSON-ONLY procedural viewmodel: while a weapon Tool is equipped
	AND the camera is in first person, the weapon is placed relative to the
	CAMERA every frame (with procedural sway/bob/breathing -- see
	Sway.luau), and the local player's own arms telescope out to hold it at
	its named grip Attachments (see ArmRig.luau). No keyframed
	AnimationTracks anywhere in this system -- everything is computed live,
	every frame. Outside first person nothing is touched at all: the
	character holds the tool with Roblox's stock grip/animations, and
	leaving first person restores everything.

	WHY THE CAMERA DRIVES THE WEAPON (and not the other way around): the
	Tool is welded to the Right Arm by Roblox's auto-created "RightGrip"
	Weld, so an earlier version that aimed the arms at the tool's live
	attachment positions was chasing its own output -- posing the arm moved
	the tool, which moved the target, which re-posed the arm, diverging
	into visible spazzing. Here the kinematic chain is solved from a single
	root, once per frame, with no read-back:
	    camera -> grip frame (sway * WEAPON_CAMERA_OFFSET, an upright
	              camera-aligned "virtual hand")
	           -> desired Handle CFrame (grip frame * Tool.Grip:Inverse() --
	              see WEAPON ORIENTATION below)
	           -> desired grip points (attachment offsets captured at equip)
	           -> arm poses (ArmRig.PoseArm, returns the PREDICTED arm CFrame)
	           -> RightGrip weld C0 solved so the Handle lands exactly on
	              the desired CFrame.
	This is also what animates the weapon itself: sway/bob/breathing move
	the gun, and the arms follow it.

	This directly poses the REAL arm parts, not a separate fake viewmodel
	clone rig: Roblox never replicates a client's own cosmetic property
	writes (CFrame/Size/Motor6D.Transform/Weld.C0) back to the server or to
	other clients, so this is visible ONLY to the local player. Other
	players keep seeing this character's normal third-person body. This
	intentionally supersedes an old Studio-only "EasyFirstPerson" script
	(never in source control) that took the fake-clone-rig approach --
	remove that script from StarterCharacterScripts in Studio so the two
	don't fight over the arms in first person.

	WEAPON ORIENTATION -- Tool.Grip is respected, not overwritten: Roblox's
	own hold places the Handle as gripFrame * Grip:Inverse(), where the grip
	frame is an upright frame aligned with the character's look direction
	(that's exactly what Grip means -- how the handle sits in the hand --
	and it's what Studio grip-editor plugins edit). The camera frame uses
	the same convention (-Z forward, +Y up), so composing our camera-derived
	grip frame with the SAME Grip:Inverse() reproduces the designer's
	intended weapon orientation in first person. Grip is read live every
	frame, so tweaking it (via the Grip properties or a grip editor plugin)
	updates the viewmodel immediately, even mid-Play. For a viewmodel-ONLY
	adjustment on top (rotate/nudge the weapon in the hand without touching
	the third-person Grip), set a CFrame attribute named
	"ViewmodelGripOffset" on the Tool -- it's applied in grip-frame space,
	so e.g. CFrame.Angles(0, math.rad(10), 0) yaws the weapon in the hand.

	Weapon setup contract: the Tool must have a "Handle" BasePart, and marks
	where each hand grips with named Attachment instances (searched for
	recursively under the Tool):
	 - RightGripAttachment -- required for ANY weapon, one- or two-handed;
	   the right hand is always the primary grip.
	 - LeftGripAttachment -- optional; only two-handed weapons need it. Its
	   absence just means the left arm is left alone (one-handed weapon).
	 - Sight + SightEnd -- optional pair; enables aim-down-sights. While
	   aiming (right mouse button held, or Viewmodel.SetAiming(true) from
	   code), the weapon blends from the hip hold to a pose where Sight
	   sits DEAD-CENTER on screen, ADS_SIGHT_DISTANCE studs in front of
	   the camera, with the Sight -> SightEnd line aligned to the look
	   direction. Only the POSITIONS of the two attachments matter (put
	   Sight at the rear of the sight picture, SightEnd farther forward
	   along the exact line the player should look down) -- their
	   ORIENTATIONS are deliberately ignored, so a mis-rotated attachment
	   can't skew the aimed grip; aimed roll comes from the weapon's own
	   Grip up. A weapon with a Sight but no SightEnd falls back to aiming
	   along the Sight's own LookVector (orientation and all -- the old
	   contract). Weapons with neither attachment simply never ADS.
	Attachment offsets are captured relative to the Handle ONCE at equip --
	per-frame code deliberately never reads att.WorldCFrame (that's the
	feedback loop described above).

	API:
	 Viewmodel.Equip(tool: Tool, character: Model)   -- call from a
	   ToolControllers/<Name>.luau's Equip(tool, character). No-op if the
	   tool has no Handle or no RightGripAttachment.
	 Viewmodel.Unequip(tool: Tool, character: Model) -- call from Unequip;
	   restores the rig/weld exactly as Equip found them. Safe to call even
	   if the character/parts were since destroyed, or if Equip never
	   actually activated for this tool -- both are silent no-ops.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ArmRig = require(script.ArmRig)
local Sway = require(script.Sway)

type ArmSide = ArmRig.ArmSide
type ArmCache = ArmRig.ArmCache

local Viewmodel = {}

Viewmodel.RIGHT_GRIP_NAME = "RightGripAttachment"
Viewmodel.LEFT_GRIP_NAME = "LeftGripAttachment"
Viewmodel.SIGHT_NAME = "Sight"
Viewmodel.SIGHT_END_NAME = "SightEnd"

-- Camera-local virtual SHOULDER anchor positions, one per arm, read EVERY
-- frame: where each arm's two-bone elbow solve hangs from, relative to the
-- (swayed) camera -- +X right, -Y down, +Z behind the view plane. Placed at
-- forearm/elbow height BELOW the eye line so the rendered forearm visibly
-- rises from low on the screen (and follows the camera's pitch); anchoring
-- at the character's real shoulder socket made the arms appear to originate
-- up at shoulder height instead of at the IK-solved elbow. See
-- ArmRig.PoseArm's anchorPos.
Viewmodel.RightShoulderOffset = Vector3.new(0.9, -1.5, 0.2)
Viewmodel.LeftShoulderOffset = Vector3.new(-0.9, -1.5, 0.2)

-- Dynamic arm offsets, one per arm, read EVERY frame -- reassign these at
-- runtime (from anywhere) to repose the arms live, e.g. for lowered or
-- sprint poses. Each is a CFrame: the POSITION shifts the virtual shoulder
-- anchor (camera-local, on top of the ShoulderOffset above), the ROTATION
-- swings the whole posed forearm around the grip point -- the hand stays
-- planted on the weapon. See ArmRig.PoseArm.
Viewmodel.RightElbowOffset = ArmRig.DEFAULT_ELBOW_OFFSET :: CFrame
Viewmodel.LeftElbowOffset = ArmRig.DEFAULT_ELBOW_OFFSET :: CFrame

-- Camera-local IK pole vectors, one per arm, read EVERY frame: which way
-- each virtual elbow bends when the arm isn't straight -- down and OUTWARD
-- (right elbow to the right, left to the left), like real elbows on a
-- shouldered weapon. See ArmRig.PoseArm's poleDir.
Viewmodel.RightElbowPole = Vector3.new(1, -0.8, 0.4)
Viewmodel.LeftElbowPole = Vector3.new(-1, -0.8, 0.4)

-- Where the GRIP FRAME (the "virtual hand" the weapon is held by -- the
-- Handle itself then sits at grip * Tool.Grip:Inverse(), see the module doc
-- comment) sits relative to the (swayed) camera: right of center, below eye
-- line, pushed forward -- the classic FPS hold. TUNE ME by feel in Studio;
-- this is the global knob for the hold pose across ALL weapons -- per-weapon
-- adjustments belong in Tool.Grip or the ViewmodelGripOffset attribute.
local WEAPON_CAMERA_OFFSET = CFrame.new(1.1, -1.1, -2.2)

-- Optional per-Tool CFrame attribute: extra viewmodel-only offset composed
-- into the grip frame (does not affect third-person holding at all).
local GRIP_OFFSET_ATTRIBUTE = "ViewmodelGripOffset"

-- ADS ("aim down sights") tuning -- see the Sight bullet in the module doc
-- comment for the full behavior/contract.
local ADS_SIGHT_DISTANCE = 1.2 -- studs from the camera to the Sight while fully aimed
local ADS_BLEND_SPEED = 12 -- 1/s; how snappily the hip <-> ADS blend moves
local ADS_SWAY_FACTOR = 0.75 -- fraction of sway/bob suppressed at full ADS (steadier aim)

-- Camera-to-focus distance at/below which we treat the camera as first
-- person. Roblox's own first-person camera pins the camera essentially onto
-- the focus (distance ~0); ordinary third-person zoom is well above 1.
local FIRST_PERSON_MAX_DISTANCE = 1

type PosedHand = {
	AttRel: CFrame, -- grip attachment's offset from the Handle, captured at equip
	Arm: ArmSide,
	Cache: ArmCache,
	TransparencyConnection: RBXScriptConnection,
}

type ActiveEntry = {
	Connection: RBXScriptConnection,
	Right: PosedHand,
	Left: PosedHand?,
	Sway: Sway.Sway,
	Handle: BasePart,
	Posed: boolean,
	SightRel: CFrame?, -- handle-local ADS sight frame, built at equip (nil = weapon can't ADS)
	AdsAlpha: number, -- smooth hip (0) <-> fully-aimed (1) blend, chases `aiming` every frame
	-- Original C0 per RightGrip Weld INSTANCE -- Roblox destroys/recreates
	-- the weld across equips, so keying by instance means we can never
	-- "restore" a stale C0 onto a fresh weld we never modified.
	OriginalWeldC0: { [Weld]: CFrame },
}

-- Keyed by Tool instance rather than a single slot -- Roblox only ever lets
-- one Tool be equipped at a time in practice, but keying this way means a
-- rapid unequip-then-equip-a-different-tool before the first Tool's
-- Unequipped fully lands can never cross-restore the wrong cache onto the
-- wrong tool.
local active: { [Tool]: ActiveEntry } = {}

-- Recursion guard for the LocalTransparencyModifier forcing below.
local forcingTransparency = false

-- Whether the player is currently TRYING to aim (the smooth per-tool blend
-- factor lives on each entry as AdsAlpha). Driven by the right mouse button
-- below; other input schemes (touch buttons, gamepad triggers) can call
-- Viewmodel.SetAiming instead.
local aiming = false

function Viewmodel.SetAiming(isAiming: boolean)
	aiming = isAiming
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		aiming = true
	end
end)

UserInputService.InputEnded:Connect(function(input)
	-- Deliberately no gameProcessed check: releasing the button must ALWAYS
	-- unaim, even if the release landed over UI.
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		aiming = false
	end
end)

local function findGripAttachment(tool: Tool, name: string): Attachment?
	local found = tool:FindFirstChild(name, true)
	if found and found:IsA("Attachment") then
		return found
	end
	return nil
end

-- In first person the engine sets LocalTransparencyModifier = 1 on limbs
-- every frame to hide them; the whole point of a viewmodel is visible arms,
-- so while posed we pin it back to 0 the instant the engine touches it.
local function watchTransparency(entry: ActiveEntry, part: BasePart): RBXScriptConnection
	return part:GetPropertyChangedSignal("LocalTransparencyModifier"):Connect(function()
		if forcingTransparency or not entry.Posed then
			return
		end
		forcingTransparency = true
		part.LocalTransparencyModifier = 0
		forcingTransparency = false
	end)
end

local function findGripWeld(entry: ActiveEntry): Weld?
	-- Roblox parents the auto-created tool weld under the Right Arm, named
	-- "RightGrip". Re-found every frame rather than cached: the engine
	-- destroys and recreates it across (un)equips.
	local weld = entry.Right.Arm.Arm:FindFirstChild("RightGrip")
	if weld and weld:IsA("Weld") then
		return weld
	end
	return nil
end

-- Puts everything back to stock (arms, joint, tool weld). Idempotent; called
-- both when leaving first person (tool stays equipped, Roblox's normal
-- third-person hold takes over) and from Unequip.
local function unpose(entry: ActiveEntry)
	if not entry.Posed then
		return
	end
	entry.Posed = false
	ArmRig.Restore(entry.Right.Arm, entry.Right.Cache)
	if entry.Left then
		ArmRig.Restore(entry.Left.Arm, entry.Left.Cache)
	end
	local weld = findGripWeld(entry)
	if weld then
		local originalC0 = entry.OriginalWeldC0[weld]
		if originalC0 then
			weld.C0 = originalC0
		end
	end
	-- LocalTransparencyModifier is left alone: the engine rewrites it every
	-- frame from camera distance, so it self-corrects the moment we stop
	-- pinning it (the watch connections gate on entry.Posed).
end

function Viewmodel.Equip(tool: Tool, character: Model)
	if active[tool] then
		return -- already active (defensive; ToolManager shouldn't double-fire)
	end

	local handle = tool:FindFirstChild("Handle")
	if not (handle and handle:IsA("BasePart")) then
		return -- no Handle, nothing to place relative to the camera
	end
	local rightGrip = findGripAttachment(tool, Viewmodel.RIGHT_GRIP_NAME)
	if not rightGrip then
		-- No grip marked at all -- nothing for this system to do; leave the
		-- Tool to Roblox's default Grip/weld behavior untouched.
		return
	end
	local rightArm = ArmRig.Find(character, "Right")
	if not rightArm then
		return -- not an R6 rig, or missing parts; nothing safe to do
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")

	-- Capture grip offsets relative to the Handle ONCE -- see the module
	-- doc comment on why per-frame WorldCFrame reads are forbidden.
	local handleInverse = handle.CFrame:Inverse()

	-- ADS sight frame, handle-local (see the Sight/SightEnd contract in the
	-- module doc comment): position from Sight, aim axis from the
	-- Sight -> SightEnd line -- attachment ORIENTATION is deliberately
	-- ignored when SightEnd exists, so a mis-rotated Sight can't skew the
	-- aimed grip. Roll comes from the weapon's own Grip up (the handle-local
	-- direction that points up in the hip grip frame -- see WEAPON
	-- ORIENTATION), so aiming never rolls the weapon relative to its hip
	-- hold. A lone Sight (no SightEnd) keeps the old full-CFrame contract.
	local sightRel: CFrame? = nil
	local sight = findGripAttachment(tool, Viewmodel.SIGHT_NAME)
	if sight then
		local sightCF = handleInverse * sight.WorldCFrame
		sightRel = sightCF
		local sightEnd = findGripAttachment(tool, Viewmodel.SIGHT_END_NAME)
		if sightEnd then
			local aimAxis = (handleInverse * sightEnd.WorldCFrame).Position - sightCF.Position
			if aimAxis.Magnitude > 1e-3 then
				local axis = aimAxis.Unit
				local upHint = tool.Grip.UpVector
				if math.abs(upHint:Dot(axis)) > 0.99 then
					upHint = sightCF.UpVector -- aim axis runs along the weapon's up; any stable hint works
				end
				if math.abs(upHint:Dot(axis)) > 0.99 then
					upHint = if math.abs(axis.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
				end
				sightRel = CFrame.lookAt(sightCF.Position, sightCF.Position + aimAxis, upHint)
			end
		end
	end

	local entry = {
		Right = nil :: any,
		Left = nil :: PosedHand?,
		Sway = Sway.new(),
		Handle = handle,
		Posed = false,
		SightRel = sightRel,
		AdsAlpha = 0,
		OriginalWeldC0 = {},
	} :: ActiveEntry
	entry.Right = {
		AttRel = handleInverse * rightGrip.WorldCFrame,
		Arm = rightArm,
		Cache = ArmRig.Capture(rightArm),
		TransparencyConnection = watchTransparency(entry, rightArm.Arm),
	}

	local leftGrip = findGripAttachment(tool, Viewmodel.LEFT_GRIP_NAME)
	if leftGrip then
		local leftArm = ArmRig.Find(character, "Left")
		if leftArm then
			entry.Left = {
				AttRel = handleInverse * leftGrip.WorldCFrame,
				Arm = leftArm,
				Cache = ArmRig.Capture(leftArm),
				TransparencyConnection = watchTransparency(entry, leftArm.Arm),
			}
		end
	end

	-- Stepped, NOT RenderStepped: the animation system writes every
	-- Motor6D.Transform right before Stepped fires, so this is the one spot
	-- where our Transform override deterministically lands last (see
	-- ArmRig.luau). NOTE Stepped's dt is the SECOND argument.
	entry.Connection = RunService.Stepped:Connect(function(_runningTime: number, dt: number)
		if not (handle.Parent and rightArm.Torso.Parent) then
			-- The tool/character was destroyed out from under us -- clean up
			-- via Unequip's own restore path rather than erroring every frame.
			Viewmodel.Unequip(tool, character)
			return
		end

		local camera = Workspace.CurrentCamera
		local isFirstPerson = camera ~= nil
			and (camera.CFrame.Position - camera.Focus.Position).Magnitude <= FIRST_PERSON_MAX_DISTANCE

		if not isFirstPerson then
			unpose(entry) -- no-op if already unposed
			return
		end
		entry.Posed = true

		-- Smooth hip <-> ADS blend (only weapons with a Sight ever aim).
		local adsTarget = if aiming and entry.SightRel then 1 else 0
		entry.AdsAlpha += (adsTarget - entry.AdsAlpha) * math.min(dt * ADS_BLEND_SPEED, 1)
		local ads = entry.AdsAlpha

		local swayCFrame = entry.Sway:Update(dt, humanoid)
		if ads > 1e-3 then
			-- Steady the weapon while aiming (fade most of the sway/bob out).
			swayCFrame = CFrame.identity:Lerp(swayCFrame, 1 - ADS_SWAY_FACTOR * ads)
		end

		-- Root of the whole chain: the camera-relative grip frame, then the
		-- Handle placed in it exactly the way Tool.Grip says it sits in a
		-- hand (see WEAPON ORIENTATION in the module doc comment). Grip is
		-- read live so grip edits show up immediately.
		local swayedCamera = camera.CFrame * swayCFrame
		local gripFrame = swayedCamera * WEAPON_CAMERA_OFFSET
		local extraOffset = tool:GetAttribute(GRIP_OFFSET_ATTRIBUTE)
		if typeof(extraOffset) == "CFrame" then
			gripFrame = gripFrame * extraOffset
		end
		local desiredHandle = gripFrame * tool.Grip:Inverse()

		local sightRel = entry.SightRel
		if sightRel and ads > 1e-3 then
			-- ADS pose: solve the Handle CFrame that puts the sight frame
			-- (built at equip from Sight/SightEnd -- see the module doc
			-- comment) dead-center, ADS_SIGHT_DISTANCE in front of the
			-- (swayed) camera and rotation-aligned with it, then blend the
			-- hip pose toward it. The arms + weld all follow desiredHandle,
			-- so the hands ride the weapon up to the eye automatically.
			local adsHandle = swayedCamera * CFrame.new(0, 0, -ADS_SIGHT_DISTANCE) * sightRel:Inverse()
			desiredHandle = desiredHandle:Lerp(adsHandle, ads)
		end

		-- Pole vectors are defined camera-locally (so elbows keep bending
		-- down-and-out relative to the view) and resolved to world here.
		-- The camera CFrame is also passed so each arm over-stretches its
		-- near (cut) end behind the view plane -- never visible on screen.
		-- Each arm's virtual shoulder anchor hangs from the (swayed) camera
		-- at forearm height (ShoulderOffset + the dynamic ElbowOffset's
		-- position shift) -- see the field comments above / ArmRig.PoseArm.
		local predictedRightArm = ArmRig.PoseArm(
			entry.Right.Arm,
			entry.Right.Cache,
			desiredHandle * entry.Right.AttRel,
			Viewmodel.RightElbowOffset,
			camera.CFrame:VectorToWorldSpace(Viewmodel.RightElbowPole),
			camera.CFrame,
			swayedCamera:PointToWorldSpace(Viewmodel.RightShoulderOffset + Viewmodel.RightElbowOffset.Position)
		)
		local left = entry.Left
		if left then
			ArmRig.PoseArm(
				left.Arm,
				left.Cache,
				desiredHandle * left.AttRel,
				Viewmodel.LeftElbowOffset,
				camera.CFrame:VectorToWorldSpace(Viewmodel.LeftElbowPole),
				camera.CFrame,
				swayedCamera:PointToWorldSpace(Viewmodel.LeftShoulderOffset + Viewmodel.LeftElbowOffset.Position)
			)
		end

		-- Actually move the tool: solve the engine's own RightGrip weld
		-- (Handle = Arm.CFrame * C0 * C1:Inverse()) so the Handle lands
		-- exactly on desiredHandle, using the arm CFrame we JUST solved
		-- (reading Arm.CFrame back would be a frame stale).
		local weld = findGripWeld(entry)
		if weld then
			if entry.OriginalWeldC0[weld] == nil then
				entry.OriginalWeldC0[weld] = weld.C0
			end
			weld.C0 = predictedRightArm:Inverse() * desiredHandle * weld.C1
		end

		-- Keep the posed arms visible (the watch connections catch the
		-- engine's own writes; this catches the very first posed frame).
		entry.Right.Arm.Arm.LocalTransparencyModifier = 0
		if left then
			left.Arm.Arm.LocalTransparencyModifier = 0
		end
	end)

	active[tool] = entry
end

function Viewmodel.Unequip(tool: Tool, _character: Model)
	local entry = active[tool]
	if not entry then
		return
	end
	active[tool] = nil
	entry.Connection:Disconnect()
	unpose(entry)
	entry.Right.TransparencyConnection:Disconnect()
	if entry.Left then
		entry.Left.TransparencyConnection:Disconnect()
	end
end

return Viewmodel
