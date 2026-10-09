--!strict
--[[
	Effects/Debris.luau
	The physical bits of an effect, simulated here and never by the engine
	(anchored, no collision, no queries):

	 Debris.Throw(spec)   chips / splinters / shards: gravity, a bounce or two
	                      off whatever they hit, rest, then fade
	 Debris.Mark(...)     a scorch or heat mark flat on the surface
	 Debris.Flash(...)    a brief point light

	Everything runs on the local time scale (a frozen zone freezes it) and is
	pooled with hard caps; past a cap the oldest gives way.
]]

local Util = require(script.Parent.Util)

local Debris = {}

local MAX_PIECES = 150
local MAX_MARKS = 32
local MAX_LIGHTS = 8
local RESTITUTION = 0.3
local FRICTION = 0.55
local REST_SPEED = 2.5
local FADE = 0.6
local MARK_FADE = 1.5
local PARK = CFrame.new(0, -1e5, 0)
local TIME_REFRESH = 0.25

local gravity = Vector3.new(0, -workspace.Gravity, 0)

type Piece = {
	Part: BasePart,
	Position: Vector3,
	Velocity: Vector3,
	Rotation: CFrame,
	Spin: Vector3,
	Age: number,
	Life: number,
	Resting: boolean,
	Radius: number,
	Transparency: number,
	Fading: boolean,
	TimeScale: number,
	TimeCheck: number,
}

type Mark = {
	Part: BasePart,
	Age: number,
	Life: number,
	Color: Color3,
	Hot: Color3?,
	TimeScale: number,
}

type Flash = {
	Part: BasePart,
	Light: PointLight,
	Age: number,
	Life: number,
	Brightness: number,
}

