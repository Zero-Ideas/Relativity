--!optimize 2
--[[
	DebugPanel  (client, Studio only)
	ReGui window (toggle with F2) with seven tabs:
	  Tools    -- give any Tool the server can find (see DebugService.server.luau)
	              or clear your backpack.
	  Time     -- your personal time ratio; drives TimeControlGui headless, so the
	              apply/throttle/server-reconcile logic stays in one place.
	  Stats    -- client and server stats, refreshed every STATS_INTERVAL.
	  Entities -- pick any Entity: highlight + viewport preview, live HP /
	              effects / tools, set HP, apply status effects, give tools.
	  Chunks   -- minimap of chunks / time zones / players (drag to pan, click
	              to select); per-chunk, radius and global time scale, chunk
	              load state.
	  Dummies  -- spawn test dummies (model, HP) at the cursor or in front of
	              you; pick one of yours from a dropdown to move (to the cursor
	              or to you), delete, or clear all (replaces the old
	              DummySpawner tool).
	  VFX      -- local ExplosionVFX preview: power, radius, tint; spawn in front,
	              at the cursor, or a weakest-to-strongest sweep.

	One module per tab in Tabs/ (see TAB_ORDER); shared helpers in Util,
	cross-tab state in State.

	Cost when idle: one 0.5s visibility check. Stats sampling, the server's
	stats/entity streams, the highlight and the viewport refresh only run while
	their tab is actually showing; labels are only written when their text
	changes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(script.Util)

local DebugPanel = {}

local TOGGLE_KEY = Enum.KeyCode.F2
local STATS_INTERVAL = Util.STATS_INTERVAL
local TAB_ORDER = { "Tools", "Time", "Stats", "Entities", "Chunks", "Dummies", "VFX" }

local started = false
local localPlayer = Players.LocalPlayer

local function tabShowing(window, name: string): boolean
	if not window.Visible or window.Collapsed then
		return false
	end
	for _, entry in window.WindowTabSelector.Tabs do
		if entry.Name == name then
			return entry.IsSelected == true
		end
	end
	return false
end

local PREFABS_TIMEOUT = 30

local function build()
	-- ReGui only waits 2s for its prefabs, but this ~400-instance ScreenGui
	-- can take longer than that to replicate, so wait for it here instead.
	local module = Shared:WaitForChild("ReGui")
	local prefabs = module:WaitForChild("ReGui-Prefabs", PREFABS_TIMEOUT)
	if not prefabs then
		warn("[DebugPanel] ReGui-Prefabs never replicated; panel disabled")
		return
	end
	local ReGui = require(module)
	-- ReGui probes gethui()/CoreGui before PlayerGui (executor leftovers); the
	-- CoreGui probe passes in a playtest but the real parent assignment then
	-- fails silently, leaving the container parentless, so pin it.
	ReGui:Init({
		Prefabs = prefabs,
		ContainerParent = localPlayer:WaitForChild("PlayerGui"),
	})
	-- ReGui's container is a Folder holding two ScreenGuis, and a respawn
	-- clears everything in PlayerGui except ResetOnSpawn=false ScreenGuis --
	-- folder included. ReGui only ever indexes Container.Windows/.Overlays,
	-- so lift both ScreenGuis out and point Container at them directly.
	local folder = ReGui.Container
	local playerGui = localPlayer.PlayerGui
	local lifted = {}
	for _, name in { "Windows", "Overlays" } do
		local gui = folder:FindFirstChild(name) :: ScreenGui
		gui.ResetOnSpawn = false
		gui.Name = "ReGui" .. name
		gui.Parent = playerGui
		lifted[name] = gui
	end
	ReGui.Container = lifted
	folder:Destroy()

	local window = ReGui:TabsWindow({
		Title = "Debug  [F2]",
		Size = UDim2.fromOffset(360, 520),
		Position = UDim2.fromOffset(16, 160),
		-- the close button hides instead of destroying, so F2 can reopen it
		CloseCallback = function(self)
		self:SetVisible(false)
		return false
		end,
	})

	-- Tab modules return { Active: (boolean) -> ()?, Tick: () -> ()? }. Active
	-- fires when a tab starts/stops showing; Tick runs every STATS_INTERVAL
	-- only while it shows.
	local tabs = {}
	for _, name in TAB_ORDER do
		local tab = require(script.Tabs:FindFirstChild(name) :: ModuleScript)(window, ReGui)
		table.insert(tabs, { Name = name, Active = tab.Active, Tick = tab.Tick, Showing = false })
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == TOGGLE_KEY and not processed then
		window:SetVisible(not window.Visible)
		end
	end)

	local function tick()
		for _, tab in tabs do
			local showing = tabShowing(window, tab.Name)
			if showing ~= tab.Showing then
				tab.Showing = showing
				if tab.Active then
					tab.Active(showing)
				end
			end
			if showing and tab.Tick then
				tab.Tick()
			end
		end
	end
	task.spawn(function()
		local lastError = nil
		while true do
			task.wait(STATS_INTERVAL)
			-- One tab's bug must not kill every other tab's updates; report each
			-- distinct error once instead of every tick.
			local ok, err = xpcall(tick, debug.traceback)
			if not ok and err ~= lastError then
				lastError = err
				warn("[DebugPanel] tick failed:", err)
			end
		end
	end)
end

function DebugPanel.start()
	if started or not RunService:IsStudio() then
		return
	end
	started = true
	-- never block (or break) the rest of client startup
	task.spawn(function()
		local ok, err = xpcall(build, debug.traceback)
		if not ok then
			warn("[DebugPanel] failed to build:", err)
		end
	end)
end

return DebugPanel
