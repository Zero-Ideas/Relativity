--!strict
--[[
	SpellRunes.luau
	The rune catalog for the spell whiteboard: zone kinds, port types,
	elements, every rune's ports/params and what magic costs. Pure data,
	shared by the editor (client), the compiler (both) and the runtime
	(server) so all three agree on what a rune is.

	Spell model
	 - Mana is energy. A Mana Well pushes its Amount along "flow" wires; every
	   cast charges the sum of all wells. Energy is conserved: a flow output
	   feeds at most one wire (use Divide to split it), If routes it one way.
	 - Flow runes (Branch zone) shape WHEN and WHERE the rest of the circle
	   runs: Delay, Repeat, For Each, Wait Until, Conjure Circle (a new circle
	   somewhere else), Store (memory), Invoke (cast another of your spells
	   from here -- a function call).
	 - Values (number / bool / entity / point / list) are computed by Sensor,
	   Logic, Vector and List runes whenever the flow that needs them runs: at
	   cast time, when a trigger fires, each Repeat round... Flow runes and
	   triggers also OUTPUT values about their moment (an impact point, a
	   Repeat's index, the entity For Each is on).
	 - EVERY number and yes/no setting is also an input port: unwired it uses
	   the value set on the rune, wired it takes the wire's value (clamped to
	   the setting's range). Params marked Fixed shape the circle itself (mana
	   amounts, trigger shares, copy counts) and stay settings.
	 - Vessels turn energy into magic. Damaging ones (Orb, Bullet, Beam,
	   Explosion, Smite) deal their energy as damage. The others say exactly
	   what they do -- a 12 x 8 wall with 150 HP for 8 s, a 90 studs/s shove,
	   +60 HP -- and the energy that reaches them pays for it (see Costs). Fed
	   less than they cost, they do proportionally less (a weaker shove, a
	   wall with less health); energy beyond the cost is wasted.
	 - List runes filter and pick from lists with a per-item condition: they
	   output Item, the entity being judged, which the condition's runes read.
	 - Every rune must sit inside a zone whose kind it allows.

	Port types
	 flow   -- mana energy (one wire out, one wire in)
	 number, bool, entity, point, list -- values (fan out freely, one wire in)
	          point is any Vector3: a position or a direction
	          list is a list of entities
	 mod    -- Modifier -> Vessel "Modifiers" (many into one)
	 vessel -- Vessel "Triggers" -> Trigger (one vessel may carry many triggers)
	 entity may be wired into a point input (it reads the entity's position)
	 or a list input (a list of one).
]]

local SpellRunes = {}

export type PortDef = {
	Name: string,
	Type: string,
	Label: string,
	Optional: boolean?,
	Multi: boolean?,
	Param: string?, -- (inputs) unwired, the input takes this param's value
	Setting: boolean?, -- (inputs) generated for a param: shows the param's value on the card
	Scoped: boolean?, -- (outputs) only has a value inside its own rune's per-item condition
}

export type ParamDef = {
	Name: string,
	Label: string,
	Type: string, -- "number" | "enum" | "bool"
	Default: any,
	Min: number?,
	Max: number?,
	Step: number?,
	Options: { string }?,
	Suffix: string?,
	Fixed: boolean?, -- never an input port (it shapes the circle at compile time)
}

export type RuneDef = {
	Id: string,
	Name: string,
	Glyph: string?, -- the rune's symbol, shown beside its name in the editor
	Category: string,
	Zones: { string },
	Description: string,
	Inputs: { PortDef },
	Outputs: { PortDef },
	Params: { ParamDef },
	Unique: boolean?,
	Element: string?,
	Vessel: boolean?, -- an Output rune that gives magic its form
	Damaging: boolean?, -- a vessel that deals damage: needs an element (Transform) upstream
	Instant: boolean?, -- a vessel with no flight
	Pass: boolean?, -- a flow rune that passes energy on (Delay, Repeat, For Each...)
	Migrate: ((params: { [string]: any }) -> ())?, -- upgrades params saved by an older editor
}

--------------------------------------------------------------------------------
-- Zones
--------------------------------------------------------------------------------

SpellRunes.ZoneKinds = { "Input", "Targeting", "Conditional", "Branch", "Transform", "Modifier", "Output", "Trigger" }

SpellRunes.Zones = {
	Input = { Color = Color3.fromRGB(80, 170, 255), Description = "Where mana enters the circle." },
	Targeting = { Color = Color3.fromRGB(90, 220, 150), Description = "Works out where things go: points, directions, entities and lists. Holds any value rune." },
	Conditional = { Color = Color3.fromRGB(255, 205, 80), Description = "Sensors, logic, vector math and lists that compute values and conditions. Any of them can feed any rune's settings." },
	Branch = { Color = Color3.fromRGB(255, 150, 70), Glyph = "Δ", Description = "Controls the flow of mana: route, split, wait, repeat, loop over entities, conjure a new circle elsewhere, remember things, or invoke another of your spells." },
	Transform = { Color = Color3.fromRGB(255, 95, 80), Description = "Converts raw mana into an element. Only damaging vessels need one." },
	Modifier = { Color = Color3.fromRGB(170, 130, 255), Description = "Shapes projectile flight, count and size, or explosion radius and placement range." },
	Output = { Color = Color3.fromRGB(255, 90, 140), Description = "Where energy leaves the circle: Vessels give the magic its form -- projectiles, blasts, smites, barriers, forces, blinks, body effects and time fields." },
	Trigger = { Color = Color3.fromRGB(80, 215, 230), Description = "Runs more of the circle while a vessel is in flight, where it lands, or when a barrier or field ends." },
}

--------------------------------------------------------------------------------
-- Types and elements
--------------------------------------------------------------------------------

SpellRunes.PortColors = {
	flow = Color3.fromRGB(255, 210, 90),
	number = Color3.fromRGB(90, 210, 255),
	bool = Color3.fromRGB(255, 120, 200),
	entity = Color3.fromRGB(255, 140, 80),
	point = Color3.fromRGB(110, 230, 140),
	list = Color3.fromRGB(230, 170, 110),
	mod = Color3.fromRGB(180, 140, 255),
	vessel = Color3.fromRGB(90, 150, 255),
}

-- Can a wire carrying `from` feed an input of type `to`?
function SpellRunes.Compatible(from: string, to: string): boolean
	return from == to or (from == "entity" and (to == "point" or to == "list"))
end

-- Impact is the share of a vessel's energy dealt as hit damage. Fire adds a
-- burn worth BurnRatio of the energy over BurnDuration; Shock stuns instead.
-- Color is the glow, Core the hot centre the client renders (see
-- ProjectileClient/VisualModel's styled visuals and client/SpellEffects).
SpellRunes.Elements = {
	Fire = { Color = Color3.fromRGB(255, 96, 28), Core = Color3.fromRGB(255, 226, 150), Impact = 0.8, BurnRatio = 0.35, BurnDuration = 3 },
	Arcane = { Color = Color3.fromRGB(150, 60, 255), Core = Color3.fromRGB(214, 160, 255), Impact = 1.0 },
	Shock = { Color = Color3.fromRGB(70, 196, 255), Core = Color3.fromRGB(226, 250, 255), Impact = 0.7, StunPerEnergy = 1 / 100, StunMax = 1 },
}
-- The look of energy that never passed a Transform (utility vessels don't
-- need one).
SpellRunes.Raw = { Color = Color3.fromRGB(150, 225, 255), Core = Color3.fromRGB(240, 252, 255), Glyph = "○" }

local FILTERS = { "Any", "Enemy", "Player" }
-- Server-evaluated filters may also ask who you can hurt: Hostile (anything
-- your magic damages) and Ally (your party).
local SCAN_FILTERS = { "Any", "Enemy", "Player", "Hostile", "Ally" }
local SLOTS = { "A", "B", "C", "D" }
local SCOPES = { "Yours", "This cast" }
local VALUE_ZONES = { "Conditional", "Targeting" }
local SPACE: ParamDef = { Name = "Space", Label = "Axes", Type = "enum", Default = "World", Options = { "World", "Facing" } }

local function flowIn(): PortDef
	return { Name = "in", Type = "flow", Label = "Energy" }
end
local function flowOut(name: string?, label: string?): PortDef
	return { Name = name or "out", Type = "flow", Label = label or "Energy" }
end
local function modOut(): PortDef
	return { Name = "mod", Type = "mod", Label = "Vessel" }
end
local function modsIn(): PortDef
	return { Name = "mods", Type = "mod", Label = "Modifiers", Optional = true, Multi = true }
end
local function vesselIn(): PortDef
	return { Name = "vessel", Type = "vessel", Label = "Vessel" }
end
local function opt(name: string, type_: string, label: string): PortDef
	return { Name = name, Type = type_, Label = label, Optional = true }
end
local function num(name: string, label: string, default: number, min: number, max: number, step: number, suffix: string?): ParamDef
	return { Name = name, Label = label, Type = "number", Default = default, Min = min, Max = max, Step = step, Suffix = suffix }
end
local function bool(name: string, label: string, default: boolean): ParamDef
	return { Name = name, Label = label, Type = "bool", Default = default }
end
local function enum(name: string, label: string, default: string, options: { string }): ParamDef
	return { Name = name, Label = label, Type = "enum", Default = default, Options = options }
end
local function fixed(param: ParamDef): ParamDef
	param.Fixed = true
	return param
end
local function share(): ParamDef
	return fixed(num("Share", "Energy share", 50, 10, 90, 5, "%"))
end

-- Older editors saved modifier strength as a Level 1..5; these are what
-- each level meant.
SpellRunes.LegacyLevels = {
	Speed = { 1.3, 1.6, 2.0, 2.5, 3.2 },
	Size = { 1.4, 1.8, 2.3, 2.9, 3.6 },
	Range = { 1.3, 1.7, 2.2, 2.8, 3.5 },
	Gravity = { 20, 40, 70, 110, 160 },
	HomingRadius = { 30, 45, 60, 80, 100 },
	HomingTurn = { 75, 105, 140, 180, 230 },
}

local function fromLevel(params: { [string]: any }, name: string, values: { number }?)
	local level = params.Level
	if typeof(level) == "number" and params[name] == nil then
		level = math.clamp(math.floor(level + 0.5), 1, 5)
		params[name] = if values then values[level] else level
	end
	params.Level = nil
end

local function projectile(id: string, name: string, glyph: string, description: string): RuneDef
	return {
		Id = id, Name = name, Glyph = glyph, Category = "Vessel", Zones = { "Output" }, Vessel = true, Damaging = true,
		Description = description,
		Inputs = {
			flowIn(),
			modsIn(),
			opt("aim", "point", "Aim"),
			opt("from", "point", "From"),
		},
		Outputs = { { Name = "vessel", Type = "vessel", Label = "Triggers" } },
		Params = {},
	}
end

--------------------------------------------------------------------------------
-- Runes
--------------------------------------------------------------------------------

local defs: { RuneDef } = {
	-- Input ---------------------------------------------------------------------
	{
		Id = "Mana", Name = "Mana Well", Glyph = "⊙", Category = "Input", Zones = { "Input" },
		Description = "Draws Amount mana each cast and pushes it into the circle as energy.",
		Inputs = {}, Outputs = { flowOut() },
		Params = { fixed(num("Amount", "Mana", 30, 1, 1000, 1, " mana")) },
	},

	-- Targeting -----------------------------------------------------------------
	{
		Id = "Target", Name = "Aim", Glyph = "⊕", Category = "Targeting", Zones = { "Targeting" },
		Description = "A point that falls back to where you're aiming: whatever is wired into Aim at, else the current target (For Each's entity, a trigger's victim), else your mouse.",
		Inputs = { opt("point", "point", "Aim at") },
		Outputs = { { Name = "point", Type = "point", Label = "Aim" } },
		Params = {},
	},

	-- Sensors -------------------------------------------------------------------
	{
		Id = "Caster", Name = "Caster", Glyph = "α", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "You.",
		Inputs = {}, Outputs = { { Name = "entity", Type = "entity", Label = "Caster" } }, Params = {},
	},
	{
		Id = "Cursor", Name = "Cursor", Glyph = "χ", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "Where you aimed when casting, and the entity under the crosshair (if any).",
		Inputs = {},
		Outputs = { { Name = "point", Type = "point", Label = "Point" }, { Name = "entity", Type = "entity", Label = "Entity" } },
		Params = {},
	},
	{
		Id = "Here", Name = "Here", Glyph = "ξ", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "Where this part of the circle is running: your hand at cast time, the vessel when a trigger fires, a conjured circle after Conjure Circle. Heading is the way it's going (your aim, the vessel's flight); Surface is the normal of what a trigger hit.",
		Inputs = {},
		Outputs = {
			{ Name = "point", Type = "point", Label = "Point" },
			{ Name = "heading", Type = "point", Label = "Heading" },
			{ Name = "normal", Type = "point", Label = "Surface" },
		},
		Params = {},
	},
	{
		Id = "Struck", Name = "Struck Entity", Glyph = "∩", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "The entity that set off the current trigger (the one hit, or the one that came close). Empty at cast time.",
		Inputs = {}, Outputs = { { Name = "entity", Type = "entity", Label = "Entity" } }, Params = {},
	},
	{
		Id = "Given", Name = "Given", Glyph = "Γ", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "What the spell that invoked this one handed it (Invoke's inputs). Empty when you cast this spell yourself; Invoked tells you which.",
		Inputs = {},
		Outputs = {
			{ Name = "point", Type = "point", Label = "Point" },
			{ Name = "entity", Type = "entity", Label = "Entity" },
			{ Name = "number", Type = "number", Label = "Number" },
			{ Name = "invoked", Type = "bool", Label = "Invoked" },
		},
		Params = {},
	},
	{
		Id = "Nearest", Name = "Nearest Entity", Glyph = "Π", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "Closest living entity (never you) within Radius of From. From defaults to Here. Hostile = anything your magic can hurt; Ally = your party.",
		Inputs = { opt("from", "point", "From") },
		Outputs = { { Name = "entity", Type = "entity", Label = "Entity" } },
		Params = {
			num("Radius", "Radius", 60, 1, 300, 1, " st"),
			enum("Filter", "Only", "Enemy", SCAN_FILTERS),
		},
	},
	{
		Id = "Scan", Name = "Scan Area", Glyph = "☼", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "Every living entity within Radius of From (default Here) -- or, with Cone under 360°, only those within that cone around Toward (default Here's heading) -- sorted, up to Max. Feed the list to For Each, Filter or Pick; First is the top of the list, Count how many there are.",
		Inputs = { opt("from", "point", "From"), opt("dir", "point", "Toward") },
		Outputs = {
			{ Name = "list", Type = "list", Label = "Entities" },
			{ Name = "first", Type = "entity", Label = "First" },
			{ Name = "count", Type = "number", Label = "Count" },
		},
		Params = {
			num("Radius", "Radius", 30, 1, 300, 1, " st"),
			num("Cone", "Cone", 360, 5, 360, 5, "°"),
			enum("Filter", "Only", "Hostile", SCAN_FILTERS),
			enum("Sort", "Sort", "Nearest", { "Nearest", "Farthest", "Weakest", "Strongest", "Random" }),
			num("Max", "Max", 8, 1, 24, 1),
			bool("Self", "Include you", false),
		},
	},
	{
		Id = "Distance", Name = "Distance", Glyph = "ρ", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "Studs between two points. Huge if either is empty.",
		Inputs = { { Name = "a", Type = "point", Label = "A" }, { Name = "b", Type = "point", Label = "B" } },
		Outputs = { { Name = "value", Type = "number", Label = "Studs" } }, Params = {},
	},
	{
		Id = "Health", Name = "Health", Glyph = "ζ", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "An entity's health (0 if empty).",
		Inputs = { { Name = "entity", Type = "entity", Label = "Entity" } },
		Outputs = { { Name = "value", Type = "number", Label = "Health" } },
		Params = { enum("Mode", "As", "Points", { "Points", "Percent" }) },
	},
	{
		Id = "Exists", Name = "Exists", Glyph = "∃", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "True when the entity is present and alive.",
		Inputs = { { Name = "entity", Type = "entity", Label = "Entity" } },
		Outputs = { { Name = "value", Type = "bool", Label = "Yes" } }, Params = {},
	},
	{
		Id = "IsPlayer", Name = "Is Player", Glyph = "∈", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "True when the entity is a player character.",
		Inputs = { { Name = "entity", Type = "entity", Label = "Entity" } },
		Outputs = { { Name = "value", Type = "bool", Label = "Yes" } }, Params = {},
	},
	{
		Id = "Is", Name = "Check Entity", Glyph = "≡", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "True when the entity is what Check asks: who it is to you (Ally, Hostile, You), how it's moving (Grounded, Airborne, Moving) or what's on it (Burning, Stunned, Shielded, Hasted, Slowed, Rooted, Levitating).",
		Inputs = { { Name = "entity", Type = "entity", Label = "Entity" } },
		Outputs = { { Name = "value", Type = "bool", Label = "Yes" } },
		Params = {
			enum("Check", "Is", "Hostile", {
				"Hostile", "Ally", "You", "Grounded", "Airborne", "Moving",
				"Burning", "Stunned", "Shielded", "Hasted", "Slowed", "Rooted", "Levitating",
			}),
		},
	},
	{
		Id = "Motion", Name = "Motion", Glyph = "∂", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "How an entity is moving: its Velocity (studs/s), Speed, and the way it Faces. Lead a target with Point Math: position + velocity × time.",
		Inputs = { { Name = "entity", Type = "entity", Label = "Entity" } },
		Outputs = {
			{ Name = "velocity", Type = "point", Label = "Velocity" },
			{ Name = "speed", Type = "number", Label = "Speed" },
			{ Name = "facing", Type = "point", Label = "Facing" },
		},
		Params = {},
	},
	{
		Id = "Raycast", Name = "Raycast", Glyph = "↘", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "Casts a ray from From (default Here) along Direction (default straight down) up to Distance studs. Point is where it hit (or where it ended), Surface the hit's normal, Entity what it hit. Find the ground, a wall, line of sight...",
		Inputs = {
			opt("from", "point", "From"),
			opt("dir", "point", "Direction"),
		},
		Outputs = {
			{ Name = "hit", Type = "bool", Label = "Hit" },
			{ Name = "point", Type = "point", Label = "Point" },
			{ Name = "normal", Type = "point", Label = "Surface" },
			{ Name = "entity", Type = "entity", Label = "Entity" },
			{ Name = "distance", Type = "number", Label = "Distance" },
		},
		Params = { num("Distance", "Distance", 100, 1, 500, 1, " st") },
	},
	{
		Id = "Clock", Name = "Clock", Glyph = "◑", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "Seconds since the spell was cast, and how long the vessel had been flying when the current trigger fired (0 at cast time).",
		Inputs = {},
		Outputs = {
			{ Name = "elapsed", Type = "number", Label = "Since cast" },
			{ Name = "flight", Type = "number", Label = "Flight time" },
		},
		Params = {},
	},
	{
		Id = "Recall", Name = "Recall", Glyph = "▤", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "Reads a memory Slot written by Store. Yours: shared by all your spells this session (mark a spot with one spell, blink back with another). This cast: private to one cast and everything it sets off.",
		Inputs = {},
		Outputs = {
			{ Name = "point", Type = "point", Label = "Point" },
			{ Name = "number", Type = "number", Label = "Number" },
			{ Name = "entity", Type = "entity", Label = "Entity" },
			{ Name = "list", Type = "list", Label = "List" },
			{ Name = "set", Type = "bool", Label = "Is set" },
		},
		Params = { enum("Slot", "Slot", "A", SLOTS), enum("Scope", "Memory", "Yours", SCOPES) },
	},

	-- Logic ---------------------------------------------------------------------
	{
		Id = "Number", Name = "Number", Glyph = "κ", Category = "Logic", Zones = VALUE_ZONES,
		Description = "A constant.",
		Inputs = {}, Outputs = { { Name = "value", Type = "number", Label = "Value" } },
		Params = { fixed(num("Value", "Value", 30, -10000, 10000, 0.1)) },
	},
	{
		Id = "Math", Name = "Math", Glyph = "*", Category = "Logic", Zones = VALUE_ZONES,
		Description = "A op B. Unwired, A and B use the values set here. Division by zero gives 0.",
		Inputs = {
			{ Name = "a", Type = "number", Label = "A", Optional = true, Param = "A" },
			{ Name = "b", Type = "number", Label = "B", Optional = true, Param = "B" },
		},
		Outputs = { { Name = "value", Type = "number", Label = "Result" } },
		Params = {
			enum("Op", "Op", "+", { "+", "-", "×", "÷", "min", "max", "^", "mod" }),
			num("A", "A", 0, -10000, 10000, 0.1),
			num("B", "B", 1, -10000, 10000, 0.1),
		},
	},
	{
		Id = "Func", Name = "Function", Glyph = "ƒ", Category = "Logic", Zones = VALUE_ZONES,
		Description = "Applies a function to a number. sin and cos take degrees; clamp keeps it between Min and Max.",
		Inputs = { { Name = "a", Type = "number", Label = "In" } },
		Outputs = { { Name = "value", Type = "number", Label = "Result" } },
		Params = {
			enum("Op", "Function", "abs", { "abs", "−x", "floor", "ceil", "round", "√", "sin", "cos", "sign", "clamp" }),
			num("Min", "Min", 0, -10000, 10000, 0.1),
			num("Max", "Max", 1, -10000, 10000, 0.1),
		},
	},
	{
		Id = "Compare", Name = "Compare", Glyph = "≶", Category = "Logic", Zones = VALUE_ZONES,
		Description = "True when A op B. Unwired, A and B use the values set here.",
		Inputs = {
			{ Name = "a", Type = "number", Label = "A", Optional = true, Param = "A" },
			{ Name = "b", Type = "number", Label = "B", Optional = true, Param = "B" },
		},
		Outputs = { { Name = "value", Type = "bool", Label = "Result" } },
		Params = {
			enum("Op", "Op", "<", { "<", "≤", "=", "≠", "≥", ">" }),
			num("A", "A", 0, -10000, 10000, 0.1),
			num("B", "B", 0, -10000, 10000, 0.1),
		},
	},
	{
		Id = "And", Name = "And", Glyph = "∧", Category = "Logic", Zones = VALUE_ZONES,
		Description = "True when both are true.",
		Inputs = { { Name = "a", Type = "bool", Label = "A" }, { Name = "b", Type = "bool", Label = "B" } },
		Outputs = { { Name = "value", Type = "bool", Label = "Result" } }, Params = {},
	},
	{
		Id = "Or", Name = "Or", Glyph = "∨", Category = "Logic", Zones = VALUE_ZONES,
		Description = "True when either is true.",
		Inputs = { { Name = "a", Type = "bool", Label = "A" }, { Name = "b", Type = "bool", Label = "B" } },
		Outputs = { { Name = "value", Type = "bool", Label = "Result" } }, Params = {},
	},
	{
		Id = "Not", Name = "Not", Glyph = "¬", Category = "Logic", Zones = VALUE_ZONES,
		Description = "Flips true and false.",
		Inputs = { { Name = "a", Type = "bool", Label = "In" } },
		Outputs = { { Name = "value", Type = "bool", Label = "Result" } }, Params = {},
	},
	{
		Id = "Select", Name = "Choose Point", Glyph = "◇", Category = "Logic", Zones = VALUE_ZONES,
		Description = "Then if the condition holds, otherwise Else. Handy for targeting fallbacks.",
		Inputs = {
			{ Name = "cond", Type = "bool", Label = "If" },
			{ Name = "a", Type = "point", Label = "Then" },
			{ Name = "b", Type = "point", Label = "Else" },
		},
		Outputs = { { Name = "point", Type = "point", Label = "Point" } }, Params = {},
	},
	{
		Id = "SelectNumber", Name = "Choose Number", Glyph = "◆", Category = "Logic", Zones = VALUE_ZONES,
		Description = "Then if the condition holds, otherwise Else. Unwired, they use the values set here.",
		Inputs = {
			{ Name = "cond", Type = "bool", Label = "If" },
			{ Name = "a", Type = "number", Label = "Then", Optional = true, Param = "A" },
			{ Name = "b", Type = "number", Label = "Else", Optional = true, Param = "B" },
		},
		Outputs = { { Name = "value", Type = "number", Label = "Number" } },
		Params = { num("A", "Then", 1, -10000, 10000, 0.1), num("B", "Else", 0, -10000, 10000, 0.1) },
	},
	{
		Id = "SelectEntity", Name = "Choose Entity", Glyph = "◈", Category = "Logic", Zones = VALUE_ZONES,
		Description = "Then if the condition holds, otherwise Else.",
		Inputs = {
			{ Name = "cond", Type = "bool", Label = "If" },
			opt("a", "entity", "Then"),
			opt("b", "entity", "Else"),
		},
		Outputs = { { Name = "entity", Type = "entity", Label = "Entity" } }, Params = {},
	},
	{
		Id = "Random", Name = "Random", Glyph = "※", Category = "Logic", Zones = VALUE_ZONES,
		Description = "Rolled afresh each moment this part of the circle runs (every Repeat round, every trigger...): a number from Min to Max, a coin flip that's true Chance% of the time, and a random direction.",
		Inputs = {},
		Outputs = {
			{ Name = "value", Type = "number", Label = "Number" },
			{ Name = "roll", Type = "bool", Label = "Chance" },
			{ Name = "dir", Type = "point", Label = "Direction" },
		},
		Params = { num("Min", "Min", 0, -10000, 10000, 0.1), num("Max", "Max", 1, -10000, 10000, 0.1), num("Chance", "Chance", 50, 0, 100, 1, "%") },
	},

	-- Lists ---------------------------------------------------------------------
	{
		Id = "Filter", Name = "Filter", Glyph = "φ", Category = "List", Zones = VALUE_ZONES,
		Description = "Keeps the entities for which Keep is true. Keep is worked out once per entity: wire Item (the entity being judged) into the runes that decide it -- e.g. Item → Health → Compare → Keep keeps the wounded.",
		Inputs = { { Name = "list", Type = "list", Label = "List" }, { Name = "cond", Type = "bool", Label = "Keep" } },
		Outputs = {
			{ Name = "list", Type = "list", Label = "Kept" },
			{ Name = "item", Type = "entity", Label = "Item", Scoped = true },
			{ Name = "count", Type = "number", Label = "Count" },
		},
		Params = {},
	},
	{
		Id = "Pick", Name = "Pick", Glyph = "σ", Category = "List", Zones = VALUE_ZONES,
		Description = "The entity with the Lowest or Highest Score. Score is worked out once per entity: wire Item into the runes that compute it -- e.g. Item → Distance from the cursor picks whoever is nearest it.",
		Inputs = { { Name = "list", Type = "list", Label = "List" }, { Name = "key", Type = "number", Label = "Score" } },
		Outputs = {
			{ Name = "entity", Type = "entity", Label = "Best" },
			{ Name = "item", Type = "entity", Label = "Item", Scoped = true },
			{ Name = "value", Type = "number", Label = "Its score" },
		},
		Params = { enum("Mode", "Pick", "Lowest", { "Lowest", "Highest" }) },
	},
	{
		Id = "ListItem", Name = "List Item", Glyph = "Λ", Category = "List", Zones = VALUE_ZONES,
		Description = "One entity of a list by Index (1 is the first, -1 the last), a random one, and how many there are.",
		Inputs = { { Name = "list", Type = "list", Label = "List" } },
		Outputs = {
			{ Name = "item", Type = "entity", Label = "Item" },
			{ Name = "random", Type = "entity", Label = "Random" },
			{ Name = "count", Type = "number", Label = "Count" },
		},
		Params = { num("Index", "Index", 1, -24, 24, 1) },
	},
	{
		Id = "Combine", Name = "Combine", Glyph = "∪", Category = "List", Zones = VALUE_ZONES,
		Description = "Joins two lists: Both (everyone in either), Common (only those in both) or A not B (A without anyone in B).",
		Inputs = { { Name = "a", Type = "list", Label = "A" }, opt("b", "list", "B") },
		Outputs = { { Name = "list", Type = "list", Label = "List" }, { Name = "count", Type = "number", Label = "Count" } },
		Params = { enum("Op", "Op", "Both", { "Both", "Common", "A not B" }) },
	},

	-- Vectors -------------------------------------------------------------------
	{
		Id = "Locate", Name = "Locate", Glyph = "μ", Category = "Vector", Zones = VALUE_ZONES,
		Description = "A point relative to From (default: you). Forward / Up / Right are studs along Basis: your Aim, your Level aim (aim without tilt), From's Body facing, this part's Heading, or the Surface a trigger hit (Up = its normal). Toward overrides Forward with any direction. Ground drops the point onto the ground beneath it. \"10 studs in front of you, on the ground\" is the default with Ground on.",
		Inputs = { opt("from", "point", "From"), opt("dir", "point", "Toward") },
		Outputs = {
			{ Name = "point", Type = "point", Label = "Point" },
			{ Name = "forward", Type = "point", Label = "Forward" },
			{ Name = "up", Type = "point", Label = "Up" },
			{ Name = "right", Type = "point", Label = "Right" },
		},
		Params = {
			enum("Basis", "Basis", "Level aim", { "Aim", "Level aim", "Body", "Heading", "Surface" }),
			num("Forward", "Forward", 10, -300, 300, 0.5, " st"),
			num("Up", "Up", 0, -300, 300, 0.5, " st"),
			num("Right", "Right", 0, -300, 300, 0.5, " st"),
			bool("Ground", "Onto ground", false),
		},
	},
	{
		Id = "Vector", Name = "Vector", Glyph = "→", Category = "Vector", Zones = VALUE_ZONES,
		Description = "Builds a vector from X, Y and Z (each from a wire, or the value set here). Facing axes are relative to Heading: X right, Y up, Z forward.",
		Inputs = {
			{ Name = "x", Type = "number", Label = "X", Optional = true, Param = "X" },
			{ Name = "y", Type = "number", Label = "Y", Optional = true, Param = "Y" },
			{ Name = "z", Type = "number", Label = "Z", Optional = true, Param = "Z" },
		},
		Outputs = { { Name = "vector", Type = "point", Label = "Vector" } },
		Params = { num("X", "X", 0, -1000, 1000, 0.5), num("Y", "Y", 1, -1000, 1000, 0.5), num("Z", "Z", 0, -1000, 1000, 0.5), SPACE },
	},
	{
		Id = "Offset", Name = "Offset", Glyph = "±", Category = "Vector", Zones = VALUE_ZONES,
		Description = "Point (default Here) moved by By, or by X/Y/Z. \"Above the impact point\" is Offset with Y. Facing axes are relative to Heading: X right, Y up, Z forward.",
		Inputs = {
			opt("point", "point", "Point"),
			opt("by", "point", "By"),
		},
		Outputs = { { Name = "point", Type = "point", Label = "Point" } },
		Params = { num("X", "X", 0, -500, 500, 0.5), num("Y", "Y", 10, -500, 500, 0.5), num("Z", "Z", 0, -500, 500, 0.5), SPACE },
	},
	{
		Id = "VecMath", Name = "Point Math", Glyph = "×", Category = "Vector", Zones = VALUE_ZONES,
		Description = "A op B on points and vectors: add, subtract, scale A by N, Lerp from A to B by N (0..1), Midpoint, Unit (A's direction), Cross, Rotate A by N degrees (about B, or the vertical axis), Reflect A off surface B, Project A onto B. Dot is always A·B.",
		Inputs = {
			{ Name = "a", Type = "point", Label = "A" },
			opt("b", "point", "B"),
			{ Name = "n", Type = "number", Label = "N", Optional = true, Param = "N" },
		},
		Outputs = {
			{ Name = "result", Type = "point", Label = "Result" },
			{ Name = "length", Type = "number", Label = "Length" },
			{ Name = "dot", Type = "number", Label = "Dot" },
		},
		Params = {
			enum("Op", "Op", "A+B", { "A+B", "A−B", "A×N", "Lerp", "Midpoint", "Unit", "Cross", "Rotate", "Reflect", "Project" }),
			num("N", "N", 1, -1000, 1000, 0.05),
		},
	},
	{
		Id = "Direction", Name = "Direction", Glyph = "↗", Category = "Vector", Zones = VALUE_ZONES,
		Description = "The direction (a unit vector) and distance from From (default Here) to To (default where the spell is aiming).",
		Inputs = {
			opt("from", "point", "From"),
			opt("to", "point", "To"),
		},
		Outputs = { { Name = "dir", Type = "point", Label = "Direction" }, { Name = "dist", Type = "number", Label = "Distance" } },
		Params = {},
	},
	{
		Id = "Split", Name = "Split", Glyph = "⋯", Category = "Vector", Zones = VALUE_ZONES,
		Description = "A point's X, Y and Z, and its length.",
		Inputs = { { Name = "point", Type = "point", Label = "Point" } },
		Outputs = {
			{ Name = "x", Type = "number", Label = "X" },
			{ Name = "y", Type = "number", Label = "Y" },
			{ Name = "z", Type = "number", Label = "Z" },
			{ Name = "length", Type = "number", Label = "Length" },
		},
		Params = {},
	},

	-- Branch / flow -------------------------------------------------------------
	{
		Id = "If", Name = "If", Glyph = "⇒", Category = "Branch", Zones = { "Branch" },
		Description = "Sends all energy down True or False depending on the condition. An unwired side fizzles.",
		Inputs = { flowIn(), { Name = "cond", Type = "bool", Label = "Condition" } },
		Outputs = { flowOut("yes", "True"), flowOut("no", "False") }, Params = {},
	},
	{
		Id = "Divide", Name = "Divide", Glyph = "÷", Category = "Branch", Zones = { "Branch" },
		Description = "Splits energy between two paths; both run, A first.",
		Inputs = { flowIn() },
		Outputs = { flowOut("a", "A"), flowOut("b", "B") },
		Params = { num("Share", "Share to A", 50, 0, 100, 5, "%") },
	},
	{
		Id = "Delay", Name = "Delay", Glyph = "◐", Category = "Branch", Zones = { "Branch" }, Pass = true,
		Description = "Waits, then passes the energy on. Everything after it senses the world afresh. Time dilation slows the wait.",
		Inputs = { flowIn(), { Name = "seconds", Type = "number", Label = "Seconds", Optional = true, Param = "Seconds" } },
		Outputs = { flowOut() },
		Params = { num("Seconds", "Wait", 0.5, 0, 15, 0.05, "s") },
	},
	{
		Id = "Repeat", Name = "Repeat", Glyph = "∞", Category = "Branch", Zones = { "Branch" }, Pass = true,
		Description = "Runs what follows Count times, Interval apart, sharing the energy evenly. Index counts 1, 2, 3... Each time senses the world afresh.",
		Inputs = { flowIn(), { Name = "count", Type = "number", Label = "Count", Optional = true, Param = "Count" } },
		Outputs = { flowOut("each", "Each time"), { Name = "index", Type = "number", Label = "Index" } },
		Params = { num("Count", "Count", 3, 1, 30, 1), num("Interval", "Interval", 0.25, 0, 5, 0.05, "s") },
	},
	{
		Id = "ForEach", Name = "For Each", Glyph = "∀", Category = "Branch", Zones = { "Branch" }, Pass = true,
		Description = "Runs what follows once per entity in the list (up to Max), sharing the energy. Vessels after it aim at / act on that entity unless told otherwise; Entity and Index tell you which one. An empty list sends all the energy to If empty.",
		Inputs = { flowIn(), { Name = "list", Type = "list", Label = "Entities" } },
		Outputs = {
			flowOut("each", "Each"),
			flowOut("none", "If empty"),
			{ Name = "entity", Type = "entity", Label = "Entity" },
			{ Name = "index", Type = "number", Label = "Index" },
			{ Name = "count", Type = "number", Label = "Count" },
		},
		Params = { num("Max", "Max", 8, 1, 24, 1), num("Interval", "Interval", 0, 0, 2, 0.02, "s") },
	},
	{
		Id = "Await", Name = "Wait Until", Glyph = "∵", Category = "Branch", Zones = { "Branch" }, Pass = true,
		Description = "Holds the energy, checking the condition every Every seconds; Then runs the moment it's true, Timed out if it never is. Traps, mines and ambushes.",
		Inputs = { flowIn(), { Name = "cond", Type = "bool", Label = "Condition" } },
		Outputs = { flowOut("then", "Then"), flowOut("timeout", "Timed out") },
		Params = { num("Timeout", "Timeout", 5, 0.1, 40, 0.1, "s"), num("Every", "Every", 0.1, 0.05, 2, 0.05, "s") },
	},
	{
		Id = "Conjure", Name = "Conjure Circle", Glyph = "◉", Category = "Branch", Zones = { "Branch" }, Pass = true,
		Description = "Draws a new magic circle at At (default Here) raised by Height, and runs the rest of the circle from there once it has drawn in. It faces Face toward if wired; otherwise it looks back down at where it was conjured from, or along your aim. Here becomes the circle.",
		Inputs = {
			flowIn(),
			opt("at", "point", "At"),
			opt("face", "point", "Face toward"),
		},
		Outputs = { flowOut(), { Name = "point", Type = "point", Label = "Circle" } },
		Params = { num("Height", "Height", 12, -30, 80, 0.5, " st"), num("Delay", "Draw time", 0.6, 0, 5, 0.05, "s"), num("Size", "Size", 1, 0.3, 4, 0.1, "×") },
	},
	{
		Id = "Store", Name = "Store", Glyph = "▣", Category = "Branch", Zones = { "Branch" }, Pass = true,
		Description = "Writes whatever is wired into a memory Slot (Recall reads it), then passes the energy on. Yours: kept for all your spells this session. This cast: private to this cast and what it sets off.",
		Inputs = {
			flowIn(),
			opt("point", "point", "Point"),
			opt("number", "number", "Number"),
			opt("entity", "entity", "Entity"),
			opt("list", "list", "List"),
		},
		Outputs = { flowOut() },
		Params = { enum("Slot", "Slot", "A", SLOTS), enum("Scope", "Memory", "Yours", SCOPES) },
	},
	{
		Id = "Invoke", Name = "Invoke", Glyph = "Ω", Category = "Branch", Zones = { "Branch" },
		Description = "Casts the spell on your hotbar Slot from here with the energy that arrives (split between its Mana Wells), handing it Point, Entity and Number (it reads them with Given). Its Here, aim and targets are this moment's. Spells can invoke spells -- up to 4 deep.",
		Inputs = {
			flowIn(),
			opt("point", "point", "Point"),
			opt("entity", "entity", "Entity"),
			opt("number", "number", "Number"),
		},
		Outputs = {},
		Params = { num("Slot", "Hotbar slot", 1, 1, 5, 1) },
	},

	-- Transform -----------------------------------------------------------------
	{
		Id = "Fire", Name = "Fire", Glyph = "△", Category = "Transform", Zones = { "Transform" }, Element = "Fire",
		Description = "80% of energy on impact, plus a burn worth 35% over 3s.",
		Inputs = { flowIn() }, Outputs = { flowOut() }, Params = {},
	},
	{
		Id = "Arcane", Name = "Arcane", Glyph = "★", Category = "Transform", Zones = { "Transform" }, Element = "Arcane",
		Description = "All energy lands as impact damage.",
		Inputs = { flowIn() }, Outputs = { flowOut() }, Params = {},
	},
	{
		Id = "Shock", Name = "Shock", Glyph = "ϟ", Category = "Transform", Zones = { "Transform" }, Element = "Shock",
		Description = "70% of energy on impact, and stuns 0.01s per energy (max 1s).",
		Inputs = { flowIn() }, Outputs = { flowOut() }, Params = {},
	},

	-- Modifiers -----------------------------------------------------------------
	{
		Id = "Speed", Name = "Speed", Glyph = "v", Category = "Modifier", Zones = { "Modifier" },
		Description = "Multiplies flight speed (below 1 slows it, for free). Costs 6.5% of the energy per +1×.",
		Inputs = {}, Outputs = { modOut() }, Params = { num("Factor", "Speed", 1.6, 0.2, 4, 0.05, "×") },
		Migrate = function(params) fromLevel(params, "Factor", SpellRunes.LegacyLevels.Speed) end,
	},
	{
		Id = "Size", Name = "Size", Glyph = "λ", Category = "Modifier", Zones = { "Modifier" },
		Description = "Multiplies projectile size and hitbox, Beam width, or Explosion radius. Costs 7.5% of the energy per +1×; Explosion radius also pays its usual size cost.",
		Inputs = {}, Outputs = { modOut() }, Params = { num("Factor", "Size", 1.8, 0.3, 4, 0.05, "×") },
		Migrate = function(params) fromLevel(params, "Factor", SpellRunes.LegacyLevels.Size) end,
	},
	{
		Id = "Gravity", Name = "Gravity", Glyph = "g", Category = "Modifier", Zones = { "Modifier" },
		Description = "Pulls the projectile down by Pull studs/s² (negative floats it up) -- arcs, lobs and risers. Costs 0.03% per stud/s².",
		Inputs = {}, Outputs = { modOut() }, Params = { num("Pull", "Pull", 40, -150, 250, 5, " st/s²") },
		Migrate = function(params) fromLevel(params, "Pull", SpellRunes.LegacyLevels.Gravity) end,
	},
	{
		Id = "Bounce", Name = "Bounce", Glyph = "∠", Category = "Modifier", Zones = { "Modifier" },
		Description = "Ricochets off walls Count times, keeping Bounciness of its speed each time. Beams reflect too. 5% per bounce.",
		Inputs = {}, Outputs = { modOut() }, Params = { num("Count", "Bounces", 1, 1, 10, 1), num("Bounciness", "Bounciness", 0.7, 0.1, 1, 0.05) },
		Migrate = function(params) fromLevel(params, "Count", nil) end,
	},
	{
		Id = "Pierce", Name = "Pierce", Glyph = "‡", Category = "Modifier", Zones = { "Modifier" },
		Description = "Passes through Count enemies, losing Falloff of its damage each time. 6% per enemy.",
		Inputs = {}, Outputs = { modOut() }, Params = { num("Count", "Pierces", 1, 1, 10, 1), num("Falloff", "Falloff", 15, 0, 60, 1, "%") },
		Migrate = function(params) fromLevel(params, "Count", nil) end,
	},
	{
		Id = "Quantity", Name = "Quantity", Glyph = "Σ", Category = "Modifier", Zones = { "Modifier" },
		Description = "Fires Count copies that share the energy: a Fan across Spread degrees, a Ring around the aim, or a Stream one after another. 2% per extra copy.",
		Inputs = {}, Outputs = { modOut() },
		Params = {
			fixed(num("Count", "Count", 3, 1, 12, 1)),
			enum("Pattern", "Pattern", "Fan", { "Fan", "Ring", "Stream" }),
			num("Spread", "Spread", 20, 0, 180, 1, "°"),
			num("Interval", "Stream gap", 0.08, 0.03, 1, 0.01, "s"),
		},
	},
	{
		Id = "Homing", Name = "Homing", Glyph = "◎", Category = "Modifier", Zones = { "Modifier" },
		Description = "Seeks targets within Radius, turning up to Turn degrees a second. Wire an entity into Lock on to chase that one. Beams steer in flight too.",
		Inputs = { opt("entity", "entity", "Lock on") },
		Outputs = { modOut() },
		Params = { num("Turn", "Turn", 105, 10, 400, 5, "°/s"), num("Radius", "Radius", 45, 5, 150, 5, " st"), enum("Filter", "Seek", "Enemy", FILTERS) },
		Migrate = function(params)
			local level = params.Level
			if typeof(level) == "number" then
				level = math.clamp(math.floor(level + 0.5), 1, 5)
				params.Turn = params.Turn or SpellRunes.LegacyLevels.HomingTurn[level]
				params.Radius = params.Radius or SpellRunes.LegacyLevels.HomingRadius[level]
			end
			params.Level = nil
		end,
	},
	{
		Id = "Range", Name = "Range", Glyph = "↔", Category = "Modifier", Zones = { "Modifier" },
		Description = "Multiplies projectile flight time or an Explosion's placement range (below 1 shortens it, for free). 6% per +1×.",
		Inputs = {}, Outputs = { modOut() }, Params = { num("Factor", "Range", 1.7, 0.1, 4, 0.05, "×") },
		Migrate = function(params) fromLevel(params, "Factor", SpellRunes.LegacyLevels.Range) end,
	},
	{
		Id = "Sustain", Name = "Sustain", Glyph = "τ", Category = "Modifier", Zones = { "Modifier" },
		Description = "Beam only: hold to channel for up to Seconds; release to stop. Follows live aim. Energy is shared across the whole duration; segments keep all flight modifiers and triggers. 4% per second.",
		Inputs = {}, Outputs = { modOut() }, Params = { num("Seconds", "Seconds", 2, 0.5, 8, 0.25, "s") },
		Migrate = function(params) fromLevel(params, "Seconds", nil) end,
	},

	-- Vessels: damage ------------------------------------------------------------
	projectile("Orb", "Orb", "◯", "A slow, heavy sphere of magic with a big hitbox. Launches from From (default: your hand / Here) toward Aim (default: your mouse or the current target)."),
	projectile("Bullet", "Bullet", "▶", "A fast, thin tracer. Launches from From (default: your hand / Here) toward Aim (default: your mouse or the current target)."),
	projectile("Beam", "Beam", "═", "A cylinder of magic traveling at 2000 studs/s from From toward Aim. Supports all flight modifiers and triggers; Sustain emits a continuous cursor-following beam."),
	{
		Id = "Explosion", Name = "Explosion", Glyph = "✽", Category = "Vessel", Zones = { "Output" }, Vessel = true, Damaging = true, Instant = true,
		Description = "Bursts at At (default: a trigger's impact point, the For Each entity, or your mouse), hitting everything within Radius: full damage at the centre down to Edge at the rim. Size multiplies blast radius; Range multiplies placement distance. Effective radius beyond 4 studs costs 2% of the energy per stud (up to 60%). Fling throws hard-hit bodies.",
		Inputs = { flowIn(), opt("aim", "point", "At"), modsIn() },
		Outputs = {},
		Params = { num("Radius", "Radius", 6, 1, 30, 0.5, " st"), num("Edge", "Edge damage", 50, 0, 100, 5, "%"), bool("Fling", "Fling", true) },
		Migrate = function(params) params.Radius = params.Radius or 6 end,
	},
	{
		Id = "Smite", Name = "Smite", Glyph = "ψ", Category = "Vessel", Zones = { "Output" }, Vessel = true, Damaging = true, Instant = true,
		Description = "Strikes Target instantly with a bolt from From (default Here) -- no flight, no dodging. Target may be a list: the energy is shared. Misses whoever is beyond Range of From, or behind a wall when Sight is on. Default target: the For Each entity, the struck entity, or what's under your crosshair. Hits for 80% of an Orb.",
		Inputs = { flowIn(), opt("target", "list", "Target"), opt("from", "point", "From") },
		Outputs = {},
		Params = { num("Range", "Range", 60, 2, 150, 1, " st"), bool("Sight", "Needs sight", true) },
	},

	-- Vessels: everything else ---------------------------------------------------
	{
		Id = "Barrier", Name = "Barrier", Glyph = "▥", Category = "Vessel", Zones = { "Output" }, Vessel = true,
		Description = "Raises solid magic at At (default: your mouse; in a trigger, Here): a Box, Dome, Sphere or Ring of Width × Height × Depth studs, turned to Face toward (default: you) and tilted by Tilt. Anchor says which part sits on At; Ground first drops At onto the ground. Follow makes it move with an entity. Lets through: who walks through it. Stops spells: whose magic it blocks. Costs 0.25 energy per HP plus 0.003 per square stud per second; underfed, it gets less health and time. Triggers can watch it (On Expire fires when it breaks or fades).",
		Inputs = {
			flowIn(),
			opt("aim", "point", "At"),
			opt("face", "point", "Face toward"),
			opt("follow", "entity", "Follow"),
		},
		Outputs = { { Name = "vessel", Type = "vessel", Label = "Triggers" } },
		Params = {
			enum("Shape", "Shape", "Box", { "Box", "Dome", "Sphere", "Ring" }),
			num("Width", "Width", 12, 0.5, 80, 0.5, " st"),
			num("Height", "Height", 8, 0.5, 60, 0.5, " st"),
			num("Depth", "Depth", 1, 0.3, 40, 0.1, " st"),
			num("Tilt", "Tilt", 0, -90, 90, 5, "°"),
			num("Health", "Health", 150, 5, 3000, 5, " HP"),
			num("Duration", "Duration", 8, 0.5, 60, 0.5, "s"),
			enum("Anchor", "Anchor", "Base", { "Base", "Centre", "Top" }),
			bool("Ground", "Onto ground", true),
			bool("Rise", "Rise up", false),
			enum("Pass", "Lets through", "Allies", { "Allies", "Nobody", "Everyone" }),
			enum("Blocks", "Stops spells", "Hostile", { "Hostile", "All", "None" }),
		},
		Migrate = function(params)
			local legacy = { Wall = { 12, 8, 1 }, Platform = { 10, 1, 10 }, Pillar = { 4, 12, 4 }, Dome = { 14, 7, 1 } }
			local size = legacy[params.Shape]
			if size and params.Width == nil then
				params.Width, params.Height, params.Depth = size[1], size[2], size[3]
				params.Rise = params.Shape == "Pillar"
				params.Shape = if params.Shape == "Dome" then "Dome" else "Box"
			end
		end,
	},
	{
		Id = "Force", Name = "Force", Glyph = "»", Category = "Vessel", Zones = { "Output" }, Vessel = true, Instant = true,
		Description = "Moves bodies at Speed studs/s. Along: the way Direction points (default: your aim / the vessel's heading). Away / Toward: from / to Centre (default Here), with Lift tipping it upward. Up: skyward. Hits Target (an entity or a list; default: the For Each entity, you at cast time -- a dash -- or the struck entity in a trigger), plus everything within Radius of Centre. Duration 0 is one shove; above 0 it keeps driving them for that long (Toward becomes a pull that holds them at Centre). Replace sets their velocity instead of adding to it. Costs 0.2 energy per stud/s per body (+50% per second held, +4 to Ragdoll); underfed, it's slower.",
		Inputs = {
			flowIn(),
			opt("target", "list", "Target"),
			opt("dir", "point", "Direction"),
			opt("center", "point", "Centre"),
		},
		Outputs = {},
		Params = {
			enum("Mode", "Mode", "Along", { "Along", "Away", "Toward", "Up" }),
			num("Speed", "Speed", 80, 0, 300, 5, " st/s"),
			num("Lift", "Lift", 0.25, 0, 1, 0.05),
			num("Duration", "Duration", 0, 0, 10, 0.05, "s"),
			num("Radius", "Radius", 0, 0, 60, 1, " st"),
			bool("Ragdoll", "Ragdoll", false),
			bool("Replace", "Replace velocity", false),
		},
		Migrate = function(params)
			if params.Mode == "Push" then params.Mode = "Away" elseif params.Mode == "Pull" then params.Mode = "Toward" end
		end,
	},
	{
		Id = "Blink", Name = "Blink", Glyph = "β", Category = "Vessel", Zones = { "Output" }, Vessel = true, Instant = true,
		Description = "Teleports Who (default: you) toward To (cast: your mouse; in a trigger: Here), at most Distance studs, stopping short of walls. Costs 0.4 energy per stud travelled; underfed, it falls short.",
		Inputs = {
			flowIn(),
			opt("who", "entity", "Who"),
			opt("to", "point", "To"),
		},
		Outputs = {},
		Params = { num("Distance", "Max distance", 60, 1, 250, 1, " st"), bool("Momentum", "Keep momentum", true) },
	},
	{
		Id = "Effect", Name = "Body Effect", Glyph = "✚", Category = "Vessel", Zones = { "Output" }, Vessel = true, Instant = true,
		Description = "Works magic on Target (an entity or a list; default: the For Each entity, you at cast time, or the struck entity in a trigger). Power is HP for Heal and Shield, and a percentage for the rest (Haste 50 = 50% faster; Weaken 30 = takes 30% more damage); Root, Levitate and Cleanse ignore it. Each effect has its own price (see the estimate); underfed, it's weaker (Root and Levitate: shorter). Your party is never harmed.",
		Inputs = {
			flowIn(),
			opt("target", "list", "Target"),
		},
		Outputs = {},
		Params = {
			enum("Effect", "Effect", "Heal", {
				"Heal", "Shield", "Haste", "Slow", "Root", "Levitate", "Empower", "Weaken", "Quicken", "Dilate", "Cleanse",
			}),
			num("Power", "Power", 50, 0, 500, 1),
			num("Duration", "Duration", 5, 0.5, 30, 0.5, "s"),
		},
	},
	{
		Id = "TimeField", Name = "Time Field", Glyph = "◒", Category = "Vessel", Zones = { "Output" }, Vessel = true,
		Description = "A bubble of bent time of Radius studs at At (cast: your mouse; in a trigger: Here): everything inside -- bodies, projectiles, spells -- runs at Scale speed for Duration seconds. Follow makes it move with an entity. Costs radius² × how far Scale is from 1 × seconds; underfed, it's shorter.",
		Inputs = {
			flowIn(),
			opt("aim", "point", "At"),
			opt("follow", "entity", "Follow"),
		},
		Outputs = { { Name = "vessel", Type = "vessel", Label = "Triggers" } },
		Params = { num("Radius", "Radius", 10, 2, 40, 0.5, " st"), num("Scale", "Time scale", 0.3, 0.1, 3, 0.05, "×"), num("Duration", "Duration", 5, 0.5, 20, 0.5, "s") },
	},

	-- Triggers ------------------------------------------------------------------
	{
		Id = "OnImpact", Name = "On Impact", Glyph = "⊗", Category = "Trigger", Zones = { "Trigger" },
		Description = "When the vessel stops on a wall or enemy, releases Share of its energy from the impact point. What it fires ricochets unless aimed. Point, Surface and Struck describe the impact.",
		Inputs = { vesselIn() },
		Outputs = {
			flowOut(),
			{ Name = "point", Type = "point", Label = "Point" },
			{ Name = "normal", Type = "point", Label = "Surface" },
			{ Name = "entity", Type = "entity", Label = "Struck" },
		},
		Params = { share() },
	},
	{
		Id = "OnExpire", Name = "On Expire", Glyph = "⊘", Category = "Trigger", Zones = { "Trigger" },
		Description = "When the vessel runs out of range without hitting anything -- or a Barrier / Time Field breaks or fades -- releases Share of its energy there.",
		Inputs = { vesselIn() }, Outputs = { flowOut(), { Name = "point", Type = "point", Label = "Point" } }, Params = { share() },
	},
	{
		Id = "OnTimer", Name = "On Timer", Glyph = "◓", Category = "Trigger", Zones = { "Trigger" },
		Description = "After Delay seconds, releases Share of the energy -- or, with Pulses above 1, a slice of it every Delay seconds. Detonate ends the vessel after the last pulse. Settings are read when the vessel is fired.",
		Inputs = { vesselIn() }, Outputs = { flowOut(), { Name = "point", Type = "point", Label = "Point" }, { Name = "pulse", Type = "number", Label = "Pulse" } },
		Params = {
			num("Delay", "Delay", 0.5, 0.05, 20, 0.05, "s"),
			share(),
			bool("Detonate", "Detonate", false),
			num("Pulses", "Pulses", 1, 1, 20, 1),
		},
	},
	{
		Id = "OnProximity", Name = "On Proximity", Glyph = "◌", Category = "Trigger", Zones = { "Trigger" },
		Description = "When an entity comes within Radius of the vessel, releases Share of the energy. Struck Entity is that entity; what it fires aims at it.",
		Inputs = { vesselIn() },
		Outputs = { flowOut(), { Name = "point", Type = "point", Label = "Point" }, { Name = "entity", Type = "entity", Label = "Entity" } },
		Params = {
			num("Radius", "Radius", 8, 1, 60, 1, " st"),
			enum("Filter", "Only", "Enemy", SCAN_FILTERS),
			share(),
			bool("Detonate", "Detonate", true),
		},
	},
}

-- "⊙ Mana Well" -- the rune's name prefixed with its glyph, when it has one.
function SpellRunes.DisplayName(def: RuneDef): string
	return if def.Glyph then def.Glyph .. "  " .. def.Name else def.Name
end

SpellRunes.Categories = { "Input", "Targeting", "Sensor", "Logic", "List", "Vector", "Branch", "Transform", "Modifier", "Vessel", "Trigger" }
-- Toolbox headings (the Branch category holds every flow rune)
SpellRunes.CategoryLabels = { Branch = "Flow", List = "Lists" } :: { [string]: string }
SpellRunes.Order = {} :: { string }
SpellRunes.Runes = {} :: { [string]: RuneDef }

-- Every number / bool param that isn't Fixed and isn't already behind a
-- declared input becomes an input port of its own (after the declared ones),
-- so any setting can be computed by a wire.
for _, def in defs do
	local covered = {}
	for _, port in def.Inputs do
		if port.Param then
			covered[port.Param] = true
		end
	end
	for _, param in def.Params do
		if (param.Type == "number" or param.Type == "bool") and not param.Fixed and not covered[param.Name] then
			local port: PortDef = {
				Name = param.Name,
				Type = param.Type :: string,
				Label = param.Label,
				Optional = true,
				Param = param.Name,
				Setting = true,
			}
			table.insert(def.Inputs, port)
		end
	end
	SpellRunes.Runes[def.Id] = def
	table.insert(SpellRunes.Order, def.Id)
end

-- ParamOf[runeId][inputPort] = the param an unwired input falls back to;
-- PortOf[runeId][param] = the input that overrides a param.
SpellRunes.ParamOf = {} :: { [string]: { [string]: string } }
SpellRunes.PortOf = {} :: { [string]: { [string]: string } }
for _, def in defs do
	local paramOf, portOf = {}, {}
	for _, port in def.Inputs do
		if port.Param then
			paramOf[port.Name] = port.Param
			portOf[port.Param] = port.Name
		end
	end
	SpellRunes.ParamOf[def.Id] = paramOf
	SpellRunes.PortOf[def.Id] = portOf
end

-- A param's value clamped to its range (wired values can be anything).
function SpellRunes.ClampParam(param: ParamDef, value: any): any
	if param.Type == "number" then
		if typeof(value) ~= "number" or value ~= value then
			return param.Default
		end
		if param.Step and param.Step >= 1 then
			value = math.floor(value + 0.5)
		end
		return math.clamp(value, param.Min or -math.huge, param.Max or math.huge)
	elseif param.Type == "bool" then
		return value == true
	end
	return value
end

--------------------------------------------------------------------------------
-- Vessel numbers and costs
--------------------------------------------------------------------------------

-- Base stats per projectile. Radius is the hitbox (a Beam's is half its
-- width), Scale the visual size multiplier, Impact multiplies element
-- impact damage. Placed vessels: how far from you a cast-time one may go.
SpellRunes.Vessels = {
	Orb = { Speed = 85, Radius = 0.7, Lifetime = 4, Scale = 1, Impact = 1.0 },
	Bullet = { Speed = 300, Radius = 0.15, Lifetime = 2, Scale = 1, Impact = 0.9 },
	Beam = { Speed = 2000, Lifetime = 3, Radius = 0.35, Scale = 1, Impact = 0.8 },
	Explosion = { Impact = 0.9, MaxCastRange = 120 },
	Smite = { Impact = 0.8 },
	Barrier = { MaxCastRange = 150 },
	Force = {},
	Blink = {},
	Effect = {},
	TimeField = { MaxCastRange = 150 },
}

-- What non-damaging magic costs, in energy.
SpellRunes.Costs = {
	BarrierHealth = 0.25, -- per HP
	BarrierArea = 0.003, -- per square stud of surface per second
	ForceSpeed = 0.2, -- per stud/s per body
	ForceHeld = 0.5, -- x(1 + this x seconds held)
	ForceRagdoll = 4, -- per body
	BlinkStud = 0.4, -- per stud travelled
	FieldBase = 2,
	FieldVolume = 0.04, -- x radius² x |ln scale| x seconds
	ExplosionFreeRadius = 4, -- studs of blast radius that cost nothing
	ExplosionRadius = 0.02, -- energy fraction per stud beyond that
	ExplosionMaxCost = 0.6,
}

-- A barrier's surface area (square studs) -- what holding it up costs.
function SpellRunes.BarrierArea(shape: string, width: number, height: number, depth: number): number
	if shape == "Dome" then
		return 2 * math.pi * (width / 2) * height
	elseif shape == "Sphere" then
		return math.pi * width * height
	elseif shape == "Ring" then
		return math.pi * width * height
	end
	return width * height + width * depth + height * depth
end

function SpellRunes.BarrierCost(p: { [string]: any }): number
	local costs = SpellRunes.Costs
	return p.Health * costs.BarrierHealth + SpellRunes.BarrierArea(p.Shape, p.Width, p.Height, p.Depth) * p.Duration * costs.BarrierArea
end

-- One body's share of a Force.
function SpellRunes.ForceCost(p: { [string]: any }): number
	local costs = SpellRunes.Costs
	return p.Speed * costs.ForceSpeed * (1 + p.Duration * costs.ForceHeld) + (if p.Ragdoll then costs.ForceRagdoll else 0)
end

function SpellRunes.FieldCost(p: { [string]: any }): number
	local costs = SpellRunes.Costs
	return costs.FieldBase + p.Radius ^ 2 * math.abs(math.log(math.max(p.Scale, 0.01))) * p.Duration * costs.FieldVolume
end

-- Energy fraction an Explosion of `radius` spends on its size.
function SpellRunes.ExplosionCost(radius: number): number
	local costs = SpellRunes.Costs
	return math.clamp((radius - costs.ExplosionFreeRadius) * costs.ExplosionRadius, 0, costs.ExplosionMaxCost)
end

-- The bounded Radius (1..30) and Size (0.3..4) settings produce this range.
-- Shared by damage previews and runtime, before split-energy radius scaling.
function SpellRunes.ExplosionRadius(radius: number, sizeFactor: number?): number
	return math.clamp(radius * (sizeFactor or 1), 0.3, 120)
end

-- Body effects. Power is HP (Heal, Shield) or a percentage capped at Cap
-- (Scale effects: Haste/Quicken x(1 + p), Slow/Dilate x(1 - p), Empower +p
-- outgoing damage, Weaken +p damage taken). Cost: per HP (Instant / Pool),
-- per percent per second (Scale), per second (Timed), or Flat.
SpellRunes.Effects = {
	Heal = { Kind = "Instant", Helpful = true, Cost = 1 / 1.5, Cap = 500, Color = Color3.fromRGB(110, 255, 150) },
	Cleanse = { Kind = "Instant", Helpful = true, Flat = 10, Color = Color3.fromRGB(230, 255, 255) },
	Shield = { Kind = "Pool", Helpful = true, Cost = 0.5, Cap = 500, Color = Color3.fromRGB(120, 200, 255) },
	Haste = { Kind = "Scale", Helpful = true, Cost = 0.1, Cap = 100, Color = Color3.fromRGB(255, 240, 120) },
	Slow = { Kind = "Scale", Helpful = false, Cost = 0.115, Cap = 80, Color = Color3.fromRGB(120, 140, 255) },
	Empower = { Kind = "Scale", Helpful = true, Cost = 0.24, Cap = 100, Color = Color3.fromRGB(255, 120, 80) },
	Weaken = { Kind = "Scale", Helpful = false, Cost = 0.24, Cap = 100, Color = Color3.fromRGB(170, 90, 200) },
	Quicken = { Kind = "Scale", Helpful = true, Cost = 0.19, Cap = 100, Color = Color3.fromRGB(255, 220, 160) },
	Dilate = { Kind = "Scale", Helpful = false, Cost = 0.2, Cap = 80, Color = Color3.fromRGB(150, 120, 255) },
	Root = { Kind = "Timed", Helpful = false, Cost = 15, Color = Color3.fromRGB(150, 110, 70) },
	Levitate = { Kind = "Timed", Helpful = true, Cost = 5, Color = Color3.fromRGB(200, 240, 255) },
}

-- Power after the effect's cap (HP, or a percentage).
function SpellRunes.EffectPower(effect: string, power: number): number
	local def = SpellRunes.Effects[effect]
	return if def and def.Cap then math.clamp(power, 0, def.Cap) else math.max(power, 0)
end

-- What one target of a body effect costs.
function SpellRunes.EffectCost(effect: string, power: number, duration: number): number
	local def = SpellRunes.Effects[effect]
	if not def then
		return 0
	end
	power = SpellRunes.EffectPower(effect, power)
	if def.Flat then
		return def.Flat
	elseif def.Kind == "Instant" or def.Kind == "Pool" then
		return power * def.Cost
	elseif def.Kind == "Timed" then
		return duration * def.Cost
	end
	return power * duration * def.Cost
end

-- Energy fraction a modifier consumes, from its (resolved) params.
function SpellRunes.ModifierCost(runeId: string, p: { [string]: any }): number
	if runeId == "Quantity" then
		return 0.02 * ((p.Count or 1) - 1)
	elseif runeId == "Speed" then
		return 0.065 * math.max((p.Factor or 1) - 1, 0)
	elseif runeId == "Size" then
		return 0.075 * math.max((p.Factor or 1) - 1, 0)
	elseif runeId == "Range" then
		return 0.06 * math.max((p.Factor or 1) - 1, 0)
	elseif runeId == "Gravity" then
		return 0.0003 * math.abs(p.Pull or 0)
	elseif runeId == "Bounce" then
		return 0.05 * (p.Count or 0)
	elseif runeId == "Pierce" then
		return 0.06 * (p.Count or 0)
	elseif runeId == "Homing" then
		return 0.0006 * (p.Turn or 0) + 0.0004 * (p.Radius or 0)
	elseif runeId == "Sustain" then
		return 0.04 * (p.Seconds or 0)
	end
	return 0
end

-- 1..5 marks for a modifier on the spell circle (how much it does).
function SpellRunes.ModifierDots(runeId: string, p: { [string]: any }): number?
	if runeId == "Quantity" then
		return nil
	end
	return math.clamp(math.floor(SpellRunes.ModifierCost(runeId, p) / 0.04 + 0.5), 1, 5)
end

-- Flight modifiers shape projectiles; placed explosions also support Size
-- and Range. Never accept a modifier that the runtime would silently ignore.
SpellRunes.Flying = { Orb = true, Bullet = true, Beam = true } :: { [string]: boolean }

function SpellRunes.ModifierApplies(vesselId: string, modifierId: string): boolean
	if vesselId == "Explosion" then
		return modifierId == "Size" or modifierId == "Range"
	end
	if modifierId == "Sustain" then
		return vesselId == "Beam"
	end
	return SpellRunes.Flying[vesselId] == true
end

-- Projectiles carry every trigger; Barriers and Time Fields stand still, so
-- they can't impact (On Expire fires when they break or fade).
function SpellRunes.TriggerApplies(vesselId: string, triggerId: string): boolean
	if SpellRunes.Flying[vesselId] then
		return true
	end
	if vesselId == "Barrier" or vesselId == "TimeField" then
		return triggerId ~= "OnImpact"
	end
	return false
end

-- Hold-to-charge casting (spells without Sustain; Sustain keeps press-to-cast,
-- hold-to-channel). Charge grows 1 per FullTime seconds held, from Min (a
-- quick click) to Max. Up to 1 it scales the energy -- and mana -- spent; past
-- 1 it adds copies, up to MaxCopyMultiplier x at Max, with energy scaled up by
-- the same factor so the extra copies are full strength. The server measures
-- the hold itself (SpellChannel "ChargeBegin" -> SpellCast).
SpellRunes.Charge = {
	FullTime = 1, -- seconds held to reach charge 1
	Min = 0.25, -- charge of an instant click
	Max = 2,
	MaxCopyMultiplier = 1.5,
	OverchargeSpread = 12, -- degrees: fan for extra copies of a Quantity-less vessel
	StaleAfter = 30, -- a ChargeBegin older than this is ignored (counts as a click)
}

-- Freezing (R while charging): the charged spell is paid for and hangs where
-- its circle was; T launches the oldest toward the cursor. Freezing one more
-- than MaxQueued fires the oldest first. MaxDistance bounds how far from the
-- caster's head a client may claim its frozen circle sits.
SpellRunes.Freeze = {
	MaxQueued = 3,
	MaxDistance = 8,
	AssembleTime = 0.45, -- seconds a frozen spell's cloud takes to reassemble before it launches
}

-- Limits on what one cast may do at runtime (SpellRuntime): flow steps it
-- runs (per trigger event, once triggers fire), vessels it fires
-- (explosions don't count), how long its delayed parts may wait (real
-- seconds after the cast), how many of them may be waiting at once, and how
-- deep Invoke may nest.
SpellRunes.Budget = {
	Steps = 4000,
	Vessels = 160,
	Lifetime = 60,
	Pending = 80,
	InvokeDepth = 4,
}

function SpellRunes.ChargeFromHold(seconds: number): number
	local charge = SpellRunes.Charge
	return math.clamp(seconds / charge.FullTime, charge.Min, charge.Max)
end

-- Copy multiplier: 1 up to charge 1, then linear to MaxCopyMultiplier at Max.
function SpellRunes.ChargeCopyMultiplier(chargeLevel: number): number
	local charge = SpellRunes.Charge
	local over = math.clamp((chargeLevel - 1) / (charge.Max - 1), 0, 1)
	return 1 + (charge.MaxCopyMultiplier - 1) * over
end

-- Energy (and mana) multiplier: the charge itself up to 1, then the copy
-- multiplier, so each copy keeps its full energy.
function SpellRunes.ChargeEnergyMultiplier(chargeLevel: number): number
	if chargeLevel <= 1 then
		return math.clamp(chargeLevel, 0, 1)
	end
	return SpellRunes.ChargeCopyMultiplier(chargeLevel)
end

-- Whether a compiled spell channels (any vessel with a Sustain modifier);
-- those keep press-to-cast so holding can sustain them.
function SpellRunes.HasSustain(compiled: any): boolean
	for _, info in compiled.vessels or {} do
		for _, modId in info.mods or {} do
			local mod = compiled.runes[modId]
			if mod and mod.rune == "Sustain" then
				return true
			end
		end
	end
	return false
end

SpellRunes.MaxModifierCost = 0.85
SpellRunes.MaxTriggerShare = 0.9

function SpellRunes.Get(id: string): RuneDef?
	return SpellRunes.Runes[id]
end

function SpellRunes.FindPort(ports: { PortDef }, name: string): PortDef?
	for _, port in ports do
		if port.Name == name then
			return port
		end
	end
	return nil
end

function SpellRunes.FindParam(def: RuneDef, name: string): ParamDef?
	for _, param in def.Params do
		if param.Name == name then
			return param
		end
	end
	return nil
end

-- Default params for a freshly placed rune.
function SpellRunes.DefaultParams(id: string): { [string]: any }
	local params = {}
	local def = SpellRunes.Runes[id]
	if def then
		for _, param in def.Params do
			params[param.Name] = param.Default
		end
	end
	return params
end

return SpellRunes
