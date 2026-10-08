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
	-- (groups, not elements: magic that moves, guards and mends; and circles
	-- built from several parts)
	{ Id = "Utility", Name = "Utility", Description = "Barriers, movement and body magic.", Price = 0 },
	{ Id = "Combo", Name = "Combos", Description = "Circles that compose: conjured circles, traps, chains.", Price = 0 },
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
			{ id = "zone_modifier", kind = "Modifier", x = 320, y = 260, w = 260, h = 120 },
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
	local y = 300
	for index, mod in mods do
		local id = `mod{index}`
		local params = SpellRunes.DefaultParams(mod[1])
		for key, value in (mod[2] or {}) :: any do
			params[key] = value
		end
		table.insert(graph.runes, { id = id, rune = mod[1], x = 362, y = y, params = params })
		table.insert(graph.wires, { from = id, fromPort = "mod", to = "vessel", toPort = "mods" })
		y += SpellCompiler.RuneHeight(mod[1]) + 16
	end
	graph.zones[3].h = math.max(y - 260 + 20, 120)
	return graph
end

-- A hand-laid circle: `columns` left to right, each a list of runes { id,
-- rune, params? } stacked top to bottom; every run of runes sharing a zone
-- kind in a column gets one zone around it. `wires` are { from, port, to,
-- port }.
local COLUMN_WIDTH = 260
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
	recipe("Fire Bolt", "Fire", "Bullet", 40, { { "Speed", { Factor = 1.6 } } }))
add("Fireball", "Fireball", "Fire", "A slow orb that bursts into flame.", 0,
	recipe("Fireball", "Fire", "Orb", 80, { { "Size", { Factor = 1.4 } } }))
add("ArcaneMissiles", "Arcane Missiles", "Arcane", "A fan of seeking missiles.", 0,
	recipe("Arcane Missiles", "Arcane", "Bullet", 90, { { "Homing" }, { "Quantity", { Count = 3 } } }))
add("ArcaneLance", "Arcane Lance", "Arcane", "Pierces through whatever is in the way.", 0,
	recipe("Arcane Lance", "Arcane", "Bullet", 70, { { "Pierce", { Count = 1 } }, { "Speed", { Factor = 1.6 } } }))
add("ShockBeam", "Shock Beam", "Shock", "A beam that stuns.", 0,
	recipe("Shock Beam", "Shock", "Beam", 120, {}))
add("ShockBurst", "Shock Burst", "Shock", "An explosion of lightning where you aim.", 0,
	circle("Shock Burst", {
		{ { "mana", "Mana", { Amount = 150 } } },
		{ { "shock", "Shock" } },
		{ { "burst", "Explosion", { Radius = 9 } } },
	}, {
		{ "mana", "out", "shock", "in" },
		{ "shock", "out", "burst", "in" },
	}))
-- The enemy nearest your mouse, struck instantly.
add("Smite", "Smite", "Shock", "Lightning strikes the enemy nearest your mouse -- no flight, no dodging.", 0,
	circle("Smite", {
		{ { "mana", "Mana", { Amount = 50 } } },
		{ { "shock", "Shock" } },
		{ { "cursor", "Cursor" }, { "near", "Nearest", { Radius = 12, Filter = "Hostile" } } },
		{ { "smite", "Smite", { Range = 90 } } },
	}, {
		{ "mana", "out", "shock", "in" },
		{ "shock", "out", "smite", "in" },
		{ "cursor", "point", "near", "from" },
		{ "near", "entity", "smite", "target" },
	}))
-- Pick (a per-item score): whoever around you is lowest on health.
add("Execute", "Execute", "Arcane", "Strikes whichever enemy around you is lowest on health (as a share of their maximum).", 0,
	circle("Execute", {
		{ { "mana", "Mana", { Amount = 70 } } },
		{ { "arcane", "Arcane" } },
		{ { "scan", "Scan", { Radius = 45, Filter = "Hostile", Max = 24 } }, { "hp", "Health", { Mode = "Percent" } }, { "pick", "Pick", { Mode = "Lowest" } } },
		{ { "smite", "Smite", { Range = 50, Sight = false } } },
	}, {
		{ "mana", "out", "arcane", "in" },
		{ "arcane", "out", "smite", "in" },
		{ "scan", "list", "pick", "list" },
		{ "pick", "item", "hp", "entity" },
		{ "hp", "value", "pick", "key" },
		{ "pick", "entity", "smite", "target" },
	}))

