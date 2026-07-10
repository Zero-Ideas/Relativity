--!optimize 2
--[[
	ShooterTool.luau
	Shared identity for the TimeBlaster tool, used server-side by
	Shooter.server.luau to check the same Name is equipped on the firing
	player's character before spawning a bullet. The Tool itself is a real
	object hand-placed in StarterPack (built once via Studio, not instantiated
	by any runtime script) so Roblox's own StarterPack -> Backpack copy grants
	it to every player.

	The client doesn't need this module: ToolManager.luau matches an equipped
	tool to its controller purely by Tool.Name == a ModuleScript's Name under
	ToolControllers/ (see ToolControllers/TimeBlaster.luau, whose own Name IS
	"TimeBlaster") -- adding a new tool never requires touching this file or
	ToolManager.luau, just dropping in a new controller module named to match.
]]

return {
	Name = "TimeBlaster",
}
