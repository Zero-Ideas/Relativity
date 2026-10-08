--!strict
--[[
	Loads and initialises ReGui once for every client UI that uses it
	(DebugPanel, Notifications). Get() yields until it's ready and returns
	nil if its prefabs never replicate.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PREFABS_TIMEOUT = 30

local Loader = {}
local ready: any = nil
local failed = false
local loading = false
local waiting: { thread } = {}

local function load(): any?
	local localPlayer = Players.LocalPlayer
	-- ReGui only waits 2s for its prefabs, but this ~400-instance ScreenGui
	-- can take longer than that to replicate, so wait for it here instead.
	local module = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReGui")
	local prefabs = module:WaitForChild("ReGui-Prefabs", PREFABS_TIMEOUT)
	if not prefabs then
		warn("[ReGuiLoader] ReGui-Prefabs never replicated")
		return nil
	end
	local ReGui = require(module) :: any
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
	return ReGui
end

function Loader.Get(): any?
	if ready or failed then
		return ready
	end
	if loading then
		table.insert(waiting, coroutine.running())
		return coroutine.yield()
	end
	loading = true
	local ok, result = pcall(load)
	if ok and result then
		ready = result
	else
		failed = true
		if not ok then
			warn("[ReGuiLoader] " .. tostring(result))
		end
	end
	for _, thread in waiting do
		task.spawn(thread, ready)
	end
	table.clear(waiting)
	return ready
end

return Loader
