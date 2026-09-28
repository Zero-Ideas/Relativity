--!strict
-- Pure shared compiler. V2 replaces fixed rings with player-authored semantic
-- areas and supports one explicit true/false conditional fork.
local SpellCompiler = {}

SpellCompiler.GraphVersion = 2
SpellCompiler.MaxNodes = 32
SpellCompiler.MaxEdges = 48
SpellCompiler.MaxRegions = 12
SpellCompiler.RegionKinds = { "Input", "Transform", "Vessel", "Output", "Modifier" }
SpellCompiler.DefaultRegions = {
	{ id = "input_area", kind = "Input", x = 0.04, y = 0.57, w = 0.20, h = 0.31 },
	{ id = "transform_area", kind = "Transform", x = 0.27, y = 0.12, w = 0.22, h = 0.34 },
	{ id = "vessel_area", kind = "Vessel", x = 0.52, y = 0.12, w = 0.22, h = 0.34 },
	{ id = "output_area", kind = "Output", x = 0.77, y = 0.57, w = 0.19, h = 0.31 },
	{ id = "modifier_area", kind = "Modifier", x = 0.27, y = 0.57, w = 0.47, h = 0.31 },
}

local DAMAGE = { 10, 20, 35, 55, 80 }
local SPEED = { 140, 200, 280, 390, 550 }
local RADIUS = { 0.2, 0.35, 0.55, 0.8, 1.2 }
local VISUAL_SCALE = { 1.15, 1.35, 1.6, 1.95, 2.4 }
local GRAVITY = { 20, 40, 70, 110, 160 }
local SPLIT = { 2, 3, 4, 6, 8 }
local SPREAD = { 4, 7, 10, 14, 18 }
local HOMING_RADIUS = { 30, 45, 60, 80, 100 }
local HOMING_TURN = { 75, 105, 140, 180, 230 }

SpellCompiler.Runes = {
	Mana = { DisplayName = "Mana", Region = "Input", Kind = "Input", Color = Color3.fromRGB(100, 190, 255) },
	Fire = { DisplayName = "Fire", Region = "Transform", Kind = "Transform", Color = Color3.fromRGB(255, 105, 50) },
	Condition = { DisplayName = "Condition", Region = "Transform", Kind = "Control", Tiered = true, Color = Color3.fromRGB(255, 214, 80) },
	Projectile = { DisplayName = "Projectile", Region = "Vessel", Kind = "Vessel", Color = Color3.fromRGB(184, 110, 255) },
	Damage = { DisplayName = "Damage", Region = "Output", Kind = "Output", Tiered = true, Color = Color3.fromRGB(255, 75, 75) },
	Speed = { DisplayName = "Speed", Region = "Modifier", Kind = "Modifier", Tiered = true, Color = Color3.fromRGB(90, 225, 255) },
	Size = { DisplayName = "Size", Region = "Modifier", Kind = "Modifier", Tiered = true, Color = Color3.fromRGB(130, 255, 170) },
	Gravity = { DisplayName = "Gravity", Region = "Modifier", Kind = "Modifier", Tiered = true, Color = Color3.fromRGB(135, 145, 205) },
	Bounce = { DisplayName = "Bounce", Region = "Modifier", Kind = "Modifier", Tiered = true, Color = Color3.fromRGB(255, 205, 80) },
	Pierce = { DisplayName = "Pierce", Region = "Modifier", Kind = "Modifier", Tiered = true, Color = Color3.fromRGB(255, 145, 190) },
	Split = { DisplayName = "Split", Region = "Modifier", Kind = "Modifier", Tiered = true, Color = Color3.fromRGB(140, 255, 235) },
	Homing = { DisplayName = "Homing", Region = "Modifier", Kind = "Modifier", Tiered = true, Color = Color3.fromRGB(215, 125, 255) },
}
SpellCompiler.RuneOrder = { "Mana", "Fire", "Condition", "Projectile", "Damage", "Speed", "Size", "Gravity", "Bounce", "Pierce", "Split", "Homing" }
SpellCompiler.ConditionNames = { [1] = "Target exists", [2] = "Target is living", [3] = "Target is not caster", [4] = "Target is a player", [5] = "Target within 75 studs" }

