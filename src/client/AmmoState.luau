--!optimize 2
--[[
	AmmoState (client)
	Caches the latest ammo/reload state the server pushes over the "AmmoSync"
	VisualOffload channel (see Shooter.server.luau's pushAmmoSync -- fired on
	equip, every shot, and every reload transition) and re-exposes it as a
	Signal so a future HUD can just connect and render, without needing to
	know anything about VisualOffload/remotes itself. Purely a cache -- no
	input, no authority; a weapon with no Magazine (e.g. TimeBlaster) simply
	never gets an entry here.

	API:
	 AmmoState.Get(toolName: string) -> { Magazine: number, Reserve: number, Reloading: boolean }?
	 AmmoState.Changed:Connect(fn(toolName: string, state)) -- fires on every sync
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)
local Signal = require(Shared.Signal)

local AmmoState = {}

AmmoState.Changed = Signal.new()

local state: { [string]: { Magazine: number, Reserve: number, Reloading: boolean } } = {}

function AmmoState.Get(toolName: string)
	local entry = state[toolName]
	if not entry then
		return nil
	end
	return table.clone(entry)
end

VisualOffload.On("AmmoSync", function(data)
	if typeof(data) ~= "table" or typeof(data.ToolName) ~= "string" then
		return
	end
	local entry = { Magazine = data.Magazine, Reserve = data.Reserve, Reloading = data.Reloading == true }
	state[data.ToolName] = entry
	AmmoState.Changed:Fire(data.ToolName, table.clone(entry))
end)

return AmmoState
