--!strict
--[[
	Parties: make / invite / accept / decline / leave / kick, public parties
	that anyone can ask to join, no size cap, and no damage between members
	(Entity.SetDamageGate).

	Members are Players, plus (for testing) dummy Models tagged "PartyDummy"
	(DummyManager / DummySpawner). A dummy stands in for another player:
	invite it and it joins at once; "request to join" it and you join its
	party at once (it leads a new one if it has none); "request an invite"
	and it sends you a real invite.

	State lives in attributes on the member -- the Player, or the dummy's
	Model -- which replicate to every client:
	  PartyId     string?  -- shared by every member of a party
	  PartyLeader boolean  -- true on the leader
	  PartyJoined number   -- join order (leadership passes to the earliest
	                          Player left)
	  PartyPublic boolean  -- on the leader: anyone may request to join

	Remote "PartyRemote" (ReplicatedStorage):
	  client -> server:
	    ("Create")                      make a party (you lead it)
	    ("Invite", member)              invite a player / dummy
	    ("Respond", inviter, accepted)  answer an invite
	    ("RequestJoin", member)         ask to join that member's party
	    ("RespondJoin", requester, accepted)  (leader) answer a request
	    ("RequestInvite", dummy)        have a dummy invite you
	    ("SetPublic", boolean)          (leader) open / close the party
	    ("JoinParty", player)           join that player's party (straight
	                                    in if a whitelist allows it, else a
	                                    join request) -- see Whitelists
	    ("Leave") ("Kick", member)
	  server -> client:
	    ("Invite", inviter, expiresAt) ("JoinRequest", requester, expiresAt)
	    ("Pending", kind, target, pending)  one of yours started / stopped
	        pending (kind "Invite" | "Join" | "InviteRequest"); a pending
	        one can't be sent again
	    ("Notice", text) ("WhitelistChanged")
	RemoteFunction "PartyQuery": ("Parties") -> { Friends, Public } for the
	Parties tab; ("Whitelist") and ("WhitelistAdd" | "WhitelistRemove" |
	"WhitelistTrust", userId, trusted?) -> { Entries, Ok?, Message? }.
	Any member may invite; only the leader kicks, answers join requests and
	sets the party public. Joining a party leaves the one you were in. A
	party lasts while it has a Player in it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")

local Entity = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Entity"))

local REQUEST_LIFETIME = 30 -- seconds: invites and join requests
local REQUEST_INTERVAL = 0.08 -- (spam guard; low enough not to drop quick clicks)
local DUMMY_TAG = "PartyDummy"

local remote = Instance.new("RemoteEvent")
remote.Name = "PartyRemote"
remote.Parent = ReplicatedStorage

-- invites[invitee][inviter] / joinRequests[leader][requester] = expiry (os.clock)
local invites: { [Player]: { [Instance]: number } } = {}
-- (each join request remembers who you asked through, for setPending)
local joinRequests: { [Player]: { [Player]: { expiry: number, target: Instance } } } = {}
local lastRequest: { [Player]: number } = {}
local joinCounter = 0

local function partyOf(member: Instance): string?
	local id = member:GetAttribute("PartyId")
	return if typeof(id) == "string" then id else nil
end

local function nameOf(member: Instance): string
	return if member:IsA("Player") then member.DisplayName else member.Name
end

local function isDummy(value: any): boolean
	return typeof(value) == "Instance" and value:IsA("Model") and value.Parent ~= nil
		and CollectionService:HasTag(value, DUMMY_TAG)
end

local function isPlayer(value: any): boolean
	return typeof(value) == "Instance" and value:IsA("Player") and value.Parent == Players
end

-- Every member of a party, by join order.
local function membersOf(id: string): { Instance }
	local members: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("PartyId") == id then
			table.insert(members, player)
		end
	end
	for _, dummy in CollectionService:GetTagged(DUMMY_TAG) do
		if dummy:GetAttribute("PartyId") == id then
			table.insert(members, dummy)
		end
	end
	table.sort(members, function(a, b)
		return (a:GetAttribute("PartyJoined") or 0) < (b:GetAttribute("PartyJoined") or 0)
	end)
	return members
end

local function leaderOf(id: string): Instance?
	for _, member in membersOf(id) do
		if member:GetAttribute("PartyLeader") == true then
			return member
		end
	end
	return nil
end

-- Tells `player` a request of theirs is (no longer) pending, so their invite
-- window can hide the button for it: kind "Invite" (they invited `target`),
-- "Join" (they asked to join `target`'s party) or "InviteRequest" (they
-- asked dummy `target` for an invite).
local function setPending(player: Instance, kind: string, target: Instance, pending: boolean)
	if player:IsA("Player") and player.Parent == Players then
		remote:FireClient(player, "Pending", kind, target, pending)
	end
end

local function notice(member: Instance, text: string)
	if member:IsA("Player") then
		remote:FireClient(member, "Notice", text)
	end
end

local function noticeParty(id: string, text: string, except: Instance?)
	for _, member in membersOf(id) do
		if member ~= except then
			notice(member, text)
		end
	end
end

local function join(member: Instance, id: string, leader: boolean)
	joinCounter += 1
	member:SetAttribute("PartyJoined", joinCounter)
	member:SetAttribute("PartyLeader", leader)
	member:SetAttribute("PartyId", id)
end

local function clear(member: Instance)
	member:SetAttribute("PartyId", nil)
	member:SetAttribute("PartyLeader", nil)
	member:SetAttribute("PartyJoined", nil)
	member:SetAttribute("PartyPublic", nil)
end

-- After a member left party `id`: a party with no Players disbands;
-- otherwise, if it lost its leader, the earliest Player leads (and keeps it
-- public if it was).
local function afterLeave(id: string, name: string, wasLeader: boolean, wasPublic: boolean)
	local rest = membersOf(id)
	local firstPlayer: Player? = nil
	for _, other in rest do
		if other:IsA("Player") then
			firstPlayer = other
			break
		end
	end
	if not firstPlayer then
		for _, other in rest do
			clear(other)
		end
		return
	end
	noticeParty(id, `{name} left the party.`)
	if wasLeader then
		firstPlayer:SetAttribute("PartyLeader", true)
		firstPlayer:SetAttribute("PartyPublic", if wasPublic then true else nil)
		notice(firstPlayer, "You are now the party leader.")
	end
end

local function leave(member: Instance)
	local id = partyOf(member)
	if not id then return end
	local wasLeader = member:GetAttribute("PartyLeader") == true
	local wasPublic = member:GetAttribute("PartyPublic") == true
	clear(member)
	afterLeave(id, nameOf(member), wasLeader, wasPublic)
end

-- `member`'s party, made on the spot (led by them) if they aren't in one.
local function ensureParty(member: Instance): string
	local id = partyOf(member)
	if not id then
		id = HttpService:GenerateGUID(false)
		join(member, id, true)
	end
	return id :: string
end

local function addMember(id: string, member: Instance)
	if partyOf(member) == id then return end
	leave(member)
	noticeParty(id, `{nameOf(member)} joined the party.`)
	join(member, id, false)
	notice(member, `You joined {nameOf(leaderOf(id) or member)}'s party.`)
end

local function invite(inviter: Player, target: any)
	if isDummy(target) then
		-- test dummies accept straight away
		local id = ensureParty(inviter)
		if partyOf(target) == id then
			return notice(inviter, `{target.Name} is already in your party.`)
		end
		addMember(id, target)
		return
	end
	if not isPlayer(target) or target == inviter then
		return
	end
	local id = partyOf(inviter)
	if id and partyOf(target) == id then
		return notice(inviter, `{target.DisplayName} is already in your party.`)
	end
	local pending = invites[target]
	if not pending then
		pending = {}
		invites[target] = pending
	end
	if pending[inviter] and pending[inviter] > os.clock() then
		return notice(inviter, `Your invite to {target.DisplayName} is still pending.`)
	end
	local expiry = os.clock() + REQUEST_LIFETIME
	pending[inviter] = expiry
	remote:FireClient(target, "Invite", inviter, workspace:GetServerTimeNow() + REQUEST_LIFETIME)
	setPending(inviter, "Invite", target, true)
	notice(inviter, `Invited {target.DisplayName}.`)
	task.delay(REQUEST_LIFETIME, function()
		local still = invites[target]
		if still and still[inviter] == expiry then
			still[inviter] = nil
			setPending(inviter, "Invite", target, false)
		end
	end)
end

-- A dummy invites `player` (testing the receiving side of invites).
local function requestInvite(player: Player, dummy: any)
	if not isDummy(dummy) then return end
	local id = partyOf(dummy)
	if id and partyOf(player) == id then
		return notice(player, `You're already in {dummy.Name}'s party.`)
	end
	local pending = invites[player]
	if not pending then
		pending = {}
		invites[player] = pending
	end
	if pending[dummy] and pending[dummy] > os.clock() then
		return notice(player, `{dummy.Name}'s invite to you is still pending.`)
	end
	local expiry = os.clock() + REQUEST_LIFETIME
	pending[dummy] = expiry
	remote:FireClient(player, "Invite", dummy, workspace:GetServerTimeNow() + REQUEST_LIFETIME)
	setPending(player, "InviteRequest", dummy, true)
	task.delay(REQUEST_LIFETIME, function()
		local still = invites[player]
		if still and still[dummy] == expiry then
			still[dummy] = nil
			setPending(player, "InviteRequest", dummy, false)
		end
	end)
end

local function respond(player: Player, inviter: any, accepted: any)
	local pending = invites[player]
	local expiry = pending and typeof(inviter) == "Instance" and pending[inviter :: Instance]
	if not expiry then return end
	(pending :: any)[inviter] = nil
	local from = inviter :: Instance
	if from:IsA("Player") then
		setPending(from, "Invite", player, false)
	else
		setPending(player, "InviteRequest", from, false)
	end
	if expiry < os.clock() or not (isPlayer(from) or isDummy(from)) then
		return notice(player, "That invite has expired.")
	end
	if accepted ~= true then
		return notice(from, `{player.DisplayName} declined your invite.`)
	end
	local id = ensureParty(from)
	addMember(id, player)
end

-- Ask to join `target`'s party: a dummy's party lets you straight in (the
-- dummy leads a new one if it has none); a player's must be public, and its
-- leader decides.
local function requestJoin(player: Player, target: any)
	if isDummy(target) then
		addMember(ensureParty(target), player)
		return
	end
	if not isPlayer(target) or target == player then return end
	local id = partyOf(target)
	if not id or partyOf(player) == id then return end
	local leader = leaderOf(id)
	if not leader or leader:GetAttribute("PartyPublic") ~= true then
		return notice(player, `{target.DisplayName}'s party isn't public.`)
	end
	if not leader:IsA("Player") then
		addMember(id, player) -- (a dummy leader lets you in)
		return
	end
	local leaderPlayer = leader :: Player
	local pending = joinRequests[leaderPlayer]
	if not pending then
		pending = {}
		joinRequests[leaderPlayer] = pending
	end
	local existing = pending[player]
	if existing and existing.expiry > os.clock() then
		return notice(player, "Your request to join that party is still pending.")
	end
	local request = { expiry = os.clock() + REQUEST_LIFETIME, target = target :: Instance }
	pending[player] = request
	remote:FireClient(leaderPlayer, "JoinRequest", player, workspace:GetServerTimeNow() + REQUEST_LIFETIME)
	setPending(player, "Join", target, true)
	notice(player, `Asked to join {leaderPlayer.DisplayName}'s party.`)
	task.delay(REQUEST_LIFETIME, function()
		local still = joinRequests[leaderPlayer]
		if still and still[player] == request then
			still[player] = nil
			setPending(player, "Join", request.target, false)
		end
	end)
end

local function respondJoin(leader: Player, requester: any, accepted: any)
	local pending = joinRequests[leader]
	local request = pending and typeof(requester) == "Instance" and pending[requester :: Player]
	if not request then return end
	(pending :: any)[requester] = nil
	local who = requester :: Player
	setPending(who, "Join", request.target, false)
	local expiry = request.expiry
	local id = partyOf(leader)
	if expiry < os.clock() or not isPlayer(who) then
		return notice(leader, "That request has expired.")
	end
	if not id or leader:GetAttribute("PartyLeader") ~= true then
		return notice(leader, "You're no longer leading a party.")
	end
	if accepted ~= true then
		return notice(who, `{leader.DisplayName} declined your request to join.`)
	end
	addMember(id, who)
end

local function setPublic(player: Player, public: any)
	local id = ensureParty(player)
	if player:GetAttribute("PartyLeader") ~= true then
		return notice(player, "Only the party leader can change that.")
	end
	if (player:GetAttribute("PartyPublic") == true) == (public == true) then
		return -- (no change)
	end
	player:SetAttribute("PartyPublic", if public == true then true else nil)
	noticeParty(id, if public == true then "The party is now public." else "The party is now private.")
end

local function kick(leader: Player, target: any)
	local id = partyOf(leader)
	if not id or leader:GetAttribute("PartyLeader") ~= true then return end
	if typeof(target) ~= "Instance" or target == leader or partyOf(target) ~= id then return end
	if not target:IsA("Player") and not isDummy(target) then return end
	leave(target)
	notice(target, `You were removed from {leader.DisplayName}'s party.`)
end

--------------------------------------------------------------------------------
-- Whitelists ("friends")
--------------------------------------------------------------------------------
-- Each player keeps a whitelist of users (by UserId, saved across sessions).
-- Being on someone's whitelist lets you straight into their party:
--   * whitelisted by the leader of a public party -> "Join" (no request)
--   * whitelisted by every player in a party      -> "Join", even if private
--   * Trusted by anyone in a party                -> "Join", even if private;
--     Trusted by someone in no party -> "Join" makes a party with them
-- Everyone else asks to join a public party (the leader answers).

local MAX_WHITELIST = 200
type WhitelistEntry = { name: string, trusted: boolean }
local whitelists: { [Player]: { [string]: WhitelistEntry } } = {}
local whitelistStore: DataStore? = nil
do
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore("PartyWhitelist_v1")
	end)
	whitelistStore = if ok then store else nil
