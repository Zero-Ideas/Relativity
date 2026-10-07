--!strict
--[[
	Crater (client, purely cosmetic -- nothing here collides or replicates)
	Ground damage for an explosion that struck a surface (floor, wall or
	ceiling alike -- everything is built in the surface's own frame):

	 - Rim: thin slabs laid all the way around, as if the ground was peeled
	   up -- one ray direction per slab in the surface plane (one more, squeezed
	   beside each, for very strong blasts). Each ray first goes outward from the
	   centre, so a slab stops short of a wall, then down onto the surface to
	   find the exact height, slope and material it copies; no ground there
	   (a ledge) leaves a gap. Slabs scatter between 0.85x and 2.15x the rim
	   radius, as wide as the gap to the next, outer edge tilted up; they pop
	   out of the ground, linger, then each slides back down on its own clock.
	 - Debris: cubes of the struck material thrown steeply (70-80 degrees)
	   out of the blast, simulated here (gravity, a bounce or two off whatever
	   they hit, then rest and fade), on the local time scale.
	--
	Crater.Spawn(surface: RaycastResult, blastRadius, intensity, lowDetail?)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared.ChunkManager)
local Heartbeat = require(Shared.Heartbeat)

local Crater = {}

local CRATER_FROM = 0.15 -- intensity below which there's no crater (debris still flies)
local DEBRIS_FROM = 0.05
local CRATER_SCALE = 0.6 -- crater radius per stud of blastw radius
local MIN_CRATER, MAX_CRATER = 3.5, 40
local RIM_ROCKS_MIN, RIM_ROCKS_MAX = 40, 325 -- rim slabs (one ray each), growing with crater size
local RIM_SPREAD_MIN, RIM_SPREAD_MAX = 0.85, 2.15 -- each slab's distance out, x the rim's base radius
local RIM_BASE = 0.6 -- the rim's base radius, x the crater radius
-- How far a slab's outer edge lifts depends on where it sits, so the rim
-- reads as a bowl: the innermost slabs (the crater wall) tilt steeply and sit
-- deeper, the outermost lie nearly flat on the ground they were thrown onto.
local RIM_TILT_INNER, RIM_TILT_OUTER = 34, 6 -- degrees
local RIM_TILT_JITTER = 7 -- +- degrees on top, so neighbours never match
local RIM_TWIST = 18 -- +- degrees each slab turns about the surface normal
local RIM_ROLL = 10 -- +- degrees each slab rolls sideways
local RIM_DEPTH = 0.6 -- how far the innermost slabs sink (x slab scale); the outermost don't
-- Slab size, like the reference rock-circle module: a part that scales with
-- the crater plus a fixed minimum (so small craters still get solid slabs),
-- and a width that never shrinks below SLAB_MIN_WIDTH however many there are.
local SLAB_THICKNESS = 0.5 -- x slab scale, at least SLAB_MIN_THICKNESS
local SLAB_MIN_THICKNESS = 0.45
local SLAB_DEPTH_MIN, SLAB_DEPTH_MAX = 2, 3 -- studs, plus 1.3 x slab scale
local SLAB_MIN_WIDTH = 2.2 -- studs, plus 1.3 x slab scale
local BONUS_FROM = 0.85 -- intensity from which an extra slab is squeezed beside each main one
local MAX_CRATERS = 10
local LINGER_MIN, LINGER_MAX = 6, 14 -- seconds a crater stays (weak .. strong)
local LINGER_JITTER = 1.5 -- each slab sinks up to this much later, so the rim crumbles away
local SINK_TIME = 1.8
local RISE_TIME = 0.1

local MAX_DEBRIS = 220
local DEBRIS_MIN, DEBRIS_MAX = 6, 26 -- chunks per blast (weak .. strong)
local DEBRIS_SPEED_MIN, DEBRIS_SPEED_MAX = 45, 140 -- launch speed (weak .. strong), studs/s
local DEBRIS_LIFE = 5
local DEBRIS_ELEVATION_MIN, DEBRIS_ELEVATION_MAX = 70, 80 -- launch angle above the surface, degrees
local DEBRIS_FADE = 1
local RESTITUTION = 0.35
local FRICTION = 0.6
local REST_SPEED = 3

-- Materials that make poor rubble get swapped for plain rock.
local RUBBLE_FALLBACK: { [Enum.Material]: boolean } = {
	[Enum.Material.Glass] = true,
	[Enum.Material.ForceField] = true,
	[Enum.Material.Neon] = true,
	[Enum.Material.Water] = true,
	[Enum.Material.Air] = true,
}

type Ground = { Material: Enum.Material, Color: Color3 }

type Chunk = {
	Part: BasePart,
	Velocity: Vector3,
	Spin: Vector3,
	Age: number,
	Life: number,
	Resting: boolean,
	HalfSize: number,
}

local folder: Folder? = nil
type CraterEntry = { Model: Model, Sinks: { [BasePart]: CFrame } }

local craters: { CraterEntry } = {}
local chunks: { Chunk } = {}
local connection: RBXScriptConnection? = nil
local rng = Random.new()

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "Craters"
	created.Parent = workspace
	folder = created
	return created
end

-- Ignores characters and every cosmetic folder, and anything non-collidable
-- (foliage, triggers, effects).
local function rayParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true
	local ignore: { Instance } = { getFolder() }
	for _, name in { "ExplosionVFX", "SpellCircles" } do
		local other = workspace:FindFirstChild(name)
		if other then
			table.insert(ignore, other)
		end
	end
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	params.FilterDescendantsInstances = ignore
	return params
end

-- Anything inside a model with a Humanoid (players, dummies, NPCs) is a body,
-- not ground.
local function onBody(instance: Instance): boolean
	local model = instance:FindFirstAncestorOfClass("Model")
	while model do
		if model:FindFirstChildOfClass("Humanoid") then
			return true
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return false
end

-- What the ground at a hit is made of, for rubble that matches it.
local function groundOf(hit: RaycastResult): Ground
	local material = hit.Material
	local color = Color3.fromRGB(110, 104, 96)
	local instance = hit.Instance
	if instance:IsA("Terrain") then
		local ok, terrainColor = pcall(instance.GetMaterialColor, instance, material)
		if ok then
			color = terrainColor
		end
	elseif instance:IsA("BasePart") then
		color = instance.Color
	end
	if RUBBLE_FALLBACK[material] then
		material = Enum.Material.Slate
	end
	return { Material = material, Color = color }
end

-- Right/up/back frame at `position` whose up is `up` and which faces
-- `forward` (projected into the plane).
local function frameAlong(position: Vector3, up: Vector3, forward: Vector3): CFrame
	local flat = forward - up * forward:Dot(up)
	if flat.Magnitude < 1e-3 then
		flat = if math.abs(up.Y) < 0.9 then Vector3.yAxis:Cross(up) else Vector3.xAxis:Cross(up)
	end
	local look = flat.Unit
	local back = -look
	return CFrame.fromMatrix(position, up:Cross(back), up, back)
end

local function newPart(class: string, ground: Ground, size: Vector3): BasePart
	local part = Instance.new(class) :: BasePart
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = ground.Material
	part.Color = ground.Color
	part.Size = size
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- Slabs slide back down into the ground (each after its own random extra
-- wait unless `now`). Then the crater is removed.
local function sinkAndRemove(entry: CraterEntry, now: boolean?)
	local info = TweenInfo.new(SINK_TIME, Enum.EasingStyle.Cubic, Enum.EasingDirection.In)
	local longest = 0
	for _, part in entry.Model:GetChildren() do
		if not part:IsA("BasePart") then
			continue
		end
		local wait = if now then 0 else rng:NextNumber(0, LINGER_JITTER)
		longest = math.max(longest, wait)
		local sink = entry.Sinks[part]
		task.delay(wait, function()
			if part.Parent then
				TweenService:Create(part, info, if sink then { CFrame = sink } else { Transparency = 1 }):Play()
			end
		end)
	end
	task.delay(longest + SINK_TIME + 0.1, function()
		entry.Model:Destroy()
	end)
end

--------------------------------------------------------------------------------
-- Rim
--------------------------------------------------------------------------------

local function buildCrater(surface: RaycastResult, radius: number, intensity: number, params: RaycastParams)
	local centre = surface.Position
	local normal = surface.Normal
	local tangent = frameAlong(centre, normal, Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))).RightVector
	local bitangent = normal:Cross(tangent)

	local model = Instance.new("Model")
	model.Name = "Crater"


	-- Rim: thin slabs laid around the crater like the ground was peeled up --
	-- each about as wide as the gap to its neighbour, scattered between
	-- 0.85x and 2.15x the rim radius, sunk a little, outer edge tilted up.
	local sinks: { [BasePart]: CFrame } = {}
	local base = radius * RIM_BASE
	local k = math.clamp(radius / 5, 0.7, 3) -- slab scale: 1 for a 5-stud crater
	local count = math.clamp(math.floor(9 + radius * 1.0), RIM_ROCKS_MIN, RIM_ROCKS_MAX)
	local step = math.pi * 2 / count
	local lift = radius * 0.6 -- ground rays start this far above the surface
	local riseInfo = TweenInfo.new(RISE_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

	local function slab(angle: number)
		local outward = tangent * math.cos(angle) + bitangent * math.sin(angle)
		local reach = base * rng:NextNumber(RIM_SPREAD_MIN, RIM_SPREAD_MAX)

		-- outward: a wall closer than that pulls the slab in front of it
		local wall = workspace:Raycast(centre + normal * math.min(lift, 1.5), outward * reach, params)
		if wall then
			reach = math.max(wall.Distance - k, base * 0.5)
		end

		-- down: the ground there (none = a ledge, leave a gap)
		local above = centre + outward * reach + normal * lift
		local ground = workspace:Raycast(above, -normal * (lift + radius), params)
		if not ground or ground.Normal:Dot(normal) < 0.3 or onBody(ground.Instance) then
			return
		end

		local gap = 2 * reach * math.sin(step / 2) -- distance to the next slab
		local size = Vector3.new(
			math.max(gap, SLAB_MIN_WIDTH) * rng:NextNumber(0.75, 1.1) + 1.3 * k,
			math.max(SLAB_THICKNESS * k, SLAB_MIN_THICKNESS),
			rng:NextNumber(SLAB_DEPTH_MIN, SLAB_DEPTH_MAX) + 1.3 * k
		)
		-- 0 = innermost (crater wall), 1 = outermost (thrown onto the ground)
		local out = math.clamp((reach / base - RIM_SPREAD_MIN) / (RIM_SPREAD_MAX - RIM_SPREAD_MIN), 0, 1)
		local tilt = RIM_TILT_INNER + (RIM_TILT_OUTER - RIM_TILT_INNER) * out + rng:NextNumber(-RIM_TILT_JITTER, RIM_TILT_JITTER)
		local depth = (RIM_DEPTH * (1 - out) + rng:NextNumber(0, 0.2)) * k
		-- facing the centre (give or take a twist): tilting about its right
		-- axis lifts the outer edge
		local seat = frameAlong(ground.Position - ground.Normal * depth, ground.Normal, -outward)
			* CFrame.Angles(0, math.rad(rng:NextNumber(-RIM_TWIST, RIM_TWIST)), 0)
		local final = seat * CFrame.Angles(math.rad(-math.max(tilt, 0)), 0, math.rad(rng:NextNumber(-RIM_ROLL, RIM_ROLL)))
		local rock = newPart("Part", groundOf(ground), size)
		rock.CastShadow = true
		rock.CFrame = final * CFrame.new(0, -size.Y, 0) -- pops up out of the ground
		rock.Parent = model
		sinks[rock] = seat * CFrame.new(0, -(size.Y + size.Z), 0)
		TweenService:Create(rock, riseInfo, { CFrame = final }):Play()
	end

	local bonus = intensity >= BONUS_FROM
	for index = 0, count - 1 do
		local angle = (index + rng:NextNumber(-0.2, 0.2)) * step
		slab(angle)
		if bonus then
			slab(angle + step * 0.5 * (if rng:NextNumber() < 0.5 then 1 else -1))
		end
	end

	model.Parent = getFolder()
	local linger = LINGER_MIN + (LINGER_MAX - LINGER_MIN) * intensity
	local entry: CraterEntry = { Model = model, Sinks = sinks }
	table.insert(craters, entry)
	while #craters > MAX_CRATERS do
		local oldest = table.remove(craters, 1)
		if oldest then
			sinkAndRemove(oldest, true)
		end
	end
	task.delay(linger, function()
		local index = table.find(craters, entry)
		if index then
			table.remove(craters, index)
			sinkAndRemove(entry)
		end
	end)
end

--------------------------------------------------------------------------------
-- Debris
--------------------------------------------------------------------------------

local debrisParams: RaycastParams? = nil

local function stepDebris(dt: number)
	local params = debrisParams or rayParams()
	local gravity = Vector3.new(0, -workspace.Gravity, 0)
	local index = 1
	while index <= #chunks do
		local chunk = chunks[index]
		local part = chunk.Part
		local position = part.Position
		local scaledDt = dt * Heartbeat.GetGlobalTimeScale() * ChunkManager.GetTimeScaleAt(position)
		chunk.Age += scaledDt
		if chunk.Age >= chunk.Life + DEBRIS_FADE or not part.Parent then
			part:Destroy()
			chunks[index] = chunks[#chunks]
			chunks[#chunks] = nil
			continue
		end
		if chunk.Age > chunk.Life then
			part.Transparency = (chunk.Age - chunk.Life) / DEBRIS_FADE
		end
		if not chunk.Resting and scaledDt > 0 then
			chunk.Velocity += gravity * scaledDt
			local travel = chunk.Velocity * scaledDt
			local hit = workspace:Raycast(position, travel + travel.Unit * chunk.HalfSize, params)
			local rotation = CFrame.fromAxisAngle(chunk.Spin.Unit, chunk.Spin.Magnitude * scaledDt)
			if hit then
				-- bounce: reflect, lose energy, scrub sideways speed
				local n = hit.Normal
				local v = chunk.Velocity
				local normalPart = n * v:Dot(n)
				chunk.Velocity = (v - normalPart) * FRICTION - normalPart * RESTITUTION
				chunk.Spin *= 0.5
				local rest = hit.Position + n * chunk.HalfSize
				part.CFrame = CFrame.new(rest) * (part.CFrame - part.Position) * rotation
				if chunk.Velocity.Magnitude < REST_SPEED then
					chunk.Resting = true
				end
			else
				part.CFrame = (part.CFrame + travel) * rotation
			end
		end
		index += 1
	end
	if #chunks == 0 and connection then
		connection:Disconnect()
		connection = nil
		debrisParams = nil
	end
end

local function throwDebris(surface: RaycastResult, radius: number, intensity: number, count: number, params: RaycastParams)
	local ground = groundOf(surface)
	local normal = surface.Normal
	local speed = DEBRIS_SPEED_MIN + (DEBRIS_SPEED_MAX - DEBRIS_SPEED_MIN) * intensity
	local parent = getFolder()
	for _ = 1, count do
		if #chunks >= MAX_DEBRIS then
			break
		end
		local side = rng:NextUnitVector()
		side = (side - normal * side:Dot(normal))
		side = if side.Magnitude > 1e-3 then side.Unit else Vector3.xAxis
		local edge = math.clamp(radius * rng:NextNumber(0.05, 0.14), 0.2, 2)
		local part = newPart("Part", ground, Vector3.one * edge)
		part.CastShadow = edge > 0.8
		part.CFrame = CFrame.new(surface.Position + normal * (edge + 0.3) + side * radius * rng:NextNumber(0, 0.35))
			* CFrame.fromAxisAngle(rng:NextUnitVector(), rng:NextNumber(0, math.pi * 2))
		part.Parent = parent
		local elevation = math.rad(rng:NextNumber(DEBRIS_ELEVATION_MIN, DEBRIS_ELEVATION_MAX))
		table.insert(chunks, {
			Part = part,
			Velocity = (normal * math.sin(elevation) + side * math.cos(elevation)) * speed * rng:NextNumber(0.6, 1.1),
			Spin = rng:NextUnitVector() * rng:NextNumber(3, 12),
			Age = 0,
			Life = DEBRIS_LIFE * rng:NextNumber(0.7, 1.3),
			Resting = false,
			HalfSize = edge * 0.5,
		})
	end
	debrisParams = params
	if not connection and #chunks > 0 then
		connection = RunService.Heartbeat:Connect(stepDebris)
	end
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- An explosion of `blastRadius` studs and `intensity` (0..1, ExplosionVFX's
-- scale) struck `surface`. lowDetail halves the debris and skips the crater
-- (many blasts at once, or far away).
function Crater.Spawn(surface: RaycastResult, blastRadius: number, intensity: number, lowDetail: boolean?)
	if intensity < DEBRIS_FROM or onBody(surface.Instance) then
		return
	end
	local params = rayParams()
	local radius = math.clamp(blastRadius * CRATER_SCALE, MIN_CRATER, MAX_CRATER)
	if intensity >= CRATER_FROM and not lowDetail then
		buildCrater(surface, radius, intensity, params)
	end
	local count = math.floor(DEBRIS_MIN + (DEBRIS_MAX - DEBRIS_MIN) * intensity + 0.5)
	if lowDetail then
		count = math.ceil(count / 2)
	end
	throwDebris(surface, radius, intensity, count, params)
end

return Crater