local function addError(errors: { string }, message: string)
	if not table.find(errors, message) then table.insert(errors, message) end
end

local function finiteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function validId(value: any): boolean
	return typeof(value) == "string" and #value >= 1 and #value <= 32 and string.match(value, "^[%w_%-]+$") ~= nil
end

local function cloneRegions()
	local result = {}
	for _, region in SpellCompiler.DefaultRegions do table.insert(result, table.clone(region)) end
	return result
end

local function defaultPosition(runeId: string, modifierIndex: number?): { x: number, y: number }
	if runeId == "Mana" then return { x = 0.14, y = 0.72 } end
	if runeId == "Fire" then return { x = 0.34, y = 0.24 } end
	if runeId == "Condition" then return { x = 0.43, y = 0.37 } end
	if runeId == "Projectile" then return { x = 0.63, y = 0.27 } end
	if runeId == "Damage" then return { x = 0.86, y = 0.72 } end
	local index = modifierIndex or 1
	return { x = 0.31 + ((index - 1) % 4) * 0.12, y = 0.66 + math.floor((index - 1) / 4) * 0.12 }
end

local function regionContains(regions: { any }, kind: string, x: number, y: number): boolean
	for _, region in regions do
		if region.kind == kind and x >= region.x - 1e-4 and y >= region.y - 1e-4
			and x <= region.x + region.w + 1e-4 and y <= region.y + region.h + 1e-4 then return true end
	end
	return false
end

