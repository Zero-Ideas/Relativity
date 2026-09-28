--!strict
-- Server-authoritative spell-card commands and Fire Projectile execution.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Entity = require(Shared:WaitForChild("Entity"))
local SpellCompiler = require(Shared:WaitForChild("SpellCompiler"))
local Projectile = require(script.Parent:WaitForChild("Projectile"))
local ProjectileQuota = require(script.Parent:WaitForChild("ProjectileQuota"))
local SpellStore = require(script.Parent:WaitForChild("SpellStore"))

local MANA = 10_000_000_000_000
local CAST_INTERVAL = 0.25
local COMMAND_INTERVAL = 0.15
local SPAWN_OFFSET = 3

local remoteFolder = ReplicatedStorage:FindFirstChild("SpellRemotes") or Instance.new("Folder")
remoteFolder.Name = "SpellRemotes"
remoteFolder.Parent = ReplicatedStorage

local command = remoteFolder:FindFirstChild("SpellCommand") or Instance.new("RemoteFunction")
command.Name = "SpellCommand"
command.Parent = remoteFolder

local cast = remoteFolder:FindFirstChild("SpellCast") or Instance.new("RemoteEvent")
cast.Name = "SpellCast"
cast.Parent = remoteFolder

local lastCast: { [Player]: number } = {}
local lastCommand: { [Player]: number } = {}

local function onPlayer(player: Player)
	player:SetAttribute("MaxMana", MANA)
	player:SetAttribute("Mana", MANA)
end

for _, player in Players:GetPlayers() do onPlayer(player) end
Players.PlayerAdded:Connect(onPlayer)

local function response(ok: boolean, state: any?, errors: any?, message: string?)
	return { ok = ok, state = state, errors = errors, message = message }
end

local function integerSlot(value: any): number?
	if typeof(value) ~= "number" or value ~= value or value % 1 ~= 0 or value < 1 or value > 5 then
		return nil
	end
	return value
end

local function truncateCharacters(text: string, maximum: number): string
	local length = utf8.len(text)
	if not length or length <= maximum then
		return text
	end
	local boundary = utf8.offset(text, maximum + 1)
	return boundary and string.sub(text, 1, boundary - 1) or text
end

local function filterName(player: Player, raw: any): (string?, string?)
	local name = typeof(raw) == "string" and raw or "Fire Projectile"
	name = string.gsub(name, "^%s+", "")
	name = string.gsub(name, "%s+$", "")
	name = truncateCharacters(name, 24)
	if name == "" then name = "Fire Projectile" end
	local ok, filtered = pcall(function()
		local result = TextService:FilterStringAsync(name, player.UserId)
		return result:GetNonChatStringForUserAsync(player.UserId)
	end)
	if not ok or typeof(filtered) ~= "string" or filtered == "" then
		return nil, "The spell name could not be filtered. Try another name."
	end
	return truncateCharacters(filtered, 24), nil
end

command.OnServerInvoke = function(player: Player, action: any, payload: any)
	if typeof(action) ~= "string" then
		return response(false, nil, nil, "Invalid spell command.")
	end
	local now = os.clock()
	if lastCommand[player] and now - lastCommand[player] < COMMAND_INTERVAL then
		return response(false, SpellStore.GetState(player), nil, "Please wait before sending another spell command.")
	end
	lastCommand[player] = now
	if action == "GetState" then
		return response(true, SpellStore.GetState(player))
	end
	if typeof(payload) ~= "table" then
		return response(false, SpellStore.GetState(player), nil, "Invalid spell command payload.")
	end
	local slot = integerSlot(payload.slot)
	if not slot then
		return response(false, SpellStore.GetState(player), nil, "Choose a card slot from 1 to 5.")
	end

	if action == "SaveCard" then
		local compiled, errors, normalized = SpellCompiler.Compile(payload.graph)
		if not compiled or not normalized then
			return response(false, SpellStore.GetState(player), errors, "The circle is invalid.")
		end
		local name, nameError = filterName(player, payload.name or normalized.name)
		if not name then
			return response(false, SpellStore.GetState(player), nil, nameError)
		end
		normalized.name = name
		local ok, err, state = SpellStore.PutSlot(player, slot, name, normalized)
		return response(ok, state or SpellStore.GetState(player), nil, err or "Spell card saved.")
	elseif action == "DeleteCard" then
		local ok, err, state = SpellStore.DeleteSlot(player, slot)
		return response(ok, state or SpellStore.GetState(player), nil, err or "Spell card deleted.")
	elseif action == "SetActive" then
		local ok, err, state = SpellStore.SetActive(player, slot)
		return response(ok, state or SpellStore.GetState(player), nil, err or "Spell card equipped.")
	end
	return response(false, SpellStore.GetState(player), nil, "Unknown spell command.")
end

local function equippedAssembler(player: Player): Tool?
	local character = player.Character
	local tool = character and character:FindFirstChild("SpellAssembler")
	return if tool and tool:IsA("Tool") then tool else nil