end
local saveQueued: { [Player]: boolean } = {}

local function whitelistOf(owner: Player): { [string]: WhitelistEntry }
	local list = whitelists[owner]
	if not list then
		list = {}
		whitelists[owner] = list
	end
	return list
end

-- (owner's whitelist has user, user's entry is trusted)
local function allows(owner: Instance, user: Player): (boolean, boolean)
	if not owner:IsA("Player") or owner == user then
		return false, false
	end
	local entry = whitelistOf(owner)[tostring(user.UserId)]
	return entry ~= nil, entry ~= nil and entry.trusted
end

local function saveWhitelist(owner: Player)
	if not whitelistStore or saveQueued[owner] then return end
	saveQueued[owner] = true
	task.delay(2, function()
		saveQueued[owner] = nil
		local list = whitelists[owner]
		if list and whitelistStore then
			pcall(function()
				(whitelistStore :: DataStore):SetAsync(`user_{owner.UserId}`, list)
			end)
		end
	end)
end

local function loadWhitelist(owner: Player)
	if not whitelistStore then return end
	local ok, data = pcall(function()
		return (whitelistStore :: DataStore):GetAsync(`user_{owner.UserId}`)
	end)
	if ok and typeof(data) == "table" and owner.Parent == Players then
		local list = whitelistOf(owner)
		for key, entry in data do
			if typeof(key) == "string" and typeof(entry) == "table" and list[key] == nil then
				list[key] = { name = tostring(entry.name or key), trusted = entry.trusted == true }
			end
		end
		remote:FireAllClients("WhitelistChanged")
	end
