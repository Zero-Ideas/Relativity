--!strict
--[[
	DroneRig (shared)
	Guns don't get held: equipping one summons a drone through a portal
	(client/DroneClient), and the drone fires the shots. This is the part
	both sides agree on:

	  Weapons        tool names that are drone weapons (the shooting weapons
	                 in server/Weapons)
	  Hover(root)    where a character's drone wants to hover: over its
	                 right shoulder, a little behind. The drone follows it
	                 (Follow); the server spawns the weapon's shots from
	                 where its followed drone is (Shooter.server's muzzle)
	  Portal(root)   where its portal opens: up and out to the right, ahead
	                 of the character, facing back at the hover point -- so
	                 its opening faces the (usually trailing) camera and the
	                 drone flies out toward it
	  Follow(state, target, dt)  how the drone chases its hover point: a
	                 damped spring with a top speed (FollowSpeed), snapping if
	                 it ends up absurdly far behind (a teleport). Clients fly
	                 the drone with it and the server runs the same motion to
	                 fire from where the drone actually is.
	  Aim replication  like the spell aim (SpellAim / SpellAimRelay): while
	                 its drone is out, the owner's client sends where it aims on
	                 an unreliable remote (AimRemote) -- only when it moves more
	                 than AimSendAngle, at most every AimSendInterval, plus a
	                 slow AimRefresh in case one was dropped. The server relays
	                 it (AimRelay, unreliable) only to players within AimRange
	                 of the drone, so every nearby copy aims, turns and flips
	                 the same way and nobody else is sent anything.
	  WeaponMountOffset  underside socket in the drone chassis's local space,
	                 where its arm's shoulder sits.
	                 Tools may supply a DroneMountOffset CFrame attribute to
	                 align their visual to the arm's hand (otherwise Grip
	                 inverse).
]]

local DroneRig = {}

DroneRig.Weapons = {
	Railgun = true,
	TimeBlaster = true,
	Pheonix = true,
} :: { [string]: boolean }

-- (relative to the character's root part)
DroneRig.HoverOffset = CFrame.new(2.6, 2.3, 1.2)
DroneRig.PortalOffset = Vector3.new(5, 3.6, -4.5)
DroneRig.PortalRadius = 2.4 -- clearance for four prop guards
DroneRig.WeaponMountOffset = CFrame.new(0, -0.42, 0)
DroneRig.AimRemote = "DroneAim" -- (UnreliableRemoteEvent in ReplicatedStorage: owner -> server)
DroneRig.AimRelay = "DroneAimRelay" -- (UnreliableRemoteEvent: server -> nearby clients)
DroneRig.AimSendInterval = 1 / 15 -- seconds between the owner's aim updates, at most
DroneRig.AimSendAngle = math.cos(math.rad(1.5)) -- smaller aim changes aren't sent
DroneRig.AimRefresh = 1 -- seconds: an unchanged aim is re-sent this rarely (a dropped update)
DroneRig.AimRange = 300 -- studs: only players this close to the drone get its aim
-- Following: spring stiffness (1/s: higher = snappier), top speed (studs/s)
-- and how far behind it may fall before it snaps to its hover point.
DroneRig.FollowStiffness = 7
DroneRig.FollowSpeed = 70
DroneRig.FollowSnapDistance = 80

export type FollowState = { position: Vector3, velocity: Vector3 }

-- Advances `state` toward `target` by `dt` seconds (critically damped,
-- speed-capped; substepped so a long frame stays stable).
function DroneRig.Follow(state: FollowState, target: Vector3, dt: number)
	if (target - state.position).Magnitude > DroneRig.FollowSnapDistance then
		state.position, state.velocity = target, Vector3.zero
		return
	end
	local omega = DroneRig.FollowStiffness
	local steps = math.clamp(math.ceil(dt * 120), 1, 12)
	local h = dt / steps
	for _ = 1, steps do
		local accel = (target - state.position) * (omega * omega) - state.velocity * (2 * omega)
		local velocity = state.velocity + accel * h
		local speed = velocity.Magnitude
		if speed > DroneRig.FollowSpeed then
			velocity *= DroneRig.FollowSpeed / speed
		end
		state.velocity = velocity
		state.position += velocity * h
	end
end

function DroneRig.IsDroneTool(instance: Instance?): boolean
	return instance ~= nil and instance:IsA("Tool") and DroneRig.Weapons[instance.Name] == true
end

function DroneRig.Hover(rootCFrame: CFrame): Vector3
	return (rootCFrame * DroneRig.HoverOffset).Position
end

-- The portal's frame: centred at PortalOffset, its front (-Z, LookVector)
-- facing the hover point, so the drone comes out of its front side.
function DroneRig.Portal(rootCFrame: CFrame): CFrame
	local centre = rootCFrame:PointToWorldSpace(DroneRig.PortalOffset)
	local hover = DroneRig.Hover(rootCFrame)
	return CFrame.lookAt(centre, hover, rootCFrame.UpVector)
end

return DroneRig