-- Utility: movement, barriers and body magic -------------------------------
-- Locate: 12 studs in front of you, on the ground.
add("ArcaneWall", "Arcane Wall", "Utility", "A 14 × 8 wall 12 studs in front of you. You and your party walk through it; enemy magic doesn't.", 0,
	circle("Arcane Wall", {
		{ { "mana", "Mana", { Amount = 45 } } },
		{ { "front", "Locate", { Basis = "Level aim", Forward = 12, Ground = true } } },
		{ { "wall", "Barrier", { Shape = "Box", Width = 14, Height = 8, Depth = 1, Health = 150, Duration = 8 } } },
	}, {
		{ "mana", "out", "wall", "in" },
		{ "front", "point", "wall", "aim" },
	}))
-- Follow: a dome that moves with you.
add("Bastion", "Bastion", "Utility", "A dome around you that moves with you: your party passes freely, hostile magic breaks on it.", 0,
	circle("Bastion", {
		{ { "mana", "Mana", { Amount = 90 } } },
		{ { "you", "Caster" } },
		{ { "dome", "Barrier", { Shape = "Dome", Width = 16, Height = 8, Depth = 0.6, Health = 300, Duration = 8 } } },
	}, {
		{ "mana", "out", "dome", "in" },
		{ "you", "entity", "dome", "aim" },
		{ "you", "entity", "dome", "follow" },
	}))
add("Skystep", "Skystep", "Utility", "A small platform just ahead of and below you -- cast it mid-jump to climb.", 0,
	circle("Skystep", {
		{ { "mana", "Mana", { Amount = 20 } } },
		{ { "step", "Locate", { Basis = "Level aim", Forward = 4, Up = -3.6 } } },
		{ { "platform", "Barrier", { Shape = "Box", Width = 8, Height = 1, Depth = 8, Health = 60, Duration = 5, Anchor = "Top", Ground = false } } },
	}, {
		{ "mana", "out", "platform", "in" },
		{ "step", "point", "platform", "aim" },
	}))
-- Tilt: a ramp rising away from you.
add("Ramp", "Ramp", "Utility", "A ramp rising from your feet the way you're facing.", 0,
	circle("Ramp", {
		{ { "mana", "Mana", { Amount = 25 } } },
		{ { "start", "Locate", { Basis = "Level aim", Forward = 8, Ground = true } } },
		{ { "ramp", "Barrier", { Shape = "Box", Width = 6, Height = 1, Depth = 16, Tilt = 25, Health = 80, Duration = 6, Anchor = "Centre" } } },
	}, {
		{ "mana", "out", "ramp", "in" },
		{ "start", "point", "ramp", "aim" },
	}))
add("Blink", "Blink", "Utility", "Teleport up to 40 studs toward your mouse, stopping short of walls.", 0,
	circle("Blink", {
		{ { "mana", "Mana", { Amount = 20 } } },
		{ { "blink", "Blink", { Distance = 40 } } },
	}, {
		{ "mana", "out", "blink", "in" },
	}))
-- Force → Target: you. 110 studs/s the way you're facing.
add("Dash", "Dash", "Utility", "A force on your own body: 110 studs/s the way you're looking.", 0,
	circle("Dash", {
		{ { "mana", "Mana", { Amount = 25 } } },
		{ { "you", "Caster" }, { "aim", "Locate", { Basis = "Level aim", Forward = 1 } } },
		{ { "dash", "Force", { Mode = "Along", Speed = 110 } } },
	}, {
		{ "mana", "out", "dash", "in" },
		{ "you", "entity", "dash", "target" },
		{ "aim", "forward", "dash", "dir" },
	}))