end

-- Whether `user` may join party `id` straight away (see the rules above).
local function canJoinNow(user: Player, id: string): boolean
	local members = membersOf(id)
	local players = 0
	local allWhitelist = true
	for _, member in members do
		if member:IsA("Player") then
			players += 1
			local listed, trusted = allows(member, user)
			if trusted then
				return true
			end
			allWhitelist = allWhitelist and listed
		end
	end
	if players > 0 and allWhitelist then
		return true
	end
	local leader = leaderOf(id)
	return leader ~= nil and leader:GetAttribute("PartyPublic") == true and (allows(leader, user))
end

-- "Join" on a party (through any of its members), or on someone in no party
-- who trusts you. Falls back to a join request for a public party.
local function joinParty(user: Player, target: any)
	if not isPlayer(target) or target == user then return end
	local id = partyOf(target)
	if id then
		if partyOf(user) == id then return end
		if canJoinNow(user, id) then
			addMember(id, user)
		else
			requestJoin(user, target)
		end
		return
	end
	local _, trusted = allows(target, user)
	if trusted then
		local newId = ensureParty(target)
		addMember(newId, user)
	else
		notice(user, `{target.DisplayName} isn't in a party.`)
	end
end

-- The Parties tab: parties of people who whitelisted you (and people who
-- trust you but are in no party) apart from the other public parties.
type PartyInfo = { Target: Player, Leader: string, Members: { string }, Public: boolean, Join: string? }

