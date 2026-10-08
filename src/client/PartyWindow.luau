--!strict
--[[
	The Party window (ReGui; the topbar's Party button, the party panel's
	"+" and "Find party"), with four tabs:

	  Invite    -- your party (make / leave, public switch for the leader)
	               and everyone else: Invite, Request to join (public
	               parties), and for test dummies Request an invite. Party
	               members say "in party"; requests waiting for an answer
	               show as text instead of their button.
	  Parties   -- "Friends' parties" (parties of people who have you as a
	               friend, and people who trust you but are in no party) kept
	               apart from the other public parties. "Join" goes straight
	               in when the leader's friends list and settings allow it;
	               otherwise "Request to join".
	  Friends   -- add people by UserId or from this server; each one can be
	               marked Trusted.
	  Settings  -- whether Trusted friends may auto-join a party with you,
	               and whether friends may auto-join your public party.
	               (Rules: server/Parties, "Friends".)

	The window is retained while hidden; state changes update its controls.
]]

local Players = game:GetService("Players")

local PartyClient = require(script.Parent.PartyClient)
local ReGuiLoader = require(script.Parent.ReGuiLoader)
local ReGuiLive = require(script.Parent.ReGuiLive)

local player = Players.LocalPlayer

local PartyWindow = {}

local open = false
local window: any = nil
local sections: { [string]: any } = {}
local geometry: { position: UDim2, size: UDim2 }? = nil
local activeTab = "Invite"
local building = false
local queued = false
local whitelistInput = "" -- the typed UserId, kept across updates
local whitelistMessage = ""

local function captureState()
	if not window then
		return
	end
	local frame = window.WindowFrame
	geometry = { position = frame.Position, size = frame.Size }
	local selector = window.WindowTabSelector
	if selector then
		for _, entry in selector.Tabs do
			if entry.IsSelected then
				activeTab = entry.Name
			end
		end
	end
end

local function hideWindow()
	captureState()
	if window then
		window:SetVisible(false)
	end
end

local function wrap(label: any)
	pcall(function()
		label.TextWrapped = true
		label.AutomaticSize = Enum.AutomaticSize.Y
		label.Size = UDim2.new(1, 0, 0, 0)
	end)
end

local refresh: () -> ()

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------

