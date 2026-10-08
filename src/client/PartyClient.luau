--!strict
--[[
	Client side of server/Parties: invites and notices arrive as
	Notifications (Accept / Decline for invites), and party membership is read
	from the replicated attributes (PartyId / PartyLeader / PartyJoined) on
	each member: a Player, or a test dummy Model tagged "PartyDummy". Changed
	fires whenever anyone's party state changes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Notifications = require(script.Parent.Notifications)

local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("PartyRemote") :: RemoteEvent
local query = ReplicatedStorage:WaitForChild("PartyQuery") :: RemoteFunction

local DUMMY_TAG = "PartyDummy"

-- A Player, or a dummy Model.
export type Member = Instance

local PartyClient = {}
local changedEvent = Instance.new("BindableEvent")
PartyClient.Changed = changedEvent.Event

local started = false
-- your requests still waiting for an answer (server "Pending" messages):
-- pending[kind][target], kind "Invite" | "Join" | "InviteRequest"
local pending: { [string]: { [Instance]: boolean } } = { Invite = {}, Join = {}, InviteRequest = {} }

function PartyClient.IsPending(kind: string, target: Instance): boolean
	local set = pending[kind]
	return set ~= nil and set[target] == true
end

function PartyClient.GetPartyId(of: Member?): string?
	local id = (of or player):GetAttribute("PartyId")
	return if typeof(id) == "string" then id else nil
end

function PartyClient.IsLeader(of: Member?): boolean
	return (of or player):GetAttribute("PartyLeader") == true
end

function PartyClient.NameOf(member: Member): string
	return if member:IsA("Player") then member.DisplayName else member.Name
end

-- The model to show for a member: a Player's character, or the dummy itself.
function PartyClient.CharacterOf(member: Member): Model?
	if member:IsA("Player") then
		return member.Character
	end
	return if member:IsA("Model") then member else nil
end

local function candidates(): { Member }
	local list: { Member } = {}
	for _, other in Players:GetPlayers() do
		table.insert(list, other)
	end
	for _, dummy in CollectionService:GetTagged(DUMMY_TAG) do
		if dummy:IsA("Model") and dummy:IsDescendantOf(workspace) then
			table.insert(list, dummy)
		end
	end
	return list
end

-- Your party's members, leader first then by join order; empty when you
-- aren't in a party.
function PartyClient.GetMembers(): { Member }
	local id = PartyClient.GetPartyId()
	if not id then
		return {}
	end
	local members = {}
	for _, member in candidates() do
		if member:GetAttribute("PartyId") == id then
			table.insert(members, member)
		end
	end
	table.sort(members, function(a, b)
		local leaderA, leaderB = PartyClient.IsLeader(a), PartyClient.IsLeader(b)
		if leaderA ~= leaderB then
			return leaderA
		end
		return (a:GetAttribute("PartyJoined") or 0) < (b:GetAttribute("PartyJoined") or 0)
	end)
	return members
end

-- Everyone you could invite: players and test dummies not in your party.
function PartyClient.GetInvitable(): { Member }
	local id = PartyClient.GetPartyId()
	local list = {}
	for _, member in candidates() do
		if member ~= player and (id == nil or PartyClient.GetPartyId(member) ~= id) then
			table.insert(list, member)
		end
	end
	table.sort(list, function(a, b)
		local dummyA, dummyB = not a:IsA("Player"), not b:IsA("Player")
		if dummyA ~= dummyB then
			return dummyB -- players first
		end
		return PartyClient.NameOf(a):lower() < PartyClient.NameOf(b):lower()
	end)
	return list
end

-- Everyone but you: those outside your party first, then your party's
-- members; players before dummies, then by name.
function PartyClient.GetOthers(): { Member }
	local id = PartyClient.GetPartyId()
	local list = {}
	for _, member in candidates() do
		if member ~= player then
			table.insert(list, member)
		end
	end
	local function rank(member: Member): number
		local inMine = id ~= nil and PartyClient.GetPartyId(member) == id
		return (if inMine then 2 else 0) + (if member:IsA("Player") then 0 else 1)
	end
	table.sort(list, function(a, b)
		local rankA, rankB = rank(a), rank(b)
		if rankA ~= rankB then
			return rankA < rankB
		end
		return PartyClient.NameOf(a):lower() < PartyClient.NameOf(b):lower()
	end)
	return list
end

-- Anyone may invite; the leader can also kick.
function PartyClient.CanKick(target: Member): boolean
	local id = PartyClient.GetPartyId()
	return id ~= nil and target ~= player and PartyClient.IsLeader() and PartyClient.GetPartyId(target) == id
end

function PartyClient.IsDummy(member: Member): boolean
	return not member:IsA("Player")
end

-- The leader of `member`'s party (yours by default).
function PartyClient.LeaderOf(member: Member?): Member?
	local id = PartyClient.GetPartyId(member)
	if not id then
		return nil
	end
	for _, other in candidates() do
		if other:GetAttribute("PartyId") == id and other:GetAttribute("PartyLeader") == true then
			return other
		end
	end
	return nil
end

-- Whether `member`'s party (yours by default) is public.
function PartyClient.IsPublic(member: Member?): boolean
	local leader = PartyClient.LeaderOf(member)
	return leader ~= nil and leader:GetAttribute("PartyPublic") == true
end

function PartyClient.Create()
	remote:FireServer("Create")
end

function PartyClient.SetPublic(public: boolean)
	remote:FireServer("SetPublic", public)
end

-- Ask to join `target`'s party (a public player's party, or any dummy).
function PartyClient.RequestJoin(target: Member)
	remote:FireServer("RequestJoin", target)
end

-- Have a test dummy send you an invite.
function PartyClient.RequestInvite(dummy: Member)
	remote:FireServer("RequestInvite", dummy)
end

-- "Join" on a party (through any member) or on someone who trusts you:
-- straight in when a whitelist allows it, otherwise a join request.
function PartyClient.JoinParty(target: Player)
	remote:FireServer("JoinParty", target)
end

-- (yields) PartyQuery: "Parties" -> { Friends, Public }; "Whitelist" and
-- "WhitelistAdd" / "WhitelistRemove" / "WhitelistTrust" -> { Entries, ... }.
function PartyClient.Query(action: string, a: any?, b: any?): any
	local ok, result = pcall(query.InvokeServer, query, action, a, b)
	return if ok then result else nil
end

function PartyClient.Invite(target: Member)
	remote:FireServer("Invite", target)
end

function PartyClient.Kick(target: Member)
	remote:FireServer("Kick", target)
end

function PartyClient.Leave()
	remote:FireServer("Leave")
end

local function changed()
	changedEvent:Fire()
end

local function watch(member: Instance)
	for _, name in { "PartyId", "PartyLeader", "PartyJoined", "PartyPublic" } do
		member:GetAttributeChangedSignal(name):Connect(changed)
	end
end

function PartyClient.start()
	if started then
		return
	end
	started = true
	for _, member in candidates() do
		watch(member)
	end
	Players.PlayerAdded:Connect(function(other)
		watch(other)
		changed()
	end)
	Players.PlayerRemoving:Connect(function()
		task.defer(changed)
	end)
	CollectionService:GetInstanceAddedSignal(DUMMY_TAG):Connect(function(dummy)
		watch(dummy)
		changed()
	end)
	CollectionService:GetInstanceRemovedSignal(DUMMY_TAG):Connect(function()
		task.defer(changed)
	end)

	remote.OnClientEvent:Connect(function(kind: any, a: any, b: any, c: any)
		local seconds = if typeof(b) == "number" then math.max(b - workspace:GetServerTimeNow(), 1) else 30
		if kind == "Invite" and typeof(a) == "Instance" then
			-- from a player, or a test dummy asked to invite you
			local inviter = a :: Instance
			local who = if inviter:IsA("Player") then `{inviter.DisplayName} (@{inviter.Name})` else `{inviter.Name} (dummy)`
			Notifications.Push({
				Title = "Party invite",
				Text = `{who} invited you to their party.`,
				ExpiresIn = seconds,
				Buttons = {
					{ Text = "Accept", Callback = function() remote:FireServer("Respond", inviter, true) end },
					{ Text = "Decline", Callback = function() remote:FireServer("Respond", inviter, false) end },
				},
			})
		elseif kind == "JoinRequest" and typeof(a) == "Instance" and a:IsA("Player") then
			local requester = a :: Player
			Notifications.Push({
				Title = "Join request",
				Text = `{requester.DisplayName} (@{requester.Name}) wants to join your party.`,
				ExpiresIn = seconds,
				Buttons = {
					{ Text = "Accept", Callback = function() remote:FireServer("RespondJoin", requester, true) end },
					{ Text = "Decline", Callback = function() remote:FireServer("RespondJoin", requester, false) end },
				},
			})
		elseif kind == "Pending" and typeof(a) == "string" and pending[a] and typeof(b) == "Instance" then
			pending[a][b] = if c == true then true else nil
			changed()
		elseif kind == "WhitelistChanged" then
			changed() -- (someone's whitelist changed: the Parties tab may differ)
		elseif kind == "Notice" and typeof(a) == "string" then
			Notifications.Push({ Title = "Party", Text = a })
		end
	end)
end

return PartyClient
