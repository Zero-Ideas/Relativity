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
