--!strict
--[[
	SpellCircleLayout.luau
	Turns a compiled spell (SpellCompiler.Compile) into the description of
	the magic circle(s) drawn when it is cast. Pure data, shared so the server
	can broadcast a spec and the caster's own client can build the identical
	one locally (same graph -> same spec, same seeds) for zero-latency
	feedback. client/SpellCircleVFX renders it.

	One circle per vessel reached straight from a Mana Well, ordered by flow;
	vessels fired by triggers become satellites on their parent's rim.
	Anatomy, centre outward:
	 - Core: the element glyph (Fire / Arcane / Shock).
	 - Polygon: a star whose shape follows the vessel and whose point count
	   is 3 + modifiers.
	 - Modifier ring: one node per modifier glyph, with its Level.
	 - Script band: the glyphs of every sensor/logic/targeting rune feeding
	   the vessel, plus the Mana Well and any If / Divide on the way.
	 - Outer ring: the mana cost in Roman numerals.
	 - Satellites: one per trigger, holding what it fires (recursively).
]]

local SpellRunes = require(script.Parent:WaitForChild("SpellRunes"))

local SpellCircleLayout = {}

export type Mod = { Glyph: string, Level: number? }

export type Satellite = {
	Glyph: string,
	Circles: { CircleSpec },
}

export type CircleSpec = {
	Vessel: string,
	VesselGlyph: string,
	Element: string,
	ElementGlyph: string,
	Color: Color3,
	Core: Color3,
	Scale: number, -- radius multiplier from this vessel's share of the mana
	Points: number,
	Mods: { Mod },
	Band: { string },
	Quantity: { Count: number, Pattern: string, Spread: number }?,
	Satellites: { Satellite },
	Seed: number,
}

export type Spec = {
	Seed: number,
	ManaCost: number,
	Numeral: string,
	Sustain: number, -- longest Sustain in seconds (0 = not a channel)
	Circles: { CircleSpec },
}

local MIN_SCALE = 0.55
local MAX_POINTS = 9
local VALUE_CATEGORIES = { Sensor = true, Logic = true, Targeting = true }

local NUMERALS = {
	{ 1000, "M" }, { 900, "CM" }, { 500, "D" }, { 400, "CD" },
	{ 100, "C" }, { 90, "XC" }, { 50, "L" }, { 40, "XL" },
	{ 10, "X" }, { 9, "IX" }, { 5, "V" }, { 4, "IV" }, { 1, "I" },
}

-- Standard subtractive Roman numerals; past 3999 the M's just repeat.
function SpellCircleLayout.Roman(value: number): string
	local n = math.floor(value + 0.5)
	if n <= 0 then
		return "N" -- nulla
	end
	local parts = {}
	for _, pair in NUMERALS do
		while n >= pair[1] do
			table.insert(parts, pair[2])
			n -= pair[1]
		end
	end
	return table.concat(parts)
end

-- Small deterministic string hash (fits in a double without precision loss).
local function hash(text: string, seed: number?): number
	local h = seed or 7
	for i = 1, #text do
		h = (h * 31 + string.byte(text, i)) % 2147483647
	end
	return h
end

local function serialize(value: any): string
	if typeof(value) ~= "table" then
		return tostring(value)
	end
	local keys = {}
	for key in value do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)
	local parts = {}
	for _, key in keys do
		table.insert(parts, key .. "=" .. serialize(value[key]))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function glyphOf(runeId: string): string?
	local def = SpellRunes.Runes[runeId]
	return def and def.Glyph
end

