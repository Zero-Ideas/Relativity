--!strict
--[[
	DebugAccess (server)
	Who may use the debug panel's server-side features (DebugService,
	DummySpawner). Team Test and live servers aren't "Studio", so this checks
	the player instead:

	  * listed (the allowlist): the place owner (user-owned place), group
	    members at or above MinGroupRank (group-owned place), and anyone in
	    UserIds. Always allowed; only they can open the panel to everyone
	    (SetPublic), and the panel's Kill button doesn't affect them.
	  * any single player can have tabs taken away (SetPlayerTab) by someone
	    who outranks them -- listed or not, Admin and Defaults included;
	  * everyone else: allowed when a listed player has made the panel public,
	    or on a local Studio server -- and then only the tabs listed players
	    have made public (CanUseTab; Stats and Dummies by default). Studio
	    servers get every tab.

	Clients learn their standing from attributes: Player "DebugListed",
	"DebugRank" and "DebugDeniedTabs" (comma-separated), and
	ReplicatedStorage "DebugPublic" and "DebugPublicTabs" (comma-separated
	tab names); client/DebugPanel reads all three.
	Listing results are cached per player for the session.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DebugAccess = {}

-- Extra people allowed on non-Studio servers (Team Test friends, testers).
DebugAccess.UserIds = {
	3598748992,
	8387051972,
	-- 123456789, -- friend's UserId
} :: { number }

-- For group-owned places: lowest group rank allowed (255 = owner only).
DebugAccess.MinGroupRank = 255

-- Panel ranks among listed players. Higher outranks lower: nobody can use the
-- panel's entity actions (HP, effects, tools, kill...) on a player of their
-- own rank or above -- so the master can't be touched by anyone. Listed
-- players not named here are rank 1; everyone else 0.
DebugAccess.Ranks = {
	[3598748992] = 3, -- master
	[8387051972] = 2,
} :: { [number]: number }
DebugAccess.RankNames = { [0] = "Player", [1] = "Admin", [2] = "Senior admin", [3] = "Master" }

local PUBLIC_ATTRIBUTE = "DebugPublic"
local LISTED_ATTRIBUTE = "DebugListed"
local PUBLIC_TABS_ATTRIBUTE = "DebugPublicTabs"

-- Every panel tab (client/DebugPanel's TAB_ORDER, minus Admin, which is
-- listed-only), and the ones non-listed players see by default.
DebugAccess.Tabs = { "Tools", "Time", "Stats", "Entities", "Chunks", "Dummies", "VFX" }
local publicTabs: { [string]: boolean } = { Stats = true, Dummies = true }
-- Tabs only listed players get. Everything (these too) can also be taken
-- from one particular player by someone who outranks them (SetPlayerTab).
local LISTED_ONLY = { Defaults = true, Admin = true }
DebugAccess.AllTabs = table.clone(DebugAccess.Tabs)
table.insert(DebugAccess.AllTabs, "Defaults")
table.insert(DebugAccess.AllTabs, "Admin")

local DENIED_ATTRIBUTE = "DebugDeniedTabs"
local denied: { [Player]: { [string]: boolean } } = {}

local cache: { [Player]: boolean } = {}
local public = false

-- On the allowlist (owner / group rank / UserIds), regardless of Studio or
-- the public switch.
function DebugAccess.IsListed(player: Player?): boolean
	if not player then
		return false
	end
	local cached = cache[player]
	if cached ~= nil then
		return cached
	end
	local listed = table.find(DebugAccess.UserIds, player.UserId) ~= nil or DebugAccess.Ranks[player.UserId] ~= nil
	if not listed then
		if game.CreatorType == Enum.CreatorType.User then
			listed = player.UserId == game.CreatorId
		else
			local ok, rank = pcall(player.GetRankInGroup, player, game.CreatorId)
			listed = ok and typeof(rank) == "number" and rank >= DebugAccess.MinGroupRank
		end
	end
	cache[player] = listed
	return listed
end

function DebugAccess.GetRank(player: Player?): number
	if not player then
		return 0
	end
	local named = DebugAccess.Ranks[player.UserId]
	if named then
		return named
	end
	return if DebugAccess.IsListed(player) then 1 else 0
end

-- May `actor` use the panel on `target`'s character? Always on themselves;
-- otherwise only on players they outrank.
function DebugAccess.CanAffect(actor: Player, target: Player?): boolean
	if not target or target == actor then
		return true
	end
	return DebugAccess.GetRank(actor) > DebugAccess.GetRank(target)
end

-- May use the debug panel's server features right now.
function DebugAccess.IsAllowed(player: Player?): boolean
	if not player then
		return false
	end
	return public or RunService:IsStudio() or DebugAccess.IsListed(player)
end

function DebugAccess.IsPublic(): boolean
	return public
end

-- May use `tab`'s server features. A tab taken from this player (by someone
-- who outranks them) never; Defaults/Admin only for listed players; any other
-- tab for listed players and Studio servers, else only while the panel is
-- public and that tab is.
function DebugAccess.CanUseTab(player: Player?, tab: string): boolean
	if not player then
		return false
	end
	local taken = denied[player]
	if taken and taken[tab] then
		return false
	end
	if LISTED_ONLY[tab] then
		return DebugAccess.IsListed(player)
	end
	if RunService:IsStudio() or DebugAccess.IsListed(player) then
		return true
	end
	return public and publicTabs[tab] == true