local function describe(user: Player, id: string, through: Player): PartyInfo
	local names = {}
	for _, member in membersOf(id) do
		table.insert(names, nameOf(member))
	end
	local leader = leaderOf(id)
	local public = leader ~= nil and leader:GetAttribute("PartyPublic") == true
	return {
		Target = through,
		Leader = if leader then nameOf(leader) else nameOf(through),
		Members = names,
		Public = public,
		Join = if canJoinNow(user, id) then "join" elseif public then "request" else nil,
	}
end

local function listParties(user: Player): { Friends: { PartyInfo }, Public: { PartyInfo } }
	local mine = partyOf(user)
	local friends: { PartyInfo } = {}
	local seen: { [string]: boolean } = {}
	for _, other in Players:GetPlayers() do
		local listed, trusted = allows(other, user)
		if not listed then continue end
		local id = partyOf(other)
		if id then
			if id ~= mine and not seen[id] then
				seen[id] = true
				table.insert(friends, describe(user, id, other))
			end
		elseif trusted and not mine then
			table.insert(friends, {
				Target = other,
				Leader = other.DisplayName,
				Members = {},
				Public = false,
				Join = "join",
			})
		end
	end
	local public: { PartyInfo } = {}
	for _, other in Players:GetPlayers() do
		local id = partyOf(other)
		if id and id ~= mine and not seen[id] and other:GetAttribute("PartyLeader") == true
			and other:GetAttribute("PartyPublic") == true then
			seen[id] = true
			table.insert(public, describe(user, id, other))
		end
	end
	return { Friends = friends, Public = public }
