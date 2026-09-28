--!strict
-- Shared live-projectile budget for weapons and compiled spells.

local Players = game:GetService("Players")

local ProjectileQuota = {}
ProjectileQuota.Maximum = 150

local active: { [Player]: number } = {}

function ProjectileQuota.Get(player: Player): number
	return active[player] or 0
end

function ProjectileQuota.TryAcquire(player: Player, count: number?): boolean
	local amount = math.max(math.floor(count or 1), 0)
	if amount == 0 then
		return true
	end
	local current = active[player] or 0
	if current + amount > ProjectileQuota.Maximum then
		return false
	end
	active[player] = current + amount
	return true
end

function ProjectileQuota.Release(player: Player, count: number?)
	local amount = math.max(math.floor(count or 1), 0)
	active[player] = math.max((active[player] or 0) - amount, 0)
end

Players.PlayerRemoving:Connect(function(player)
	active[player] = nil
end)

return ProjectileQuota