local function normalizeGraph(graph: any, errors: { string })
	if typeof(graph) ~= "table" then addError(errors, "Spell graph must be a table."); return nil end
	local legacy = graph.version == 1
	if graph.version ~= SpellCompiler.GraphVersion and not legacy then addError(errors, `Unsupported spell graph version (expected {SpellCompiler.GraphVersion}).`) end
	if typeof(graph.nodes) ~= "table" or typeof(graph.edges) ~= "table" then addError(errors, "Spell graph requires node and edge arrays."); return nil end
	if #graph.nodes > SpellCompiler.MaxNodes then addError(errors, `A spell may contain at most {SpellCompiler.MaxNodes} runes.`) end
	if #graph.edges > SpellCompiler.MaxEdges then addError(errors, `A spell may contain at most {SpellCompiler.MaxEdges} connections.`) end

	local normalized = { version = SpellCompiler.GraphVersion, name = typeof(graph.name) == "string" and string.sub(graph.name, 1, 96) or "Fire Projectile", regions = {}, nodes = {}, edges = {} }
	local rawRegions = if legacy then cloneRegions() else graph.regions
	if typeof(rawRegions) ~= "table" or #rawRegions == 0 then addError(errors, "Define at least one spell area."); rawRegions = {} end
	if #rawRegions > SpellCompiler.MaxRegions then addError(errors, `A spell may contain at most {SpellCompiler.MaxRegions} areas.`) end
	local regionIds = {}
	for index, raw in ipairs(rawRegions) do
		if index > SpellCompiler.MaxRegions then break end
		local validKind = typeof(raw) == "table" and table.find(SpellCompiler.RegionKinds, raw.kind) ~= nil
		if typeof(raw) ~= "table" or not validId(raw.id) or regionIds[raw.id] or not validKind
			or not finiteNumber(raw.x) or not finiteNumber(raw.y) or not finiteNumber(raw.w) or not finiteNumber(raw.h)
			or raw.x < 0 or raw.y < 0 or raw.w < 0.06 or raw.h < 0.06 or raw.x + raw.w > 1 or raw.y + raw.h > 1 then
			addError(errors, `Spell area {index} is malformed or outside the canvas.`); continue
		end
		regionIds[raw.id] = true
		table.insert(normalized.regions, { id = raw.id, kind = raw.kind, x = raw.x, y = raw.y, w = raw.w, h = raw.h })
	end

	local ids, nodeRuneById = {}, {}
	local modifierIndex = 0
	for index, raw in ipairs(graph.nodes) do
		if index > SpellCompiler.MaxNodes then break end
		if typeof(raw) ~= "table" or not validId(raw.id) then addError(errors, `Rune {index} has an invalid ID.`); continue end
		if ids[raw.id] then addError(errors, `Duplicate rune ID "{raw.id}".`); continue end
		local rune = SpellCompiler.Runes[raw.runeId]
		if not rune then addError(errors, `Rune "{tostring(raw.runeId)}" is not supported.`); continue end
		if rune.Kind == "Modifier" then modifierIndex += 1 end
		local position = if legacy then defaultPosition(raw.runeId, modifierIndex) else raw.position
		local x = typeof(position) == "table" and position.x or nil
		local y = typeof(position) == "table" and position.y or nil
		if not finiteNumber(x) or not finiteNumber(y) or x < 0 or x > 1 or y < 0 or y > 1 then addError(errors, `Rune "{raw.id}" has an invalid position.`); continue end
		if not regionContains(normalized.regions, rune.Region, x, y) then addError(errors, `{rune.DisplayName} must be inside a {rune.Region} area.`) end
		local tier = raw.tier
		if rune.Tiered then
			if not finiteNumber(tier) or tier % 1 ~= 0 or tier < 1 or tier > 5 then addError(errors, `{rune.DisplayName} requires a tier from I to V.`); tier = 1 end
		elseif tier ~= nil then addError(errors, `{rune.DisplayName} does not accept a tier.`); tier = nil end
		ids[raw.id], nodeRuneById[raw.id] = true, raw.runeId
		table.insert(normalized.nodes, { id = raw.id, runeId = raw.runeId, tier = tier, position = { x = x, y = y } })
	end

	local seenEdges = {}
	for index, raw in ipairs(graph.edges) do
		if index > SpellCompiler.MaxEdges then break end
		if typeof(raw) ~= "table" or not validId(raw.from) or not validId(raw.to) or not ids[raw.from] or not ids[raw.to] then addError(errors, `Connection {index} references an invalid rune.`); continue end
		if raw.from == raw.to then addError(errors, "A rune cannot connect to itself."); continue end
		local branch = raw.branch
		if nodeRuneById[raw.from] == "Condition" then
			if branch ~= "true" and branch ~= "false" then addError(errors, "Condition connections must use a true or false branch."); continue end
		elseif branch ~= nil then addError(errors, "Only Condition outputs may be labelled as branches."); continue end
		local key = raw.from .. ">" .. raw.to .. ">" .. tostring(branch)
		if seenEdges[key] then addError(errors, "Duplicate connections are not allowed."); continue end
		seenEdges[key] = true
		table.insert(normalized.edges, { from = raw.from, to = raw.to, branch = branch })
	end
	return normalized
end

function SpellCompiler.CreateDefaultGraph()
	return { version = SpellCompiler.GraphVersion, name = "Fire Projectile", regions = cloneRegions(), nodes = {
		{ id = "mana", runeId = "Mana", position = defaultPosition("Mana") }, { id = "fire", runeId = "Fire", position = defaultPosition("Fire") },
		{ id = "projectile", runeId = "Projectile", position = defaultPosition("Projectile") }, { id = "damage", runeId = "Damage", tier = 1, position = defaultPosition("Damage") },
	}, edges = { { from = "mana", to = "fire" }, { from = "fire", to = "projectile" }, { from = "projectile", to = "damage" } } }
end

