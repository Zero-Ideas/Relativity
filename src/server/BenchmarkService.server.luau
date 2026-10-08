--!optimize 2
-- Debug-only real projectile loads. Never accepts client configs/callbacks or
-- arbitrary source/model Instances. No per-projectile listeners for zero damage.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage.Shared
local Schema = require(Shared.ProjectileBenchmark)
local VisualOffload = require(Shared.VisualOffload)
local Entity = require(Shared.Entity)
local Heartbeat = require(Shared.Heartbeat)
local Projectile = require(script.Parent.Projectile)
local DebugAccess = require(script.Parent.DebugAccess)
local WeaponsShared = require(script.Parent.Weapons.Shared)
local states = {}

local function reply(player, message)
	if player.Parent then VisualOffload.FireClient(player, "DebugBenchmarkResult", message) end
end

local function prune(state)
	local live = {}
	for _, shot in state.shots do if not shot.Dead then table.insert(live, shot) end end
	state.shots = live
end

local function stop(state, clear)
	state.cancelled = true
	if clear then
		for _, shot in state.shots do if not shot.Dead then shot:Destroy() end end
		table.clear(state.shots)
	end
end

VisualOffload.On("DebugBenchmark", function(data, player)
	if not player or not DebugAccess.CanUseTab(player, "Benchmarks") then return end
	if typeof(data) ~= "table" then return end
	local state = states[player]
	if not state then state = {shots = {}, busy = false, cancelled = false, last = -math.huge}; states[player] = state end
	if data.Action == "Cancel" or data.Action == "Clear" then
		stop(state, data.Action == "Clear")
		reply(player, {Status = if data.Action == "Clear" then "Cleared your benchmark projectiles" else "Cancelled further spawns"})
		return
	end
	if data.Action ~= "Run" then return end
	if state.busy then reply(player, {Error = "A batch is still spawning; cancel it first"}); return end
	if os.clock() - state.last < 0.5 then reply(player, {Error = "Wait 0.5 seconds between benchmark requests"}); return end
	state.last = os.clock()
	local settings, problem = Schema.Validate(data.Settings)
	if not settings then reply(player, {Error = problem}); return end
	local character = player.Character
	local root = character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		reply(player, {Error = "A living character is required"}); return
	end
	local config = Schema.Config(settings)
	if settings.Model ~= "" then
		local effects = ReplicatedStorage:FindFirstChild("Effects")
		local model = effects and effects:FindFirstChild(settings.Model)
		if not model or not (model:IsA("Model") or model:IsA("BasePart")) then
			reply(player, {Error = "Model must name a Model or BasePart directly inside ReplicatedStorage.Effects"}); return
		end
		config.Model = model
	end
	local origin = root.Position + settings.SpawnOffset
	local aim = root.CFrame.LookVector
	if settings.CustomDirection then aim = settings.Direction.Unit end
	if settings.UseTargetPosition then
		local offset = settings.TargetPosition - origin
		if offset.Magnitude < 0.001 then reply(player, {Error = "TargetPosition equals spawn origin"}); return end
		aim = offset.Unit
	elseif typeof(data.Target) == "Vector3" then
		local target = data.Target
		if target.X == target.X and target.Y == target.Y and target.Z == target.Z and target.Magnitude < 1e8 then
			local offset = target - origin
			if offset.Magnitude > 0.001 then aim = offset.Unit end
		end
	end
	local shooter = Entity.Get(character)
	config.Source = shooter
	config.IgnoreInstances = if settings.IgnoreSelf then {character} else nil
	config.Filter = function(entity)
		if settings.LivingEntitiesOnly and (entity.IsDestroyed or entity.Health <= 0) then return false end
		local instance = entity.Instance
		local targetPlayer = if instance and instance:IsA("Model") then Players:GetPlayerFromCharacter(instance) else nil
		return settings.Damage == 0 or DebugAccess.CanAffect(player, targetPlayer)
	end
	prune(state)
	if #state.shots + settings.Count > Schema.MaxActive then
		reply(player, {Error = `Benchmark active limit ({Schema.MaxActive}) exceeded; clear previous runs first`}); return
	end
	state.cancelled, state.busy = false, true
	local requested, spawned, spawnSeconds = settings.Count, 0, 0
	local started, lastProgress = os.clock(), os.clock()
	local baseline = Projectile.GetStats().Active
	local ok, err = xpcall(function()
		local compiled = Projectile.Compile(config) -- once, never normalize a plain payload 50k times
		local rng = Random.new(settings.Seed)
		local batchSize = if settings.BatchSize == 0 then requested else settings.BatchSize
		while spawned < requested and not state.cancelled do
			if not player.Parent or not character.Parent or humanoid.Health <= 0 or not DebugAccess.CanUseTab(player, "Benchmarks") then break end
			local batchEnd = math.min(requested, spawned + batchSize)
			local tickStarted = os.clock()
			for index = spawned + 1, batchEnd do
				local position, direction = Schema.Sample(settings, index, origin, aim, rng)
				local shot = Projectile.Fire(compiled, position, direction)
				table.insert(state.shots, shot)
				if settings.Damage > 0 then
					local ctx = {Player = player, Shooter = shooter, Projectile = shot}
					shot.OnHit:Connect(function(hit) WeaponsShared.DealDefaultDamage(ctx, hit) end)
				end
				spawned += 1
			end
			spawnSeconds += os.clock() - tickStarted
			if spawned < requested then
				if os.clock() - lastProgress >= 0.25 then
					lastProgress = os.clock()
					reply(player, {Status = `Spawning {spawned} / {requested}`, Spawned = spawned})
				end
				RunService.Heartbeat:Wait()
			end
		end
	end, debug.traceback)
	state.busy = false
	local stats = Projectile.GetStats()
	local loop = Heartbeat.GetStats()
	reply(player, {Status = if ok then `{if state.cancelled then "Stopped" else "Finished"}: {spawned} / {requested}` else "Benchmark failed",
		Error = if not ok then tostring(err) else nil, Spawned = spawned,
		SpawnMs = spawnSeconds * 1000, WallMs = (os.clock() - started) * 1000,
		Active = stats.Active, Baseline = baseline, Pending = stats.PendingVisualSpawns,
		FrameMs = loop.AvgFrameTime * 1000})
	-- Bound retained dead handles without a polling loop or 50k destroy listeners.
	task.delay(settings.MaxRealLifetime + 1, function()
		if states[player] == state then prune(state) end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	local state = states[player]
	if state then stop(state, true); states[player] = nil end
end)
