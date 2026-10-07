--!strict
--[[
	SpellCompiler.luau (graph v3)
	Validates a whiteboard spell graph and compiles it into the plan the
	server runtime executes (see server/SpellRuntime.luau). Pure and shared:
	the editor runs it live for feedback and the server runs it again on
	every save and cast, so a client can never smuggle in an invalid circle.

	Graph format
	 {
	   version = 3, name = string,
	   zones = { { id, kind, label?, locked?, x, y, w, h } },          -- board units
	   runes = { { id, rune, x, y, locked?, params = { [name]: value } } }, -- x,y = card top-left
	   wires = { { from, fromPort, to, toPort } },
	 }

	Compile(graph) -> (compiled?, errors, normalized?)
	 errors: { { message: string, rune: string?, zone: string? } }
	 Params are sanitized (clamped / defaulted) rather than rejected.
]]

local SpellRunes = require(script.Parent.SpellRunes)

local SpellCompiler = {}

SpellCompiler.GraphVersion = 3
SpellCompiler.MaxRunes = 64
SpellCompiler.MaxWires = 128
SpellCompiler.MaxZones = 24
SpellCompiler.MaxTriggerDepth = 3
SpellCompiler.MaxChainQuantity = 2 -- Quantity runes allowed along one trigger chain (cast -> trigger -> ...)
SpellCompiler.BoardLimit = 20000

-- Card geometry shared with the editor. A rune "sits in" a zone when the
-- middle of its header does.
SpellCompiler.Layout = { RuneWidth = 176, Header = 30, Row = 22, Footer = 24 }

