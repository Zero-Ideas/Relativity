--!optimize 2
--[[
	ShooterController (client)
	Click to fire. Sends the shot origin (character head) and aim direction (a
	camera ray through the cursor) to the server, which spawns the actual bullet
	via the Projectile system. Purely an input forwarder — no authority here.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)
local ShooterConfigGui = require(script.Parent.ShooterConfigGui)

local ShooterController = {}

local player = Players.LocalPlayer
local started = false
local COOLDOWN = 0
local lastFire = 0
local debugRays = false -- matches the server default; toggle with B

local AIM_RANGE = 5000

local function fire()
	local character = player.Character
	local head = character and (character:FindFirstChild("Head") or character.PrimaryPart)
	local camera = workspace.CurrentCamera
	if not head or not camera then
		return
	end

	-- 1) find the WORLD POINT under the cursor (camera ray -> first surface).
	local screenPos = UserInputService:GetMouseLocation()
	local camRay = camera:ViewportPointToRay(screenPos.X, screenPos.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true
	local hit = workspace:Raycast(camRay.Origin, camRay.Direction * AIM_RANGE, params)
	local targetPoint = hit and hit.Position or (camRay.Origin + camRay.Direction * AIM_RANGE)

	-- 2) aim the muzzle AT that point, so the bullet converges where you clicked
	--    (fixes the camera/muzzle parallax that made shots drift off-target).
	local origin = head.Position
	VisualOffload.Fire("FireBullet", {
		Origin = origin,
		Direction = (targetPoint - origin).Unit,
		Config = ShooterConfigGui.getConfig(),
	})
end

-- Load-testing the projectile system means spawning many projectiles AT ONCE, not
-- firing many separate player shots -- Shooter.server.luau's FIRE_COOLDOWN (10/sec)
-- exists to rate-limit real clicking and would silently drop almost all of a tight
-- client-side firing loop. This sends ONE request asking the server to spawn N
-- projectiles directly, bypassing that per-click gate entirely (see StressTestFire
-- in Shooter.server.luau). Press N to fire a stress-test batch.
local STRESS_TEST_COUNT = 1000

local function stressTest()
	VisualOffload.Fire("StressTestFire", { Count = STRESS_TEST_COUNT })
end

function ShooterController.start()
	if started then
		return
	end
	started = true

	UserInputService.InputBegan:Connect(function(input, processed)
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
		end
	end)
end

return ShooterController