end

local function whitelistView(owner: Player): { any }
	local list = {}
	for key, entry in whitelistOf(owner) do
		local userId = tonumber(key)
		table.insert(list, {
			UserId = userId,
			Name = entry.name,
			Trusted = entry.trusted,
			InServer = userId ~= nil and Players:GetPlayerByUserId(userId) ~= nil,
		})
	end
	table.sort(list, function(a, b)
		return a.Name:lower() < b.Name:lower()
	end)
	return list
end

local function changeWhitelist(owner: Player, action: string, userId: any, value: any): (boolean, string?)
	if typeof(userId) ~= "number" or userId ~= userId or userId % 1 ~= 0 or userId <= 0 or userId >= 2 ^ 53 then
		return false, "Enter a valid UserId."
	end
	if userId == owner.UserId then
		return false, "That's you."
	end
	local list = whitelistOf(owner)
	local key = tostring(userId)
	if action == "WhitelistAdd" then
		if list[key] then return true, nil end
		local count = 0
		for _ in list do count += 1 end
		if count >= MAX_WHITELIST then
			return false, `Your whitelist is full ({MAX_WHITELIST}).`
		end
		local inServer = Players:GetPlayerByUserId(userId)
		local name = if inServer then inServer.Name else nil
		if not name then
			local ok, result = pcall(Players.GetNameFromUserIdAsync, Players, userId)
			if not ok or typeof(result) ~= "string" then
				return false, "No Roblox user has that UserId."
			end
			name = result
		end
		list[key] = { name = name :: string, trusted = false }
	elseif action == "WhitelistRemove" then
		if not list[key] then return true, nil end -- (no change)
		list[key] = nil
	elseif action == "WhitelistTrust" then
		local entry = list[key]
		if not entry then return false, "They aren't on your whitelist." end
		if entry.trusted == (value == true) then return true, nil end -- (no change)
		entry.trusted = value == true
	else
		return false, "Unknown action."
	end
	saveWhitelist(owner)
	remote:FireAllClients("WhitelistChanged")
	return true, nil
