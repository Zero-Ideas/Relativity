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
	   and a Vessel (Orb / Bullet / Beam) turns what arrives into damage after its modifiers and
	   triggers take their cut.
	 - Values (number / bool / entity / point) are computed by Sensor and
	   Logic runes whenever the flow that needs them runs: at cast time, or
	   at the moment a Trigger fires in flight.
	 - Every rune must sit inside a zone whose kind it allows. Zones are the
	   player-drawn structure of the circle.

	Port types
	 flow   -- mana energy (one wire out, one wire in)
	 number, bool, entity, point -- values (fan out freely, one wire in)
	 mod    -- Modifier -> Vessel "Modifiers" (many into one)
	 vessel -- Vessel "Triggers" -> Trigger (one vessel may carry many triggers)
	 entity may be wired into a point input (it reads the entity's position).
]]

local SpellRunes = {}

export type PortDef = {
	Name: string,
	Type: string,
	Label: string,
	Optional: boolean?,
	Multi: boolean?,
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
	Category: string,
	Zones: { string },
	Description: string,
	Inputs: { PortDef },
	Outputs: { PortDef },
	Params: { ParamDef },
	Unique: boolean?,
	Element: string?,
	ModifierCost: number?, -- energy fraction consumed per level (Modifier runes)
	Vessel: boolean?, -- an Output rune that gives magic its form (Orb/Bullet/Beam)
	Instant: boolean?, -- a vessel with no flight (Explosion)
}

--------------------------------------------------------------------------------
-- Zones
--------------------------------------------------------------------------------

SpellRunes.ZoneKinds = { "Input", "Targeting", "Conditional", "Branch", "Transform", "Modifier", "Output", "Trigger" }

SpellRunes.Zones = {
	Input = { Color = Color3.fromRGB(80, 170, 255), Description = "Where mana enters the circle." },
	Targeting = { Color = Color3.fromRGB(90, 220, 150), Description = "Decides where the spell aims. Leave it out to aim at the mouse." },
	Conditional = { Color = Color3.fromRGB(255, 205, 80), Description = "Sensors and logic that compute conditions." },
	Branch = { Color = Color3.fromRGB(255, 150, 70), Description = "Routes or splits the flow of mana." },
	Transform = { Color = Color3.fromRGB(255, 95, 80), Description = "Converts raw mana into an element." },
	Modifier = { Color = Color3.fromRGB(170, 130, 255), Description = "Shapes how a vessel flies, how many there are, and what it passes through." },
	Output = { Color = Color3.fromRGB(255, 90, 140), Description = "Where energy leaves the circle: Vessels (Orb, Bullet, Beam) give the magic its form." },
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
	mod = Color3.fromRGB(180, 140, 255),
	vessel = Color3.fromRGB(90, 150, 255),
}

-- Can a wire carrying `from` feed an input of type `to`?
function SpellRunes.Compatible(from: string, to: string): boolean
	return from == to or (from == "entity" and to == "point")
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

local FILTERS = { "Any", "Enemy", "Player" }
local LEVEL: ParamDef = { Name = "Level", Label = "Level", Type = "number", Default = 1, Min = 1, Max = 5, Step = 1 }
local SHARE: ParamDef = { Name = "Share", Label = "Energy share", Type = "number", Default = 50, Min = 10, Max = 90, Step = 5, Suffix = "%" }
local VALUE_ZONES = { "Conditional", "Targeting" }

local function flowIn(): PortDef
	return { Name = "in", Type = "flow", Label = "Energy" }
end
local function flowOut(name: string?, label: string?): PortDef
	return { Name = name or "out", Type = "flow", Label = label or "Energy" }
end
local function modOut(): PortDef
	return { Name = "mod", Type = "mod", Label = "Vessel" }
end
local function vesselIn(): PortDef
	return { Name = "vessel", Type = "vessel", Label = "Vessel" }
