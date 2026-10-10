--!strict
-- Shared live-projectile budget for weapons and compiled spells.

local Players = game:GetService("Players")

local ProjectileQuota = {}
-- Head packets AND independently hitting beamlets share this budget. The
-- old 150 ceiling could admit a head but reject its required joiners during
-- ordinary sustain, leaving real gaps. Allow the requested 10k-scale loads;
-- spawn/render/network per-frame caps remain separate and unchanged.
ProjectileQuota.Maximum = 15000
-- Gameplay admission only; administrator benchmarks deliberately bypass quotas.
ProjectileQuota.GlobalMaximum = 100000

local active: { [Player]: number } = {}
local total = 0

local function amountOf(count: number?): number?
	local value = count or 1
	if typeof(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return nil end
	return math.max(math.floor(value), 0)
end

function ProjectileQuota.GetTotal(): number
	return total
end

function ProjectileQuota.Get(player: Player): number
	return active[player] or 0
end

function ProjectileQuota.TryAcquire(player: Player, count: number?): boolean
	if player.Parent ~= Players then return false end
	local amount = amountOf(count)
	if not amount then return false end
	if amount == 0 then
		return true
	end
	local current = active[player] or 0
	if current + amount > ProjectileQuota.Maximum or total + amount > ProjectileQuota.GlobalMaximum then
		return false
	end
	active[player] = current + amount
	total += amount
	return true
end

function ProjectileQuota.Release(player: Player, count: number?)
	local amount = amountOf(count)
	if not amount then return end
	local current = active[player] or 0
	local released = math.min(current, amount)
	active[player] = if current > released then current - released else nil
	total -= released
end

-- Departing players' projectiles still consume global capacity until destroyed.
-- Their final Release removes the entry; no early removal or double decrement.

return ProjectileQuota