end

local query = Instance.new("RemoteFunction")
query.Name = "PartyQuery"
query.Parent = ReplicatedStorage
local lastQuery: { [Player]: number } = {}

query.OnServerInvoke = function(player: Player, action: any, a: any, b: any): any
	local now = os.clock()
	if lastQuery[player] and now - lastQuery[player] < 0.05 then
		task.wait(0.05)
	end
	lastQuery[player] = os.clock()
	if action == "Parties" then
		return listParties(player)
	elseif action == "Whitelist" then
		return { Entries = whitelistView(player) }
	elseif action == "WhitelistAdd" or action == "WhitelistRemove" or action == "WhitelistTrust" then
		local ok, err = changeWhitelist(player, action, a, b)
		return { Ok = ok, Message = err, Entries = whitelistView(player) }
	end
	return nil
end

Players.PlayerAdded:Connect(loadWhitelist)
for _, player in Players:GetPlayers() do
	task.spawn(loadWhitelist, player)
end

remote.OnServerEvent:Connect(function(player: Player, action: any, a: any, b: any)
	local now = os.clock()
	if lastRequest[player] and now - lastRequest[player] < REQUEST_INTERVAL then return end
	lastRequest[player] = now
	if action == "Create" then
		if not partyOf(player) then
			ensureParty(player)
		end
	elseif action == "Invite" then
		invite(player, a)
	elseif action == "Respond" then
		respond(player, a, b)
	elseif action == "RequestJoin" then
		requestJoin(player, a)
	elseif action == "RespondJoin" then
		respondJoin(player, a, b)
	elseif action == "RequestInvite" then
		requestInvite(player, a)
	elseif action == "SetPublic" then
		setPublic(player, a)
	elseif action == "Leave" then
		leave(player)
	elseif action == "Kick" then
		kick(player, a)
	elseif action == "JoinParty" then
		joinParty(player, a)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	leave(player)
	if whitelists[player] and whitelistStore then
		local list = whitelists[player]
		pcall(function()
			(whitelistStore :: DataStore):SetAsync(`user_{player.UserId}`, list)
		end)
	end
	whitelists[player] = nil
	saveQueued[player] = nil
	lastQuery[player] = nil
	invites[player] = nil
	joinRequests[player] = nil
	lastRequest[player] = nil
	for _, pending in invites do
		pending[player] = nil
	end
	for _, pending in joinRequests do
		pending[player] = nil
	end
end)

-- A dummy that's destroyed (or respawned) leaves its party.
CollectionService:GetInstanceRemovedSignal(DUMMY_TAG):Connect(function(dummy)
	local id = partyOf(dummy)
	if id then
		afterLeave(id, dummy.Name, dummy:GetAttribute("PartyLeader") == true, dummy:GetAttribute("PartyPublic") == true)
	end
	for _, pending in invites do
		pending[dummy] = nil
	end
end)

-- Friendly fire: members of the same party can't damage each other (anyone
-- can still hurt themselves). Sources and targets are Entities (or Players).
local function memberOf(value: any): Instance?
	local instance = if typeof(value) == "Instance" then value
		elseif typeof(value) == "table" and typeof(value.Instance) == "Instance" then value.Instance
		else nil
	if not instance then
		return nil
	end
	if instance:IsA("Player") then
		return instance
	end
	return Players:GetPlayerFromCharacter(instance) or instance
end

Entity.SetDamageGate(function(source, target)
	local attacker = memberOf(source)
	local victim = attacker and memberOf(target)
	if not attacker or not victim or attacker == victim then
		return true
	end
	local id = partyOf(attacker)
	return id == nil or partyOf(victim) ~= id
end)
