--!strict
--[[
	The Encyclopedia: elements and premade spells, to be sold later. Each
	entry has a Price; Price 0 entries are free and owned by everyone. Paid
	ones need a purchase first -- not available yet (server/SpellService
	"Purchase" says so), so for now only free ones can be equipped.

	Premade spells are built here from a short recipe (element, vessel,
	modifiers) into a normal spell graph, so they cast, preview and appear on
	the hotbar exactly like player-made ones. A loadout refers to one as
	"e:<Id>" (player spells are "c:<id>").
]]

local SpellCompiler = require(script.Parent:WaitForChild("SpellCompiler"))
local SpellRunes = require(script.Parent:WaitForChild("SpellRunes"))

export type Element = { Id: string, Name: string, Description: string, Price: number }
export type Spell = {
	Id: string,
	Name: string,
	Element: string,
	Description: string,
	Price: number,
	Graph: any, -- a normal spell graph
	Record: { name: string, graph: any, encyclopedia: string }, -- (stable, for caches)
}

local Encyclopedia = {}

Encyclopedia.Elements = {
	{ Id = "Fire", Name = "Fire", Description = "Burns what it hits.", Price = 0 },
	{ Id = "Arcane", Name = "Arcane", Description = "Raw magic.", Price = 0 },
	{ Id = "Shock", Name = "Shock", Description = "Stuns what it hits.", Price = 0 },
} :: { Element }

