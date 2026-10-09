--!strict
--[[
	Effects/Surface.luau
	Works out what an effect landed on, so it can adapt to it:

	 Family       Stone / Metal / Wood / Earth / Powder / Glass / Water /
	              Fabric / Plastic / Energy / Flesh / Air (nothing there)
	 Color        the struck part's colour, or the terrain material's
	 Orientation  Floor / Wall / Ceiling (from the normal), Air when nothing
	 Underwater   the point sits in terrain water

	Surface.Probe(position, normal?, params?) -> Info
	Surface.FromResult(result, underwater?) -> Info
	Surface.Underwater(position) -> boolean
]]

local Util = require(script.Parent.Util)

local Surface = {}

export type Info = {
	Family: string,
	Material: Enum.Material?,
	Color: Color3,
	Position: Vector3,
	Normal: Vector3,
	Orientation: string,
	Underwater: boolean,
	Instance: Instance?,
}

-- By material name, so a material missing from older engines can't error.
local FAMILY_BY_MATERIAL: { [string]: string } = {
	Slate = "Stone", Concrete = "Stone", Granite = "Stone", Marble = "Stone", Pebble = "Stone",
	Cobblestone = "Stone", Rock = "Stone", Basalt = "Stone", Brick = "Stone", Pavement = "Stone",
	Asphalt = "Stone", Limestone = "Stone", Sandstone = "Stone", CrackedLava = "Stone",
	CeramicTiles = "Stone", ClayRoofTiles = "Stone", Plaster = "Stone", Salt = "Stone",
	Metal = "Metal", CorrodedMetal = "Metal", DiamondPlate = "Metal", Foil = "Metal",
	Wood = "Wood", WoodPlanks = "Wood", Cardboard = "Wood", RoofShingles = "Wood",
	Grass = "Earth", LeafyGrass = "Earth", Ground = "Earth", Mud = "Earth",
	Sand = "Powder", Snow = "Powder",
	Glass = "Glass", Ice = "Glass", Glacier = "Glass",
	Water = "Water",
	Fabric = "Fabric", Carpet = "Fabric", Leather = "Fabric", Rubber = "Fabric",
	Plastic = "Plastic", SmoothPlastic = "Plastic",
	Neon = "Energy", ForceField = "Energy",
}

local FAMILY_COLOR: { [string]: Color3 } = {
	Stone = Color3.fromRGB(150, 146, 140),
	Metal = Color3.fromRGB(170, 172, 178),
	Wood = Color3.fromRGB(140, 100, 64),
	Earth = Color3.fromRGB(110, 92, 64),
	Powder = Color3.fromRGB(220, 205, 170),
	Glass = Color3.fromRGB(200, 230, 245),
	Water = Color3.fromRGB(190, 225, 240),
	Fabric = Color3.fromRGB(150, 140, 130),
	Plastic = Color3.fromRGB(180, 180, 180),
	Energy = Color3.fromRGB(255, 255, 255),
	Flesh = Color3.fromRGB(255, 255, 255),
	Air = Color3.fromRGB(220, 220, 220),
}

local terrain = workspace.Terrain

local defaultParams = RaycastParams.new()
defaultParams.FilterType = Enum.RaycastFilterType.Exclude
defaultParams.IgnoreWater = false

local function orientation(normal: Vector3): string
	if normal.Y > 0.6 then
		return "Floor"
	elseif normal.Y < -0.6 then
		return "Ceiling"
	end
	return "Wall"
end

local function isEntity(instance: Instance): boolean
	local model = instance:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

-- Terrain water, per 4-stud voxel. Cached briefly: a burst of impacts in the
-- same spot reads the voxel once.
local waterCache: { [Vector3]: boolean } = {}
local waterCacheAt = 0
function Surface.Underwater(position: Vector3): boolean
	local now = os.clock()
	if now - waterCacheAt > 2 then
		table.clear(waterCache)
		waterCacheAt = now
	end
	local corner = Vector3.new(math.floor(position.X / 4) * 4, math.floor(position.Y / 4) * 4, math.floor(position.Z / 4) * 4)
	local cached = waterCache[corner]
	if cached ~= nil then
		return cached
	end
	local ok, materials, occupancies = pcall(terrain.ReadVoxels, terrain, Region3.new(corner, corner + Vector3.one * 4), 4)
	local water = ok and materials[1][1][1] == Enum.Material.Water and occupancies[1][1][1] > 0.5
	waterCache[corner] = water
	return water
end

local function materialColor(result: RaycastResult): Color3
	local instance = result.Instance
	if instance == terrain then
		if result.Material == Enum.Material.Water then
			return terrain.WaterColor:Lerp(Color3.new(1, 1, 1), 0.5)
		end
		local ok, color = pcall(terrain.GetMaterialColor, terrain, result.Material)
		if ok then
			return color
		end
		return FAMILY_COLOR.Stone
	end
	if instance:IsA("BasePart") then
		return instance.Color
	end
	return FAMILY_COLOR.Stone
end

function Surface.FromResult(result: RaycastResult, underwater: boolean?): Info
	local instance = result.Instance
	local family
	if instance ~= terrain and isEntity(instance) then
		family = "Flesh"
	else
		family = FAMILY_BY_MATERIAL[result.Material.Name] or "Plastic"
	end
	local position = result.Position
	return {
		Family = family,
		Material = result.Material,
		Color = if family == "Flesh" then FAMILY_COLOR.Flesh else materialColor(result),
		Position = position,
		Normal = result.Normal,
		Orientation = orientation(result.Normal),
		Underwater = if underwater ~= nil then underwater else Surface.Underwater(position + result.Normal * 0.5),
		Instance = instance,
	}
end

local function air(position: Vector3, normal: Vector3): Info
	return {
		Family = "Air",
		Material = nil,
		Color = FAMILY_COLOR.Air,
		Position = position,
		Normal = normal,
		Orientation = "Air",
		Underwater = Surface.Underwater(position),
		Instance = nil,
	}
end

-- Looks just behind `position` along -normal (and, failing that, along the
-- incoming direction) for the surface an impact landed on.
function Surface.Probe(position: Vector3, normal: Vector3?, incoming: Vector3?, params: RaycastParams?): Info
	local rayParams = params or defaultParams
	if not params then
		defaultParams.FilterDescendantsInstances = Util.IgnoreList()
	end
	local n = Util.Unit(normal, Vector3.zero)
	if n ~= Vector3.zero then
		local result = workspace:Raycast(position + n * 0.75, -n * 2, rayParams)
		if result then
			return Surface.FromResult(result)
		end
	end
	if incoming and incoming.Magnitude > 1e-3 then
		local d = incoming.Unit
		local result = workspace:Raycast(position - d * 1, d * 2.5, rayParams)
		if result then
			return Surface.FromResult(result)
		end
	end
	return air(position, if n ~= Vector3.zero then n else Vector3.yAxis)
end

function Surface.FamilyColor(family: string): Color3
	return FAMILY_COLOR[family] or FAMILY_COLOR.Stone
end

return Surface
