--!strict
-- Creates a small Actor pool, then each clone performs read-only math in a
-- parallel message callback. Results are written to per-worker SharedTables.

local SharedTableRegistry = game:GetService("SharedTableRegistry")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local actor = script:GetActor()
if not actor then
	local folder = script.Parent:FindFirstChild("ProjectileActors")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ProjectileActors"
		folder.Parent = script.Parent
	end
	for index = 1, 4 do
		local inputKey = `RelativityProjectileInput{index}`
		local outputKey = `RelativityProjectileOutput{index}`
		if not SharedTableRegistry:GetSharedTable(inputKey) then
			SharedTableRegistry:SetSharedTable(inputKey, SharedTable.new())
		end
		if not SharedTableRegistry:GetSharedTable(outputKey) then
			SharedTableRegistry:SetSharedTable(outputKey, SharedTable.new())
		end
	end
	if #folder:GetChildren() == 0 then
		for index = 1, 4 do
			local workerActor = Instance.new("Actor")
			workerActor.Name = `ProjectileWorker{index}`
			local workerScript = script:Clone()
			workerScript.Name = "Worker"
			workerScript.Parent = workerActor
			workerActor.Parent = folder
		end
	end
	return
end

local workerId = assert(tonumber(string.match(actor.Name, "(%d+)$")), "Projectile worker requires a numeric suffix")
local ProjectileMotion = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ProjectileMotion"))
local input = SharedTableRegistry:GetSharedTable(`RelativityProjectileInput{workerId}`)
local output = SharedTableRegistry:GetSharedTable(`RelativityProjectileOutput{workerId}`)

actor:BindToMessageParallel("ComputeProjectileHints", function(generation: number, count: number)
	for index = 1, count do
		local inputBase = (index - 1) * 5
		local outputBase = (index - 1) * 4
		local id = input[inputBase + 1]
		local velocity = input[inputBase + 2]
		local acceleration = input[inputBase + 3]
		local direction = input[inputBase + 4]
		local gravity = input[inputBase + 5]
		if direction == false then direction = nil end
		local accelerationVector = ProjectileMotion.GetAcceleration(velocity, acceleration, direction, gravity)
		output[outputBase + 1] = id
		output[outputBase + 2] = velocity
		output[outputBase + 3] = accelerationVector
		output[outputBase + 4] = ProjectileMotion.GetCurvatureStepDt(velocity, accelerationVector, 0.35)
	end
	output.done = generation
end)