local function buildInvite(tab: any)
	local id = PartyClient.GetPartyId()
	local leader = id ~= nil and PartyClient.IsLeader()
	if id then
		local leaderOf = PartyClient.LeaderOf()
		local count = #PartyClient.GetMembers()
		local row = tab:Row({ LiveKey = "partyStatus" })
		row:Label({
			Text = if leader then `Your party ({count})` else `{if leaderOf then PartyClient.NameOf(leaderOf) else "?"}'s party ({count})`,
		})
		row:SmallButton({ Text = "Leave", Callback = PartyClient.Leave })
		if leader then
			tab:Checkbox({
				Label = "Public party (anyone can ask to join)",
				Value = PartyClient.IsPublic(),
				-- (ReGui runs this on creation too: only act on a real change,
				-- or a programmatic update could echo back to the server)
				Callback = function(_, value: boolean)
					if value ~= PartyClient.IsPublic() then
						PartyClient.SetPublic(value)
					end
				end,
			})
		else
			tab:Label({ Text = "Only the party leader can invite." })
		end
	else
		local row = tab:Row({ LiveKey = "partyStatus" })
		row:Label({ Text = "You're not in a party." })
		row:SmallButton({ Text = "Make party", Callback = PartyClient.Create })
	end
	tab:Separator({ Text = "Players" })
	local others = PartyClient.GetOthers()
	if #others == 0 then
		tab:Label({ Text = "No one else is here." })
	end
	for _, other in others do
		local dummy = PartyClient.IsDummy(other)
		local name = PartyClient.NameOf(other) .. (if dummy then " (dummy)" else "")
		local row = tab:Row({ LiveKey = other })
		if id and PartyClient.GetPartyId(other) == id then
			row:Label({ Text = `{name} - in party` })
			continue
		end
		local public = not dummy and PartyClient.IsPublic(other)
		local invitePending = PartyClient.IsPending("Invite", other)
		local joinPending = PartyClient.IsPending("Join", other)
		local askPending = PartyClient.IsPending("InviteRequest", other)
		local notes = {}
		if public then table.insert(notes, "public") end
		if invitePending then table.insert(notes, "invite pending") end
		if joinPending then table.insert(notes, "join requested") end
		if askPending then table.insert(notes, "invite requested") end
		row:Label({ Text = name .. (if #notes > 0 then ` - {table.concat(notes, ", ")}` else "") })
		if (not id or leader) and not invitePending then
			row:SmallButton({ Text = "Invite", Callback = function() PartyClient.Invite(other) end })
		end
		if (dummy or public) and not joinPending then
			row:SmallButton({ Text = "Request to join", Callback = function() PartyClient.RequestJoin(other) end })
		end
		if dummy and not askPending then
			row:SmallButton({ Text = "Request an invite", Callback = function() PartyClient.RequestInvite(other) end })
		end
	end
end

local function partyRow(tab: any, info: any)
	tab = tab:Group({ LiveKey = tostring(info.Target) })
	local count = #info.Members
	local title = if count == 0 then `{info.Leader} - not in a party, trusts you`
		else `{info.Leader}'s party ({count}){if info.Public then " - public" else " - private"}`
	local row = tab:Row()
	row:Label({ Text = title })
	if PartyClient.IsPending("Join", info.Target) then
		row:Label({ Text = "(join requested)" })
	elseif info.Join == "join" then
		row:SmallButton({ Text = "Join", Callback = function() PartyClient.JoinParty(info.Target) end })
	elseif info.Join == "request" then
		row:SmallButton({ Text = "Request to join", Callback = function() PartyClient.JoinParty(info.Target) end })
	end
	if count > 0 then
		local members = tab:Label({ Text = "    " .. table.concat(info.Members, ", ") })
		wrap(members)
	end
end

local function buildParties(tab: any, parties: any)
	tab:Button({ Text = "Refresh", Callback = function() refresh() end })
	local friends = if parties then parties.Friends else {}
	local public = if parties then parties.Public else {}
	tab:Separator({ Text = `Friends' parties ({#friends})` })
	if #friends == 0 then
		tab:Label({ Text = "None of the people who added you as a friend are in a party." })
	end
	for _, info in friends do
		partyRow(tab, info)
	end
	tab:Separator({ Text = `Public parties ({#public})` })
	if #public == 0 then
		tab:Label({ Text = "No public parties right now." })
	end
	for _, info in public do
		partyRow(tab, info)
	end
end

local function changeWhitelist(action: string, userId: number, value: boolean?)
	task.spawn(function()
		local result = PartyClient.Query(action, userId, value)
		whitelistMessage = if result and result.Ok == false then result.Message or "" else ""
		refresh()
	end)
end

local function buildFriends(tab: any, whitelist: any)
	local help = tab:Label({
		Text = "Friends can join your public party without asking, and "
			.. "Trusted friends can join you any time -- even a private party, "
			.. "or with no party (it makes one, led by you). See Settings.",
	})
	wrap(help)
	local entries = if whitelist then whitelist.Entries else {}
	local listed: { [number]: boolean } = {}
	for _, entry in entries do
		listed[entry.UserId] = true
	end

	local add = tab:Row()
	add:InputText({
		Label = "",
		Placeholder = "UserId",
		Value = whitelistInput,
		Callback = function(_, text: string)
			whitelistInput = text
		end,
	})
	add:SmallButton({
		Text = "Add",
		Callback = function()
			local userId = tonumber(whitelistInput)
			if not userId then
				whitelistMessage = "Enter a UserId (a number)."
				refresh()
				return
			end
			whitelistInput = ""
			changeWhitelist("WhitelistAdd", userId)
		end,
	})
	if whitelistMessage ~= "" then
		tab:Label({ Text = whitelistMessage })
	end

	tab:Separator({ Text = `Your friends ({#entries})` })
	if #entries == 0 then
		tab:Label({ Text = "None yet." })
	end
	for _, entry in entries do
		local row = tab:Row({ LiveKey = "friend:" .. entry.UserId })
		row:Label({ Text = `{entry.Name} ({entry.UserId}){if entry.InServer then " - here" else ""}` })
		row:Checkbox({
			Label = "Trusted",
			Value = entry.Trusted,
			-- (ReGui runs this on creation too: only act on a real change)
			Callback = function(_, value: boolean)
				if value ~= entry.Trusted then
					changeWhitelist("WhitelistTrust", entry.UserId, value)
				end
			end,
		})
		row:SmallButton({ Text = "Remove", Callback = function() changeWhitelist("WhitelistRemove", entry.UserId) end })
	end

	tab:Separator({ Text = "In this server" })
	local any = false
	for _, other in Players:GetPlayers() do
		if other ~= player and not listed[other.UserId] then
			any = true
			local row = tab:Row({ LiveKey = "player:" .. other.UserId })
			row:Label({ Text = `{other.DisplayName} (@{other.Name})` })
			row:SmallButton({ Text = "Add friend", Callback = function() changeWhitelist("WhitelistAdd", other.UserId) end })
		end
	end
	if not any then
		tab:Label({ Text = "Everyone here is already your friend." })
	end
end

local SETTINGS = {
	{ "AllowTrustedJoin", "Allow trusted friends to auto-join a party with you" },
	{ "AllowFriendsJoin", "Allow friends to automatically join your public party" },
}

local function buildSettings(tab: any, settings: any)
	for _, info in SETTINGS do
		local name = info[1]
		local current = settings ~= nil and settings[name] == true
		tab:Checkbox({
			Label = info[2],
			Value = current,
			-- (ReGui runs this on creation too: only act on a real change)
			Callback = function(_, value: boolean)
				if value ~= current then
					current = value
					task.spawn(PartyClient.Query, "SetSetting", name, value)
				end
			end,
		})
	end
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local function build(ReGui: any, parties: any, whitelist: any, settings: any)
	if window then
		sections.Invite:Render(nil, buildInvite)
		sections.Parties:Render(nil, function(tab) buildParties(tab, parties) end)
		sections.Friends:Render(nil, function(tab) buildFriends(tab, whitelist) end)
		sections.Settings:Render(nil, function(tab) buildSettings(tab, settings) end)
		return
	end
	local created: any
	created = ReGui:TabsWindow({
		Title = "Party",
		Size = if geometry then geometry.size else UDim2.fromOffset(520, 420),
		NoCollapse = true,
		NoWindowRegistor = true,
		CloseCallback = function()
			hideWindow()
			open = false
			return false
		end,
	})
	window = created
	local frame = created.WindowFrame
	-- (top-left anchor, which ReGui's resize handle assumes: placed in the
	-- bottom-right by its size instead)
	frame.Position = if geometry then geometry.position
		else UDim2.new(1, -16 - frame.Size.X.Offset, 1, -250 - frame.Size.Y.Offset)
	for _, name in { "Invite", "Parties", "Friends", "Settings" } do
		sections[name] = ReGuiLive.Section(created:CreateTab({ Name = name }))
	end
	build(ReGui, parties, whitelist, settings)
	pcall(function()
		created.WindowTabSelector:SetActiveTab(activeTab)
	end)
end

-- Updates retained controls with fresh data; bursts coalesce into one query.
function refresh()
	if not open then
		return
	end
	if building then
		queued = true
		return
	end
	building = true
	task.spawn(function()
		local ReGui = ReGuiLoader.Get()
		repeat
			queued = false
			local parties = PartyClient.Query("Parties")
			local whitelist = PartyClient.Query("Whitelist")
			local settings = PartyClient.Query("Settings")
			if ReGui and open then
				build(ReGui, parties, whitelist, settings)
			end
		until not queued or not open
		building = false
	end)
end

function PartyWindow.Open(tab: string?)
	if tab then
		if window then
			pcall(function()
				window.WindowTabSelector:SetActiveTab(tab)
			end)
		end
		activeTab = tab
	end
	if open then
		return
	end
	open = true
	if window then window:SetVisible(true) end
	refresh()
end

function PartyWindow.Close()
	open = false
	hideWindow()
end

function PartyWindow.Toggle(tab: string?)
	if open then
		PartyWindow.Close()
	else
		PartyWindow.Open(tab)
	end
end

function PartyWindow.IsOpen(): boolean
	return open
end

PartyClient.Changed:Connect(function()
	refresh()
end)

return PartyWindow