local function compileBranch(projectileNode: any, damageNode: any, modifierNodes: { any })
	local stats = { Speed = 100, MinSpeed = 0, MaxSpeed = 1000, Damage = DAMAGE[damageNode.tier], Lifetime = 5, Gravity = 0, Radius = 0.1, VisualScale = 1, Bounces = 0, Restitution = 0.7, Penetration = 0, MaxPierces = 0, PierceFalloff = 0.15 }
	local manaCost, count, spread, homing = 10 + 4 * damageNode.tier, 1, 0, nil
	local modifiers = {}
	for _, node in modifierNodes do modifiers[node.runeId] = node.tier end
	local tier = modifiers.Speed
	if tier then stats.Speed = SPEED[tier]; manaCost += 2 * tier end
	tier = modifiers.Size
	if tier then stats.Radius = RADIUS[tier]; stats.VisualScale = VISUAL_SCALE[tier]; manaCost += 3 * tier end
	tier = modifiers.Gravity
	if tier then stats.Gravity = GRAVITY[tier]; manaCost += 2 * tier end
	tier = modifiers.Bounce
	if tier then stats.Bounces = tier; manaCost += 4 * tier end
	tier = modifiers.Pierce
	if tier then stats.MaxPierces = tier; manaCost += 5 * tier end
	tier = modifiers.Split
	if tier then count = SPLIT[tier]; spread = math.rad(SPREAD[tier]); manaCost += 6 * count end
	tier = modifiers.Homing
	if tier then homing = { AcquireRadius = HOMING_RADIUS[tier], Retarget = true, ReacquireRate = 0.3, Permalock = false, TurnRate = math.rad(HOMING_TURN[tier]), Delay = 0.05 }; manaCost += 5 * tier end
	return { projectileId = projectileNode.id, stats = stats, count = count, spread = spread, homing = homing, manaCost = manaCost }
end

