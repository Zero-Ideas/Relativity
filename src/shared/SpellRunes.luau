--!strict
--[[
	SpellRunes.luau
	The rune catalog for the spell whiteboard: zone kinds, port types,
	elements and every rune's ports/params. Pure data, shared by the editor
	(client), the compiler (both) and the runtime (server) so all three agree
	on what a rune is.

	Spell model
	 - Mana is energy. A Mana Well pushes its Amount along "flow" wires; every
	   cast charges the sum of all wells. Energy is conserved: a flow output
	   feeds at most one wire (use Divide to split it), If routes it one way,
	   and a Vessel turns what arrives into its effect after its modifiers and
	   triggers take their cut.
	 - Flow runes (Branch zone) shape WHEN and WHERE the rest of the circle
	   runs: Delay waits, Repeat runs it several times, For Each once per
	   entity in a list, Wait Until polls a condition, Conjure Circle moves the
	   circle somewhere else (a new circle appears there), Store writes to the
	   caster's memory.
	 - Values (number / bool / entity / point / list) are computed by Sensor,
	   Logic and Vector runes whenever the flow that needs them runs: at cast
	   time, or at the moment a Trigger fires, a Repeat comes round again...
	   Flow runes and triggers also OUTPUT values about their moment (a
	   trigger's impact point, a Repeat's index, the entity For Each is on),
	   readable by anything downstream of them.
	 - An input port with a `Param` falls back to that param when unwired, so
	   constants never need a Number rune.
	 - Every rune must sit inside a zone whose kind it allows. Zones are the
	   player-drawn structure of the circle.

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
	ModifierCost: number?, -- energy fraction consumed per level (Modifier runes)
	Vessel: boolean?, -- an Output rune that gives magic its form
	Damaging: boolean?, -- a vessel that deals damage: needs an element (Transform) upstream
	Instant: boolean?, -- a vessel with no flight (Explosion, Force, Blink, Effect)
	Pass: boolean?, -- a flow rune that passes energy on (Delay, Repeat, For Each...)
}

--------------------------------------------------------------------------------
-- Zones
--------------------------------------------------------------------------------

SpellRunes.ZoneKinds = { "Input", "Targeting", "Conditional", "Branch", "Transform", "Modifier", "Output", "Trigger" }

SpellRunes.Zones = {
	Input = { Color = Color3.fromRGB(80, 170, 255), Description = "Where mana enters the circle." },
	Targeting = { Color = Color3.fromRGB(90, 220, 150), Description = "Decides where the spell aims. Leave it out to aim at the mouse. Holds any value rune." },
	Conditional = { Color = Color3.fromRGB(255, 205, 80), Description = "Sensors, logic and vector math that compute values and conditions." },
	Branch = { Color = Color3.fromRGB(255, 150, 70), Glyph = "Δ", Description = "Controls the flow of mana: route, split, wait, repeat, loop over entities, or conjure a new circle elsewhere." },
	Transform = { Color = Color3.fromRGB(255, 95, 80), Description = "Converts raw mana into an element." },
	Modifier = { Color = Color3.fromRGB(170, 130, 255), Description = "Shapes how a vessel flies, how many there are, how big and how long it lasts." },
	Output = { Color = Color3.fromRGB(255, 90, 140), Description = "Where energy leaves the circle: Vessels give the magic its form -- projectiles, blasts, barriers, forces, blinks and body effects." },
	Trigger = { Color = Color3.fromRGB(80, 215, 230), Description = "Runs more of the circle while a vessel is in flight, or where it lands." },
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
local LEVEL: ParamDef = { Name = "Level", Label = "Level", Type = "number", Default = 1, Min = 1, Max = 5, Step = 1 }
local SHARE: ParamDef = { Name = "Share", Label = "Energy share", Type = "number", Default = 50, Min = 10, Max = 90, Step = 5, Suffix = "%" }
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
local function num(name: string, label: string, default: number, min: number, max: number, step: number, suffix: string?): ParamDef
	return { Name = name, Label = label, Type = "number", Default = default, Min = min, Max = max, Step = step, Suffix = suffix }
end
local function vesselDef(id: string, name: string, glyph: string, description: string): RuneDef
	return {
		Id = id, Name = name, Glyph = glyph, Category = "Vessel", Zones = { "Output" }, Vessel = true, Damaging = true,
		Description = description,
		Inputs = {
			flowIn(),
			modsIn(),
			{ Name = "aim", Type = "point", Label = "Aim", Optional = true },
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
		Params = { { Name = "Amount", Label = "Mana", Type = "number", Default = 30, Min = 1, Max = 1000, Step = 1, Suffix = " mana" } },
	},

	-- Targeting -----------------------------------------------------------------
	{
		Id = "Target", Name = "Aim", Glyph = "⊕", Category = "Targeting", Zones = { "Targeting" },
		Description = "Where a vessel points: wire Aim into a vessel's Aim port. With nothing in Aim at it aims at your mouse; feed it a point or entity (e.g. Nearest Entity) to aim there instead, falling back to the mouse when that's empty.",
		Inputs = { { Name = "point", Type = "point", Label = "Aim at", Optional = true } },
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
		Id = "Nearest", Name = "Nearest Entity", Glyph = "Π", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "Closest living entity (never you) within Radius of From. From defaults to Here. Hostile = anything your magic can hurt; Ally = your party.",
		Inputs = { { Name = "from", Type = "point", Label = "From", Optional = true } },
		Outputs = { { Name = "entity", Type = "entity", Label = "Entity" } },
		Params = {
			{ Name = "Radius", Label = "Radius", Type = "number", Default = 60, Min = 5, Max = 200, Step = 5, Suffix = " st" },
			{ Name = "Filter", Label = "Only", Type = "enum", Default = "Enemy", Options = SCAN_FILTERS },
		},
	},
	{
		Id = "Scan", Name = "Scan Area", Glyph = "☼", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "Every living entity within Radius of From (default Here), sorted, up to Max. Feed the list to For Each to act on each one; First is the top of the list, Count how many there are.",
		Inputs = { { Name = "from", Type = "point", Label = "From", Optional = true } },
		Outputs = {
			{ Name = "list", Type = "list", Label = "Entities" },
			{ Name = "first", Type = "entity", Label = "First" },
			{ Name = "count", Type = "number", Label = "Count" },
		},
		Params = {
			num("Radius", "Radius", 30, 1, 200, 1, " st"),
			{ Name = "Filter", Label = "Only", Type = "enum", Default = "Hostile", Options = SCAN_FILTERS },
			{ Name = "Sort", Label = "Sort", Type = "enum", Default = "Nearest", Options = { "Nearest", "Farthest", "Weakest", "Strongest", "Random" } },
			num("Max", "Max", 8, 1, 24, 1),
			{ Name = "Self", Label = "Include you", Type = "bool", Default = false },
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
		Params = { { Name = "Mode", Label = "As", Type = "enum", Default = "Points", Options = { "Points", "Percent" } } },
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
			{ Name = "Check", Label = "Is", Type = "enum", Default = "Hostile", Options = {
				"Hostile", "Ally", "You", "Grounded", "Airborne", "Moving",
				"Burning", "Stunned", "Shielded", "Hasted", "Slowed", "Rooted", "Levitating",
			} },
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
			{ Name = "from", Type = "point", Label = "From", Optional = true },
			{ Name = "dir", Type = "point", Label = "Direction", Optional = true },
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
		Description = "Reads a memory Slot written by Store -- by this spell or any other of yours this session. Mark a spot with one spell and blink back to it with another.",
		Inputs = {},
		Outputs = {
			{ Name = "point", Type = "point", Label = "Point" },
			{ Name = "number", Type = "number", Label = "Number" },
			{ Name = "entity", Type = "entity", Label = "Entity" },
			{ Name = "set", Type = "bool", Label = "Is set" },
		},
		Params = { { Name = "Slot", Label = "Slot", Type = "enum", Default = "A", Options = SLOTS } },
	},

	-- Logic ---------------------------------------------------------------------
	{
		Id = "Number", Name = "Number", Glyph = "κ", Category = "Logic", Zones = VALUE_ZONES,
		Description = "A constant.",
		Inputs = {}, Outputs = { { Name = "value", Type = "number", Label = "Value" } },
		Params = { { Name = "Value", Label = "Value", Type = "number", Default = 30, Min = -10000, Max = 10000, Step = 1 } },
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
			{ Name = "Op", Label = "Op", Type = "enum", Default = "+", Options = { "+", "-", "×", "÷", "min", "max", "^", "mod" } },
			num("A", "A", 0, -10000, 10000, 0.1),
			num("B", "B", 1, -10000, 10000, 0.1),
		},
	},
	{
		Id = "Func", Name = "Function", Glyph = "ƒ", Category = "Logic", Zones = VALUE_ZONES,
		Description = "Applies a function to a number. sin and cos take degrees.",
		Inputs = { { Name = "a", Type = "number", Label = "In" } },
		Outputs = { { Name = "value", Type = "number", Label = "Result" } },
		Params = { { Name = "Op", Label = "Function", Type = "enum", Default = "abs", Options = { "abs", "−x", "floor", "ceil", "round", "√", "sin", "cos", "sign" } } },
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
			{ Name = "Op", Label = "Op", Type = "enum", Default = "<", Options = { "<", "≤", "=", "≠", "≥", ">" } },
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
			{ Name = "a", Type = "entity", Label = "Then", Optional = true },
			{ Name = "b", Type = "entity", Label = "Else", Optional = true },
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

	-- Vectors -------------------------------------------------------------------
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
			{ Name = "point", Type = "point", Label = "Point", Optional = true },
			{ Name = "by", Type = "point", Label = "By", Optional = true },
		},
		Outputs = { { Name = "point", Type = "point", Label = "Point" } },
		Params = { num("X", "X", 0, -500, 500, 0.5), num("Y", "Y", 10, -500, 500, 0.5), num("Z", "Z", 0, -500, 500, 0.5), SPACE },
	},
	{
		Id = "VecMath", Name = "Point Math", Glyph = "×", Category = "Vector", Zones = VALUE_ZONES,
		Description = "A op B on points and vectors: add, subtract, scale A by N, Lerp from A to B by N (0..1), Midpoint, Unit (A's direction), Cross, or Rotate A about the vertical axis by N degrees.",
		Inputs = {
			{ Name = "a", Type = "point", Label = "A" },
			{ Name = "b", Type = "point", Label = "B", Optional = true },
			{ Name = "n", Type = "number", Label = "N", Optional = true, Param = "N" },
		},
		Outputs = { { Name = "result", Type = "point", Label = "Result" }, { Name = "length", Type = "number", Label = "Length" } },
		Params = {
			{ Name = "Op", Label = "Op", Type = "enum", Default = "A+B", Options = { "A+B", "A−B", "A×N", "Lerp", "Midpoint", "Unit", "Cross", "Rotate" } },
			num("N", "N", 1, -1000, 1000, 0.05),
		},
	},
	{
		Id = "Direction", Name = "Direction", Glyph = "↗", Category = "Vector", Zones = VALUE_ZONES,
		Description = "The direction (a unit vector) and distance from From (default Here) to To (default where the spell is aiming).",
		Inputs = {
			{ Name = "from", Type = "point", Label = "From", Optional = true },
			{ Name = "to", Type = "point", Label = "To", Optional = true },
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
		Params = { { Name = "Share", Label = "Share to A", Type = "number", Default = 50, Min = 5, Max = 95, Step = 5, Suffix = "%" } },
	},
	{
		Id = "Delay", Name = "Delay", Glyph = "◐", Category = "Branch", Zones = { "Branch" }, Pass = true,
		Description = "Waits, then passes the energy on. Everything after it senses the world afresh. Time dilation slows the wait.",
		Inputs = { flowIn(), { Name = "seconds", Type = "number", Label = "Seconds", Optional = true, Param = "Seconds" } },
		Outputs = { flowOut() },
		Params = { num("Seconds", "Wait", 0.5, 0, 10, 0.05, "s") },
	},
	{
		Id = "Repeat", Name = "Repeat", Glyph = "∞", Category = "Branch", Zones = { "Branch" }, Pass = true,
		Description = "Runs what follows Count times, Interval apart, sharing the energy evenly. Index counts 1, 2, 3... Each time senses the world afresh.",
		Inputs = { flowIn(), { Name = "count", Type = "number", Label = "Count", Optional = true, Param = "Count" } },
		Outputs = { flowOut("each", "Each time"), { Name = "index", Type = "number", Label = "Index" } },
		Params = { num("Count", "Count", 3, 1, 20, 1), num("Interval", "Interval", 0.25, 0, 3, 0.05, "s") },
	},
	{
		Id = "ForEach", Name = "For Each", Glyph = "∀", Category = "Branch", Zones = { "Branch" }, Pass = true,
		Description = "Runs what follows once per entity in the list (up to Max), sharing the energy. Vessels after it aim at that entity unless aimed elsewhere; Entity and Index tell you which one. An empty list sends all the energy to If empty.",
		Inputs = { flowIn(), { Name = "list", Type = "list", Label = "Entities" } },
		Outputs = {
			flowOut("each", "Each"),
			flowOut("none", "If empty"),
			{ Name = "entity", Type = "entity", Label = "Entity" },
			{ Name = "index", Type = "number", Label = "Index" },
			{ Name = "count", Type = "number", Label = "Count" },
		},
		Params = { num("Max", "Max", 8, 1, 24, 1), num("Interval", "Interval", 0, 0, 1, 0.02, "s") },
	},
	{
		Id = "Await", Name = "Wait Until", Glyph = "∵", Category = "Branch", Zones = { "Branch" }, Pass = true,
		Description = "Holds the energy, checking the condition every Every seconds; Then runs the moment it's true, Timed out if it never is. Traps, mines and ambushes.",
		Inputs = { flowIn(), { Name = "cond", Type = "bool", Label = "Condition" } },
		Outputs = { flowOut("then", "Then"), flowOut("timeout", "Timed out") },
		Params = { num("Timeout", "Timeout", 5, 0.1, 30, 0.1, "s"), num("Every", "Every", 0.1, 0.05, 1, 0.05, "s") },
	},
	{
		Id = "Conjure", Name = "Conjure Circle", Glyph = "◉", Category = "Branch", Zones = { "Branch" }, Pass = true,
		Description = "Draws a new magic circle at At (default Here) raised by Height, and runs the rest of the circle from there once it has drawn in (Delay). It faces Face if wired; otherwise it looks back down at where it was conjured from, or along your aim. Here becomes the circle.",
		Inputs = {
			flowIn(),
			{ Name = "at", Type = "point", Label = "At", Optional = true },
			{ Name = "face", Type = "point", Label = "Face", Optional = true },
		},
		Outputs = { flowOut(), { Name = "point", Type = "point", Label = "Circle" } },
		Params = { num("Height", "Height", 12, -20, 60, 0.5, " st"), num("Delay", "Draw time", 0.6, 0, 5, 0.05, "s"), num("Size", "Size", 1, 0.5, 3, 0.1, "×") },
	},
	{
		Id = "Store", Name = "Store", Glyph = "▣", Category = "Branch", Zones = { "Branch" }, Pass = true,
		Description = "Writes whatever is wired into a memory Slot of yours (Recall reads it, in any of your spells), then passes the energy on.",
		Inputs = {
			flowIn(),
			{ Name = "point", Type = "point", Label = "Point", Optional = true },
			{ Name = "number", Type = "number", Label = "Number", Optional = true },
			{ Name = "entity", Type = "entity", Label = "Entity", Optional = true },
		},
		Outputs = { flowOut() },
		Params = { { Name = "Slot", Label = "Slot", Type = "enum", Default = "A", Options = SLOTS } },
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
		Id = "Speed", Name = "Speed", Glyph = "v", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.03,
		Description = "Faster flight (×1.3 to ×3.2), including Beam segments.",
		Inputs = {}, Outputs = { modOut() }, Params = { LEVEL },
	},
	{
		Id = "Size", Name = "Size", Glyph = "λ", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.04,
		Description = "Bigger (×1.4 to ×3.6): projectile hitboxes, a wider Beam, a bigger blast, Barrier, Time Field or Force area.",
		Inputs = {}, Outputs = { modOut() }, Params = { LEVEL },
	},
	{
		Id = "Gravity", Name = "Gravity", Glyph = "g", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.01,
		Description = "Arcing flight, including Beam segments.",
		Inputs = {}, Outputs = { modOut() }, Params = { LEVEL },
	},
	{
		Id = "Bounce", Name = "Bounce", Glyph = "∠", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.05,
		Description = "Ricochets off walls Level times. Beams reflect too.",
		Inputs = {}, Outputs = { modOut() }, Params = { LEVEL },
	},
	{
		Id = "Pierce", Name = "Pierce", Glyph = "‡", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.06,
		Description = "Passes through Level enemies (15% less damage each).",
		Inputs = {}, Outputs = { modOut() }, Params = { LEVEL },
	},
	{
		Id = "Quantity", Name = "Quantity", Glyph = "Σ", Category = "Modifier", Zones = { "Modifier" },
		Description = "Fires Count copies that share the energy: a Fan across Spread degrees, a Ring around the aim, or a Stream one after another.",
		Inputs = {}, Outputs = { modOut() },
		Params = {
			{ Name = "Count", Label = "Count", Type = "number", Default = 3, Min = 1, Max = 12, Step = 1 },
			{ Name = "Pattern", Label = "Pattern", Type = "enum", Default = "Fan", Options = { "Fan", "Ring", "Stream" } },
			{ Name = "Spread", Label = "Spread", Type = "number", Default = 20, Min = 0, Max = 120, Step = 1, Suffix = "°" },
			{ Name = "Interval", Label = "Stream gap", Type = "number", Default = 0.08, Min = 0.03, Max = 0.5, Step = 0.01, Suffix = "s" },
		},
	},
	{
		Id = "Homing", Name = "Homing", Glyph = "◎", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.06,
		Description = "Seeks targets. Wire an entity into Lock on to chase that one; otherwise it finds its own. Beams steer in flight too.",
		Inputs = { { Name = "entity", Type = "entity", Label = "Lock on", Optional = true } },
		Outputs = { modOut() },
		Params = { LEVEL, { Name = "Filter", Label = "Seek", Type = "enum", Default = "Enemy", Options = FILTERS } },
	},
	{
		Id = "Range", Name = "Range", Glyph = "↔", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.03,
		Description = "Lasts or reaches further (×1.3 to ×3.5): flight time, Barrier / Time Field / Effect duration, Blink distance.",
		Inputs = {}, Outputs = { modOut() }, Params = { LEVEL },
	},
	{
		Id = "Sustain", Name = "Sustain", Glyph = "τ", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.04,
		Description = "Beam only: hold to channel for up to 1–5 seconds; release to stop. Follows live aim. Energy is shared across the maximum duration; segments keep all flight modifiers and triggers.",
		Inputs = {}, Outputs = { modOut() }, Params = { LEVEL },
	},

	-- Vessels (the form the magic takes) ---------------------------------------
	vesselDef("Orb", "Orb", "◯", "A slow, heavy sphere of magic with a big hitbox. Flies at your mouse unless something is wired into Aim."),
	vesselDef("Bullet", "Bullet", "▶", "A fast, thin tracer. Flies at your mouse unless something is wired into Aim."),
	vesselDef("Beam", "Beam", "═", "A cylinder of magic traveling at 2000 studs/s. Supports all flight modifiers and triggers; Sustain emits a continuous cursor-following beam."),
	{
		Id = "Explosion", Name = "Explosion", Glyph = "✽", Category = "Vessel", Zones = { "Output" }, Vessel = true, Damaging = true, Instant = true,
		Description = "Bursts on the spot, hitting everything within 8 studs (Size widens it): full damage at the centre, half at the edge. Fed by On Impact it goes off at the impact point; cast directly it goes off at At, or your mouse. Only Size applies.",
		Inputs = {
			flowIn(),
			modsIn(),
			{ Name = "aim", Type = "point", Label = "At", Optional = true },
		},
		Outputs = {},
		Params = {},
	},
	{
		Id = "Barrier", Name = "Barrier", Glyph = "▥", Category = "Vessel", Zones = { "Output" }, Vessel = true,
		Description = "Raises a solid barrier of magic at At (cast: your mouse; in a trigger: Here) for Duration seconds: a Wall facing you, a Dome over the spot, a Platform to stand on, or a Pillar that rises from the ground. It blocks bodies and projectiles (yours pass through) and holds 4 damage per energy. Size and Range apply; triggers can watch it (On Expire fires when it breaks or fades).",
		Inputs = {
			flowIn(),
			modsIn(),
			{ Name = "aim", Type = "point", Label = "At", Optional = true },
		},
		Outputs = { { Name = "vessel", Type = "vessel", Label = "Triggers" } },
		Params = {
			{ Name = "Shape", Label = "Shape", Type = "enum", Default = "Wall", Options = { "Wall", "Dome", "Platform", "Pillar" } },
			num("Duration", "Duration", 6, 1, 30, 0.5, "s"),
		},
	},
	{
		Id = "Force", Name = "Force", Glyph = "»", Category = "Vessel", Zones = { "Output" }, Vessel = true, Instant = true,
		Description = "Shoves bodies -- characters, dummies and loose parts. Along: the way Direction points (default: your aim / the vessel's heading). Push / Pull: away from / toward Here. Up: skyward. Hits Target (default: you at cast time -- a dash -- or the struck entity in a trigger), or with Radius above 0 everything within Radius of Here, sharing the energy. 2.5 studs/s per energy. Ragdoll flings them limp.",
		Inputs = {
			flowIn(),
			modsIn(),
			{ Name = "target", Type = "entity", Label = "Target", Optional = true },
			{ Name = "dir", Type = "point", Label = "Direction", Optional = true },
		},
		Outputs = {},
		Params = {
			{ Name = "Mode", Label = "Mode", Type = "enum", Default = "Along", Options = { "Along", "Push", "Pull", "Up" } },
			num("Radius", "Radius", 0, 0, 60, 1, " st"),
			{ Name = "Ragdoll", Label = "Ragdoll", Type = "bool", Default = false },
		},
	},
	{
		Id = "Blink", Name = "Blink", Glyph = "β", Category = "Vessel", Zones = { "Output" }, Vessel = true, Instant = true,
		Description = "Teleports Who (default: you) toward To (cast: your mouse; in a trigger: Here), stopping short of walls. Reaches 2 studs per energy (Range reaches further).",
		Inputs = {
			flowIn(),
			modsIn(),
			{ Name = "who", Type = "entity", Label = "Who", Optional = true },
			{ Name = "to", Type = "point", Label = "To", Optional = true },
		},
		Outputs = {},
		Params = { { Name = "Momentum", Label = "Keep momentum", Type = "bool", Default = true } },
	},
	{
		Id = "Effect", Name = "Body Effect", Glyph = "✚", Category = "Vessel", Zones = { "Output" }, Vessel = true, Instant = true,
		Description = "Works magic on a body: Target (default: you at cast time, or the struck entity in a trigger). Heal and Shield scale with energy; timed effects get stronger with more energy per second of Duration (Range lengthens it). Quicken / Dilate change the body's own flow of time.",
		Inputs = {
			flowIn(),
			modsIn(),
			{ Name = "target", Type = "entity", Label = "Target", Optional = true },
		},
		Outputs = {},
		Params = {
			{ Name = "Effect", Label = "Effect", Type = "enum", Default = "Heal", Options = {
				"Heal", "Shield", "Haste", "Slow", "Root", "Levitate", "Empower", "Weaken", "Quicken", "Dilate", "Cleanse",
			} },
			num("Duration", "Duration", 5, 1, 30, 0.5, "s"),
		},
	},
	{
		Id = "TimeField", Name = "Time Field", Glyph = "◒", Category = "Vessel", Zones = { "Output" }, Vessel = true,
		Description = "A bubble of bent time at At (cast: your mouse; in a trigger: Here): everything inside -- bodies, projectiles, spells -- runs at Scale speed for Duration seconds. Its radius grows with energy and Size; Range lengthens it.",
		Inputs = {
			flowIn(),
			modsIn(),
			{ Name = "aim", Type = "point", Label = "At", Optional = true },
		},
		Outputs = { { Name = "vessel", Type = "vessel", Label = "Triggers" } },
		Params = { num("Scale", "Time scale", 0.3, 0.1, 3, 0.05, "×"), num("Duration", "Duration", 5, 1, 15, 0.5, "s") },
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
		Params = { SHARE },
	},
	{
		Id = "OnExpire", Name = "On Expire", Glyph = "⊘", Category = "Trigger", Zones = { "Trigger" },
		Description = "When the vessel runs out of range without hitting anything -- or a Barrier / Time Field breaks or fades -- releases Share of its energy there.",
		Inputs = { vesselIn() }, Outputs = { flowOut(), { Name = "point", Type = "point", Label = "Point" } }, Params = { SHARE },
	},
	{
		Id = "OnTimer", Name = "On Timer", Glyph = "◓", Category = "Trigger", Zones = { "Trigger" },
		Description = "After Delay seconds, releases Share of the energy -- or, with Pulses above 1, a slice of it every Delay seconds. Detonate ends the vessel after the last pulse.",
		Inputs = { vesselIn() }, Outputs = { flowOut(), { Name = "point", Type = "point", Label = "Point" }, { Name = "pulse", Type = "number", Label = "Pulse" } },
		Params = {
			{ Name = "Delay", Label = "Delay", Type = "number", Default = 0.5, Min = 0.1, Max = 5, Step = 0.1, Suffix = "s" },
			SHARE,
			{ Name = "Detonate", Label = "Detonate", Type = "bool", Default = false },
			num("Pulses", "Pulses", 1, 1, 10, 1),
		},
	},
	{
		Id = "OnProximity", Name = "On Proximity", Glyph = "◌", Category = "Trigger", Zones = { "Trigger" },
		Description = "When an entity comes within Radius of the vessel, releases Share of the energy. Struck Entity is that entity; what it fires aims at it.",
		Inputs = { vesselIn() },
		Outputs = { flowOut(), { Name = "point", Type = "point", Label = "Point" }, { Name = "entity", Type = "entity", Label = "Entity" } },
		Params = {
			{ Name = "Radius", Label = "Radius", Type = "number", Default = 8, Min = 2, Max = 40, Step = 1, Suffix = " st" },
			{ Name = "Filter", Label = "Only", Type = "enum", Default = "Enemy", Options = SCAN_FILTERS },
			SHARE,
			{ Name = "Detonate", Label = "Detonate", Type = "bool", Default = true },
		},
	},
}

-- "⊙ Mana Well" -- the rune's name prefixed with its glyph, when it has one.
function SpellRunes.DisplayName(def: RuneDef): string
	return if def.Glyph then def.Glyph .. "  " .. def.Name else def.Name
end

SpellRunes.Categories = { "Input", "Targeting", "Sensor", "Logic", "Vector", "Branch", "Transform", "Modifier", "Vessel", "Trigger" }
-- Toolbox headings (the Branch category holds every flow rune)
SpellRunes.CategoryLabels = { Branch = "Flow" } :: { [string]: string }
SpellRunes.Order = {} :: { string }
SpellRunes.Runes = {} :: { [string]: RuneDef }
for _, def in defs do
	SpellRunes.Runes[def.Id] = def
	table.insert(SpellRunes.Order, def.Id)
end

-- ParamOf[runeId][inputPort] = the param an unwired input falls back to.
SpellRunes.ParamOf = {} :: { [string]: { [string]: string } }
for _, def in defs do
	local map = {}
	for _, port in def.Inputs do
		if port.Param then
			map[port.Name] = port.Param
		end
	end
	SpellRunes.ParamOf[def.Id] = map
end

-- Per-level numbers used by the runtime (and the editor's estimates). Speed,
-- Size and Range multiply the vessel's base stats below.
SpellRunes.ModifierTables = {
	Speed = { 1.3, 1.6, 2.0, 2.5, 3.2 },
	Size = { 1.4, 1.8, 2.3, 2.9, 3.6 },
	Range = { 1.3, 1.7, 2.2, 2.8, 3.5 },
	Gravity = { 20, 40, 70, 110, 160 },
	HomingRadius = { 30, 45, 60, 80, 100 },
	HomingTurn = { 75, 105, 140, 180, 230 }, -- degrees/s
	Sustain = { 1, 2, 3, 4, 5 }, -- caster-dilated seconds
}

-- Base stats per vessel. Radius is the hitbox (a Beam's is half its width),
-- Scale the visual size multiplier, Impact multiplies element impact damage.
SpellRunes.Vessels = {
	Orb = { Speed = 85, Radius = 0.7, Lifetime = 4, Scale = 1, Impact = 1.0 },
	Bullet = { Speed = 300, Radius = 0.15, Lifetime = 2, Scale = 1, Impact = 0.9 },
	Beam = { Speed = 2000, Lifetime = 3, Radius = 0.35, Scale = 1, Impact = 0.8 },
	-- Radius is the blast radius; MaxCastRange keeps a cast-time blast near you.
	Explosion = { Radius = 3, Impact = 0.9, MaxCastRange = 80 },
	-- Health per energy; how far from you a cast-time barrier may stand.
	Barrier = { HealthPerEnergy = 4, MaxCastRange = 80, MinHealth = 10 },
	-- Velocity change per energy, its cap, and how far the push reaches when
	-- the radius is 0 but there's no single target.
	Force = { SpeedPerEnergy = 2.5, MaxSpeed = 220 },
	Blink = { StudsPerEnergy = 2, MaxDistance = 300 },
	Effect = {},
	TimeField = { Radius = 6, RadiusPerEnergy = 0.08, MaxRadius = 45, MaxCastRange = 120 },
}

-- Barrier shapes (studs at Size 1): Wall/Platform/Pillar are boxes (width,
-- height, depth); Dome is a radius.
SpellRunes.BarrierShapes = {
	Wall = Vector3.new(12, 8, 1),
	Platform = Vector3.new(10, 1, 10),
	Pillar = Vector3.new(4, 12, 4),
	Dome = 7,
}

-- Body effects. Instant ones (Heal, Cleanse) and pools (Shield) scale with
-- energy (PerEnergy). Timed ones get Strength = energy / (Duration x
-- PerSecond), capped at 1, and change their stat by Strength x Swing:
--   Haste/Quicken x(1 + s x Swing), Slow/Dilate x(1 - s x Swing),
--   Empower +s x Swing outgoing damage, Weaken +s x Swing damage taken.
-- Root and Levitate are all-or-nothing: they last min(Duration, energy /
-- PerSecond).
SpellRunes.Effects = {
	Heal = { Kind = "Instant", Helpful = true, PerEnergy = 1.5, Color = Color3.fromRGB(110, 255, 150) },
	Cleanse = { Kind = "Instant", Helpful = true, Color = Color3.fromRGB(230, 255, 255) },
	Shield = { Kind = "Pool", Helpful = true, PerEnergy = 2, Color = Color3.fromRGB(120, 200, 255) },
	Haste = { Kind = "Scale", Helpful = true, PerSecond = 8, Swing = 0.8, Color = Color3.fromRGB(255, 240, 120) },
	Slow = { Kind = "Scale", Helpful = false, PerSecond = 8, Swing = 0.7, Color = Color3.fromRGB(120, 140, 255) },
	Empower = { Kind = "Scale", Helpful = true, PerSecond = 12, Swing = 0.5, Color = Color3.fromRGB(255, 120, 80) },
	Weaken = { Kind = "Scale", Helpful = false, PerSecond = 12, Swing = 0.5, Color = Color3.fromRGB(170, 90, 200) },
	Quicken = { Kind = "Scale", Helpful = true, PerSecond = 15, Swing = 0.8, Color = Color3.fromRGB(255, 220, 160) },
	Dilate = { Kind = "Scale", Helpful = false, PerSecond = 15, Swing = 0.75, Color = Color3.fromRGB(150, 120, 255) },
	Root = { Kind = "Timed", Helpful = false, PerSecond = 15, Color = Color3.fromRGB(150, 110, 70) },
	Levitate = { Kind = "Timed", Helpful = true, PerSecond = 5, Color = Color3.fromRGB(200, 240, 255) },
}

-- What a body effect does with `energy` over `duration` seconds:
-- (strength 0..1 or amount, seconds it lasts).
function SpellRunes.EffectStrength(effect: string, energy: number, duration: number): (number, number)
	local def = SpellRunes.Effects[effect]
	if not def then
		return 0, 0
	end
	if def.Kind == "Instant" then
		return energy * (def.PerEnergy or 0), 0
	elseif def.Kind == "Pool" then
		return energy * (def.PerEnergy or 0), duration
	elseif def.Kind == "Timed" then
		return 1, math.min(duration, energy / (def.PerSecond or 1))
	end
	return math.clamp(energy / (math.max(duration, 0.1) * (def.PerSecond or 1)), 0, 1), duration
end

-- Energy fraction a modifier consumes. Quantity costs per extra copy.
function SpellRunes.ModifierCost(runeId: string, params: { [string]: any }): number
	if runeId == "Quantity" then
		return 0.02 * (params.Count - 1)
	end
	local def = SpellRunes.Runes[runeId]
	return (def and def.ModifierCost or 0) * (params.Level or 0)
end

-- Vessels that fly (projectiles): all flight modifiers and triggers apply.
SpellRunes.Flying = { Orb = true, Bullet = true, Beam = true } :: { [string]: boolean }

-- Modifiers that do something on a vessel that doesn't fly.
local GROUNDED_MODIFIERS: { [string]: { [string]: boolean } } = {
	Explosion = { Size = true },
	Barrier = { Size = true, Range = true },
	Force = { Size = true },
	Blink = { Range = true },
	Effect = { Range = true },
	TimeField = { Size = true, Range = true },
}

function SpellRunes.ModifierApplies(vesselId: string, modifierId: string): boolean
	if modifierId == "Sustain" then return vesselId == "Beam" end
	if SpellRunes.Flying[vesselId] then
		return true
	end
	local allowed = GROUNDED_MODIFIERS[vesselId]
	return allowed ~= nil and allowed[modifierId] == true
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
-- runs, vessels it fires, how long its delayed parts may wait (real seconds
-- after the cast), and how many of them may be waiting at once.
SpellRunes.Budget = {
	Steps = 4000,
	Vessels = 160,
	Lifetime = 45,
	Pending = 80,
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