-- Store / Delay / Recall: memory private to one cast.
add("Rewind", "Rewind", "Utility", "Remembers where you stand; 3 seconds later you blink back there.", 0,
	circle("Rewind", {
		{ { "mana", "Mana", { Amount = 60 } } },
		{ { "here", "Locate", { Basis = "Level aim", Forward = 0, Ground = true } } },
		{ { "mark", "Store", { Slot = "A", Scope = "This cast" } }, { "wait", "Delay", { Seconds = 3 } } },
		{ { "spot", "Recall", { Slot = "A", Scope = "This cast" } } },
		{ { "back", "Blink", { Distance = 150, Momentum = false } } },
	}, {
		{ "mana", "out", "mark", "in" },
		{ "here", "point", "mark", "point" },
		{ "mark", "out", "wait", "in" },
		{ "wait", "out", "back", "in" },
		{ "spot", "point", "back", "to" },
	}))
add("Mend", "Mend", "Utility", "Heals you for 60.", 0,
	circle("Mend", {
		{ { "mana", "Mana", { Amount = 40 } } },
		{ { "you", "Caster" } },
		{ { "heal", "Effect", { Effect = "Heal", Power = 60 } } },
	}, {
		{ "mana", "out", "heal", "in" },
		{ "you", "entity", "heal", "target" },
	}))
add("Haste", "Haste", "Utility", "You run 50% faster for 8 seconds.", 0,
	circle("Haste", {
		{ { "mana", "Mana", { Amount = 40 } } },
		{ { "haste", "Effect", { Effect = "Haste", Power = 50, Duration = 8 } } },
	}, {
		{ "mana", "out", "haste", "in" },
	}))
add("Float", "Float", "Utility", "Gravity lets go of you: you drift down slowly for 8 seconds.", 0,
	circle("Float", {
		{ { "mana", "Mana", { Amount = 40 } } },
		{ { "float", "Effect", { Effect = "Levitate", Duration = 8 } } },
	}, {
		{ "mana", "out", "float", "in" },
	}))
add("StasisField", "Stasis Field", "Utility", "A 10-stud bubble of slow time where you aim: everything inside crawls at 0.2× for 5 seconds.", 0,
	circle("Stasis Field", {
		{ { "mana", "Mana", { Amount = 40 } } },
		{ { "field", "TimeField", { Radius = 10, Scale = 0.2, Duration = 5 } } },
	}, {
		{ "mana", "out", "field", "in" },
	}))