end
local function vesselDef(id: string, name: string, description: string, instant: boolean?): RuneDef
	return {
		Id = id, Name = name, Category = "Vessel", Zones = { "Output" }, Vessel = true, Instant = instant,
		Description = description,
		Inputs = {
			flowIn(),
			{ Name = "mods", Type = "mod", Label = "Modifiers", Optional = true, Multi = true },
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
		Id = "Mana", Name = "Mana Well", Category = "Input", Zones = { "Input" },
		Description = "Draws Amount mana each cast and pushes it into the circle as energy.",
		Inputs = {}, Outputs = { flowOut() },
		Params = { { Name = "Amount", Label = "Mana", Type = "number", Default = 30, Min = 1, Max = 1000, Step = 1, Suffix = " mana" } },
	},

	-- Targeting -----------------------------------------------------------------
	{
		Id = "Target", Name = "Aim", Category = "Targeting", Zones = { "Targeting" },
		Description = "Where a vessel points: wire Aim into a vessel's Aim port. With nothing in Aim at it aims at your mouse; feed it a point or entity (e.g. Nearest Entity) to aim there instead, falling back to the mouse when that's empty.",
		Inputs = { { Name = "point", Type = "point", Label = "Aim at", Optional = true } },
		Outputs = { { Name = "point", Type = "point", Label = "Aim" } },
		Params = {},
	},

	-- Sensors -------------------------------------------------------------------
	{
		Id = "Caster", Name = "Caster", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "You.",
		Inputs = {}, Outputs = { { Name = "entity", Type = "entity", Label = "Caster" } }, Params = {},
	},
	{
		Id = "Cursor", Name = "Cursor", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "Where you aimed when casting, and the entity under the crosshair (if any).",
		Inputs = {},
		Outputs = { { Name = "point", Type = "point", Label = "Point" }, { Name = "entity", Type = "entity", Label = "Entity" } },
		Params = {},
	},
	{
		Id = "Here", Name = "Here", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "Where this part of the circle is running: your hand at cast time, or the bolt's position when a trigger fires.",
		Inputs = {}, Outputs = { { Name = "point", Type = "point", Label = "Point" } }, Params = {},
	},
	{
		Id = "Struck", Name = "Struck Entity", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "The entity that set off the current trigger (the one hit, or the one that came close). Empty at cast time.",
		Inputs = {}, Outputs = { { Name = "entity", Type = "entity", Label = "Entity" } }, Params = {},
	},
	{
		Id = "Nearest", Name = "Nearest Entity", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "Closest living entity (never you) within Radius of From. From defaults to Here.",
		Inputs = { { Name = "from", Type = "point", Label = "From", Optional = true } },
		Outputs = { { Name = "entity", Type = "entity", Label = "Entity" } },
		Params = {
			{ Name = "Radius", Label = "Radius", Type = "number", Default = 60, Min = 5, Max = 200, Step = 5, Suffix = " st" },
			{ Name = "Filter", Label = "Only", Type = "enum", Default = "Enemy", Options = FILTERS },
		},
	},
	{
		Id = "Distance", Name = "Distance", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "Studs between two points. Huge if either is empty.",
		Inputs = { { Name = "a", Type = "point", Label = "A" }, { Name = "b", Type = "point", Label = "B" } },
		Outputs = { { Name = "value", Type = "number", Label = "Studs" } }, Params = {},
	},
	{
		Id = "Health", Name = "Health", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "An entity's health (0 if empty).",
		Inputs = { { Name = "entity", Type = "entity", Label = "Entity" } },
		Outputs = { { Name = "value", Type = "number", Label = "Health" } },
		Params = { { Name = "Mode", Label = "As", Type = "enum", Default = "Points", Options = { "Points", "Percent" } } },
	},
	{
		Id = "Exists", Name = "Exists", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "True when the entity is present and alive.",
		Inputs = { { Name = "entity", Type = "entity", Label = "Entity" } },
		Outputs = { { Name = "value", Type = "bool", Label = "Yes" } }, Params = {},
	},
	{
		Id = "IsPlayer", Name = "Is Player", Category = "Sensor", Zones = VALUE_ZONES,
		Description = "True when the entity is a player character.",
		Inputs = { { Name = "entity", Type = "entity", Label = "Entity" } },
		Outputs = { { Name = "value", Type = "bool", Label = "Yes" } }, Params = {},
	},

	-- Logic ---------------------------------------------------------------------
	{
		Id = "Number", Name = "Number", Category = "Logic", Zones = VALUE_ZONES,
		Description = "A constant.",
		Inputs = {}, Outputs = { { Name = "value", Type = "number", Label = "Value" } },
		Params = { { Name = "Value", Label = "Value", Type = "number", Default = 30, Min = -10000, Max = 10000, Step = 1 } },
	},
	{
		Id = "Math", Name = "Math", Category = "Logic", Zones = VALUE_ZONES,
		Description = "A op B. Division by zero gives 0.",
		Inputs = { { Name = "a", Type = "number", Label = "A" }, { Name = "b", Type = "number", Label = "B" } },
		Outputs = { { Name = "value", Type = "number", Label = "Result" } },
		Params = { { Name = "Op", Label = "Op", Type = "enum", Default = "+", Options = { "+", "-", "×", "÷", "min", "max" } } },
	},
	{
		Id = "Compare", Name = "Compare", Category = "Logic", Zones = VALUE_ZONES,
		Description = "True when A op B.",
		Inputs = { { Name = "a", Type = "number", Label = "A" }, { Name = "b", Type = "number", Label = "B" } },
		Outputs = { { Name = "value", Type = "bool", Label = "Result" } },
		Params = { { Name = "Op", Label = "Op", Type = "enum", Default = "<", Options = { "<", "≤", "=", "≠", "≥", ">" } } },
	},
	{
		Id = "And", Name = "And", Category = "Logic", Zones = VALUE_ZONES,
		Description = "True when both are true.",
		Inputs = { { Name = "a", Type = "bool", Label = "A" }, { Name = "b", Type = "bool", Label = "B" } },
		Outputs = { { Name = "value", Type = "bool", Label = "Result" } }, Params = {},
	},
	{
		Id = "Or", Name = "Or", Category = "Logic", Zones = VALUE_ZONES,
		Description = "True when either is true.",
		Inputs = { { Name = "a", Type = "bool", Label = "A" }, { Name = "b", Type = "bool", Label = "B" } },
		Outputs = { { Name = "value", Type = "bool", Label = "Result" } }, Params = {},
	},
	{
		Id = "Not", Name = "Not", Category = "Logic", Zones = VALUE_ZONES,
		Description = "Flips true and false.",
		Inputs = { { Name = "a", Type = "bool", Label = "In" } },
		Outputs = { { Name = "value", Type = "bool", Label = "Result" } }, Params = {},
	},
	{
		Id = "Select", Name = "Choose Point", Category = "Logic", Zones = VALUE_ZONES,
		Description = "Then if the condition holds, otherwise Else. Handy for targeting fallbacks.",
		Inputs = {
			{ Name = "cond", Type = "bool", Label = "If" },
			{ Name = "a", Type = "point", Label = "Then" },
			{ Name = "b", Type = "point", Label = "Else" },
		},
		Outputs = { { Name = "point", Type = "point", Label = "Point" } }, Params = {},
	},

	-- Branch --------------------------------------------------------------------
	{
		Id = "If", Name = "If", Category = "Branch", Zones = { "Branch" },
		Description = "Sends all energy down True or False depending on the condition. An unwired side fizzles.",
		Inputs = { flowIn(), { Name = "cond", Type = "bool", Label = "Condition" } },
		Outputs = { flowOut("yes", "True"), flowOut("no", "False") }, Params = {},
	},
	{
		Id = "Divide", Name = "Divide", Category = "Branch", Zones = { "Branch" },
		Description = "Splits energy between two paths; both run.",
		Inputs = { flowIn() },
		Outputs = { flowOut("a", "A"), flowOut("b", "B") },
		Params = { { Name = "Share", Label = "Share to A", Type = "number", Default = 50, Min = 5, Max = 95, Step = 5, Suffix = "%" } },
	},

	-- Transform -----------------------------------------------------------------
	{
		Id = "Fire", Name = "Fire", Category = "Transform", Zones = { "Transform" }, Element = "Fire",
		Description = "80% of energy on impact, plus a burn worth 35% over 3s.",
		Inputs = { flowIn() }, Outputs = { flowOut() }, Params = {},
	},
	{
		Id = "Arcane", Name = "Arcane", Category = "Transform", Zones = { "Transform" }, Element = "Arcane",
		Description = "All energy lands as impact damage.",
		Inputs = { flowIn() }, Outputs = { flowOut() }, Params = {},
	},
	{
		Id = "Shock", Name = "Shock", Category = "Transform", Zones = { "Transform" }, Element = "Shock",
		Description = "70% of energy on impact, and stuns 0.01s per energy (max 1s).",
		Inputs = { flowIn() }, Outputs = { flowOut() }, Params = {},
	},

	-- Modifiers -----------------------------------------------------------------
	{
		Id = "Speed", Name = "Speed", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.03,
		Description = "Faster flight (×1.3 to ×3.2), including Beam segments.",
		Inputs = {}, Outputs = { modOut() }, Params = { LEVEL },
	},
	{
		Id = "Size", Name = "Size", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.04,
		Description = "Bigger hitbox and visual (×1.4 to ×3.6); a wider Beam.",
		Inputs = {}, Outputs = { modOut() }, Params = { LEVEL },
	},
	{
		Id = "Gravity", Name = "Gravity", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.01,
		Description = "Arcing flight, including Beam segments.",
		Inputs = {}, Outputs = { modOut() }, Params = { LEVEL },
	},
	{
		Id = "Bounce", Name = "Bounce", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.05,
		Description = "Ricochets off walls Level times. Beams reflect too.",
		Inputs = {}, Outputs = { modOut() }, Params = { LEVEL },
	},
	{
		Id = "Pierce", Name = "Pierce", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.06,
		Description = "Passes through Level enemies (15% less damage each).",
		Inputs = {}, Outputs = { modOut() }, Params = { LEVEL },
	},
	{
		Id = "Quantity", Name = "Quantity", Category = "Modifier", Zones = { "Modifier" },
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
		Id = "Homing", Name = "Homing", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.06,
		Description = "Seeks targets. Wire an entity into Lock on to chase that one; otherwise it finds its own. Beams steer in flight too.",
		Inputs = { { Name = "entity", Type = "entity", Label = "Lock on", Optional = true } },
		Outputs = { modOut() },
		Params = { LEVEL, { Name = "Filter", Label = "Seek", Type = "enum", Default = "Enemy", Options = FILTERS } },
	},
	{
		Id = "Range", Name = "Range", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.03,
		Description = "Longer flight time (×1.3 to ×3.5).",
		Inputs = {}, Outputs = { modOut() }, Params = { LEVEL },
	},
	{
		Id = "Sustain", Name = "Sustain", Category = "Modifier", Zones = { "Modifier" }, ModifierCost = 0.04,
		Description = "Beam only: hold to channel for up to 1–5 seconds; release to stop. Follows live aim. Energy is shared across the maximum duration; segments keep all flight modifiers and triggers.",
		Inputs = {}, Outputs = { modOut() }, Params = { LEVEL },
	},

	-- Vessels (the form the magic takes) ---------------------------------------
	vesselDef("Orb", "Orb", "A slow, heavy sphere of magic with a big hitbox. Flies at your mouse unless something is wired into Aim."),
	vesselDef("Bullet", "Bullet", "A fast, thin tracer. Flies at your mouse unless something is wired into Aim."),
	vesselDef("Beam", "Beam", "A cylinder of magic traveling at 2000 studs/s. Supports all flight modifiers and triggers; Sustain emits a continuous cursor-following beam."),
	{
		Id = "Explosion", Name = "Explosion", Category = "Vessel", Zones = { "Output" }, Vessel = true, Instant = true,
		Description = "Bursts on the spot, hitting everything within 8 studs (Size widens it): full damage at the centre, half at the edge. Fed by On Impact it goes off at the impact point; cast directly it goes off at At, or your mouse. Only Size applies.",
		Inputs = {
			flowIn(),
			{ Name = "mods", Type = "mod", Label = "Modifiers", Optional = true, Multi = true },
			{ Name = "aim", Type = "point", Label = "At", Optional = true },
		},
		Outputs = {},
		Params = {},
	},

	-- Triggers ------------------------------------------------------------------
	{
		Id = "OnImpact", Name = "On Impact", Category = "Trigger", Zones = { "Trigger" },
		Description = "When the vessel stops on a wall or enemy, releases Share of its energy from the impact point. What it fires ricochets unless aimed.",
		Inputs = { vesselIn() }, Outputs = { flowOut() }, Params = { SHARE },
	},
	{
		Id = "OnExpire", Name = "On Expire", Category = "Trigger", Zones = { "Trigger" },
		Description = "When the vessel runs out of range without hitting anything, releases Share of its energy there.",
		Inputs = { vesselIn() }, Outputs = { flowOut() }, Params = { SHARE },
	},
	{
		Id = "OnTimer", Name = "On Timer", Category = "Trigger", Zones = { "Trigger" },
		Description = "After Delay seconds of flight, releases Share of the energy. Detonate ends the vessel.",
		Inputs = { vesselIn() }, Outputs = { flowOut() },
		Params = {
			{ Name = "Delay", Label = "Delay", Type = "number", Default = 0.5, Min = 0.1, Max = 5, Step = 0.1, Suffix = "s" },
			SHARE,
			{ Name = "Detonate", Label = "Detonate", Type = "bool", Default = false },
		},
	},
	{
		Id = "OnProximity", Name = "On Proximity", Category = "Trigger", Zones = { "Trigger" },
		Description = "When an entity comes within Radius of the vessel, releases Share of the energy. Struck Entity is that entity; what it fires aims at it.",
		Inputs = { vesselIn() }, Outputs = { flowOut() },
		Params = {
			{ Name = "Radius", Label = "Radius", Type = "number", Default = 8, Min = 2, Max = 40, Step = 1, Suffix = " st" },
			{ Name = "Filter", Label = "Only", Type = "enum", Default = "Enemy", Options = FILTERS },
			SHARE,
			{ Name = "Detonate", Label = "Detonate", Type = "bool", Default = true },
		},
	},
}