end

-- Gives `tab` back to, or takes it from, one player. Needs the Admin tab and
-- to outrank them (never yourself, so nobody locks themselves out).
function DebugAccess.SetPlayerTab(by: Player, target: Player, tab: string, allowed: boolean): boolean
	if by == target or not DebugAccess.CanUseTab(by, "Admin") or not DebugAccess.CanAffect(by, target) then
		return false
	end
	if not table.find(DebugAccess.AllTabs, tab) then
		return false
	end
	local taken = denied[target] or {}
	taken[tab] = if allowed then nil else true
	denied[target] = if next(taken) then taken else nil
	local names = {}
	for _, name in DebugAccess.AllTabs do
		if taken[name] then
			table.insert(names, name)
		end
	end
	target:SetAttribute(DENIED_ATTRIBUTE, table.concat(names, ","))
	return true
end

local function publishTabs()
	local names = {}
	for _, name in DebugAccess.Tabs do
		if publicTabs[name] then
			table.insert(names, name)
		end
	end
	ReplicatedStorage:SetAttribute(PUBLIC_TABS_ATTRIBUTE, table.concat(names, ","))
end

-- Shows or hides `tab` for non-listed players. Only listed players may.
function DebugAccess.SetTabPublic(by: Player, tab: string, enabled: boolean): boolean
	if not DebugAccess.CanUseTab(by, "Admin") or not table.find(DebugAccess.Tabs, tab) then
		return false
	end
	publicTabs[tab] = if enabled then true else nil
	publishTabs()
	return true
end

-- Opens (or closes) the debug panel to every player. Only listed players may.
function DebugAccess.SetPublic(by: Player, enabled: boolean): boolean
	if not DebugAccess.CanUseTab(by, "Admin") then
		return false
	end
	public = enabled
	ReplicatedStorage:SetAttribute(PUBLIC_ATTRIBUTE, enabled)
	return true
end

ReplicatedStorage:SetAttribute(PUBLIC_ATTRIBUTE, public)
publishTabs()

local function onPlayer(player: Player)
	-- GetRankInGroup can yield; never hold up whoever required this module
	task.spawn(function()
		player:SetAttribute(LISTED_ATTRIBUTE, DebugAccess.IsListed(player))
		player:SetAttribute("DebugRank", DebugAccess.GetRank(player))
	end)
end
for _, player in Players:GetPlayers() do
	onPlayer(player)
end
Players.PlayerAdded:Connect(onPlayer)

Players.PlayerRemoving:Connect(function(player)
	cache[player] = nil
	denied[player] = nil
end)

return DebugAccess
