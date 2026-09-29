--!strict
--[[
	Parallel, read-only projectile math coordinator.

	Actors compute acceleration/curvature hints and bounded homing target scores
	from immutable snapshots.
	This module alone consumes their SharedTable results and publishes hints to
	the authoritative projectile loop. Workers never mutate projectile objects,
	active arrays, entities, signals, Instances, or replication state.
]]

local SharedTableRegistry = game:GetService("SharedTableRegistry")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local Entity = require(Shared:WaitForChild("Entity"))

local ProjectileParallel = {}

local MIN_PARALLEL_PROJECTILES = 128
local HINT_MAX_AGE_FRAMES = 120
local HOMING_HINT_MAX_AGE_FRAMES = 4

type Worker = {
	actor: Actor,
	input: SharedTable,
	output: SharedTable,
	homingInput: SharedTable,
	homingOutput: SharedTable,
	generation: number,
	pending: any?,
}

local workers: { Worker } = {}
local knownActors: { [Actor]: boolean } = {}
local hints: { [number]: any } = {}
local homingHints: { [number]: any } = {}
local frame = 0
local parallelEnabled = false
local stats = {
	BatchesDispatched = 0,
	ItemsDispatched = 0,
	BatchesCompleted = 0,
	ItemsCompleted = 0,
	BusyWorkers = 0,
	HintHits = 0,
	HintMisses = 0,
	HomingJobsDispatched = 0,
	HomingCandidatesTested = 0,
	HomingHintHits = 0,
	HomingHintMisses = 0,
}

local function refreshWorkers()
	local folder = script.Parent:FindFirstChild("ProjectileActors")
	if not folder then return end
	for _, child in folder:GetChildren() do
		if child:IsA("Actor") and not knownActors[child] then
			local id = tonumber(string.match(child.Name, "(%d+)$"))
			if id then
				knownActors[child] = true
				table.insert(workers, {
					actor = child,
					input = SharedTableRegistry:GetSharedTable(`RelativityProjectileInput{id}`),
					output = SharedTableRegistry:GetSharedTable(`RelativityProjectileOutput{id}`),
					homingInput = SharedTableRegistry:GetSharedTable(`RelativityProjectileHomingInput{id}`),
					homingOutput = SharedTableRegistry:GetSharedTable(`RelativityProjectileHomingOutput{id}`),
					generation = 0,
					pending = nil,
				})
			end
		end
	end
	table.sort(workers, function(a, b) return a.actor.Name < b.actor.Name end)
end

function ProjectileParallel.Collect()
	refreshWorkers()
	for _, worker in workers do
		local pending = worker.pending
		if pending and worker.output.done == pending.generation then
			for index, snapshot in pending.snapshots do
				local base = (index - 1) * 4
				local id = worker.output[base + 1]
				if id == snapshot.Id then
					hints[id] = {
						Velocity = worker.output[base + 2],
						AccelerationVector = worker.output[base + 3],
						CurvatureDt = worker.output[base + 4],
						Acceleration = snapshot.Acceleration,
						AccelerationDirection = snapshot.AccelerationDirection,
						Gravity = snapshot.Gravity,
						Frame = pending.frame,
					}
				end
			end
			if worker.homingOutput.done == pending.generation then
				for index, job in pending.homingJobs do
					local base = (index - 1) * 2
					if worker.homingOutput[base + 1] == job.Id then
						local bestIndex = worker.homingOutput[base + 2]
						homingHints[job.Id] = {
							Target = if bestIndex and bestIndex > 0 then job.Candidates[bestIndex] else false,
							Origin = job.Origin,
							Radius = job.Radius,
							Frame = pending.frame,
						}
					end
				end
			end
			stats.BatchesCompleted += 1
			stats.ItemsCompleted += #pending.snapshots
			worker.pending = nil
		end
	end
end

local function homingEligible(projectile: any, homing: any, entity: any): boolean
	if entity == projectile.Source or entity.IsDestroyed then return false end
	if projectile.Filter and not projectile.Filter(entity) then return false end
	if homing.TargetTags then
		for _, tag in homing.TargetTags do if entity:HasTag(tag) then return true end end
		return false
	elseif homing.TargetTag then
		return entity:HasTag(homing.TargetTag)
	end
	return true
end

