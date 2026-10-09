--!strict
--[[
	The server browser window (ReGui), opened from the topbar's server-region
	bubble. Lists every live server (server/ServerBrowser) grouped by region:
	each region has "Join best in region" (its busiest server with room) and
	each server its own Join. "Hide full servers" filters the list. It
	refreshes itself every REFRESH seconds while open.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ReGuiLoader = require(script.Parent.ReGuiLoader)
local ReGuiLive = require(script.Parent.ReGuiLive)

local remote = ReplicatedStorage:WaitForChild("ServerBrowser") :: RemoteFunction

local REFRESH = 10

local ServerBrowser = {}
local open = false
local window: any = nil
local section: any = nil
local geometry: { position: UDim2, size: UDim2 }? = nil
local hideFull = true
local message = ""
local building = false
local queued = false
local generation = 0 -- (stops an old auto-refresh loop)

local function call(action: string, a: any?): any
	local ok, result = pcall(remote.InvokeServer, remote, action, a)
	return if ok then result else nil
end

local function hideWindow()
	if window then
		local frame = window.WindowFrame
		geometry = { position = frame.Position, size = frame.Size }
		window:SetVisible(false)
	end
end

local refresh: () -> ()

local function join(action: string, value: string)
	task.spawn(function()
		message = "Joining…"
		refresh()
		local result = call(action, value)
		message = if result and result.Ok then "Teleporting…" else (result and result.Message) or "Couldn't join."
		refresh()
	end)
end

local function isFull(server: any): boolean
	return server.MaxPlayers > 0 and server.Players >= server.MaxPlayers
end

local function build(ReGui: any, data: any)
	if not window then
		local created: any
		created = ReGui:Window({
			Title = "Servers",
			Size = if geometry then geometry.size else UDim2.fromOffset(440, 420),
			NoCollapse = true,
			NoWindowRegistor = true,
			CloseCallback = function()
				hideWindow()
				open = false
				return false
			end,
		})
		window = created
		created.WindowFrame.Position = if geometry then geometry.position else UDim2.fromOffset(16, 70)
		section = ReGuiLive.Section(created)
	end
	section:Render(nil, function(created)

		local controls = created:Row()
		controls:Checkbox({
			Label = "Hide full servers",
			Value = hideFull,
			-- (ReGui runs this on creation too: only act on a real change)
			Callback = function(_, value: boolean)
				if value ~= hideFull then
					hideFull = value
					refresh()
				end
			end,
		})
		controls:SmallButton({ Text = "Refresh", Callback = function() refresh() end })
		if message ~= "" then
			created:Label({ Text = message })
		end
		if data and data.Studio then
			created:Label({ Text = "Studio: this session isn't listed, and teleports are off." })
		end

		local servers = if data then data.Servers else nil
		if not servers then
			created:Label({ Text = "Couldn't load the server list." })
			return
		end
		-- group by region (the server sorts by region, then busiest first)
		local regions: { string } = {}
		local byRegion: { [string]: { any } } = {}
		for _, server in servers do
			local list = byRegion[server.Region]
			if not list then
				list = {}
				byRegion[server.Region] = list
				table.insert(regions, server.Region)
			end
			table.insert(list, server)
		end
		if #regions == 0 then
			created:Label({ Text = "No servers listed yet." })
		end
		for _, regionName in regions do
			local list = byRegion[regionName]
			local created = created:Group({ LiveKey = "region:" .. regionName })
			local playerCount, openCount = 0, 0
			for _, server in list do
				playerCount += server.Players
				if not isFull(server) and not server.Current then
					openCount += 1
				end
			end
			created:Separator({ Text = `{regionName}: {#list} server{if #list == 1 then "" else "s"}, {playerCount} player{if playerCount == 1 then "" else "s"}` })
			if openCount > 0 then
				created:SmallButton({ Text = "Join best in region", Callback = function() join("JoinRegion", regionName) end })
			end
			for _, server in list do
				local full = isFull(server)
				if hideFull and full and not server.Current then
					continue
				end
				local row = created:Row({ LiveKey = server.JobId })
				row:Label({
					Text = `{server.Players}/{server.MaxPlayers}  {string.sub(server.JobId, 1, 8)}`
						.. (if server.Current then "  (you're here)" elseif full then "  (full)" else ""),
				})
				if not server.Current and not full then
					row:SmallButton({ Text = "Join", Callback = function() join("Join", server.JobId) end })
				end
			end
		end
	end)
end

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
			local data = call("List")
			if ReGui and open then
				build(ReGui, data)
			end
		until not queued or not open
		building = false
	end)
end

function ServerBrowser.Open()
	if open then
		return
	end
	open = true
	if window then window:SetVisible(true) end
	message = ""
	generation += 1
	local mine = generation
	refresh()
	task.spawn(function()
		while open and generation == mine do
			task.wait(REFRESH)
			if open and generation == mine then
				refresh()
			end
		end
	end)
end

function ServerBrowser.Close()
	open = false
	hideWindow()
end

function ServerBrowser.Toggle()
	if open then
		ServerBrowser.Close()
	else
		ServerBrowser.Open()
	end
end


function ServerBrowser.IsOpen(): boolean
	return open
end

return ServerBrowser