function SpellCompiler.Compile(graph: any)
	local errors = {}
	local normalized = normalizeGraph(graph, errors)
	if not normalized then return nil, errors, nil end
	local byId, byRune = {}, {}
	for _, node in normalized.nodes do byId[node.id] = node; byRune[node.runeId] = byRune[node.runeId] or {}; table.insert(byRune[node.runeId], node) end
	for _, unique in { "Mana", "Fire", "Condition" } do if #(byRune[unique] or {}) > 1 then addError(errors, `Only one {unique} rune is allowed.`) end end
	for _, required in { "Mana", "Fire", "Projectile", "Damage" } do if #(byRune[required] or {}) == 0 then addError(errors, `Missing required {required} rune.`) end end

	local adjacency, incoming = {}, {}
	for _, edge in normalized.edges do adjacency[edge.from] = adjacency[edge.from] or {}; incoming[edge.to] = incoming[edge.to] or {}; table.insert(adjacency[edge.from], edge); table.insert(incoming[edge.to], edge) end
	local function outgoing(id: string) return adjacency[id] or {} end
	local function inputs(id: string) return incoming[id] or {} end
	local mana, fire, condition = (byRune.Mana or {})[1], (byRune.Fire or {})[1], (byRune.Condition or {})[1]
	local projectiles, damages = byRune.Projectile or {}, byRune.Damage or {}
	if mana and (#inputs(mana.id) ~= 0 or #outgoing(mana.id) ~= 1 or not fire or outgoing(mana.id)[1].to ~= fire.id) then addError(errors, "Mana must be the sole input to Fire.") end
	if fire then
		local expected = condition or projectiles[1]
		if #inputs(fire.id) ~= 1 or not mana or inputs(fire.id)[1].from ~= mana.id or #outgoing(fire.id) ~= 1 or not expected or outgoing(fire.id)[1].to ~= expected.id then addError(errors, if condition then "Fire must connect to Condition." else "Fire must connect to Projectile.") end
	end
	local conditionalDestinations = {}
	if condition then
		if #projectiles ~= 2 or #damages ~= 2 then addError(errors, "A conditional spell needs exactly two Projectile and two Damage runes.") end
		for _, edge in outgoing(condition.id) do if byId[edge.to] and byId[edge.to].runeId == "Projectile" then conditionalDestinations[edge.branch] = edge.to end end
		if #inputs(condition.id) ~= 1 or not fire or inputs(condition.id)[1].from ~= fire.id or #outgoing(condition.id) ~= 2 or not conditionalDestinations["true"] or not conditionalDestinations["false"] or conditionalDestinations["true"] == conditionalDestinations["false"] then addError(errors, "Condition requires distinct true and false Projectile branches.") end
	elseif #projectiles ~= 1 or #damages ~= 1 then addError(errors, "A spell without a Condition needs exactly one Projectile and one Damage rune.") end

	local branchByProjectile = {}
	for _, projectile in projectiles do
		local nonModifierInputs, modifierInputs, seenModifiers = {}, {}, {}
		for _, edge in inputs(projectile.id) do
			local source = byId[edge.from]
			if source and SpellCompiler.Runes[source.runeId].Kind == "Modifier" then
				if seenModifiers[source.runeId] then addError(errors, `Projectile "{projectile.id}" has duplicate {source.runeId} modifiers.`) end
				seenModifiers[source.runeId] = true; table.insert(modifierInputs, source)
			else table.insert(nonModifierInputs, source) end
		end
		local outs = outgoing(projectile.id)
		local damage = #outs == 1 and byId[outs[1].to] or nil
		if #nonModifierInputs ~= 1 or (condition and nonModifierInputs[1] ~= condition) or (not condition and nonModifierInputs[1] ~= fire) then addError(errors, `Projectile "{projectile.id}" needs one transform/control input.`) end
		if not damage or damage.runeId ~= "Damage" then addError(errors, `Projectile "{projectile.id}" needs one Damage output.`) end
		if damage and damage.runeId == "Damage" then branchByProjectile[projectile.id] = compileBranch(projectile, damage, modifierInputs) end
	end
	for _, damage in damages do if #outgoing(damage.id) ~= 0 or #inputs(damage.id) ~= 1 or not byId[inputs(damage.id)[1].from] or byId[inputs(damage.id)[1].from].runeId ~= "Projectile" then addError(errors, `Damage "{damage.id}" must be a final Projectile output.`) end end
	for _, node in normalized.nodes do
		if SpellCompiler.Runes[node.runeId].Kind == "Modifier" and (#inputs(node.id) ~= 0 or #outgoing(node.id) ~= 1 or not byId[outgoing(node.id)[1].to] or byId[outgoing(node.id)[1].to].runeId ~= "Projectile") then addError(errors, `{node.runeId} may only modify one Projectile.`) end
	end

	local visiting, visited = {}, {}
	local function visit(id: string): boolean
		if visiting[id] then return false end; if visited[id] then return true end
		visiting[id] = true; for _, edge in outgoing(id) do if not visit(edge.to) then return false end end
		visiting[id] = nil; visited[id] = true; return true
	end
	for id in byId do if not visit(id) then addError(errors, "Spell graphs cannot contain cycles."); break end end
	for id in byId do if #inputs(id) == 0 and #outgoing(id) == 0 then addError(errors, `Rune "{id}" is disconnected.`) end end
	if #errors > 0 then return nil, errors, normalized end

	local execution, manaCost, maxProjectiles
	if condition then
		local trueBranch, falseBranch = branchByProjectile[conditionalDestinations["true"]], branchByProjectile[conditionalDestinations["false"]]
		execution = { kind = "Conditional", predicate = condition.tier, trueBranch = trueBranch, falseBranch = falseBranch }
		manaCost, maxProjectiles = 3 + math.max(trueBranch.manaCost, falseBranch.manaCost), math.max(trueBranch.count, falseBranch.count)
	else
		local branch = branchByProjectile[projectiles[1].id]
		execution, manaCost, maxProjectiles = { kind = "Single", branch = branch }, branch.manaCost, branch.count
	end
	return { version = SpellCompiler.GraphVersion, name = normalized.name, element = "Fire", vessel = "Projectile", output = "Damage", manaCost = manaCost, maxProjectiles = maxProjectiles, execution = execution,
		stats = execution.kind == "Single" and execution.branch.stats or nil, count = execution.kind == "Single" and execution.branch.count or nil,
		spread = execution.kind == "Single" and execution.branch.spread or nil, homing = execution.kind == "Single" and execution.branch.homing or nil }, errors, normalized
end

return SpellCompiler
