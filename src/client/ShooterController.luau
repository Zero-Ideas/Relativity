--!optimize 2
--[[
	ShooterController (client)
	Click to fire. Sends where the player is AIMING (a world point found via a
	camera ray through the cursor) to the server, which spawns the actual
	bullet via the Projectile system. Purely an input forwarder — no
	authority here. Where the shot actually SPAWNS from (a weapon's "Tip"
	Attachment if it has one, else the character's Head) is resolved entirely
	server-side (see Shooter.server.luau's resolveMuzzleOrigin) — the client
	never sends an origin at all, only the aimed-at point, so the server can
	converge the shot exactly where the player clicked regardless of which
	origin it ends up using.

	start()/stop() are called by any shooting weapon's ToolControllers/
	<Name>.luau Equip/Unequip (see _ShootingWeapon.luau) -- this only
	listens for input while one of those tools is actually equipped. The
	server enforces this independently for FireBullet/ReloadWeapon/
	StressTestFire (see Shooter.server.luau, which validates against the
	Weapons registry), so this is about not listening for input at all
	while no shooting tool is equipped, not about security. Every weapon's
	REAL numbers live server-side in its own Weapons/<Name>.luau module;
	tuning them means editing that file, not this panel. In Studio only,
	ShooterConfigGui's live-tunable overrides are also sent along (see
	Shooter.server.luau's applyStudioDebugOverrides) -- a live client never
	sends or has this read at all.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)
local ShooterConfigGui = require(script.Parent.ShooterConfigGui)

local ShooterController = {}

local player = Players.LocalPlayer
local COOLDOWN = 0.1 -- matches Shooter.server.luau's MIN_FIRE_INTERVAL floor; the server enforces its own copy regardless
local lastFire = 0
local debugRays = false -- matches the server default; toggle with B
local debugSync = false -- prints ProjSpawn/ProjSync/ProjHit + a ProjMove rate summary server-side; toggle with V
local inputConnection: RBXScriptConnection? = nil

local AIM_RANGE = 5000

local function fire()
	local character = player.Character
	local camera = workspace.CurrentCamera
	if not character or not camera then
		return
	end

	-- find the WORLD POINT under the cursor (camera ray -> first surface).
	local screenPos = UserInputService:GetMouseLocation()
	local camRay = camera:ViewportPointToRay(screenPos.X, screenPos.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true
	local hit = workspace:Raycast(camRay.Origin, camRay.Direction * AIM_RANGE, params)
	local targetPoint = hit and hit.Position or (camRay.Origin + camRay.Direction * AIM_RANGE)

	-- Every gameplay number (Model/Speed/Damage/etc.) AND the spawn origin
	-- itself come from the server (see Shooter.server.luau) -- this only
	-- ever sends the aimed-at world point, plus (Studio only) the debug
	-- panel's overrides, which a live server never even looks at.
	local payload = { TargetPoint = targetPoint }
	if RunService:IsStudio() then
		payload.Config = ShooterConfigGui.getConfig()
	end
	VisualOffload.Fire("FireBullet", payload)
end

local function reload()
	VisualOffload.Fire("ReloadWeapon", {})
end

-- Load-testing the projectile system means spawning many projectiles AT ONCE, not
-- firing many separate player shots -- Shooter.server.luau's MIN_FIRE_INTERVAL floor
-- (10/sec) exists to rate-limit real clicking and would silently drop almost all of a tight
-- client-side firing loop. This sends ONE request asking the server to spawn N
-- projectiles directly, bypassing that per-click gate entirely (see StressTestFire
-- in Shooter.server.luau). Press N to fire a stress-test batch.
local STRESS_TEST_COUNT = 1000

local function stressTest()
	VisualOffload.Fire("StressTestFire", { Count = STRESS_TEST_COUNT })
end

function ShooterController.start()
	if inputConnection then
		return
	end

	inputConnection = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return -- click was consumed by the GUI (e.g. the time slider)
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			local now = os.clock()
			if now - lastFire >= COOLDOWN then
				lastFire = now
				fire()
			end
		elseif input.KeyCode == Enum.KeyCode.B then
			-- toggle raycast hit-detection visualization (server owns the flag)
			debugRays = not debugRays
			VisualOffload.Fire("SetProjectileDebug", debugRays)
		elseif input.KeyCode == Enum.KeyCode.N then
			stressTest()
		elseif input.KeyCode == Enum.KeyCode.R then
			reload()
		elseif input.KeyCode == Enum.KeyCode.V then
			-- toggle ProjSpawn/ProjSync/ProjHit + ProjMove-rate server console logging
			debugSync = not debugSync
			VisualOffload.Fire("SetProjectileSyncDebug", debugSync)
		end
	end)
end

function ShooterController.stop()
	if inputConnection then
		inputConnection:Disconnect()
		inputConnection = nil
	end
end

return ShooterController
