--!strict
--[[
	DebugAccess (server)
	Who may use the debug panel's server-side features (DebugService,
	DummySpawner). Team Test runs its server in the cloud, where
	RunService:IsStudio() is false, so "is this Studio?" can't be the gate --
	this checks the player instead:

	  * any player when the server itself runs in Studio (local Play);
	  * the place owner (user-owned place), or group members at or above
	    MinGroupRank (group-owned place);
	  * anyone listed in UserIds -- add the people you Team Test with.

	Results are cached per player for the session.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local DebugAccess = {}

-- Extra people allowed on non-Studio servers (Team Test friends, testers).
DebugAccess.UserIds = {
	3598748992,
	8387051972
	-- 123456789, -- friend's UserId
} :: { number }

-- For group-owned places: lowest group rank allowed (255 = owner only).
DebugAccess.MinGroupRank = 255

local cache: { [Player]: boolean } = {}

function DebugAccess.IsAllowed(player: Player?): boolean
	if not player then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	local cached = cache[player]
	if cached ~= nil then
		return cached
	end
	local allowed = table.find(DebugAccess.UserIds, player.UserId) ~= nil
	if not allowed then
		if game.CreatorType == Enum.CreatorType.User then
			allowed = player.UserId == game.CreatorId
		else
			local ok, rank = pcall(player.GetRankInGroup, player, game.CreatorId)
			allowed = ok and typeof(rank) == "number" and rank >= DebugAccess.MinGroupRank
		end
	end
	cache[player] = allowed
	return allowed
end

Players.PlayerRemoving:Connect(function(player)
	cache[player] = nil
end)

return DebugAccess