add("Repulse", "Repulse", "Shock", "Blasts everything within 16 studs of you away, limp.", 0,
	circle("Repulse", {
		{ { "mana", "Mana", { Amount = 70 } } },
		{ { "shock", "Shock" } },
		{ { "push", "Force", { Mode = "Away", Speed = 90, Lift = 0.45, Radius = 16, Ragdoll = true } } },
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
		{ { "bolt", "Bullet" }, { "speed", "Speed", { Factor = 2 } } },
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
-- A circle opens high over the cursor and rains fireballs that burst where
-- they land.
add("Starfall", "Starfall", "Combo", "A circle opens high above your mouse and rains bursting fireballs down on the spot.", 0,
	circle("Starfall", {
		{ { "mana", "Mana", { Amount = 160 } } },
		{ { "fire", "Fire" } },
		{ { "cursor", "Cursor" } },
		{ { "sky", "Conjure", { Height = 28, Delay = 0.8, Size = 1.6 } }, { "rain", "Repeat", { Count = 4, Interval = 0.3 } } },
		{ { "orb", "Orb" }, { "ring", "Quantity", { Count = 4, Pattern = "Ring", Spread = 14 } } },
		{ { "impact", "OnImpact", { Share = 70 } } },
		{ { "burst", "Explosion", { Radius = 7 } } },
	}, {
		{ "mana", "out", "fire", "in" },
		{ "fire", "out", "sky", "in" },
		{ "cursor", "point", "sky", "at" },
		{ "sky", "out", "rain", "in" },
		{ "rain", "each", "orb", "in" },
		{ "ring", "mod", "orb", "mods" },
		{ "orb", "vessel", "impact", "vessel" },
		{ "impact", "out", "burst", "in" },
	}))
-- Bolts from the sky onto everyone near the cursor, one after another.
add("ChainStorm", "Chain Storm", "Combo", "Lightning falls from the sky on every enemy near your mouse, one after another.", 0,
	circle("Chain Storm", {
		{ { "mana", "Mana", { Amount = 120 } } },
		{ { "shock", "Shock" } },
		{ { "cursor", "Cursor" }, { "scan", "Scan", { Radius = 20, Filter = "Hostile", Max = 8 } } },
		{ { "each", "ForEach", { Max = 8, Interval = 0.12 } } },
		{ { "sky", "Offset", { X = 0, Y = 30, Z = 0 } } },
		{ { "smite", "Smite", { Range = 60, Sight = false } } },
	}, {
		{ "mana", "out", "shock", "in" },
		{ "shock", "out", "each", "in" },
		{ "cursor", "point", "scan", "from" },
		{ "scan", "list", "each", "list" },
		{ "each", "each", "smite", "in" },
		{ "each", "entity", "sky", "point" },
		{ "sky", "point", "smite", "from" },
	}))
-- A steady pull: Force Toward for 2 seconds, then a blast where they've gathered.
add("GravityWell", "Gravity Well", "Combo", "Drags everything near your mouse into one spot for 2 seconds, then detonates it.", 0,
	circle("Gravity Well", {
		{ { "mana", "Mana", { Amount = 130 } } },
		{ { "split", "Divide", { Share = 45 } } },
		{ { "cursor", "Cursor" } },
		{ { "pull", "Force", { Mode = "Toward", Speed = 40, Radius = 18, Duration = 2 } }, { "wait", "Delay", { Seconds = 2 } } },
		{ { "arcane", "Arcane" } },
		{ { "boom", "Explosion", { Radius = 10 } } },
	}, {
		{ "mana", "out", "split", "in" },
		{ "split", "a", "pull", "in" },
		{ "cursor", "point", "pull", "center" },
		{ "split", "b", "wait", "in" },
		{ "wait", "out", "arcane", "in" },
		{ "arcane", "out", "boom", "in" },
		{ "cursor", "point", "boom", "aim" },
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
		{ { "mana", "Mana", { Amount = 100 } } },
		{ { "split", "Divide", { Share = 60 } } },
		{ { "arcane", "Arcane" } },
		{ { "caster", "Caster" } },
		{ { "blink", "Blink", { Distance = 40 } }, { "boom", "Explosion", { Radius = 8 } } },
	}, {
		{ "mana", "out", "split", "in" },
		{ "split", "a", "arcane", "in" },
		{ "arcane", "out", "boom", "in" },
		{ "caster", "entity", "boom", "aim" },
		{ "split", "b", "blink", "in" },
	}))
-- A wall that blows up when it breaks or fades.
add("VolatileWard", "Volatile Ward", "Combo", "A wall in front of you that explodes in fire when it breaks or fades.", 0,
	circle("Volatile Ward", {
		{ { "mana", "Mana", { Amount = 100 } } },
		{ { "front", "Locate", { Basis = "Level aim", Forward = 10, Ground = true } } },
		{ { "ward", "Barrier", { Shape = "Box", Width = 12, Height = 8, Depth = 1, Health = 150, Duration = 6 } } },
		{ { "expire", "OnExpire", { Share = 50 } } },
		{ { "fire", "Fire" } },
		{ { "boom", "Explosion", { Radius = 10 } } },
	}, {
		{ "mana", "out", "ward", "in" },
		{ "front", "point", "ward", "aim" },
		{ "ward", "vessel", "expire", "vessel" },
		{ "expire", "out", "fire", "in" },
		{ "fire", "out", "boom", "in" },
	}))
-- Invoke: spells as functions.
add("Echo", "Echo", "Combo", "Opens a circle over your head that casts the spell on your hotbar slot 1 three times.", 0,
	circle("Echo", {
		{ { "mana", "Mana", { Amount = 150 } } },
		{ { "halo", "Conjure", { Height = 7, Delay = 0.5 } }, { "thrice", "Repeat", { Count = 3, Interval = 0.35 } }, { "cast", "Invoke", { Slot = 1 } } },
	}, {
		{ "mana", "out", "halo", "in" },
		{ "halo", "out", "thrice", "in" },
		{ "thrice", "each", "cast", "in" },
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
