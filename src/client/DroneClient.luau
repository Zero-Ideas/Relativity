--!strict
--[[
	DroneClient (client, purely visual)
	Guns aren't held: when any player's character equips a drone weapon
	(shared/DroneRig.Weapons) every client hides the gun and summons that
	character's drone through a portal; putting the gun away sends it back.
	The server fires the gun's shots from the drone's hover point
	(DroneRig.Hover), so the shots leave the drone.

	Summon: a portal (client/Portal: a SurfaceGui window hanging in mid-air)
	tears open beside the character (DroneRig.Portal), the drone flies up out
	of the illuminated concrete bay -- seen through the opening (a copy inside
	the portal's ViewportFrame) until its centre is through the portal's
	plane, then the real one -- to its hover point over the shoulder, and
	the portal closes. Dismiss runs it
	backwards. Everything is measured from the character's root each frame,
	so it all keeps up with a moving character.

	Each Tool gets a separate quadcopter with one underside weapon. Switching
	Tools sends the old drone home and launches a fresh one, never rearming an
	existing drone. It hovers with a slow bob and turns to
	face where its owner aims: the mouse for your own drone, the
	character's facing for everyone else's.

	Summon(character) / Dismiss(character) also work without a gun (the
	debug panel's VFX tab uses them).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DroneRig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DroneRig"))
local Portal = require(script.Parent.Portal)
local DroneVisual = require(script.Parent.DroneVisual)

local DroneClient = {}

local OPEN_TIME = 0.3
local TRAVEL_TIME = 0.75
local CLOSE_TIME = 0.25
local START_DEPTH = 7 -- studs behind the portal's plane the drone starts
local BOB, BOB_SPEED = 0.15, 2.2
local TURN_RATE = 12 -- how quickly it turns to its aim (1/s)
local MAX_RETURNING = 2 -- rapid tool switching must not accumulate drone copies

type State = "summoning" | "hovering" | "dismissing"
type Drone = {
	character: Model,
	root: BasePart,
	part: Model,
	ghost: Model, -- its copy inside the portal
	parts: {BasePart},
	rotors: {DroneVisual.Rotor},
	ghostRotors: {DroneVisual.Rotor},
	behind: boolean,
	weaponTool: Tool?, -- immutable equipment identity, including during return
	createdAt: number,
	portal: any?,
	state: State,
	t: number, -- seconds into the current summon / dismiss
	look: Vector3,
	hidden: { [Instance]: number }, -- the gun's parts: their old LocalTransparencyModifier
	tool: Tool?,
}

local drones: { [Model]: Drone } = {}
local live: {[Drone]: boolean} = {} -- includes outgoing drones during a swap
local stepping: RBXScriptConnection? = nil
local player = Players.LocalPlayer
local started = false
local watchedCharacters: {[Model]: boolean} = setmetatable({}, {__mode = "k"}) :: any
local watchedPlayers: {[Player]: boolean} = setmetatable({}, {__mode = "k"}) :: any

local makeDrone = DroneVisual.Create

local function openPortal(frame: CFrame, seconds: number?): any
	local portal = Portal.new(frame, DroneRig.PortalRadius)
	portal:Retain()
	portal:Open(seconds or OPEN_TIME)
	return portal
end

local function ease(t: number): number
	t = math.clamp(t, 0, 1)
	return 1 - (1 - t) ^ 3
end

-- Where the drone wants to look: the owner's aim.
local function aimOf(drone: Drone, from: Vector3): Vector3
	if drone.character == player.Character then
		local camera = workspace.CurrentCamera
		if not camera then return drone.root.CFrame.LookVector end
		local mouse = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
		local target = ray.Origin + ray.Direction * 300
		local offset = target - from
		if offset.Magnitude > 1e-3 then
			return offset.Unit
		end
	end
	return drone.root.CFrame.LookVector
end

-- The path out of the portal: from START_DEPTH behind its plane to the
-- hover point. `alpha` 0..1.
local function pathPoint(portalFrame: CFrame, hover: Vector3, alpha: number): Vector3
	local start = portalFrame * CFrame.new(0, 0, START_DEPTH)
	local mouth = portalFrame.Position
	-- through the mouth at the halfway mark, then on to the hover point
	if alpha < 0.5 then
		return start.Position:Lerp(mouth, alpha / 0.5)
	end
	return mouth:Lerp(hover, (alpha - 0.5) / 0.5)
end

local function hideTool(drone: Drone, tool: Tool?)
	if not tool then
		return
	end
	drone.tool = tool
	for _, part in tool:GetDescendants() do
		if part:IsA("BasePart") or part:IsA("Decal") then
			if drone.hidden[part] == nil then
				drone.hidden[part] = part.LocalTransparencyModifier
			end
			part.LocalTransparencyModifier = 1
		end
	end
end

local function showTool(drone: Drone)
	for part, old in drone.hidden do
		if part.Parent then
			(part :: any).LocalTransparencyModifier = old
		end
	end
	table.clear(drone.hidden)
	drone.tool = nil
end

local function finish(drone: Drone)
	live[drone] = nil
	drone.part:Destroy()
	drone.ghost:Destroy()
	if drone.portal then
		drone.portal:Release(CLOSE_TIME)
		drone.portal = nil
	end
	showTool(drone)
	if drones[drone.character] == drone then
		drones[drone.character] = nil
	end
end

local function step(dt: number)
	local now = os.clock()
	for drone in live do
		local character = drone.character
		local root = drone.root
		if not root.Parent or not character.Parent then
			finish(drone)
			continue
		end
		-- (a gun's parts can stream in late, and Roblox's own transparency
		-- updates reset the modifier: keep it hidden)
		if drone.tool and drone.state ~= "dismissing" then
			hideTool(drone, drone.tool)
		end
		local rootFrame = root.CFrame
		local hover = DroneRig.Hover(rootFrame) + Vector3.new(0, math.sin(now * BOB_SPEED) * BOB, 0)
		local portalFrame = DroneRig.Portal(rootFrame)
		if drone.portal then
			drone.portal:SetCFrame(portalFrame)
		end
		local position: Vector3
		if drone.state == "hovering" then
			position = hover
		else
			drone.t += dt
			local travel = math.clamp((drone.t - OPEN_TIME * 0.6) / TRAVEL_TIME, 0, 1)
			local alpha = if drone.state == "summoning" then ease(travel) else 1 - ease(travel)
			position = pathPoint(portalFrame, hover, alpha)
			if travel >= 1 then
				if drone.state == "summoning" then
					drone.state = "hovering"
					if drone.portal then
						-- (the ghost isn't needed while it hovers; keep it out of
						-- the closing portal, which takes its contents with it)
						drone.ghost.Parent = nil
						drone.portal:Release(CLOSE_TIME)
						drone.portal = nil
					end
				else
					if drone.portal then
						drone.portal:Release(CLOSE_TIME)
						drone.portal = nil
					end
					finish(drone)
					continue
				end
			end
		end
		-- turn toward the aim (while travelling: along the path)
		local wanted = if drone.state == "hovering" then aimOf(drone, position) else (hover - portalFrame.Position).Unit
		drone.look = drone.look:Lerp(wanted, 1 - math.exp(-TURN_RATE * dt))
		local look = if drone.look.Magnitude > 1e-3 then drone.look.Unit else rootFrame.LookVector
		local frame = CFrame.lookAt(position, position + look)
		-- the real drone shows once its centre is through the portal's plane;
		-- before that it's only seen through the opening (its ghost inside)
		local depth = (position - portalFrame.Position):Dot(-portalFrame.LookVector) -- >0: behind the plane
		local behind = drone.state ~= "hovering" and depth > 0
		if drone.behind ~= behind then
			drone.behind = behind
			DroneVisual.SetHidden(drone.parts, behind)
		end
		drone.part:PivotTo(frame)
		if not behind then DroneVisual.Spin(drone.rotors, frame, now) end
		if drone.portal then
			drone.ghost:PivotTo(frame)
			DroneVisual.Spin(drone.ghostRotors, frame, now)
		end
	end
	if next(live) == nil and stepping then
		stepping:Disconnect()
		stepping = nil
	end
end

local function ensureStepping()
	if not stepping then
		stepping = RunService.RenderStepped:Connect(step)
	end
end

-- Summons `character`'s drone (hiding `tool`, the gun, if given).
function DroneClient.Summon(character: Model, tool: Tool?)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local existing = drones[character]
	if existing and existing.root ~= root then
		-- Streaming can replace the root before the next render cleanup.
		-- Do not reuse a drone still following the removed root.
		finish(existing)
		existing = nil
	end
	local sharedPortal: any = nil
	if existing and existing.weaponTool ~= tool then
		-- Keep the previous quadcopter flying home independently. Its mounted
		-- weapon is immutable, so the new Tool needs a different drone.
		DroneClient.Dismiss(character)
		sharedPortal = existing.portal
		existing = nil
	end
	if existing then
		hideTool(existing, tool)
		if existing.state == "dismissing" then
			-- turned back mid-dismiss: fly out again from where it is
			existing.state = "summoning"
			existing.t = OPEN_TIME * 0.6 + TRAVEL_TIME * (1 - math.clamp((existing.t - OPEN_TIME * 0.6) / TRAVEL_TIME, 0, 1))
			if not existing.portal then
				existing.portal = openPortal(DroneRig.Portal(root.CFrame), 0.15)
				existing.ghost.Parent = existing.portal.Inside
			end
		end
		return
	end
	local portal = sharedPortal or openPortal(DroneRig.Portal(root.CFrame))
	if sharedPortal then portal:Retain() end
	local part = makeDrone(tool)
	local parts = DroneVisual.Parts(part)
	DroneVisual.SetHidden(parts, true)
	part.Parent = workspace
	local ghost = part:Clone()
	DroneVisual.SetHidden(DroneVisual.Parts(ghost), false)
	ghost.Parent = portal.Inside
	local drone: Drone = {
		character = character,
		root = root,
		part = part,
		ghost = ghost,
		parts = parts,
		rotors = DroneVisual.Rotors(part),
		ghostRotors = DroneVisual.Rotors(ghost),
		behind = true,
		weaponTool = tool,
		createdAt = os.clock(),
		portal = portal,
		state = "summoning",
		t = 0,
		look = (DroneRig.Hover(root.CFrame) - portal.CFrame.Position).Unit,
		hidden = {},
		tool = nil,
	}
	hideTool(drone, tool)
	drones[character] = drone
	live[drone] = true
	while true do
		local count, oldest = 0, nil :: Drone?
		for returning in live do
			if returning.character == character and returning.state == "dismissing" then
				count += 1
				if not oldest or returning.createdAt < oldest.createdAt then oldest = returning end
			end
		end
		if count <= MAX_RETURNING or not oldest then break end
		finish(oldest)
	end
	ensureStepping()
end

-- Sends `character`'s drone back through a portal (and shows the gun again).
function DroneClient.Dismiss(character: Model)
	local drone = drones[character]
	if not drone or drone.state == "dismissing" then
		return
	end
	showTool(drone)
	local travelled = math.clamp((drone.t - OPEN_TIME * 0.6) / TRAVEL_TIME, 0, 1)
	if drone.state == "hovering" then
		travelled = 1
	end
	drone.state = "dismissing"
	-- (pick up from wherever a summon had got to)
	drone.t = OPEN_TIME * 0.6 + TRAVEL_TIME * (1 - travelled)
	if not drone.portal then
		local portal = openPortal(DroneRig.Portal(drone.root.CFrame))
		drone.portal = portal
		drone.ghost.Parent = portal.Inside
		drone.t = 0 -- (wait for it to open)
	end
	ensureStepping()
end

-- Debug (VFX tab): a portal at `portalFrame` (front = LookVector) that a
-- drone flies out of, hangs in front of for a moment and flies back into.
function DroneClient.Demo(portalFrame: CFrame, radius: number)
	local portal = Portal.new(portalFrame, radius)
	portal:Open(OPEN_TIME)
	local part = makeDrone()
	part:ScaleTo(math.max(radius / DroneRig.PortalRadius, 1))
	local parts = DroneVisual.Parts(part)
	DroneVisual.SetHidden(parts, true)
	part.Parent = workspace
	local ghost = part:Clone()
	DroneVisual.SetHidden(DroneVisual.Parts(ghost), false)
	ghost.Parent = portal.Inside
	local rotors, ghostRotors = DroneVisual.Rotors(part), DroneVisual.Rotors(ghost)
	local start = portalFrame * CFrame.new(0, 0, START_DEPTH + radius * 2)
	local stop = portalFrame * CFrame.new(0, 0, -(radius * 2.5 + 2))
	local OUT, HANG, BACK = TRAVEL_TIME * 1.4, 0.8, TRAVEL_TIME * 1.2
	local began = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local t = os.clock() - began - OPEN_TIME * 0.6
		local alpha
		if t < OUT then
			alpha = ease(t / OUT)
		elseif t < OUT + HANG then
			alpha = 1
		else
			alpha = 1 - ease((t - OUT - HANG) / BACK)
		end
		local position = start.Position:Lerp(stop.Position, math.clamp(alpha, 0, 1))
		local frame = CFrame.lookAt(position, position + portalFrame.LookVector) * CFrame.new(0, math.sin(os.clock() * BOB_SPEED) * BOB, 0)
		local depth = (position - portalFrame.Position):Dot(-portalFrame.LookVector)
		DroneVisual.SetHidden(parts, depth > 0)
		part:PivotTo(frame)
		ghost:PivotTo(frame)
		local clock = os.clock()
		if depth <= 0 then DroneVisual.Spin(rotors, frame, clock) end
		DroneVisual.Spin(ghostRotors, frame, clock)
		if t >= OUT + HANG + BACK then
			connection:Disconnect()
			part:Destroy()
			portal:Close(CLOSE_TIME, true)
		end
	end)
end

function DroneClient.Has(character: Model): boolean
	return drones[character] ~= nil and drones[character].state ~= "dismissing"
end

-- Watches every character for drone weapons being equipped / put away.
local function watchCharacter(character: Model)
	if watchedCharacters[character] then return end
	watchedCharacters[character] = true
	local function check()
		local tool: Tool? = nil
		for _, child in character:GetChildren() do
			if DroneRig.IsDroneTool(child) then
				tool = child :: Tool
				break
			end
		end
		if tool then
			DroneClient.Summon(character, tool)
		elseif drones[character] and drones[character].tool then
			DroneClient.Dismiss(character)
		end
	end
	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") or child.Name == "HumanoidRootPart" then
			task.defer(check)
		end
	end)
	character.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") then
			task.defer(check)
		end
	end)
	check()
end

local function watchPlayer(other: Player)
	if watchedPlayers[other] then return end
	watchedPlayers[other] = true
	other.CharacterAdded:Connect(watchCharacter)
	if other.Character then
		task.spawn(watchCharacter, other.Character)
	end
end

function DroneClient.start()
	if started then return end
	started = true
	-- Every client observes ALL players' replicated equipped Tools and builds
	-- their drones locally, including players already equipped when we join.
	-- No owner-only rendering or per-frame drone transform remotes.
	Players.PlayerAdded:Connect(watchPlayer)
	for _, other in Players:GetPlayers() do
		watchPlayer(other)
	end
end

return DroneClient
