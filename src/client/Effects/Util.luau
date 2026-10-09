--!strict
--[[
	Effects/Util.luau
	Bits every effect module shares: the workspace folder effect parts live in,
	the local time scale at a point, the camera's distance, and a frame built
	around an up vector.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared.ChunkManager)
local Heartbeat = require(Shared.Heartbeat)

local Util = {}

local folder: Folder? = nil
-- Parts (debris, marks, lights) go here. Attachments go under Terrain, where
-- their CFrame is world space and no carrier part is needed.
function Util.Folder(): Folder
	if not folder or not folder.Parent then
		local created = Instance.new("Folder")
		created.Name = "Effects"
		created.Parent = workspace
		folder = created
	end
	return folder :: Folder
end

-- Global x chunk time scale at a point (0 = frozen).
function Util.TimeScaleAt(position: Vector3): number
	return Heartbeat.GetGlobalTimeScale() * ChunkManager.GetTimeScaleAt(position)
end

function Util.CameraPosition(): Vector3
	local camera = workspace.CurrentCamera
	return if camera then camera.CFrame.Position else Vector3.zero
end

-- Distance to the camera and whether the point is roughly in front of it.
function Util.View(position: Vector3): (number, boolean)
	local camera = workspace.CurrentCamera
	if not camera then
		return 0, true
	end
	local offset = position - camera.CFrame.Position
	local distance = offset.Magnitude
	return distance, distance < 30 or offset:Dot(camera.CFrame.LookVector) > -0.2 * distance
end

function Util.Unit(vector: Vector3?, fallback: Vector3): Vector3
	if vector and vector.Magnitude > 1e-4 then
		return vector.Unit
	end
	return fallback
end

-- A frame at `position` whose +Y is `up` (ParticleEmitters attached to an
-- Attachment emit along its +Y).
function Util.Upright(position: Vector3, up: Vector3): CFrame
	local right = up:Cross(if math.abs(up.Z) < 0.9 then Vector3.zAxis else Vector3.xAxis).Unit
	return CFrame.fromMatrix(position, right, up)
end

-- Everything an effect ray should never stop on: effect folders and the
-- players' own characters.
local ignoreCache: { Instance } = {}
local ignoreBuilt = 0
function Util.IgnoreList(): { Instance }
	local now = os.clock()
	if now - ignoreBuilt > 1 then
		ignoreBuilt = now
		table.clear(ignoreCache)
		table.insert(ignoreCache, Util.Folder())
		local explosions = workspace:FindFirstChild("ExplosionVFX")
		if explosions then
			table.insert(ignoreCache, explosions)
		end
		local player = Players.LocalPlayer
		if player and player.Character then
			table.insert(ignoreCache, player.Character)
		end
	end
	return ignoreCache
end

return Util
