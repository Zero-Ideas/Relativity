--!optimize 2
--[[
	ToolManager (client)
	Generalized tool-controller swapper: any tool that wants custom client
	behavior gets a ModuleScript in ToolControllers/ named EXACTLY like the
	Tool instance (e.g. "TimeBlaster" -> ToolControllers/TimeBlaster.luau).
	Whenever a tool with a matching controller becomes equipped, this calls
	that controller's Equip(tool, character); when it's unequipped (or a
	death/respawn cuts it off without a clean Unequipped), it calls
	Unequip(tool, character). This is the ONLY thing that knows tools exist --
	individual controllers (ShooterController, Viewmodel, etc.) know
	nothing about equip state; they're just started/stopped by their
	controller module. A tool with no matching module is ignored entirely --
	this only drives custom per-tool client behavior, not equipping itself,
	so plain vanilla tools work exactly as Roblox already handles them.

	Controller module contract (see ToolControllers/TimeBlaster.luau):
	  return {
	    Equip = function(tool: Tool, character: Model) ... end,
	    Unequip = function(tool: Tool, character: Model) ... end,
	  }

	Watches Player:GetDescendants()/DescendantAdded rather than just Backpack:
	Roblox replaces the Player's Backpack instance with a fresh one sometime
	after initial join/spawn (confirmed by tracing Player.ChildAdded/
	ChildRemoved in a real Play session), so a listener bound to the original
	Backpack instance silently stops seeing anything once it's swapped.
	DescendantAdded on the Player itself isn't tied to any one container's
	identity, so it keeps working across that swap (and across a tool moving
	between Backpack and Character on every equip/unequip).

	(Also note: Humanoid has no Equipped/Unequipped event -- only Tool does.)
]]

local Players = game:GetService("Players")

local ToolControllers = script.Parent:WaitForChild("ToolControllers")

local ToolManager = {}

local player = Players.LocalPlayer
local started = false
local watched: { [Tool]: boolean } = {}
local current: { tool: Tool, controller: any }? = nil

-- false is a valid cached "no controller for this name" result, distinct
-- from nil (not looked up yet) -- see getController.
local controllerCache: { [string]: any } = {}

local function getController(name: string): any?
	local cached = controllerCache[name]
	if cached ~= nil then
		if cached == false then
			return nil
		end
		return cached
	end

	local module = ToolControllers:FindFirstChild(name)
	if not module or not module:IsA("ModuleScript") then
		controllerCache[name] = false
		return nil
	end

	local ok, controller = pcall(require, module)
	if not ok then
		warn(`[ToolManager] failed to require controller "{name}": {controller}`)
		controllerCache[name] = false
		return nil
	end
	controllerCache[name] = controller
	return controller
end

local function onEquipped(tool: Tool)
	local controller = getController(tool.Name)
	if not controller then
		return
	end

	if current and current.tool ~= tool then
		-- defensive: Tool.Unequipped on the previous tool should already have
		-- cleared `current`, but never leave two controllers active at once
		local ok, err = pcall(current.controller.Unequip, current.tool, current.tool.Parent)
		if not ok then
			warn(`[ToolManager] "{current.tool.Name}".Unequip errored: {err}`)
		end
	end

	current = { tool = tool, controller = controller }
	local ok, err = pcall(controller.Equip, tool, tool.Parent)
	if not ok then
		warn(`[ToolManager] "{tool.Name}".Equip errored: {err}`)
	end
end

local function onUnequipped(tool: Tool)
	if not current or current.tool ~= tool then
		return
	end
	local controller = current.controller
	current = nil
	local ok, err = pcall(controller.Unequip, tool, tool.Parent)
	if not ok then
		warn(`[ToolManager] "{tool.Name}".Unequip errored: {err}`)
	end
end

local function watchTool(instance: Instance)
	if not instance:IsA("Tool") or watched[instance] then
		return
	end
	watched[instance] = true

	-- the tool may already be sitting equipped in the character by the time
	-- we discover it (e.g. a respawn that re-equips instantly)
	local parent = instance.Parent
	if parent and parent:IsA("Model") and parent:FindFirstChildOfClass("Humanoid") then
		onEquipped(instance)
	end

	instance.Equipped:Connect(function()
		onEquipped(instance)
	end)
	instance.Unequipped:Connect(function()
		onUnequipped(instance)
	end)
end

function ToolManager.start()
	if started then
		return
	end
	started = true

	for _, descendant in player:GetDescendants() do
		watchTool(descendant)
	end
	player.DescendantAdded:Connect(watchTool)

	-- defensive: make sure a controller never stays "active" across a death
	-- that doesn't cleanly fire Tool.Unequipped
	player.CharacterRemoving:Connect(function()
		if current then
			onUnequipped(current.tool)
		end
	end)
end

return ToolManager