-- A Mana -> element -> vessel circle with modifiers, laid out like the
-- editor's default graph.
local function recipe(name: string, element: string, vessel: string, mana: number, mods: { { any } }): any
	local graph = {
		version = SpellCompiler.GraphVersion,
		name = name,
		zones = {
			{ id = "zone_input", kind = "Input", x = 0, y = 0, w = 260, h = 200 },
			{ id = "zone_transform", kind = "Transform", x = 320, y = 0, w = 260, h = 200 },
			{ id = "zone_modifier", kind = "Modifier", x = 320, y = 260, w = 260, h = 120 + 80 * math.max(#mods, 1) },
			{ id = "zone_output", kind = "Output", x = 640, y = 0, w = 280, h = 260 },
		},
		runes = {
			{ id = "mana", rune = "Mana", x = 42, y = 60, params = { Amount = mana } },
			{ id = "element", rune = element, x = 362, y = 60, params = {} },
			{ id = "vessel", rune = vessel, x = 692, y = 60, params = {} },
		},
		wires = {
			{ from = "mana", fromPort = "out", to = "element", toPort = "in" },
			{ from = "element", fromPort = "out", to = "vessel", toPort = "in" },
		},
	}
	for index, mod in mods do
		local id = `mod{index}`
		local params = SpellRunes.DefaultParams(mod[1])
		for key, value in (mod[2] or {}) :: any do
			params[key] = value
		end
		table.insert(graph.runes, { id = id, rune = mod[1], x = 362, y = 300 + (index - 1) * 80, params = params })
		table.insert(graph.wires, { from = id, fromPort = "mod", to = "vessel", toPort = "mods" })
	end
	return graph
end

-- A hand-laid circle: `columns` left to right, each a list of runes { id,
-- rune, params? } stacked top to bottom; every run of runes sharing a zone
-- kind in a column gets one zone around it. `wires` are { from, port, to,
-- port }.
local COLUMN_WIDTH = 236
local GAP = 26
local function circle(name: string, columns: { { { any } } }, wires: { { string } }): any
	local graph = { version = SpellCompiler.GraphVersion, name = name, zones = {}, runes = {}, wires = {} }
	local zoneCount = 0
	for columnIndex, column in columns do
		local x = (columnIndex - 1) * COLUMN_WIDTH
		local y = 0
		local zone: any = nil
		for _, spec in column do
			local runeId = spec[2]
			local def = SpellRunes.Runes[runeId]
			local kind = def.Zones[1]
			local height = SpellCompiler.RuneHeight(runeId)
			if not zone or zone.kind ~= kind then
				if zone then
					y += GAP
				end
				zoneCount += 1
				zone = { id = `zone{zoneCount}`, kind = kind, x = x, y = y, w = COLUMN_WIDTH - 24, h = 0 }
				table.insert(graph.zones, zone)
				y += 40
			end
			local params = SpellRunes.DefaultParams(runeId)
			for key, value in (spec[3] or {}) :: any do
				params[key] = value
			end
			table.insert(graph.runes, { id = spec[1], rune = runeId, x = x + 20, y = y, params = params })
			y += height + 16
			zone.h = y - zone.y
		end
	end
	for _, wire in wires do
		table.insert(graph.wires, { from = wire[1], fromPort = wire[2], to = wire[3], toPort = wire[4] })
	end
	return graph
end

local spells: { Spell } = {}
local byId: { [string]: Spell } = {}

local function add(id: string, name: string, element: string, description: string, price: number, graph: any)
	local spell: Spell = {
		Id = id,
		Name = name,
		Element = element,
		Description = description,
		Price = price,
		Graph = graph,
		Record = { name = name, graph = graph, encyclopedia = id },
	}
	table.insert(spells, spell)
	byId[id] = spell
end

add("FireBolt", "Fire Bolt", "Fire", "A quick bolt of fire.", 0,
	recipe("Fire Bolt", "Fire", "Bullet", 40, { { "Speed" } }))
add("Fireball", "Fireball", "Fire", "A slow orb that bursts into flame.", 0,
	recipe("Fireball", "Fire", "Orb", 80, { { "Size" } }))
add("ArcaneMissiles", "Arcane Missiles", "Arcane", "A fan of seeking missiles.", 0,
	recipe("Arcane Missiles", "Arcane", "Bullet", 90, { { "Homing" }, { "Quantity", { Count = 3 } } }))
add("ArcaneLance", "Arcane Lance", "Arcane", "Pierces through whatever is in the way.", 0,
	recipe("Arcane Lance", "Arcane", "Bullet", 70, { { "Pierce" }, { "Speed" } }))
add("ShockBeam", "Shock Beam", "Shock", "A beam that stuns.", 0,
	recipe("Shock Beam", "Shock", "Beam", 120, {}))
add("ShockBurst", "Shock Burst", "Shock", "An explosion of lightning around the target.", 0,
	recipe("Shock Burst", "Shock", "Explosion", 150, {}))

-- Utility: movement, barriers and body magic -------------------------------
add("ArcaneWall", "Arcane Wall", "Utility", "A wall of force where you aim. Your own magic passes through it.", 0,
	circle("Arcane Wall", {
		{ { "mana", "Mana", { Amount = 60 } } },
		{ { "arcane", "Arcane" } },
		{ { "wall", "Barrier", { Shape = "Wall", Duration = 8 } } },
	}, {
		{ "mana", "out", "arcane", "in" },
		{ "arcane", "out", "wall", "in" },
	}))
add("Bastion", "Bastion", "Utility", "A dome over the spot you aim at.", 0,
	circle("Bastion", {
		{ { "mana", "Mana", { Amount = 120 } } },
		{ { "wall", "Barrier", { Shape = "Dome", Duration = 8 } } },
	}, {
		{ "mana", "out", "wall", "in" },
	}))
add("Blink", "Blink", "Utility", "Teleport toward your mouse, stopping short of walls.", 0,
	circle("Blink", {
		{ { "mana", "Mana", { Amount = 50 } } },
		{ { "blink", "Blink" } },
	}, {
		{ "mana", "out", "blink", "in" },
	}))
add("Dash", "Dash", "Utility", "Throws you the way you're aiming.", 0,
	circle("Dash", {
		{ { "mana", "Mana", { Amount = 36 } } },
		{ { "dash", "Force", { Mode = "Along" } } },
	}, {
		{ "mana", "out", "dash", "in" },
	}))
add("Mend", "Mend", "Utility", "Heals you.", 0,
	circle("Mend", {
		{ { "mana", "Mana", { Amount = 80 } } },
		{ { "heal", "Effect", { Effect = "Heal" } } },
	}, {
		{ "mana", "out", "heal", "in" },
	}))
add("Haste", "Haste", "Utility", "You run faster for a while.", 0,
	circle("Haste", {
		{ { "mana", "Mana", { Amount = 60 } } },
		{ { "haste", "Effect", { Effect = "Haste", Duration = 8 } } },
	}, {
		{ "mana", "out", "haste", "in" },
	}))
add("StasisField", "Stasis Field", "Utility", "A bubble of slow time where you aim: everything inside crawls.", 0,
	circle("Stasis Field", {
		{ { "mana", "Mana", { Amount = 100 } } },
		{ { "field", "TimeField", { Scale = 0.2, Duration = 5 } } },
	}, {
		{ "mana", "out", "field", "in" },
	}))
add("Repulse", "Repulse", "Shock", "Blasts everything around you away, limp.", 0,
	circle("Repulse", {
		{ { "mana", "Mana", { Amount = 70 } } },
		{ { "shock", "Shock" } },
		{ { "push", "Force", { Mode = "Push", Radius = 16, Ragdoll = true } } },
	}, {
		{ "mana", "out", "shock", "in" },
		{ "shock", "out", "push", "in" },
	}))

-- Combos: circles that compose ------------------------------------------------
-- A bullet that, where it lands, scans for enemies; if any are there it
-- conjures a circle in the air above the impact and fires a bolt at each.
add("HuntersSigil", "Hunter's Sigil", "Combo", "A bullet that scans where it lands; if enemies are near, a circle opens above the impact and fires at each of them.", 0,
	circle("Hunter's Sigil", {
		{ { "mana", "Mana", { Amount = 140 } } },
		{ { "arcane", "Arcane" } },
		{ { "bullet", "Bullet" } },
		{ { "impact", "OnImpact", { Share = 75 } } },
		{ { "scan", "Scan", { Radius = 35, Filter = "Hostile", Max = 6 } }, { "any", "Compare", { Op = ">", B = 0 } } },
		{ { "if", "If" }, { "sigil", "Conjure", { Height = 15, Delay = 0.6 } }, { "each", "ForEach", { Max = 6, Interval = 0.08 } } },
		{ { "bolt", "Bullet" }, { "speed", "Speed", { Level = 2 } } },
	}, {
		{ "mana", "out", "arcane", "in" },
		{ "arcane", "out", "bullet", "in" },
		{ "bullet", "vessel", "impact", "vessel" },
		{ "impact", "point", "scan", "from" },
		{ "scan", "count", "any", "a" },
		{ "impact", "out", "if", "in" },
		{ "any", "value", "if", "cond" },
		{ "if", "yes", "sigil", "in" },
		{ "impact", "point", "sigil", "at" },
		{ "sigil", "out", "each", "in" },
		{ "scan", "list", "each", "list" },
		{ "each", "each", "bolt", "in" },
		{ "speed", "mod", "bolt", "mods" },
	}))
-- A circle opens high over the cursor and rains a ring of fireballs on it.
add("Starfall", "Starfall", "Combo", "A circle opens high above your mouse and rains fire down on the spot.", 0,
	circle("Starfall", {
		{ { "mana", "Mana", { Amount = 160 } } },
		{ { "fire", "Fire" } },
		{ { "cursor", "Cursor" } },
		{ { "sky", "Conjure", { Height = 28, Delay = 0.8, Size = 1.6 } }, { "rain", "Repeat", { Count = 4, Interval = 0.25 } } },
		{ { "orb", "Orb" }, { "ring", "Quantity", { Count = 5, Pattern = "Ring", Spread = 30 } }, { "size", "Size", { Level = 1 } } },
	}, {
		{ "mana", "out", "fire", "in" },
		{ "fire", "out", "sky", "in" },
		{ "cursor", "point", "sky", "at" },
		{ "sky", "out", "rain", "in" },
		{ "rain", "each", "orb", "in" },
		{ "ring", "mod", "orb", "mods" },
		{ "size", "mod", "orb", "mods" },
	}))
-- A mine: a circle on the ground that waits for an enemy, then erupts.
add("Snare", "Snare", "Combo", "Plants a circle on the ground at your mouse. When an enemy steps near, it erupts and roots them.", 0,
	circle("Snare", {
		{ { "mana", "Mana", { Amount = 120 } } },
		{ { "shock", "Shock" } },
		{ { "cursor", "Cursor" }, { "near", "Nearest", { Radius = 8, Filter = "Hostile" } }, { "there", "Exists" } },
		{ { "plant", "Conjure", { Height = 0.5, Delay = 0.5 } }, { "wait", "Await", { Timeout = 20, Every = 0.1 } }, { "split", "Divide", { Share = 60 } } },
		{ { "boom", "Explosion" }, { "root", "Effect", { Effect = "Root", Duration = 2 } } },
	}, {
		{ "mana", "out", "shock", "in" },
		{ "shock", "out", "plant", "in" },
		{ "cursor", "point", "plant", "at" },
		{ "plant", "out", "wait", "in" },
		{ "near", "entity", "there", "entity" },
		{ "there", "value", "wait", "cond" },
		{ "wait", "then", "split", "in" },
		{ "split", "a", "boom", "in" },
		{ "split", "b", "root", "in" },
		{ "near", "entity", "root", "target" },
	}))
-- Blink to the cursor, leaving an explosion where you were.
add("Phase", "Phase Step", "Combo", "Blinks you toward your mouse and blasts the spot you left.", 0,
	circle("Phase Step", {
		{ { "mana", "Mana", { Amount = 110 } } },
		{ { "split", "Divide", { Share = 40 } } },
		{ { "arcane", "Arcane" } },
		{ { "caster", "Caster" } },
		{ { "blink", "Blink" }, { "boom", "Explosion" } },
	}, {
		{ "mana", "out", "split", "in" },
		{ "split", "a", "arcane", "in" },
		{ "arcane", "out", "boom", "in" },
		{ "caster", "entity", "boom", "aim" },
		{ "split", "b", "blink", "in" },
	}))

Encyclopedia.Spells = spells

function Encyclopedia.Get(id: string): Spell?
	return byId[id]
end

-- Usable by a player who owns `owned` (purchased ids): free, or bought.
function Encyclopedia.IsOwned(id: string, owned: { [string]: boolean }?): boolean
	local spell = byId[id]
	if not spell then
		return false
	end
	return spell.Price <= 0 or (owned ~= nil and owned[id] == true)
end

return Encyclopedia
