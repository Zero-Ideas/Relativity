--!optimize 2
--[[
	Admin tab (listed players only -- DebugPanel hides it from everyone else,
	and server/DebugAccess re-checks every change):
	  * your panel rank (DebugAccess.Ranks: you can only use entity actions on
	    players you outrank; the master on no one but themselves);
	  * open the debug panel to every player, or back to the allowlist;
	  * pick which tabs non-listed players get while it's open (Stats and
	    Dummies by default). Listed players always see every tab;
	  * player access: pick any player you outrank and untick tabs to take
	    them from that player alone (Defaults and Admin included) -- the
	    master's tabs can't be touched. Stored on their Player as the
	    "DebugDeniedTabs" attribute, which these boxes follow.
	State lives on the server; it reaches every client as ReplicatedStorage's
	"DebugPublic" and "DebugPublicTabs" attributes, which the checkboxes follow.

	ReGui checkboxes fire their callback on every SetTicked, including the
	ones made here to follow the server, so a callback only sends a change
	when it differs from the server's state (no echo loops).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)

-- Mirrors server/DebugAccess.Tabs and RankNames.
local TABS = { "Tools", "Time", "Stats", "Entities", "Chunks", "Dummies", "VFX" }
local ALL_TABS = table.clone(TABS) -- every tab one player can be denied (DebugAccess.AllTabs)
table.insert(ALL_TABS, "Defaults")
table.insert(ALL_TABS, "Admin")
local RANK_NAMES = { [0] = "Player", [1] = "Admin", [2] = "Senior admin", [3] = "Master" }

local function isPublic(): boolean
	return ReplicatedStorage:GetAttribute("DebugPublic") == true
end

local function publicTabs(): { [string]: boolean }
	local set = {}
	local raw = ReplicatedStorage:GetAttribute("DebugPublicTabs")
	if typeof(raw) == "string" then
		for name in string.gmatch(raw, "[^,]+") do
			set[name] = true
		end
	end
	return set
end

return function(window)
	local tab = window:CreateTab({ Name = "Admin" })
	local localPlayer = Players.LocalPlayer

	local rankLabel = tab:Label({ Text = "" })
	local function refreshRank()
		local rank = localPlayer:GetAttribute("DebugRank")
		rankLabel.Text = "Your rank: " .. (RANK_NAMES[if typeof(rank) == "number" then rank else 0] or "?")
	end
	localPlayer:GetAttributeChangedSignal("DebugRank"):Connect(refreshRank)
	refreshRank()

	local publicBox = tab:Checkbox({
		Label = "Open the panel to every player",
		Value = isPublic(),
		Callback = function(_, value: boolean)
			if value ~= isPublic() then
				VisualOffload.Fire("DebugSetPublic", value)
			end
		end,
	})

	tab:Separator({ Text = "Tabs other players can see" })
	local boxes: { [string]: any } = {}
	local initial = publicTabs()
	for _, name in TABS do
		boxes[name] = tab:Checkbox({
			Label = name,
			Value = initial[name] == true,
			Callback = function(_, value: boolean)
				if value ~= (publicTabs()[name] == true) then
					VisualOffload.Fire("DebugSetTabPublic", { Tab = name, Enabled = value })
				end
			end,
		})
	end
	local note = tab:Label({ Text = "" })

	-- follow the server (another admin's change, or a refused one)
	local function refresh()
		if publicBox.Value ~= isPublic() then
			publicBox:SetTicked(isPublic())
		end
		local set = publicTabs()
		for name, box in boxes do
			local value = set[name] == true
			if box.Value ~= value then
				box:SetTicked(value)
			end
		end
		note.Text = if isPublic()
			then "Other players see the ticked tabs now."
			else "Takes effect once the panel is open to every player."
	end
	ReplicatedStorage:GetAttributeChangedSignal("DebugPublic"):Connect(refresh)
	ReplicatedStorage:GetAttributeChangedSignal("DebugPublicTabs"):Connect(refresh)
	refresh()

	----------------------------------------------------------------------------
	-- Player access: take tabs from one player you outrank
	----------------------------------------------------------------------------
	tab:Separator({ Text = "Player access (ticked = allowed)" })

	local function rankOf(player: Player): number
		local rank = player:GetAttribute("DebugRank")
		return if typeof(rank) == "number" then rank else 0
	end
	local function deniedOf(player: Player?): { [string]: boolean }
		local set = {}
		local raw = player and player:GetAttribute("DebugDeniedTabs")
		if typeof(raw) == "string" then
			for name in string.gmatch(raw, "[^,]+") do
				set[name] = true
			end
		end
		return set
	end

	local selected: Player? = nil
	local selectedWatch: RBXScriptConnection? = nil
	local byLabel: { [string]: Player } = {}
	local labels: { string } = {}
	local playerBoxes: { [string]: any } = {}
	local refreshPlayer -- forward-declared: the picker calls it

	local picker = tab:Combo({
		Label = "Player",
		Placeholder = "Select a player",
		GetItems = function()
			-- everyone you outrank, rebuilt each time the list opens
			table.clear(byLabel)
			table.clear(labels)
			local mine = rankOf(localPlayer)
			for _, player in Players:GetPlayers() do
				if player ~= localPlayer and rankOf(player) < mine then
					local label = string.format("%s (%s)", player.Name, RANK_NAMES[rankOf(player)] or "?")
					byLabel[label] = player
					table.insert(labels, label)
				end
			end
			table.sort(labels)
			return labels
		end,
		Callback = function(_, value)
			local player = byLabel[value]
			if not player then
				return
			end
			selected = player
			if selectedWatch then
				selectedWatch:Disconnect()
			end
			selectedWatch = player:GetAttributeChangedSignal("DebugDeniedTabs"):Connect(function()
				refreshPlayer()
			end)
			refreshPlayer()
		end,
	})
	for _, name in ALL_TABS do
		playerBoxes[name] = tab:Checkbox({
			Label = name,
			Value = true,
			Callback = function(_, value: boolean)
				local target = selected
				if target and target.Parent and value == (deniedOf(target)[name] == true) then
					VisualOffload.Fire("DebugSetPlayerTab", { Player = target, Tab = name, Allowed = value })
				end
			end,
		})
	end
	local accessNote = tab:Label({ Text = "" })

	local function clearSelection()
		selected = nil
		if selectedWatch then
			selectedWatch:Disconnect()
			selectedWatch = nil
		end
		picker:SetValueText("Select a player")
	end

	function refreshPlayer()
		if selected and not selected.Parent then
			clearSelection()
		end
		local target = selected
		local taken = deniedOf(target)
		for name, box in playerBoxes do
			local value = not taken[name]
			if box.Value ~= value then
				box:SetTicked(value)
			end
			box:SetDisabled(target == nil)
		end
		accessNote.Text = if target
			then "Unticked tabs are hidden from " .. target.Name .. " and blocked on the server."
			else "Pick a player you outrank (the master can't be restricted)."
	end
	Players.PlayerRemoving:Connect(function(player)
		if player == selected then
			clearSelection() -- still parented while PlayerRemoving fires
			refreshPlayer()
		end
	end)
	refreshPlayer()
	return {}
end
