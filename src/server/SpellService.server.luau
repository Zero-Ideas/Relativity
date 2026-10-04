--!strict
-- Server-authoritative spell-card commands and casting. The circle itself is
-- executed by SpellRuntime; this script owns remotes, mana and cooldowns.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Entity = require(Shared:WaitForChild("Entity"))
local SafeMath = require(Shared:WaitForChild("SafeMath"))
local SpellCompiler = require(Shared:WaitForChild("SpellCompiler"))
local SpellStore = require(script.Parent:WaitForChild("SpellStore"))
local SpellRuntime = require(script.Parent:WaitForChild("SpellRuntime"))

local MANA = 10_000_000_000_000
local CAST_INTERVAL = 0.25
local COMMAND_INTERVAL = 0.15

local remoteFolder = ReplicatedStorage:FindFirstChild("SpellRemotes") or Instance.new("Folder")
remoteFolder.Name = "SpellRemotes"
remoteFolder.Parent = ReplicatedStorage

local command = remoteFolder:FindFirstChild("SpellCommand") or Instance.new("RemoteFunction")
command.Name = "SpellCommand"
command.Parent = remoteFolder

local cast = remoteFolder:FindFirstChild("SpellCast") or Instance.new("RemoteEvent")
cast.Name = "SpellCast"
cast.Parent = remoteFolder

-- While the tool is held the client streams its cursor here (unreliable,
-- ~20 Hz) so Stream copies can re-aim mid-cast. Only positions newer than
-- LIVE_AIM_MAX_AGE are trusted; otherwise the click's cursor is used.
local aimRemote = remoteFolder:FindFirstChild("SpellAim") or Instance.new("UnreliableRemoteEvent")
aimRemote.Name = "SpellAim"
aimRemote.Parent = remoteFolder
local LIVE_AIM_MAX_AGE = 0.5
local liveAim: { [Player]: { position: Vector3, time: number } } = {}

local function validPoint(value: any): boolean
	return typeof(value) == "Vector3"
		and value.X == value.X and value.Y == value.Y and value.Z == value.Z
		and math.abs(value.X) < 1e6 and math.abs(value.Y) < 1e6 and math.abs(value.Z) < 1e6
end

aimRemote.OnServerEvent:Connect(function(player: Player, position: any)
	if validPoint(position) then
		liveAim[player] = { position = position, time = os.clock() }
	end
end)

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
	local name = typeof(raw) == "string" and raw or "Untitled Spell"
	name = string.gsub(name, "^%s+", "")
	name = string.gsub(name, "%s+$", "")
	name = truncateCharacters(name, 24)
	if name == "" then name = "Untitled Spell" end
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

local function aimedEntity(character: Model, origin: Vector3, targetPoint: Vector3)
	local offset = targetPoint - origin
	if offset.Magnitude < 1e-3 then return nil end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true
	local result = workspace:Raycast(origin, offset * 1.05, params)
	return result and Entity.Get(result.Instance) or nil
end

-- Saved graphs are immutable records (PutSlot stores a fresh copy), so the
-- compiled plan can be cached per record instead of recompiling every cast.
local compiledCache: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any

local function compiledFor(record: any): any?
	local cached = compiledCache[record]
	if cached == nil then
		cached = SpellCompiler.Compile(record.graph) or false
		compiledCache[record] = cached
	end
	return cached or nil
end

cast.OnServerEvent:Connect(function(player: Player, rawTarget: any)
	-- A NaN aim has no recoverable direction, so reject it; +-inf components
	-- clamp to SafeMath.Limit so an absurd aim still fires the way it points.
	if typeof(rawTarget) ~= "Vector3" or SafeMath.hasNaN(rawTarget) then
		return
	end
	local targetPoint = SafeMath.vector(rawTarget, Vector3.zero)
	local tool = equippedAssembler(player)
	local character = player.Character
	local root = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
	if not tool or not character or not root or not root:IsA("BasePart") then
		return
	end
	local record = SpellStore.GetActive(player)
	if not record then return end
	local compiled = compiledFor(record)
	if not compiled then return end

	local now = os.clock()
	if lastCast[player] and now - lastCast[player] < CAST_INTERVAL then return end
	local mana = player:GetAttribute("Mana")
	if typeof(mana) ~= "number" or mana < compiled.manaCost then return end
	lastCast[player] = now
	player:SetAttribute("Mana", mana - compiled.manaCost)

	local head = character:FindFirstChild("Head")
	local origin = if head and head:IsA("BasePart") then head.Position else root.Position
	liveAim[player] = { position = targetPoint, time = os.clock() }
	local ok, err = pcall(SpellRuntime.Cast, compiled, {
		player = player,
		caster = Entity.Get(character),
		character = character,
		origin = origin,
		cursorPoint = targetPoint,
		cursorEntity = aimedEntity(character, origin, targetPoint),
		live = function()
			local headNow = character:FindFirstChild("Head")
			local aim = liveAim[player]
			local fresh = aim and os.clock() - aim.time <= LIVE_AIM_MAX_AGE
			return if headNow and headNow:IsA("BasePart") then headNow.Position else nil,
				if fresh then aim.position else nil
		end,
	})
	if not ok then
		warn(`[SpellService] cast failed: {tostring(err)}`)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	liveAim[player] = nil
	lastCast[player] = nil
	lastCommand[player] = nil
end)

print("[Relativity] spell service online")