local pieces: { Piece } = {}
local marks: { Mark } = {}
local flashes: { Flash } = {}
local freeParts: { BasePart } = {}
local freeMarks: { BasePart } = {}
local freeLights: { Flash } = {}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function cosmetic(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
end

local function takePart(): BasePart
	local part = table.remove(freeParts)
	if part then
		return part
	end
	local created = Instance.new("Part")
	created.Name = "Debris"
	created.TopSurface = Enum.SurfaceType.Smooth
	created.BottomSurface = Enum.SurfaceType.Smooth
	cosmetic(created)
	created.CFrame = PARK
	created.Parent = Util.Folder()
	return created
end

local function releasePiece(index: number)
	local piece = pieces[index]
	pieces[index] = pieces[#pieces]
	pieces[#pieces] = nil
	piece.Part.CFrame = PARK
	table.insert(freeParts, piece.Part)
end

export type ThrowSpec = {
	Position: Vector3,
	Normal: Vector3, -- the surface the bits leave
	Direction: Vector3?, -- bias (e.g. a ricochet), blended with the normal
	Count: number,
	Size: number, -- typical edge length
	Shape: string?, -- "Chip" (default) | "Splinter" | "Shard"
	Speed: number,
	Spread: number?, -- 0..1 how far from the aim the bits scatter (default 0.6)
	Color: Color3,
	Material: Enum.Material?,
	Life: number?,
}

local function randomUnit(random: Random): Vector3
	return random:NextUnitVector()
end

local random = Random.new()

function Debris.Throw(spec: ThrowSpec): number
	local count = math.floor(spec.Count + random:NextNumber())
	if count <= 0 then
		return 0
	end
	local aim = Util.Unit(spec.Direction, spec.Normal)
	if spec.Direction then
		aim = Util.Unit(aim + spec.Normal * 0.6, spec.Normal)
	end
	local spread = spec.Spread or 0.6
	local material = spec.Material or Enum.Material.Slate
	if material == Enum.Material.Water or material == Enum.Material.Air or material == Enum.Material.ForceField then
		material = Enum.Material.SmoothPlastic
	end
	local shape = spec.Shape or "Chip"
	local timeScale = Util.TimeScaleAt(spec.Position)
	local spawned = 0
	for _ = 1, count do
		if #pieces >= MAX_PIECES then
			-- the oldest gives way
			local oldest, oldestAge = 1, -1
			for index, piece in pieces do
				if piece.Age > oldestAge then
					oldest, oldestAge = index, piece.Age
				end
			end
			releasePiece(oldest)
		end
		local part = takePart()
		local s = spec.Size * random:NextNumber(0.55, 1.35)
		local size = if shape == "Splinter" then Vector3.new(s * 0.25, s * 0.25, s * 2.2)
			elseif shape == "Shard" then Vector3.new(s * 0.9, s * 0.08, s * 0.7)
			else Vector3.new(s, s * random:NextNumber(0.5, 1), s * random:NextNumber(0.6, 1.1))
		part.Size = size
		part.Material = if shape == "Shard" then Enum.Material.Glass else material
		part.Color = spec.Color:Lerp(Color3.new(0, 0, 0), random:NextNumber(0, 0.25))
		local transparency = if shape == "Shard" then 0.35 else 0
		part.Transparency = transparency
		local direction = Util.Unit(aim + randomUnit(random) * spread, aim)
		if direction:Dot(spec.Normal) < 0.05 then
			direction = Util.Unit(direction + spec.Normal * 0.5, spec.Normal)
		end
		table.insert(pieces, {
			Part = part,
			Position = spec.Position + spec.Normal * (s * 0.6),
			Velocity = direction * spec.Speed * random:NextNumber(0.5, 1.15),
			Rotation = CFrame.fromAxisAngle(randomUnit(random), random:NextNumber(0, math.pi * 2)),
			Spin = randomUnit(random) * random:NextNumber(6, 22),
			Age = 0,
			Life = (spec.Life or 2.5) * random:NextNumber(0.75, 1.25),
			Resting = false,
			Radius = math.min(size.X, size.Y, size.Z) * 0.5,
			Transparency = transparency,
			Fading = false,
			TimeScale = timeScale,
			TimeCheck = 0,
		})
		spawned += 1
	end
	return spawned
end

function Debris.Mark(position: Vector3, normal: Vector3, radius: number, color: Color3, hot: Color3?, life: number?)
	local part: BasePart
	if #marks >= MAX_MARKS then
		local oldest = table.remove(marks, 1) :: Mark
		part = oldest.Part
	else
		part = table.remove(freeMarks) or (function()
			local created = Instance.new("Part")
			created.Name = "Mark"
			created.Shape = Enum.PartType.Cylinder
			cosmetic(created)
			created.Parent = Util.Folder()
			return created
		end)()
	end
	local n = Util.Unit(normal, Vector3.yAxis)
	part.Size = Vector3.new(0.05, radius * 2, radius * 2)
	-- a Cylinder's axis is its X: lay X along the normal
	part.CFrame = CFrame.lookAt(position + n * 0.03, position + n * 2) * CFrame.Angles(0, math.rad(90), 0)
		* CFrame.Angles(math.rad(random:NextNumber(0, 360)), 0, 0)
	part.Material = if hot then Enum.Material.Neon else Enum.Material.SmoothPlastic
	part.Color = hot or color
	part.Transparency = if hot then 0 else 0.25
	table.insert(marks, {
		Part = part,
		Age = 0,
		Life = life or 6,
		Color = color,
		Hot = hot,
		TimeScale = Util.TimeScaleAt(position),
	})
end

function Debris.Flash(position: Vector3, color: Color3, range: number, brightness: number, life: number?)
	local flash = table.remove(freeLights)
	if not flash then
		if #flashes >= MAX_LIGHTS then
			flash = table.remove(flashes, 1)
		else
			local part = Instance.new("Part")
			part.Name = "Flash"
			part.Size = Vector3.one * 0.2
			part.Transparency = 1
			cosmetic(part)
			local light = Instance.new("PointLight")
			light.Shadows = false
			light.Parent = part
			part.Parent = Util.Folder()
			flash = { Part = part, Light = light, Age = 0, Life = 0, Brightness = 0 }
		end
	end
	local item = flash :: Flash
	item.Part.CFrame = CFrame.new(position)
	item.Light.Color = color
	item.Light.Range = range
	item.Light.Brightness = brightness
	item.Light.Enabled = true
	item.Age, item.Life, item.Brightness = 0, life or 0.12, brightness
	table.insert(flashes, item)
end

local moveParts: { BasePart } = {}
local moveFrames: { CFrame } = {}

function Debris.Step(dt: number)
	rayParams.FilterDescendantsInstances = Util.IgnoreList()
	table.clear(moveParts)
	table.clear(moveFrames)
	local index = 1
	while index <= #pieces do
		local piece = pieces[index]
		piece.TimeCheck -= dt
		if piece.TimeCheck <= 0 then
			piece.TimeCheck = TIME_REFRESH
			piece.TimeScale = Util.TimeScaleAt(piece.Position)
		end
		local step = dt * piece.TimeScale
		if step > 0 then
			piece.Age += step
			if piece.Age >= piece.Life then
				releasePiece(index)
				continue
			end
			if not piece.Resting then
				piece.Velocity += gravity * step
				local move = piece.Velocity * step
				local hit = workspace:Raycast(piece.Position, move + move.Unit * piece.Radius, rayParams)
				if hit then
					local n = hit.Normal
					local v = piece.Velocity
					local into = v:Dot(n)
					local tangent = v - n * into
					piece.Velocity = tangent * FRICTION - n * into * RESTITUTION
					piece.Position = hit.Position + n * piece.Radius
					piece.Spin *= 0.5
					if piece.Velocity.Magnitude < REST_SPEED and n.Y > 0.5 then
						piece.Resting = true
						piece.Velocity = Vector3.zero
					end
				else
					piece.Position += move
				end
				piece.Rotation = CFrame.fromAxisAngle(Util.Unit(piece.Spin, Vector3.yAxis), piece.Spin.Magnitude * step) * piece.Rotation
			end
			local remaining = piece.Life - piece.Age
			if remaining < FADE then
				piece.Fading = true
				piece.Part.Transparency = piece.Transparency + (1 - piece.Transparency) * (1 - remaining / FADE)
			end
			if not piece.Resting or piece.Fading then
				table.insert(moveParts, piece.Part)
				table.insert(moveFrames, CFrame.new(piece.Position) * piece.Rotation)
			end
		end
		index += 1
	end
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end

	index = 1
	while index <= #marks do
		local mark = marks[index]
		mark.Age += dt * mark.TimeScale
		local remaining = mark.Life - mark.Age
		if remaining <= 0 then
			table.remove(marks, index)
			mark.Part.CFrame = PARK
			table.insert(freeMarks, mark.Part)
			continue
		end
		if mark.Hot and mark.Age < 1.2 then
			local cool = mark.Age / 1.2
			mark.Part.Color = (mark.Hot :: Color3):Lerp(mark.Color, cool)
			if cool > 0.6 and mark.Part.Material ~= Enum.Material.SmoothPlastic then
				mark.Part.Material = Enum.Material.SmoothPlastic
			end
		end
		if remaining < MARK_FADE then
			mark.Part.Transparency = 0.25 + 0.75 * (1 - remaining / MARK_FADE)
		end
		index += 1
	end

	index = 1
	while index <= #flashes do
		local flash = flashes[index]
		flash.Age += dt
		if flash.Age >= flash.Life then
			flash.Light.Enabled = false
			table.remove(flashes, index)
			table.insert(freeLights, flash)
			continue
		end
		flash.Light.Brightness = flash.Brightness * (1 - flash.Age / flash.Life) ^ 2
		index += 1
	end
end

function Debris.IsIdle(): boolean
	return #pieces == 0 and #marks == 0 and #flashes == 0
end

function Debris.GetStats(): { Pieces: number, Marks: number, Lights: number }
	return { Pieces = #pieces, Marks = #marks, Lights = #flashes }
end

return Debris