function SpellCompiler.RuneHeight(runeId: string): number
	local def = SpellRunes.Runes[runeId]
	local rows = if def then math.max(#def.Inputs, #def.Outputs, 1) else 1
	local layout = SpellCompiler.Layout
	return layout.Header + rows * layout.Row + layout.Footer
end

function SpellCompiler.RuneAnchor(rune: any): (number, number)
	local layout = SpellCompiler.Layout
	return rune.x + layout.RuneWidth / 2, rune.y + layout.Header / 2
end

type Error = { message: string, rune: string?, zone: string? }

local function finite(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function validId(value: any): boolean
	return typeof(value) == "string" and #value >= 1 and #value <= 32 and string.match(value, "^[%w_%-]+$") ~= nil
end

local function sanitizeParams(def: any, raw: any): { [string]: any }
	local params = {}
	local source = if typeof(raw) == "table" then raw else {}
	for _, param in def.Params do
		local value = source[param.Name]
		if param.Type == "number" then
			if not finite(value) then
				value = param.Default
			end
			local step = param.Step or 0
			if step > 0 then
				value = math.floor(value / step + 0.5) * step
				-- Remove float noise from steps like 0.1 so saved values stay tidy.
				value = tonumber(string.format("%.4f", value)) :: number
			end
			value = math.clamp(value, param.Min or -math.huge, param.Max or math.huge)
		elseif param.Type == "enum" then
			if typeof(value) ~= "string" or not table.find(param.Options :: { string }, value) then
				value = param.Default
			end
		elseif param.Type == "bool" then
			if typeof(value) ~= "boolean" then
				value = param.Default
			end
		end
		params[param.Name] = value
	end
	return params
end

local function normalize(graph: any, errors: { Error }): (any, any)
	local function fail(message: string, rune: string?, zone: string?)
		table.insert(errors, { message = message, rune = rune, zone = zone })
	end
	if typeof(graph) ~= "table" then
		fail("Spell graph must be a table.")
		return nil, nil
	end
	if graph.version ~= SpellCompiler.GraphVersion then
		fail("This spell was made with an older editor and can't be loaded.")
		return nil, nil
	end
	if typeof(graph.zones) ~= "table" or typeof(graph.runes) ~= "table" or typeof(graph.wires) ~= "table" then
		fail("Spell graph needs zones, runes and wires.")
		return nil, nil
	end
	local limit = SpellCompiler.BoardLimit
	local normalized = {
		version = SpellCompiler.GraphVersion,
		name = if typeof(graph.name) == "string" then string.sub(graph.name, 1, 96) else "Untitled Spell",
		zones = {},
		runes = {},
		wires = {},
	}

	if #graph.zones > SpellCompiler.MaxZones then
		fail(`A spell may have at most {SpellCompiler.MaxZones} zones.`)
	end
	local zoneIds = {}
	for index, raw in ipairs(graph.zones) do
		if index > SpellCompiler.MaxZones then break end
		if typeof(raw) ~= "table" or not validId(raw.id) or zoneIds[raw.id]
			or not SpellRunes.Zones[raw.kind]
			or not finite(raw.x) or not finite(raw.y) or not finite(raw.w) or not finite(raw.h)
			or math.abs(raw.x) > limit or math.abs(raw.y) > limit
			or raw.w < 80 or raw.h < 60 or raw.w > 8000 or raw.h > 8000 then
			fail(`Zone {index} is malformed.`)
			continue
		end
		zoneIds[raw.id] = true
		table.insert(normalized.zones, {
			id = raw.id,
			kind = raw.kind,
			label = if typeof(raw.label) == "string" then string.sub(raw.label, 1, 32) else nil,
			locked = if raw.locked == true then true else nil,
			x = raw.x, y = raw.y, w = raw.w, h = raw.h,
		})
	end

	if #graph.runes > SpellCompiler.MaxRunes then
		fail(`A spell may have at most {SpellCompiler.MaxRunes} runes.`)
	end
	local runeById = {}
	for index, raw in ipairs(graph.runes) do
		if index > SpellCompiler.MaxRunes then break end
		local def = typeof(raw) == "table" and SpellRunes.Runes[raw.rune] or nil
		if typeof(raw) ~= "table" or not validId(raw.id) then
			fail(`Rune {index} has an invalid id.`)
			continue
		end
		if runeById[raw.id] then
			fail(`Duplicate rune id "{raw.id}".`, raw.id)
			continue
		end
		if not def then
			fail(`Rune "{tostring(raw.rune)}" doesn't exist.`, raw.id)
			continue
		end
		if not finite(raw.x) or not finite(raw.y) or math.abs(raw.x) > limit or math.abs(raw.y) > limit then
			fail(`{def.Name} has an invalid position.`, raw.id)
			continue
		end
		local rune = {
			id = raw.id,
			rune = def.Id,
			x = raw.x,
			y = raw.y,
			params = sanitizeParams(def, raw.params),
			locked = if raw.locked == true then true else nil,
		}
		runeById[raw.id] = rune
		table.insert(normalized.runes, rune)
	end

	if #graph.wires > SpellCompiler.MaxWires then
		fail(`A spell may have at most {SpellCompiler.MaxWires} wires.`)
	end
	local seen = {}
	for index, raw in ipairs(graph.wires) do
		if index > SpellCompiler.MaxWires then break end
		if typeof(raw) ~= "table" or not validId(raw.from) or not validId(raw.to)
			or typeof(raw.fromPort) ~= "string" or typeof(raw.toPort) ~= "string" then
			fail(`Wire {index} is malformed.`)
			continue
		end
		local fromRune, toRune = runeById[raw.from], runeById[raw.to]
		if not fromRune or not toRune then
			fail(`Wire {index} connects a missing rune.`)
			continue
		end
		if raw.from == raw.to then
			fail("A rune can't be wired to itself.", raw.from)
			continue
		end
		local fromDef, toDef = SpellRunes.Runes[fromRune.rune], SpellRunes.Runes[toRune.rune]
		local outPort = SpellRunes.FindPort(fromDef.Outputs, raw.fromPort)
		local inPort = SpellRunes.FindPort(toDef.Inputs, raw.toPort)
		if not outPort or not inPort then
			fail(`Wire {index} uses a port that doesn't exist.`, raw.to)
			continue
		end
		if not SpellRunes.Compatible(outPort.Type, inPort.Type) then
			fail(`{fromDef.Name} {outPort.Label} ({outPort.Type}) can't feed {toDef.Name} {inPort.Label} ({inPort.Type}).`, raw.to)
			continue
		end
		local key = `{raw.from}.{raw.fromPort}>{raw.to}.{raw.toPort}`
		if seen[key] then
			continue -- exact duplicates are harmless; drop them
		end
		seen[key] = true
		table.insert(normalized.wires, { from = raw.from, fromPort = raw.fromPort, to = raw.to, toPort = raw.toPort })
	end
	return normalized, runeById
end

local function zoneContains(zone: any, x: number, y: number): boolean
	return x >= zone.x and y >= zone.y and x <= zone.x + zone.w and y <= zone.y + zone.h
end

-- A name describing what a spell does, for cards saved without one: its
-- element(s), vessels left to right, and "Sustained" if any vessel channels,
-- e.g. "Fire Orb + Explosion", "Sustained Shock Beam".
function SpellCompiler.SuggestName(graph: any): string
	local runes = if typeof(graph) == "table" and typeof(graph.runes) == "table" then table.clone(graph.runes) else {}
	table.sort(runes, function(a, b)
		return (tonumber(a.x) or 0) < (tonumber(b.x) or 0)
	end)
	local elements, vessels, seen = {}, {}, {}
	local sustained = false
	for _, rune in runes do
		local id = rune.rune
		if typeof(id) ~= "string" or seen[id] then
			continue
		end
		if SpellRunes.Elements[id] then
			seen[id] = true
			table.insert(elements, id)
		elseif SpellRunes.Vessels[id] then
			seen[id] = true
			table.insert(vessels, id)
		elseif id == "Sustain" then
			sustained = true
		end
	end
	if #vessels == 0 then
		return "Untitled Spell"
	end
	local name = table.concat(vessels, " + ")
	if #elements > 0 then
		name = table.concat(elements, "/") .. " " .. name
	end
	if sustained then
		name = "Sustained " .. name
	end
	return string.sub(name, 1, 24)
end

-- A starter circle: Mana -> Fire -> Orb with a Speed modifier.
function SpellCompiler.CreateDefaultGraph()
	return {
		version = SpellCompiler.GraphVersion,
		name = "", -- unnamed: saving without a name uses SuggestName
		zones = {
			{ id = "zone_input", kind = "Input", x = 0, y = 0, w = 260, h = 200 },
			{ id = "zone_transform", kind = "Transform", x = 320, y = 0, w = 260, h = 200 },
			{ id = "zone_modifier", kind = "Modifier", x = 320, y = 260, w = 260, h = 200 },
			{ id = "zone_output", kind = "Output", x = 640, y = 0, w = 280, h = 260 },
		},
		runes = {
			{ id = "mana", rune = "Mana", x = 42, y = 60, params = SpellRunes.DefaultParams("Mana") },
			{ id = "fire", rune = "Fire", x = 362, y = 60, params = {} },
			{ id = "speed", rune = "Speed", x = 362, y = 320, params = SpellRunes.DefaultParams("Speed") },
			{ id = "orb", rune = "Orb", x = 692, y = 60, params = {} },
		},
		wires = {
			{ from = "mana", fromPort = "out", to = "fire", toPort = "in" },
			{ from = "fire", fromPort = "out", to = "orb", toPort = "in" },
			{ from = "speed", fromPort = "mod", to = "orb", toPort = "mods" },
		},
	}
end

function SpellCompiler.Compile(graph: any)
	local errors: { Error } = {}
	local normalized, runeById = normalize(graph, errors)
	if not normalized or not runeById then
		return nil, errors, nil
	end
	-- Soft limits (splitting): the spell stays valid, but the vessel or
	-- Quantity over the limit doesn't work -- `disabled` vessels never fire
	-- (their energy fizzles), `noQuantity` vessels fire a single copy. Each is
	-- reported in `warnings` for the editor. Soft on purpose: cards saved
	-- before these limits existed must keep casting.
	local warnings: { Error } = {}
	local disabled: { [string]: boolean } = {}
	local noQuantity: { [string]: boolean } = {}
	local function limit(message: string, rune: string?)
		for _, existing in warnings do
			if existing.message == message and existing.rune == rune then return end
		end
		table.insert(warnings, { message = message, rune = rune })
	end
	local function fail(message: string, rune: string?, zone: string?)
		for _, existing in errors do
			if existing.message == message and existing.rune == rune then return end
		end
		table.insert(errors, { message = message, rune = rune, zone = zone })
	end

	-- Adjacency ---------------------------------------------------------------
	local inputs: { [string]: any } = {}
	local outputs: { [string]: any } = {}
	for _, rune in normalized.runes do
		inputs[rune.id], outputs[rune.id] = {}, {}
	end
	for _, wire in normalized.wires do
		local ins = inputs[wire.to]
		ins[wire.toPort] = ins[wire.toPort] or {}
		table.insert(ins[wire.toPort], { from = wire.from, port = wire.fromPort })
		local outs = outputs[wire.from]
		outs[wire.fromPort] = outs[wire.fromPort] or {}
		table.insert(outs[wire.fromPort], { to = wire.to, port = wire.toPort })
	end

	-- Per-rune structural rules ------------------------------------------------
	local counts = {}
	local manaRoots, vessels = {}, {}
	for _, rune in normalized.runes do
		local def = SpellRunes.Runes[rune.rune]
		counts[def.Id] = (counts[def.Id] or 0) + 1
		if def.Unique and counts[def.Id] > 1 then
			fail(`Only one {def.Name} rune is allowed.`, rune.id)
		end
		if def.Id == "Mana" then table.insert(manaRoots, rune.id) end
		if def.Vessel then table.insert(vessels, rune.id) end

		local ax, ay = SpellCompiler.RuneAnchor(rune)
		local placed = false
		for _, zone in normalized.zones do
			if table.find(def.Zones, zone.kind) and zoneContains(zone, ax, ay) then
				placed = true
				break
			end
		end
		if not placed then
			fail(`{def.Name} must sit inside a {table.concat(def.Zones, " or ")} zone.`, rune.id)
		end

		for _, port in def.Inputs do
			local wires = inputs[rune.id][port.Name]
			local n = if wires then #wires else 0
			if n == 0 and not port.Optional then
				fail(`{def.Name}: connect its {port.Label} input.`, rune.id)
			elseif n > 1 and not port.Multi then
				fail(`{def.Name}: {port.Label} accepts only one wire.`, rune.id)
			end
		end
		for _, port in def.Outputs do
			local wires = outputs[rune.id][port.Name]
			local n = if wires then #wires else 0
			if (port.Type == "flow" or port.Type == "mod") and n > 1 then
				fail(`{def.Name}: {port.Label} can only feed one wire. Use Divide to split energy.`, rune.id)
			end
			if port.Type == "mod" and n == 0 then
				fail(`{def.Name} isn't attached to a vessel (Orb, Bullet or Beam).`, rune.id)
			end
			if def.Id == "Target" and n == 0 then
				fail("Aim: wire its Aim output into a vessel's Aim port.", rune.id)
			end
		end
	end
	if #manaRoots == 0 then fail("Add a Mana Well in an Input zone.") end
	if #vessels == 0 then fail("Add a vessel (Orb, Bullet or Beam) in an Output zone.") end

	-- Vessel modifier/trigger budgets -----------------------------------------
	local vesselInfo = {}
	for _, vesselId in vessels do
		local vesselDef = SpellRunes.Runes[runeById[vesselId].rune]
		local mods, seenMods, modCost, count = {}, {}, 0, 1
		for _, link in inputs[vesselId].mods or {} do
			local source = runeById[link.from]
			local def = SpellRunes.Runes[source.rune]
			if seenMods[def.Id] then
				fail(`{vesselDef.Name} has two {def.Name} modifiers.`, vesselId)
			end
			if not SpellRunes.ModifierApplies(vesselDef.Id, def.Id) then
				fail(`{def.Name} does nothing on this {vesselDef.Name}.`, link.from)
			end
			seenMods[def.Id] = true
			modCost += SpellRunes.ModifierCost(def.Id, source.params)
			if def.Id == "Quantity" then
				count = source.params.Count
			end
			table.insert(mods, link.from)
		end
		if modCost > SpellRunes.MaxModifierCost then
			fail(`Modifiers on this {vesselDef.Name} would consume {math.floor(modCost * 100)}% of its energy (max {math.floor(SpellRunes.MaxModifierCost * 100)}%).`, vesselId)
		end
		local triggers, share = {}, 0
		for _, link in (outputs[vesselId].vessel or {}) do
			local trigger = runeById[link.to]
			if not SpellRunes.TriggerApplies(vesselDef.Id, trigger.rune) then
				fail(`{SpellRunes.Runes[trigger.rune].Name} can't be used on this {vesselDef.Name}: it has no flight time.`, link.to)
			end
			table.insert(triggers, link.to)
			share += trigger.params.Share / 100
		end
		if share > SpellRunes.MaxTriggerShare + 1e-6 then
			fail(`Triggers on this {vesselDef.Name} claim {math.floor(share * 100 + 0.5)}% of its energy (max {math.floor(SpellRunes.MaxTriggerShare * 100)}%).`, vesselId)
		end
		vesselInfo[vesselId] = { mods = mods, modCost = modCost, triggers = triggers, triggerShare = share, count = count }
	end

	-- Cycles -------------------------------------------------------------------
	local state = {}
	local cyclic = false
	local function visit(id: string)
		if state[id] == 1 then
			cyclic = true
			return
		end
		if state[id] == 2 then
			return
		end
		state[id] = 1
		for _, links in outputs[id] do
			for _, link in links do visit(link.to) end
		end
		state[id] = 2
	end
	for id in runeById do visit(id) end
	if cyclic then fail("Wires form a loop; spells must flow one way.") end

	-- Energy + element propagation (static estimates) -------------------------
	-- Walks each flow tree from its root carrying energy, element and trigger
	-- depth. With If both sides get the full amount ("up to").
	local estimates: { [string]: any } = {}
	local elements: { [string]: string } = {}
	local reached = {}
	-- `source` is the vessel whose trigger this flow came out of (nil at cast
	-- time); `quantities` how many Quantity runes the vessels above it on this
	-- trigger chain used. Splitting limits (soft -- see `limit` above), so
	-- trigger chains can't multiply projectiles without bound:
	--  * at most MaxChainQuantity Quantity runes along any one chain (extra
	--    ones are ignored);
	--  * only one trigger hop may make a new non-Explosion vessel -- one
	--    fired by a vessel that was itself fired by a trigger doesn't fire;
	--  * a Beam's triggers only fire Explosions (anything else doesn't fire).
	local function follow(id: string, port: string, energy: number, element: string?, depth: number, source: string?, quantities: number?)
		quantities = quantities or 0
		for _, link in (outputs[id][port] or {}) do
			local rune = runeById[link.to]
			local def = SpellRunes.Runes[rune.rune]
			reached[link.to] = true
			estimates[link.to] = { energy = energy }
			if def.Element then
				follow(link.to, "out", energy, def.Element, depth, source, quantities)
			elseif def.Id == "If" then
				follow(link.to, "yes", energy, element, depth, source, quantities)
				follow(link.to, "no", energy, element, depth, source, quantities)
			elseif def.Id == "Divide" then
				local share = rune.params.Share / 100
				follow(link.to, "a", energy * share, element, depth, source, quantities)
				follow(link.to, "b", energy * (1 - share), element, depth, source, quantities)
			elseif def.Vessel then
				local chainQuantities = quantities :: number
				for _, modId in vesselInfo[link.to].mods do
					if runeById[modId].rune == "Quantity" then
						if chainQuantities >= SpellCompiler.MaxChainQuantity then
							limit(`Only {SpellCompiler.MaxChainQuantity} Quantity runes work along one trigger chain -- this one is ignored.`, modId)
							noQuantity[link.to] = true
							vesselInfo[link.to].count = 1
						else
							chainQuantities += 1
						end
					end
				end
				if def.Id ~= "Explosion" then
					if source == "Beam" then
						limit(`Beam triggers can only fire an Explosion -- this {def.Name} won't fire.`, link.to)
						disabled[link.to] = true
					elseif depth >= 2 then
						limit(`Only an Explosion can come from a vessel fired by a trigger -- this {def.Name} won't fire.`, link.to)
						disabled[link.to] = true
					end
				end
				if not element then
					fail(`Energy reaches this {def.Name} without a Transform rune (Fire, Arcane or Shock).`, link.to)
				else
					elements[link.to] = element
				end
				local info = vesselInfo[link.to]
				local perBolt = energy * (1 - math.min(info.modCost, 1)) / info.count
				local elementDef = element and SpellRunes.Elements[element]
				local impact = (if elementDef then elementDef.Impact else 1) * SpellRunes.Vessels[def.Id].Impact
				estimates[link.to].count = info.count
				estimates[link.to].damage = perBolt * (1 - info.triggerShare) * impact
				estimates[link.to].element = element
				if #info.triggers > 0 then
					if depth >= SpellCompiler.MaxTriggerDepth then
						fail(`Triggers can nest at most {SpellCompiler.MaxTriggerDepth} deep.`, link.to)
					else
						for _, triggerId in info.triggers do
							local triggerEnergy = perBolt * runeById[triggerId].params.Share / 100
							reached[triggerId] = true
							estimates[triggerId] = { energy = triggerEnergy }
							follow(triggerId, "out", triggerEnergy, element, depth + 1, def.Id, chainQuantities)
						end
					end
				end
			end
		end
	end
	if not cyclic then
		for _, rootId in manaRoots do
			local amount = runeById[rootId].params.Amount
			estimates[rootId] = { energy = amount }
			reached[rootId] = true
			follow(rootId, "out", amount, nil, 0)
		end
		for _, rune in normalized.runes do
			local def = SpellRunes.Runes[rune.rune]
			if SpellRunes.FindPort(def.Inputs, "in") and inputs[rune.id]["in"] and not reached[rune.id] then
				fail(`{def.Name} never receives energy from a Mana Well.`, rune.id)
			end
			if def.Category == "Trigger" and not reached[rune.id] and inputs[rune.id].vessel then
				fail(`{def.Name}'s vessel never receives energy.`, rune.id)
			end
		end
	end

	local manaCost = 0
	for _, rootId in manaRoots do
		manaCost += runeById[rootId].params.Amount
	end

	local analysis = { estimates = estimates, manaCost = manaCost, warnings = warnings }
	if #errors > 0 then
		return nil, errors, normalized, analysis
	end

	local runes = {}
	for _, rune in normalized.runes do
		runes[rune.id] = { id = rune.id, rune = rune.rune, params = rune.params }
	end
	return {
		version = SpellCompiler.GraphVersion,
		name = normalized.name,
		manaCost = manaCost,
		runes = runes,
		inputs = inputs,
		outputs = outputs,
		manaRoots = manaRoots,
		vessels = vesselInfo,
		elements = elements,
		estimates = estimates,
		disabledVessels = disabled, -- soft limits: these never fire
		noQuantity = noQuantity, -- soft limits: these ignore their Quantity
		warnings = warnings,
	}, errors, normalized, analysis
end

return SpellCompiler
