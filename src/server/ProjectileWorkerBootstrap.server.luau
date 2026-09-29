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
		local homingInputKey = `RelativityProjectileHomingInput{index}`
		local homingOutputKey = `RelativityProjectileHomingOutput{index}`
		if not SharedTableRegistry:GetSharedTable(inputKey) then
			SharedTableRegistry:SetSharedTable(inputKey, SharedTable.new())
		end
		if not SharedTableRegistry:GetSharedTable(outputKey) then
			SharedTableRegistry:SetSharedTable(outputKey, SharedTable.new())
		end
		if not SharedTableRegistry:GetSharedTable(homingInputKey) then
			SharedTableRegistry:SetSharedTable(homingInputKey, SharedTable.new())
		end
		if not SharedTableRegistry:GetSharedTable(homingOutputKey) then
			SharedTableRegistry:SetSharedTable(homingOutputKey, SharedTable.new())
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
local homingInput = SharedTableRegistry:GetSharedTable(`RelativityProjectileHomingInput{workerId}`)
local homingOutput = SharedTableRegistry:GetSharedTable(`RelativityProjectileHomingOutput{workerId}`)

actor:BindToMessageParallel("ComputeProjectileHints", function(generation: number, count: number, homingCount: number)
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
	local cursor = 1
	for jobIndex = 1, homingCount do
		local id = homingInput[cursor]
		local origin = homingInput[cursor + 1]
		local radius = homingInput[cursor + 2]
		local candidateCount = homingInput[cursor + 3]
		cursor += 4
		local bestIndex = 0
		local bestDistanceSq = radius * radius
		for candidateIndex = 1, candidateCount do
			local position = homingInput[cursor]
			cursor += 1
			local offset = position - origin
			local distanceSq = offset:Dot(offset)
			if distanceSq <= bestDistanceSq then
				bestDistanceSq = distanceSq
				bestIndex = candidateIndex
			end
		end
		local outputBase = (jobIndex - 1) * 2
		homingOutput[outputBase + 1] = id
		homingOutput[outputBase + 2] = bestIndex
	end
	homingOutput.done = generation
	output.done = generation
end)