local function buildHomingJob(projectile: any)
	local homing = projectile.Homing
	if not homing or not (homing.AcquireRadius or homing.TargetTag or homing.TargetTags) then return nil end
	local target = projectile.HomingTarget
	local targetGone = target == nil
	if typeof(target) == "Instance" then
		targetGone = target.Parent == nil
	elseif typeof(target) == "table" then
		targetGone = target.IsDestroyed == true
	end
	local dueRetarget = target ~= nil and not homing.Permalock and homing.Retarget and projectile.ReacquireTimer <= 1 / 30
	if not targetGone and not dueRetarget then return nil end
	local origin = projectile.Position
	local radius = homing.AcquireRadius or 1e9
	local function eligible(entity) return homingEligible(projectile, homing, entity) end
	local candidates
	if homing.AcquireRadius then
		candidates = ChunkManager.GetEntityCandidatesInRadius(origin, homing.AcquireRadius, { Filter = eligible })
	else
		local source = homing.TargetTag and Entity.GetTagged(homing.TargetTag) or Entity.GetAll()
		candidates = {}
		for _, entity in source do if eligible(entity) then table.insert(candidates, entity) end end
	end
	local positions = table.create(#candidates)
	for index, entity in candidates do positions[index] = entity:GetPosition() end
	return { Id = projectile.Id, Origin = origin, Radius = radius, Candidates = candidates, Positions = positions }
end

function ProjectileParallel.GetHint(projectile: any)
	local hint = hints[projectile.Id]
	if hint
		and hint.Velocity == projectile.Velocity
		and hint.Acceleration == projectile.Acceleration
		and hint.AccelerationDirection == projectile.AccelerationDirection
		and hint.Gravity == projectile.Gravity
	then
		stats.HintHits += 1
		return hint
	end
	stats.HintMisses += 1
	return nil
end

-- Returns (ready, target). A ready result may intentionally contain nil when
-- the parallel search found no valid target. Eligibility and radius are
-- revalidated here on the authoritative thread before a target is accepted.
function ProjectileParallel.ConsumeHomingHint(projectile: any): (boolean, any?)
	local hint = homingHints[projectile.Id]
	if not hint then stats.HomingHintMisses += 1; return false, nil end
	homingHints[projectile.Id] = nil
	if frame - hint.Frame > HOMING_HINT_MAX_AGE_FRAMES then
		stats.HomingHintMisses += 1
		return false, nil
	end
	local target = hint.Target
	if target == false then stats.HomingHintHits += 1; return true, nil end
	local homing = projectile.Homing
	if not homing or not homingEligible(projectile, homing, target) then
		stats.HomingHintMisses += 1
		return false, nil
	end
	local position = target:GetPosition()
	if homing.AcquireRadius and (position - projectile.Position).Magnitude > homing.AcquireRadius then
		stats.HomingHintMisses += 1
		return false, nil
	end
	stats.HomingHintHits += 1
	return true, target
end

function ProjectileParallel.ShouldDeferHoming(): boolean
	return parallelEnabled
end

function ProjectileParallel.Dispatch(projectiles: { any }, totalActiveCount: number?)
	frame += 1
	refreshWorkers()
	local scaleCount = totalActiveCount or #projectiles
	parallelEnabled = scaleCount >= MIN_PARALLEL_PROJECTILES and #workers > 0
	if scaleCount < MIN_PARALLEL_PROJECTILES or #workers == 0 then
		if scaleCount == 0 then table.clear(hints); table.clear(homingHints) end
		return
	end

	local available = {}
	for _, worker in workers do
		if not worker.pending then
			table.insert(available, worker)
		else
			stats.BusyWorkers += 1
		end
	end
	if #available == 0 then return end

	local partitions = table.create(#available)
	for index = 1, #available do partitions[index] = {} end
	for index, projectile in projectiles do
		table.insert(partitions[(index - 1) % #available + 1], projectile)
	end

	for index, worker in available do
		local list = partitions[index]
		if #list == 0 then continue end
		worker.generation += 1
		local snapshots = table.create(#list)
		local homingJobs = {}
		for itemIndex, projectile in list do
			local base = (itemIndex - 1) * 5
			worker.input[base + 1] = projectile.Id
			worker.input[base + 2] = projectile.Velocity
			worker.input[base + 3] = projectile.Acceleration
			worker.input[base + 4] = projectile.AccelerationDirection or false
			worker.input[base + 5] = projectile.Gravity
			snapshots[itemIndex] = {
				Id = projectile.Id,
				Acceleration = projectile.Acceleration,
				AccelerationDirection = projectile.AccelerationDirection,
				Gravity = projectile.Gravity,
			}
			local homingJob = buildHomingJob(projectile)
			if homingJob then table.insert(homingJobs, homingJob) end
		end
		local cursor = 1
		for _, job in homingJobs do
			worker.homingInput[cursor] = job.Id
			worker.homingInput[cursor + 1] = job.Origin
			worker.homingInput[cursor + 2] = job.Radius
			worker.homingInput[cursor + 3] = #job.Positions
			cursor += 4
			for _, position in job.Positions do worker.homingInput[cursor] = position; cursor += 1 end
			stats.HomingCandidatesTested += #job.Positions
		end
		worker.pending = { generation = worker.generation, snapshots = snapshots, homingJobs = homingJobs, frame = frame }
		worker.actor:SendMessage("ComputeProjectileHints", worker.generation, #list, #homingJobs)
		stats.BatchesDispatched += 1
		stats.ItemsDispatched += #list
		stats.HomingJobsDispatched += #homingJobs
	end

	if frame % HINT_MAX_AGE_FRAMES == 0 then
		for id, hint in hints do
			if frame - hint.Frame > HINT_MAX_AGE_FRAMES then hints[id] = nil end
		end
		for id, hint in homingHints do
			if frame - hint.Frame > HOMING_HINT_MAX_AGE_FRAMES then homingHints[id] = nil end
		end
	end
end

function ProjectileParallel.GetStats()
	return table.clone(stats)
end

return ProjectileParallel
