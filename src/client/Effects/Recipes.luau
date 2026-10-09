--!strict
--[[
	Effects/Recipes.luau
	What an impact looks like for each kind of surface, and how it bends to
	the situation:

	 - surface family picks the layers (sparks off metal, splinters off wood,
	   dust and grit off earth, glints and shards off glass, a splash off
	   water, fibres off fabric, pulses off energy and characters)
	 - colours come from the struck surface; energy layers from the shot
	 - floors throw dust up, ceilings drop it, walls spray out and fall
	 - an incoming velocity tilts the spray toward the ricochet
	 - underwater, everything turns into bubbles and murk
	 - strength (kind and speed) scales counts, speeds and debris
	 - tier 2 (far or crowded) keeps one or two particle layers, no debris,
	   lights or marks

	Recipes.Impact(surface, context)
]]

local Debris = require(script.Parent.Debris)
local Emitters = require(script.Parent.Emitters)
local Util = require(script.Parent.Util)

local Recipes = {}

export type Context = {
	Kind: string, -- "world" | "entity" | "bounce" | "detonate" | "scrape" | ...
	Strength: number,
	Velocity: Vector3?,
	Color: Color3?, -- the shot's own colour, for energy layers
	Tier: number, -- 1 full, 2 reduced
	TimeScale: number,
}

local WARM = Color3.fromRGB(255, 170, 70)
local HOT_MARK = Color3.fromRGB(255, 120, 40)

local function darker(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(0, 0, 0), amount)
end
local function lighter(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(1, 1, 1), amount)
end

function Recipes.Impact(surface: any, context: Context)
	local s = math.clamp(context.Strength, 0.1, 3)
	local full = context.Tier == 1
	local reduce = if full then 1 else 0.45
	local ts = context.TimeScale
	local n: Vector3 = surface.Normal
	local position: Vector3 = surface.Position + n * 0.08
	local color: Color3 = surface.Color
	local tint = context.Color
	local kind = context.Kind
	local speedScale = math.clamp(0.7 + 0.3 * s, 0.6, 1.8)

	-- spray direction: the ricochet, leaning on the normal
	local spray = n
	local incoming = context.Velocity
	if incoming and incoming.Magnitude > 1 then
		local d = incoming.Unit
		local reflected = d - n * 2 * d:Dot(n)
		spray = Util.Unit(reflected * 0.65 + n * 0.35, n)
	end
	if kind == "scrape" and incoming and incoming.Magnitude > 1 then
		spray = Util.Unit(incoming.Unit * 0.7 + n * 0.3, n)
	end
	local up = Util.Upright(position, n)
	local aimed = Util.Upright(position, spray)

	local function emit(layer: string, count: number, layerColor: Color3?, frame: CFrame?, speed: number?)
		Emitters.Emit(layer, frame or up, count * reduce, layerColor, ts, speed or speedScale)
	end

	if surface.Underwater then
		emit("Bubbles", 10 * s)
		emit("Murk", 2 * s, darker(color, 0.2))
		if full and surface.Family ~= "Air" and kind ~= "scrape" then
			Debris.Throw({ Position = surface.Position, Normal = n, Count = 1.5 * s, Size = 0.25, Speed = 8,
				Color = color, Material = surface.Material, Life = 2 })
		end
		return
	end

	local family = surface.Family
	local orientation = surface.Orientation
	local dustLayer = if orientation == "Ceiling" then "DustFall" else "Dust"
	local scrape = kind == "scrape"
	local heavy = kind == "world" or kind == "detonate"

	if family == "Air" or family == "Flesh" or family == "Energy" then
		local glow = tint or (if family == "Energy" then color else WARM)
		emit("Pulse", 1, glow)
		emit("Streaks", (if scrape then 4 else 9) * s, glow, aimed)
		if full and not scrape and family ~= "Flesh" then
			Debris.Flash(position, glow, 6 + 4 * s, 1.5)
		end
		return
	end

	if family == "Metal" then
		emit("Sparks", (if scrape then 7 else 16) * s, WARM, aimed)
		if s > 0.8 and not scrape then
			emit("Embers", 4 * s, WARM, aimed)
		end
		emit(dustLayer, 1 * s, lighter(color, 0.2))
		if full and not scrape then
			Debris.Flash(position, WARM, 5 + 3 * s, 1.2)
			if heavy and s >= 0.7 then
				Debris.Mark(surface.Position, n, 0.25 + 0.2 * s, darker(color, 0.55), HOT_MARK, 5)
			end
		end
	elseif family == "Stone" then
		emit(dustLayer, 4 * s, lighter(color, 0.15))
		emit("Grit", (if scrape then 4 else 8) * s, color, aimed)
		if scrape or s > 0.6 then
			emit("Sparks", (if scrape then 5 else 4) * s, WARM, aimed)
		end
		if full and not scrape then
			Debris.Throw({ Position = surface.Position, Normal = n, Direction = spray, Count = 2.5 * s,
				Size = 0.22 * math.sqrt(s), Speed = 22 * speedScale, Color = color, Material = surface.Material })
			if heavy and s >= 0.9 then
				Debris.Mark(surface.Position, n, 0.3 + 0.25 * s, darker(color, 0.6))
			end
		end
	elseif family == "Wood" then
		emit(dustLayer, 3 * s, lighter(color, 0.3))
		emit("Grit", 4 * s, color, aimed)
		if full and not scrape then
			Debris.Throw({ Position = surface.Position, Normal = n, Direction = spray, Count = 3 * s,
				Size = 0.16 * math.sqrt(s), Shape = "Splinter", Speed = 20 * speedScale, Color = color,
				Material = surface.Material, Spread = 0.8 })
			if heavy and s >= 0.9 then
				Debris.Mark(surface.Position, n, 0.25 + 0.2 * s, darker(color, 0.7))
			end
		end
	elseif family == "Earth" then
		emit(dustLayer, 5 * s, lighter(color, 0.1))
		emit("Grit", (if scrape then 6 else 12) * s, color, Util.Upright(position, Util.Unit(spray + n, n)))
		if full and not scrape then
			Debris.Throw({ Position = surface.Position, Normal = n, Direction = n, Count = 2 * s,
				Size = 0.25 * math.sqrt(s), Speed = 18 * speedScale, Color = darker(color, 0.1), Material = surface.Material })
		end
	elseif family == "Powder" then
		emit(dustLayer, 7 * s, lighter(color, 0.2))
		emit("Grit", 14 * s, color, Util.Upright(position, Util.Unit(spray + n, n)))
	elseif family == "Glass" then
		emit("Glint", 12 * s, lighter(color, 0.5), aimed)
		emit(dustLayer, 1 * s, lighter(color, 0.4))
		if full and not scrape then
			Debris.Throw({ Position = surface.Position, Normal = n, Direction = spray, Count = 3 * s,
				Size = 0.3 * math.sqrt(s), Shape = "Shard", Speed = 18 * speedScale, Color = color })
		end
	elseif family == "Water" then
		-- a column straight up off the surface, whatever the angle of attack
		local column = Util.Upright(position, Util.Unit(n + Vector3.yAxis, Vector3.yAxis))
		emit("Splash", (if scrape then 6 else 16) * s, color, column, speedScale * (if scrape then 0.6 else 1))
		emit("Mist", 3 * s, color, column)
	elseif family == "Fabric" then
		emit("Fibers", 10 * s, color, aimed)
		emit(dustLayer, 1.5 * s, lighter(color, 0.3))
	else -- Plastic and anything unknown
		emit("Grit", 6 * s, color, aimed)
		emit(dustLayer, 2 * s, lighter(color, 0.3))
		if scrape or s > 0.8 then
			emit("Sparks", 3 * s, WARM, aimed)
		end
		if full and not scrape and s >= 0.8 then
			Debris.Throw({ Position = surface.Position, Normal = n, Direction = spray, Count = 1.5 * s,
				Size = 0.18, Speed = 20 * speedScale, Color = color, Material = surface.Material })
		end
	end

	-- an energy shot leaves a little of its own colour behind
	if tint and not scrape then
		emit("Streaks", 4 * s, tint, aimed)
		if full and heavy then
			Debris.Flash(position, tint, 5 + 3 * s, 1)
		end
	end
