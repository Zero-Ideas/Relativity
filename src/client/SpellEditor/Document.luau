--!strict
--[[
	The spell graph being edited, its mutations and undo/redo. Every user
	action calls doc:record() once BEFORE changing anything (drags record on
	their first movement), so each undo step is one whole action.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local SpellCompiler = require(Shared:WaitForChild("SpellCompiler"))
local SpellRunes = require(Shared:WaitForChild("SpellRunes"))

local Document = {}
Document.__index = Document

local HISTORY_LIMIT = 80

local function deepCopy(value: any): any
	if typeof(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = deepCopy(child)
	end
	return result
end
Document.deepCopy = deepCopy

function Document.new(graph: any)
	local self = setmetatable({}, Document)
	self.graph = deepCopy(graph)
	self.undoStack = {}
	self.redoStack = {}
	return self
end

-- Replaces the whole graph (loading a card / New). Clears history.
function Document:load(graph: any)
	self.graph = deepCopy(graph)
	table.clear(self.undoStack)
	table.clear(self.redoStack)
end

function Document:record()
	table.insert(self.undoStack, deepCopy(self.graph))
	if #self.undoStack > HISTORY_LIMIT then
		table.remove(self.undoStack, 1)
	end
	table.clear(self.redoStack)
end

function Document:undo(): boolean
	local previous = table.remove(self.undoStack)
	if not previous then return false end
	table.insert(self.redoStack, self.graph)
	self.graph = previous
	return true
end

function Document:redo(): boolean
	local nextGraph = table.remove(self.redoStack)
	if not nextGraph then return false end
	table.insert(self.undoStack, self.graph)
	self.graph = nextGraph
	return true
end

function Document:newId(prefix: string): string
	local used = {}
	for _, zone in self.graph.zones do used[zone.id] = true end
	for _, rune in self.graph.runes do used[rune.id] = true end
	local base = string.lower(string.gsub(prefix, "[^%w]", ""))
	local index = 1
	while used[`{base}{index}`] do index += 1 end
	return `{base}{index}`
end

function Document:rune(id: string): any?
	for _, rune in self.graph.runes do
		if rune.id == id then return rune end
	end
	return nil
end

function Document:zone(id: string): any?
	for _, zone in self.graph.zones do
		if zone.id == id then return zone end
	end
	return nil
end

-- x, y is where the rune's anchor (header centre) should land.
function Document:addRune(runeId: string, x: number, y: number): any?
	if #self.graph.runes >= SpellCompiler.MaxRunes then return nil end
	local layout = SpellCompiler.Layout
	local rune = {
		id = self:newId(runeId),
		rune = runeId,
		x = math.floor(x - layout.RuneWidth / 2),
		y = math.floor(y - layout.Header / 2),
		params = SpellRunes.DefaultParams(runeId),
	}
	table.insert(self.graph.runes, rune)
	return rune
end

function Document:removeRune(id: string)
	for index = #self.graph.runes, 1, -1 do
		if self.graph.runes[index].id == id then table.remove(self.graph.runes, index) end
	end
	for index = #self.graph.wires, 1, -1 do
		local wire = self.graph.wires[index]
		if wire.from == id or wire.to == id then table.remove(self.graph.wires, index) end
	end
end

function Document:addZone(kind: string, x: number, y: number, w: number, h: number): any?
	if #self.graph.zones >= SpellCompiler.MaxZones then return nil end
	local zone = { id = self:newId("zone"), kind = kind, x = math.floor(x), y = math.floor(y), w = math.floor(w), h = math.floor(h) }
	table.insert(self.graph.zones, zone)
	return zone
end

function Document:removeZone(id: string)
	for index = #self.graph.zones, 1, -1 do
		if self.graph.zones[index].id == id then table.remove(self.graph.zones, index) end
	end
end

function Document:runesInZone(zone: any): { any }
	local result = {}
	for _, rune in self.graph.runes do
		local ax, ay = SpellCompiler.RuneAnchor(rune)
		if ax >= zone.x and ay >= zone.y and ax <= zone.x + zone.w and ay <= zone.y + zone.h then
			table.insert(result, rune)
		end
	end
	return result
end

function Document:wiresInto(runeId: string, port: string): { any }
	local result = {}
	for _, wire in self.graph.wires do
		if wire.to == runeId and wire.toPort == port then table.insert(result, wire) end
	end
	return result
end

-- Connects out-port -> in-port, enforcing the same rules as the compiler so a
-- wire can't be drawn that the circle would reject: compatible types, one
-- wire into single inputs (the new wire replaces the old), one wire out of
-- flow/mod outputs (likewise replaced). Returns false + reason otherwise.
function Document:connect(fromId: string, fromPort: string, toId: string, toPort: string): (boolean, string?)
	if fromId == toId then return false, "A rune can't feed itself." end
	local fromRune, toRune = self:rune(fromId), self:rune(toId)
	if not fromRune or not toRune then return false, "Missing rune." end
	local outPort = SpellRunes.FindPort(SpellRunes.Runes[fromRune.rune].Outputs, fromPort)
	local inPort = SpellRunes.FindPort(SpellRunes.Runes[toRune.rune].Inputs, toPort)
	if not outPort or not inPort then return false, "Missing port." end
	if not SpellRunes.Compatible(outPort.Type, inPort.Type) then
		return false, `{outPort.Type} can't connect to {inPort.Type}.`
	end
	if #self.graph.wires >= SpellCompiler.MaxWires then return false, "Too many wires." end
	local wires = self.graph.wires
	for index = #wires, 1, -1 do
		local wire = wires[index]
		local sameInput = wire.to == toId and wire.toPort == toPort
		if sameInput and wire.from == fromId and wire.fromPort == fromPort then
			return false, nil -- already connected
		end
		local replacesInput = sameInput and not inPort.Multi
		local replacesOutput = wire.from == fromId and wire.fromPort == fromPort
			and (outPort.Type == "flow" or outPort.Type == "mod")
		if replacesInput or replacesOutput then
			table.remove(wires, index)
		end
	end
	table.insert(wires, { from = fromId, fromPort = fromPort, to = toId, toPort = toPort })
	return true, nil
end

function Document:removeWire(wire: any)
	local index = table.find(self.graph.wires, wire)
	if index then table.remove(self.graph.wires, index) end
end

return Document