end

local function damageHit(shooter: any, projectile: any, hit: any)
	local target = hit.Entity
	if not target or target.IsDestroyed or target.Health <= 0 then
		return
	end
	local amount = projectile.Damage * projectile.DamageMultiplier
	if hit.Hurtbox == "Head" then
		amount *= target.HeadshotMultiplier
	end
	if amount <= 0 then return end
	local info = {
		Type = "Projectile",
		Element = "Fire",
		Source = shooter,
		Position = hit.CFrame.Position,
		Hurtbox = hit.Hurtbox,
	}
	if shooter and shooter.DealDamage then
		shooter:DealDamage(target, amount, info)
	else
		target:TakeDamage(amount, info)
	end
end

local function aimedEntity(character: Model, origin: Vector3, targetPoint: Vector3)
	local offset = targetPoint - origin
	if offset.Magnitude < 1e-3 then return nil end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true
	local result = workspace:Raycast(origin, offset, params)
	return result and Entity.Get(result.Instance) or nil
end

local function evaluateCondition(predicate: number, target: any, shooter: any, origin: Vector3): boolean
	if predicate == 1 then return target ~= nil end
	if predicate == 2 then return target ~= nil and not target.IsDestroyed and target.Health > 0 end
	if predicate == 3 then return target ~= nil and target ~= shooter end
	if predicate == 4 then
		return target ~= nil and target.Instance ~= nil and Players:GetPlayerFromCharacter(target.Instance) ~= nil
	end
	if predicate == 5 then
		return target ~= nil and not target.IsDestroyed and (target:GetPosition() - origin).Magnitude <= 75
	end
	return false
end

cast.OnServerEvent:Connect(function(player: Player, targetPoint: any)
	if typeof(targetPoint) ~= "Vector3"
		or targetPoint.X ~= targetPoint.X
		or targetPoint.Y ~= targetPoint.Y
		or targetPoint.Z ~= targetPoint.Z
		or math.abs(targetPoint.X) == math.huge
		or math.abs(targetPoint.Y) == math.huge
		or math.abs(targetPoint.Z) == math.huge
	then
		return
	end
	local tool = equippedAssembler(player)
	local character = player.Character
	local root = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
	if not tool or not character or not root or not root:IsA("BasePart") then
		return
	end
	local record = SpellStore.GetActive(player)
	if not record then return end
	local compiled = SpellCompiler.Compile(record.graph)
	if not compiled then return end

	local head = character:FindFirstChild("Head")
	local baseOrigin = if head and head:IsA("BasePart") then head.Position else root.Position
	local offset = targetPoint - baseOrigin
	if offset.Magnitude < 1e-3 then return end
	local shooter = Entity.Get(character)
	local execution = compiled.execution
	local branch
	if execution.kind == "Conditional" then
		local target = aimedEntity(character, baseOrigin, targetPoint)
		branch = if evaluateCondition(execution.predicate, target, shooter, baseOrigin) then execution.trueBranch else execution.falseBranch
	else
		branch = execution.branch
	end
	if not branch then return end

	local now = os.clock()
	if lastCast[player] and now - lastCast[player] < CAST_INTERVAL then return end
	local mana = player:GetAttribute("Mana")
	if typeof(mana) ~= "number" or mana < compiled.manaCost then return end
	if not ProjectileQuota.TryAcquire(player, branch.count) then return end

	local direction = offset.Unit
	lastCast[player] = now
	player:SetAttribute("Mana", mana - compiled.manaCost)

	local stats = table.clone(branch.stats)
	stats.Origin = baseOrigin + direction * SPAWN_OFFSET
	stats.Direction = direction
	stats.Source = shooter
	stats.IgnoreInstances = { character }
	stats.Filter = function(entity)
		return entity ~= shooter and not entity.IsDestroyed and entity.Health > 0
	end
	stats.Visualize = true
	stats.VisualRange = 800
	stats.Visual = { Shape = "Ball", Size = Vector3.one * 0.75, Color = Color3.fromRGB(255, 105, 35) }
	local effects = ReplicatedStorage:FindFirstChild("Effects")
	stats.Model = effects and effects:FindFirstChild("firbal")
	stats.Spread = branch.spread
	if branch.homing then stats.Homing = table.clone(branch.homing) end

	local ok, projectiles = pcall(Projectile.Burst, stats, branch.count)
	if not ok then
		ProjectileQuota.Release(player, branch.count)
		player:SetAttribute("Mana", mana)
		lastCast[player] = nil
		warn(`[SpellService] projectile spawn failed: {tostring(projectiles)}`)
		return
	end
	for _, projectile in projectiles do
		local released = false
		projectile.OnDestroy:Connect(function()
			if not released then
				released = true
				ProjectileQuota.Release(player, 1)
			end
		end)
		projectile.OnHit:Connect(function(hit)
			damageHit(shooter, projectile, hit)
		end)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	lastCast[player] = nil
	lastCommand[player] = nil
end)

print("[Relativity] spell service online")
