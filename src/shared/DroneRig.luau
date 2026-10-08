--!strict
--[[
	DroneRig (shared)
	Guns don't get held: equipping one summons a drone through a portal
	(client/DroneClient), and the drone fires the shots. This is the part
	both sides agree on:

	  Weapons        tool names that are drone weapons (the shooting weapons
	                 in server/Weapons)
	  Hover(root)    where a character's drone hovers: over its right
	                 shoulder, a little behind -- the server spawns the
	                 weapon's shots from here (Shooter.server's muzzle), the
	                 clients draw the drone here (plus a small bob)
	  Portal(root)   where its portal opens: up and out to the right, ahead
	                 of the character, facing back at the hover point -- so
	                 its opening faces the (usually trailing) camera and the
	                 drone flies out toward it
	  WeaponMountOffset  underside socket in the drone chassis's local space.
	                 Tools may supply a DroneMountOffset CFrame attribute to
	                 align their visual to that socket (otherwise Grip inverse).
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
