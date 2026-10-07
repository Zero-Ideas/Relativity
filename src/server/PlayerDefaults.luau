--!strict
--[[
	PlayerDefaults (server)
	Optional forced spawn stats for every player character: max health, walk
	speed and jump power. Admins edit them and switch forcing on/off from the
	debug panel's Defaults tab (DebugService "DebugSetDefaults"). OFF by
	default: characters then spawn exactly as Roblox / StarterPlayer make them,
	and the edited values just wait. PlayerManager applies them to each
	character as it spawns (while on), and to every living character whenever
	they or the switch change -- switching off restores the game's own
	defaults (StarterPlayer's walk speed / jump settings, 100 max health).
	Per server: a new server starts OFF at DEFAULTS.

	Movement bases are also written to the Humanoid as attributes
	(BaseWalkSpeed, and BaseJumpPower or BaseJumpHeight): time dilation scales
	the live values every frame (client MovementController, server Entity),
	and both read their base from these, so a change can't be overwritten by
	a stale base captured at spawn. Clients read the state from
	ReplicatedStorage attributes "DefaultsEnabled", "DefaultMaxHealth",
	"DefaultWalkSpeed" and "DefaultJumpPower".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local PlayerDefaults = {}

export type Stats = { MaxHealth: number, WalkSpeed: number, JumpPower: number }

local DEFAULTS: Stats = { MaxHealth = 100, WalkSpeed = 16, JumpPower = 50 }
local LIMITS = {
	MaxHealth = { 1, 1_000_000 },
	WalkSpeed = { 0, 500 },
	JumpPower = { 0, 1000 },
}
local GAME_MAX_HEALTH = 100 -- Roblox's own default, restored when forcing stops

local current: Stats = table.clone(DEFAULTS)
local enabled = false
local listeners: { (Stats, boolean) -> () } = {}

local function publish()
	for name, value in current :: any do
		ReplicatedStorage:SetAttribute("Default" .. name, value)
	end
	ReplicatedStorage:SetAttribute("DefaultsEnabled", enabled)
end

local function notify()
	publish()
	for _, listener in listeners do
		task.spawn(listener, PlayerDefaults.Get(), enabled)
	end
end

function PlayerDefaults.Get(): Stats
	return table.clone(current)
end

function PlayerDefaults.IsEnabled(): boolean
	return enabled
end

-- Turns forcing on (applies the stats to everyone alive) or off (restores the
-- game's own defaults on everyone alive).
function PlayerDefaults.SetEnabled(value: boolean)
	if enabled ~= value then
		enabled = value
		notify()
	end
end

-- Updates any of MaxHealth / WalkSpeed / JumpPower present in `changes`
-- (clamped to LIMITS; non-finite values ignored). True if anything changed.
-- Stored even while forcing is off.
function PlayerDefaults.Set(changes: { [string]: any }): boolean
	local changed = false
	for name, range in LIMITS do
		local value = changes[name]
		if typeof(value) == "number" and value == value and math.abs(value) ~= math.huge then
			value = math.clamp(value, range[1], range[2])
			if (current :: any)[name] ~= value then
				(current :: any)[name] = value
				changed = true
			end
		end
	end
	if changed then
		notify()
	end
	return changed
end

function PlayerDefaults.Reset()
	PlayerDefaults.Set(DEFAULTS :: any)
end

function PlayerDefaults.OnChanged(listener: (Stats, boolean) -> ())
	table.insert(listeners, listener)
end

local function setHealth(humanoid: Humanoid, maxHealth: number, fresh: boolean)
	local fraction = if humanoid.MaxHealth > 0 then humanoid.Health / humanoid.MaxHealth else 1
	humanoid.MaxHealth = maxHealth
	humanoid.Health = if fresh then maxHealth else math.max(maxHealth * fraction, if humanoid.Health > 0 then 1 else 0)
end

-- While forcing is on, writes the stats onto a character's Humanoid (a no-op
-- while off). `fresh` (a new spawn) also fills its health; otherwise health
-- keeps its fraction of the old maximum. Returns the movement base it set
-- (walk speed, jump power), or nil when off.
function PlayerDefaults.Apply(humanoid: Humanoid, fresh: boolean): (number?, number?)
	if not enabled then
		return nil, nil
	end
	local stats = current
	setHealth(humanoid, stats.MaxHealth, fresh)
	humanoid.UseJumpPower = true
	humanoid.WalkSpeed = stats.WalkSpeed
	humanoid.JumpPower = stats.JumpPower
	humanoid:SetAttribute("BaseWalkSpeed", stats.WalkSpeed)
	humanoid:SetAttribute("BaseJumpPower", stats.JumpPower)
	humanoid:SetAttribute("BaseJumpHeight", nil)
	return stats.WalkSpeed, stats.JumpPower
end

-- Forcing was switched off: puts a living character back on the game's own
-- defaults (StarterPlayer's movement settings, Roblox's 100 max health).
-- Returns the movement base it set (walk speed, jump power-or-height).
function PlayerDefaults.Restore(humanoid: Humanoid): (number, number)
	setHealth(humanoid, GAME_MAX_HEALTH, false)
	local walk = StarterPlayer.CharacterWalkSpeed
	humanoid.WalkSpeed = walk
	humanoid:SetAttribute("BaseWalkSpeed", walk)
	humanoid.UseJumpPower = StarterPlayer.CharacterUseJumpPower
	if StarterPlayer.CharacterUseJumpPower then
		humanoid.JumpPower = StarterPlayer.CharacterJumpPower
		humanoid:SetAttribute("BaseJumpPower", StarterPlayer.CharacterJumpPower)
		humanoid:SetAttribute("BaseJumpHeight", nil)
		return walk, StarterPlayer.CharacterJumpPower
	end
	humanoid.JumpHeight = StarterPlayer.CharacterJumpHeight
	humanoid:SetAttribute("BaseJumpHeight", StarterPlayer.CharacterJumpHeight)
	humanoid:SetAttribute("BaseJumpPower", nil)
	return walk, StarterPlayer.CharacterJumpHeight
end

publish()

return PlayerDefaults