function SpellCircleLayout.Build(compiled: any): Spec
	local runes = compiled.runes
	local ids = {}
	for id in runes do
		table.insert(ids, id)
	end
	table.sort(ids)
	local seedText = {}
	for _, id in ids do
		table.insert(seedText, id .. ":" .. runes[id].rune .. serialize(runes[id].params))
	end
	local seed = hash(table.concat(seedText, ";"))
	local manaCost = compiled.manaCost or 0
	local sustain = 0

	-- Glyphs of the value runes feeding `id` (not through flow/mod/vessel
	-- wires), depth first in port order, each once.
	local function collectValues(id: string, seen: { [string]: boolean }, out: { string })
		local def = SpellRunes.Runes[runes[id].rune]
		for _, port in def.Inputs do
			if port.Type == "flow" or port.Type == "mod" or port.Type == "vessel" then
				continue
			end
			for _, link in (compiled.inputs[id] and compiled.inputs[id][port.Name]) or {} do
				if seen[link.from] then
					continue
				end
				seen[link.from] = true
				local source = runes[link.from]
				local sourceDef = SpellRunes.Runes[source.rune]
				if VALUE_CATEGORIES[sourceDef.Category] then
					collectValues(link.from, seen, out)
					if sourceDef.Glyph then
						table.insert(out, sourceDef.Glyph)
					end
				end
			end
		end
	end

	local follow: (id: string, port: string, path: { string }, out: { CircleSpec }, depth: number) -> ()

	local function buildCircle(vesselId: string, path: { string }, depth: number): CircleSpec
		local rune = runes[vesselId]
		local def = SpellRunes.Runes[rune.rune]
		local info = compiled.vessels[vesselId] or { mods = {}, triggers = {} }
		local elementId = compiled.elements[vesselId] or "Arcane"
		local element = SpellRunes.Elements[elementId]

		local band = table.clone(path)
		local seen = {}
		collectValues(vesselId, seen, band)
		local mods: { Mod } = {}
		local quantity = nil
		for _, modId in info.mods do
			local mod = runes[modId]
			table.insert(mods, { Glyph = glyphOf(mod.rune) or "?", Level = mod.params.Level })
			collectValues(modId, seen, band)
			if mod.rune == "Quantity" then
				quantity = { Count = mod.params.Count, Pattern = mod.params.Pattern, Spread = mod.params.Spread }
			elseif mod.rune == "Sustain" then
				sustain = math.max(sustain, SpellRunes.ModifierTables.Sustain[mod.params.Level] or 0)
			end
		end

		local satellites: { Satellite } = {}
		for _, triggerId in info.triggers do
			local children: { CircleSpec } = {}
			follow(triggerId, "out", {}, children, depth + 1)
			table.insert(satellites, { Glyph = glyphOf(runes[triggerId].rune) or "?", Circles = children })
		end

		local estimate = compiled.estimates[vesselId]
		local share = if estimate and estimate.energy and manaCost > 0 then estimate.energy / manaCost else 1
		return {
			Vessel = def.Id,
			VesselGlyph = def.Glyph or "?",
			Element = elementId,
			ElementGlyph = glyphOf(elementId) or "?",
			Color = element.Color,
			Core = element.Core,
			Scale = math.clamp(math.sqrt(share), MIN_SCALE, 1),
			Points = if def.Id == "Explosion" then 8 else math.clamp(3 + #mods, 3, MAX_POINTS),
			Mods = mods,
			Band = band,
			Quantity = quantity,
			Satellites = satellites,
			Seed = hash(vesselId, seed),
		}
	end

	-- Walks flow from (id, port) like the compiler does, collecting the
	-- branch glyphs on the way and a circle for each vessel reached.
	function follow(id: string, port: string, path: { string }, out: { CircleSpec }, depth: number)
		local outputs = compiled.outputs[id]
		for _, link in (outputs and outputs[port]) or {} do
			local rune = runes[link.to]
			local def = SpellRunes.Runes[rune.rune]
			if def.Element then
				follow(link.to, "out", path, out, depth)
			elseif def.Id == "If" then
				local branchPath = table.clone(path)
				table.insert(branchPath, def.Glyph or "?")
				collectValues(link.to, {}, branchPath)
				follow(link.to, "yes", branchPath, out, depth)
				follow(link.to, "no", branchPath, out, depth)
			elseif def.Id == "Divide" then
				local branchPath = table.clone(path)
				table.insert(branchPath, def.Glyph or "?")
				follow(link.to, "a", branchPath, out, depth)
				follow(link.to, "b", branchPath, out, depth)
			elseif def.Vessel then
				table.insert(out, buildCircle(link.to, path, depth))
			end
		end
	end

	local circles: { CircleSpec } = {}
	for _, rootId in compiled.manaRoots do
		follow(rootId, "out", { glyphOf("Mana") or "?" }, circles, 0)
	end

	return {
		Seed = seed,
		ManaCost = manaCost,
		Numeral = SpellCircleLayout.Roman(manaCost),
		Sustain = sustain,
		Circles = circles,
	}
end

return SpellCircleLayout
