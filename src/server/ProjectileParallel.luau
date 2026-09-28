--!strict
--[[
	Parallel, read-only projectile math coordinator.

	Actors compute acceleration and curvature hints from immutable snapshots.
	This module alone consumes their SharedTable results and publishes hints to
	the authoritative projectile loop. Workers never mutate projectile objects,
	active arrays, entities, signals, Instances, or replication state.
]]

local SharedTableRegistry = game:GetService("SharedTableRegistry")

local ProjectileParallel = {}

local MIN_PARALLEL_PROJECTILES = 128
local HINT_MAX_AGE_FRAMES = 120

type Worker = {
	actor: Actor,
	input: SharedTable,
	output: SharedTable,
	generation: number,
	pending: any?,
}

local workers: { Worker } = {}
local knownActors: { [Actor]: boolean } = {}
local hints: { [number]: any } = {}
local frame = 0
local stats = {
	BatchesDispatched = 0,
	ItemsDispatched = 0,
	BatchesCompleted = 0,
	ItemsCompleted = 0,
	BusyWorkers = 0,
	HintHits = 0,
	HintMisses = 0,
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
			stats.BatchesCompleted += 1
			stats.ItemsCompleted += #pending.snapshots
			worker.pending = nil
		end
	end
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

function ProjectileParallel.Dispatch(projectiles: { any })
	frame += 1
	refreshWorkers()
	if #projectiles < MIN_PARALLEL_PROJECTILES or #workers == 0 then
		if #projectiles == 0 then table.clear(hints) end
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
		end
		worker.pending = { generation = worker.generation, snapshots = snapshots, frame = frame }
		worker.actor:SendMessage("ComputeProjectileHints", worker.generation, #list)
		stats.BatchesDispatched += 1
		stats.ItemsDispatched += #list
	end

	if frame % HINT_MAX_AGE_FRAMES == 0 then
		for id, hint in hints do
			if frame - hint.Frame > HINT_MAX_AGE_FRAMES then hints[id] = nil end
		end
	end
end

function ProjectileParallel.GetStats()
	return table.clone(stats)
end

return ProjectileParallel
