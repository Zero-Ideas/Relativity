--!strict
--[[
	Effects/Streak.luau
	Speed streaks for very fast projectiles. At hundreds of studs per second a
	bolt jumps several of its own lengths per frame, so the eye loses it; a
	streak draws the path it covered in the last few hundredths of a second.

	A streak is one Beam between two Attachments on the projectile's own root
	part (a head at the root, a tail behind it), so it rides the existing
	Motor6D pose for free: nothing is moved per frame. Every BUDGET_INTERVAL
	the nearest MAX_ACTIVE streaks are switched on and their tail length is
	refreshed from the projectile's speed (local time scale included).

	Streak.Attach(part, rootOffset, getVelocity, color?, width?) -> detach()
]]

local Util = require(script.Parent.Util)

local Streak = {}

Streak.Enabled = true
Streak.MinSpeed = 220 -- studs/s (real) below which no streak shows
Streak.Seconds = 0.035 -- tail length = this much of the path
Streak.MaxLength = 60
Streak.MaxActive = 64
Streak.MaxAttached = 512 -- past this, new projectiles get none
local BUDGET_INTERVAL = 0.15
local MAX_DISTANCE = 900

type Item = {
	Head: Attachment,
	Tail: Attachment,
	Beam: Beam,
	Part: BasePart,
	Back: Vector3, -- unit, the part's local "behind"
	GetVelocity: () -> Vector3,
	On: boolean,
	Length: number,
}

local items: { Item } = {}
local free: { Item } = {}
local sinceBudget = 0
local activeCount = 0

local TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.7, 0.55),
	NumberSequenceKeypoint.new(1, 0.15),
})

local function make(): Item
	local head = Instance.new("Attachment")
	head.Name = "StreakHead"
	local tail = Instance.new("Attachment")
	tail.Name = "StreakTail"
	local beam = Instance.new("Beam")
	beam.Name = "Streak"
	beam.Attachment0 = tail
	beam.Attachment1 = head
	beam.FaceCamera = true
	beam.Segments = 1
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Transparency = TRANSPARENCY
	beam.Enabled = false
	beam.Parent = head
	return {
		Head = head, Tail = tail, Beam = beam, Part = nil :: any, Back = Vector3.zAxis,
		GetVelocity = function() return Vector3.zero end, On = false, Length = 0,
	}
end

local function setOn(item: Item, on: boolean)
	if item.On ~= on then
		item.On = on
		item.Beam.Enabled = on
		activeCount += if on then 1 else -1
	end
end

local function realSpeed(item: Item): number
	local part = item.Part
	return item.GetVelocity().Magnitude * Util.TimeScaleAt(part.Position)
end

local function refreshLength(item: Item, speed: number)
	local length = math.min(speed * Streak.Seconds, Streak.MaxLength)
	if math.abs(length - item.Length) > 0.5 then
		item.Length = length
		item.Tail.Position = item.Back * length
	end
end

-- part: the root the projectile's pose drives; rootOffset: pose -> part
-- (the pose looks down -Z, so "behind" is +Z in pose space).
function Streak.Attach(part: BasePart, rootOffset: CFrame, getVelocity: () -> Vector3, color: Color3?, width: number?): () -> ()
	if #items >= Streak.MaxAttached then
		return function() end
	end
	local item = table.remove(free) or make()
	item.Part = part
	item.Back = rootOffset:VectorToObjectSpace(Vector3.zAxis)
	item.GetVelocity = getVelocity
	item.Length = 0
	item.Head.Position = Vector3.zero
	item.Tail.Position = Vector3.zero
	local tint = color or Color3.fromRGB(255, 240, 210)
	item.Beam.Color = ColorSequence.new(tint:Lerp(Color3.new(1, 1, 1), 0.2), tint:Lerp(Color3.new(1, 1, 1), 0.6))
	local w = math.clamp(width or 0.35, 0.08, 2)
	item.Beam.Width0 = w * 0.15
	item.Beam.Width1 = w
	item.Head.Parent = part
	item.Tail.Parent = part
	table.insert(items, item)
	sinceBudget = BUDGET_INTERVAL -- rank it next frame
	local attached = true
	return function()
		if not attached then
			return
		end
		attached = false
		setOn(item, false)
		local index = table.find(items, item)
		if index then
			items[index] = items[#items]
			items[#items] = nil
		end
		item.Head.Parent = nil
		item.Tail.Parent = nil
		item.Part = nil :: any
		table.insert(free, item)
	end
end

local ranked: { Item } = {}
local distances: { [Item]: number } = {}

function Streak.Step(dt: number)
	sinceBudget += dt
	if sinceBudget < BUDGET_INTERVAL or #items == 0 then
		return
	end
	sinceBudget = 0
	if not Streak.Enabled then
		for _, item in items do
			setOn(item, false)
		end
		return
	end
	local camera = Util.CameraPosition()
	table.clear(ranked)
	table.clear(distances)
	for _, item in items do
		local part = item.Part
		local speed = if part.Parent then realSpeed(item) else 0
		local distance = (part.Position - camera).Magnitude
		if speed >= Streak.MinSpeed and distance <= MAX_DISTANCE then
			refreshLength(item, speed)
			distances[item] = distance
			table.insert(ranked, item)
		else
			setOn(item, false)
		end
	end
	if #ranked > Streak.MaxActive then
		table.sort(ranked, function(a, b)
			return distances[a] < distances[b]
		end)
	end
	for index, item in ranked do
		setOn(item, index <= Streak.MaxActive)
	end
end

function Streak.GetStats(): { Attached: number, Active: number }
	return { Attached = #items, Active = activeCount }
end

return Streak