end

-- Extra, surface-aware layers on top of an ExplosionVFX blast.
function Recipes.Explosion(surface: any, radius: number, timeScale: number, full: boolean)
	local scale = math.clamp(radius / 8, 0.5, 6)
	local reduce = if full then 1 else 0.4
	local up = Util.Upright(surface.Position + surface.Normal * 0.2, surface.Normal)
	local speed = math.clamp(scale, 0.8, 3)
	if surface.Underwater then
		Emitters.Emit("Bubbles", up, 40 * scale * reduce, nil, timeScale, speed)
		Emitters.Emit("Murk", up, 10 * scale * reduce, darker(surface.Color, 0.2), timeScale, speed)
		return
	end
	local family = surface.Family
	if family == "Water" then
		local column = Util.Upright(surface.Position, Vector3.yAxis)
		Emitters.Emit("Splash", column, 60 * scale * reduce, surface.Color, timeScale, speed * 1.4)
		Emitters.Emit("Mist", column, 14 * scale * reduce, surface.Color, timeScale, speed)
	elseif family == "Powder" or family == "Earth" then
		Emitters.Emit("Dust", up, 18 * scale * reduce, lighter(surface.Color, 0.15), timeScale, speed)
		Emitters.Emit("Grit", up, 30 * scale * reduce, surface.Color, timeScale, speed)
	elseif family == "Glass" then
		Emitters.Emit("Glint", up, 30 * scale * reduce, lighter(surface.Color, 0.5), timeScale, speed)
		if full then
			Debris.Throw({ Position = surface.Position, Normal = surface.Normal, Count = 6 * math.min(scale, 3),
				Size = 0.4, Shape = "Shard", Speed = 30, Color = surface.Color })
		end
	elseif family == "Metal" then
		Emitters.Emit("Sparks", up, 30 * scale * reduce, WARM, timeScale, speed)
	elseif family == "Wood" and full then
		Debris.Throw({ Position = surface.Position, Normal = surface.Normal, Count = 6 * math.min(scale, 3),
			Size = 0.3, Shape = "Splinter", Speed = 35, Color = surface.Color, Material = surface.Material })
	end
end

return Recipes