SpellRunes.Categories = { "Input", "Targeting", "Sensor", "Logic", "Branch", "Transform", "Modifier", "Vessel", "Trigger" }
SpellRunes.Order = {} :: { string }
SpellRunes.Runes = {} :: { [string]: RuneDef }
for _, def in defs do
	SpellRunes.Runes[def.Id] = def
	table.insert(SpellRunes.Order, def.Id)
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
	Explosion = { Radius = 8, Impact = 0.9, MaxCastRange = 80 },
}

-- Energy fraction a modifier consumes. Quantity costs per extra copy.
function SpellRunes.ModifierCost(runeId: string, params: { [string]: any }): number
	if runeId == "Quantity" then
		return 0.02 * (params.Count - 1)
	end
	local def = SpellRunes.Runes[runeId]
	return (def and def.ModifierCost or 0) * (params.Level or 0)
end

-- Beams use the same flight pipeline as Orb/Bullet. Sustain is Beam-only.

function SpellRunes.ModifierApplies(vesselId: string, modifierId: string): boolean
	if modifierId == "Sustain" then return vesselId == "Beam" end
	if vesselId == "Explosion" then
		return modifierId == "Size"
	end
	return true
end

function SpellRunes.TriggerApplies(vesselId: string, triggerId: string): boolean
	return vesselId ~= "Explosion"
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
