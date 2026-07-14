--!optimize 2
--[[
	ShooterTool.luau
	Shared registry of every Tool name allowed to fire through the Shooter/
	Projectile pipeline (see Shooter.server.luau), and which asset under
	ReplicatedStorage.Effects each one's bullets render as. The server looks
	the Model up from HERE, keyed by the validated equipped tool's Name --
	NEVER from client-sent config (see Shooter.server.luau's module doc
	comment on why a client-supplied Model reference would be exploitable).
	Each Tool itself is a real object hand-placed in StarterPack (built once
	via Studio, not instantiated by any runtime script) so Roblox's own
	StarterPack -> Backpack copy grants it to every player.

	The client doesn't need this module for equip dispatch: ToolManager.luau
	matches an equipped tool to its controller purely by
	Tool.Name == a ModuleScript's Name under ToolControllers/ (see
	ToolControllers/TimeBlaster.luau and Railgun.luau). Adding a new
	SHOOTING weapon means: drop in a Tool + ToolControllers/<Name>.luau that
	starts ShooterController (mirror TimeBlaster.luau), AND add an entry
	here so the server accepts shots from it and knows which effect to spawn.
]]

return {
	Weapons = {
		TimeBlaster = "Model",
		Railgun = "RailgunRod",
	},
}
