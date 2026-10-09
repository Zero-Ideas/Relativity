--!strict
-- Server-authoritative spell-card commands and casting. The circle itself is
-- executed by SpellRuntime; this script owns remotes, mana and cooldowns.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Entity = require(Shared:WaitForChild("Entity"))
local SafeMath = require(Shared:WaitForChild("SafeMath"))
local SpellCompiler = require(Shared:WaitForChild("SpellCompiler"))
local SpellRunes = require(Shared:WaitForChild("SpellRunes"))
local SpellCircleLayout = require(Shared:WaitForChild("SpellCircleLayout"))
local VisualOffload = require(Shared:WaitForChild("VisualOffload"))
local SpellStore = require(script.Parent:WaitForChild("SpellStore"))
local SpellRuntime = require(script.Parent:WaitForChild("SpellRuntime"))
local BeamHandler = require(script.Parent:WaitForChild("Projectile"):WaitForChild("BeamProjectileHandler"))

local PlayerResources = require(script.Parent.PlayerResources)
-- (the cast cooldown is a live admin setting: SpellSettings.GetCooldown())
local SpellSettings = require(Shared.SpellSettings)
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

-- Spell sharing (client/SpellLibrary): ("Offer", shareId, from, name,
-- expiresAt) to the recipient, ("Answer", recipient, accepted, name) back to
-- the sharer.
local shareRemote = remoteFolder:FindFirstChild("SpellShare") or Instance.new("RemoteEvent")
shareRemote.Name = "SpellShare"
shareRemote.Parent = remoteFolder

local feedback = remoteFolder:FindFirstChild("SpellFeedback") or Instance.new("RemoteEvent")
feedback.Name = "SpellFeedback"
feedback.Parent = remoteFolder

local channel = remoteFolder:FindFirstChild("SpellChannel") or Instance.new("RemoteEvent")
channel.Name = "SpellChannel"
channel.Parent = remoteFolder
-- Hold-to-charge: the server times the hold itself, from ChargeBegin to the
-- SpellCast that ends it, so a client can't claim a charge it never held.
local chargeStart: { [Player]: number } = {}
-- Mana is paid when charging starts: the spell's full (charge 1) cost on
-- ChargeBegin. The release settles the difference -- the unused part of a
-- partial charge comes back, overcharge pays extra -- and a cancelled charge
-- keeps what it paid.
local chargePaid: { [Player]: number } = {}

-- While the tool is held the client streams its cursor here (unreliable,
-- ~20 Hz) so Stream copies can re-aim mid-cast. Only positions newer than
-- LIVE_AIM_MAX_AGE are trusted; otherwise the click's cursor is used.
local aimRemote = remoteFolder:FindFirstChild("SpellAim") or Instance.new("UnreliableRemoteEvent")
aimRemote.Name = "SpellAim"
aimRemote.Parent = remoteFolder
-- Live aim of a charging/channelling caster, forwarded to clients that asked
-- for it (SpellChannel "AimSubscribe"; SpellCircleVFX turns their circle).
local aimRelay = remoteFolder:FindFirstChild("SpellAimRelay") or Instance.new("UnreliableRemoteEvent")
aimRelay.Name = "SpellAimRelay"
aimRelay.Parent = remoteFolder
local LIVE_AIM_MAX_AGE = 0.5
local liveAim: { [Player]: { position: Vector3, time: number } } = {}

local function validPoint(value: any): boolean
	return typeof(value) == "Vector3"
		and value.X == value.X and value.Y == value.Y and value.Z == value.Z
		and math.abs(value.X) < 1e6 and math.abs(value.Y) < 1e6 and math.abs(value.Z) < 1e6
end

-- GUI spellcasting is available while alive and not holding another weapon.
-- Legacy assembler Tools remain compatible, but no Tool is required.
local function canCastSpells(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then return false end
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child.Name ~= "SpellAssembler" then return false end
	end
	return true
end

aimRemote.OnServerEvent:Connect(function(player: Player, position: any)
	local now = os.clock()
	local previous = liveAim[player]
	if canCastSpells(player) and SpellStore.GetActive(player) and validPoint(position) and (not previous or now - previous.time >= 0.025) then
		liveAim[player] = { position = position, time = now }
	end
end)

local lastCast: { [Player]: { [number]: number } } = {}
local lastCommand: { [Player]: number } = {}
local lastCommandWasSelection: { [Player]: boolean } = {}

local function coolingDown(player: Player, slot: number?): boolean
	local key = slot or SpellStore.GetActiveSlot(player)
	local previous = key and lastCast[player] and lastCast[player][key]
	return previous ~= nil and os.clock() - previous < SpellSettings.GetCooldown()
end

local function markCast(player: Player, slot: number?, manaSpent: number)
	if not slot then return end
	local deadlines = lastCast[player]
	if not deadlines then deadlines = {}; lastCast[player] = deadlines end
	deadlines[slot] = os.clock()
	local deadline = workspace:GetServerTimeNow() + SpellSettings.GetCooldown()
	player:SetAttribute("SpellCooldownEndsAt" .. slot, deadline)
	feedback:FireClient(player, { Accepted = true, Slot = slot, EndsAt = deadline, ManaSpent = manaSpent })
end

-- Settles a charge that prepaid `paid` mana: pays the rest of its cost at
-- `charge`, or refunds the excess. Overcharge that can't be afforded falls
-- back to charge 1. Returns the charge to cast at, or nil when even that
-- can't be paid.
local function settleCharge(player: Player, compiled: any, charge: number, paid: number): number?
	local cost = compiled.manaCost * SpellRunes.ChargeEnergyMultiplier(charge)
	if cost > paid and not PlayerResources.Consume(player, "Mana", cost - paid) then
		charge = math.min(charge, 1)
		cost = compiled.manaCost * SpellRunes.ChargeEnergyMultiplier(charge)
		if cost > paid and not PlayerResources.Consume(player, "Mana", cost - paid) then
			return nil
		end
	end
	if cost < paid then
		PlayerResources.Refund(player, "Mana", paid - cost)
	end
	return charge
end

local function rejectCast(player: Player, slot: number?)
	local key = slot or SpellStore.GetActiveSlot(player)
	feedback:FireClient(player, { Accepted = false, Slot = key, EndsAt = if key then player:GetAttribute("SpellCooldownEndsAt" .. key) or 0 else 0 })
end

local function onPlayer(player: Player)
	PlayerResources.Initialize(player)
	player:SetAttribute("SpellCooldownEndsAt", nil)
	for slot = 1, 5 do player:SetAttribute("SpellCooldownEndsAt" .. slot, 0) end
	player:SetAttribute("SpellFrozenSlot", nil)
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
	-- Studio and Team Test save to the same live store, so names are always
	-- filtered.
	local ok, filtered = pcall(function()
		local result = TextService:FilterStringAsync(name, player.UserId)
		return result:GetNonChatStringForUserAsync(player.UserId)
	end)
	if not ok or typeof(filtered) ~= "string" or filtered == "" then
		return nil, "The spell name could not be filtered. Try another name."
	end
	return truncateCharacters(filtered, 24), nil
end

-- Shared spells waiting for an answer: shares[recipient][shareId].
local SHARE_LIFETIME = 60
type Share = { from: Player, name: string, graph: any, expiry: number, savedId: string? }
local shares: { [Player]: { [string]: Share } } = {}

local function refOf(payload: any): string?
	local ref = payload.ref
	return if typeof(ref) == "string" and #ref <= 80 then ref else nil
end

local function textOf(value: any, maximum: number): string?
	return if typeof(value) == "string" and #value <= maximum then value else nil
end

-- Commands that don't take a hotbar slot. Returns nil for the others.
local function handleLibraryCommand(player: Player, action: string, payload: any)
	local function done(ok: boolean, err: string?, state: any?, success: string)
		return response(ok, state or SpellStore.GetState(player), nil, if ok then (err or success) else err)
	end
	if action == "SaveSpell" then
		-- a library spell: payload.id overwrites it, none adds a new one
		local compiled, errors, normalized = SpellCompiler.Compile(payload.graph)
		if not compiled or not normalized then
			return response(false, SpellStore.GetState(player), errors, "The circle is invalid.")
		end
		local name, nameError = filterName(player, payload.name or normalized.name)
		if not name then
			return response(false, SpellStore.GetState(player), nil, nameError)
		end
		normalized.name = name
		local ok, err, state, id = SpellStore.SaveSpell(player, textOf(payload.id, 64), name, normalized)
		local result = done(ok, err, state, "Spell saved to your library.")
		result.id = id
		return result
	elseif action == "DeleteSpell" then
		local id = textOf(payload.id, 64)
		if not id then return response(false, SpellStore.GetState(player), nil, "Unknown spell.") end
		local ok, err, state = SpellStore.DeleteSpell(player, id)
		return done(ok, err, state, "Spell deleted.")
	elseif action == "Equip" then
		local slot, ref = integerSlot(payload.slot), refOf(payload)
		if not slot or not ref then return response(false, SpellStore.GetState(player), nil, "Pick a slot from 1 to 5.") end
		local ok, err, state = SpellStore.Equip(player, slot, ref)
		return done(ok, err, state, `Put on slot {slot}.`)
	elseif action == "MoveSlot" then
		local slot = integerSlot(payload.slot)
		if not slot or (payload.direction ~= -1 and payload.direction ~= 1) then
			return response(false, SpellStore.GetState(player), nil, "Can't move that.")
		end
		local ok, err, state = SpellStore.MoveSlot(player, slot, payload.direction)
		return done(ok, err, state, "Moved.")
	elseif action == "SwapSlots" then
		local a, b = integerSlot(payload.slot), integerSlot(payload.other)
		if not a or not b then return response(false, SpellStore.GetState(player), nil, "Pick two slots.") end
		local ok, err, state = SpellStore.SwapSlots(player, a, b)
		return done(ok, err, state, "Swapped.")
	elseif action == "CreateFolder" then
		local raw = textOf(payload.name, 200)
		if not raw then return response(false, SpellStore.GetState(player), nil, "Name the folder.") end
		local name, nameError = filterName(player, raw)
		if not name then return response(false, SpellStore.GetState(player), nil, nameError) end
		local ok, err, state = SpellStore.CreateFolder(player, name)
		return done(ok, err, state, `Made folder "{name}".`)
	elseif action == "DeleteFolder" then
		local name = textOf(payload.name, 200)
		if not name then return response(false, SpellStore.GetState(player), nil, "Unknown folder.") end
		local ok, err, state = SpellStore.DeleteFolder(player, name)
		return done(ok, err, state, "Folder deleted (its spells are now unfiled).")
	elseif action == "MoveToFolder" then
		local id = textOf(payload.id, 64)
		local folder = if payload.folder == nil then nil else textOf(payload.folder, 200)
		if not id or (payload.folder ~= nil and not folder) then
			return response(false, SpellStore.GetState(player), nil, "Can't move that.")
		end
		local ok, err, state = SpellStore.MoveToFolder(player, id, folder)
		return done(ok, err, state, if folder then `Moved to "{folder}".` else "Moved to Unfiled.")
	elseif action == "SaveLoadout" or action == "LoadLoadout" or action == "DeleteLoadout" then
		local raw = textOf(payload.name, 200)
		if not raw then return response(false, SpellStore.GetState(player), nil, "Name the loadout.") end
		if action == "SaveLoadout" then
			local name, nameError = filterName(player, raw)
			if not name then return response(false, SpellStore.GetState(player), nil, nameError) end
			local ok, err, state = SpellStore.SaveLoadout(player, name)
			return done(ok, err, state, `Saved loadout "{name}".`)
		elseif action == "LoadLoadout" then
			BeamHandler.Stop(player)
			local ok, err, state = SpellStore.LoadLoadout(player, raw)
			return done(ok, err, state, `Loaded "{raw}".`)
		end
		local ok, err, state = SpellStore.DeleteLoadout(player, raw)
		return done(ok, err, state, "Loadout deleted.")
	elseif action == "Purchase" then
		local id = textOf(payload.id, 64)
		if not id then return response(false, SpellStore.GetState(player), nil, "Unknown spell.") end
		local ok, err, state = SpellStore.Purchase(player, id)
		return done(ok, err, state, "Purchased.")
	elseif action == "ShareSpell" then
		-- offer one of your spells to another player in this server
		local id = textOf(payload.id, 64)
		local target = if typeof(payload.targetUserId) == "number" then Players:GetPlayerByUserId(payload.targetUserId) else payload.target
		local record = id and SpellStore.GetLibrarySpell(player, id)
		if not record or record.invalid then
			return response(false, SpellStore.GetState(player), nil, "Pick a working spell from your library.")
		end
		if typeof(target) ~= "Instance" or not target:IsA("Player") or target == player or target.Parent ~= Players then
			return response(false, SpellStore.GetState(player), nil, "Pick someone in this server.")
		end
		local compiled, _, snapshot = SpellCompiler.Compile(record.graph)
		if not compiled or not snapshot then
			return response(false, SpellStore.GetState(player), nil, "That spell no longer compiles. Edit and save it before sharing.")
		end
		local pending = shares[target]
		if not pending then
			pending = {}
			shares[target] = pending
		end
		for _, share in pending do
			if share.from == player and share.expiry > os.clock() then
				return response(false, SpellStore.GetState(player), nil, `{target.DisplayName} hasn't answered your last share yet.`)
			end
		end
		-- The sender's personal filter result isn't valid for the recipient.
		-- Filter before showing the offer, not only after it is accepted.
		local ok, filtered = pcall(function()
			local result = TextService:FilterStringAsync(record.name, player.UserId)
			return result:GetNonChatStringForUserAsync(target.UserId)
		end)
		local name = if ok and typeof(filtered) == "string" and filtered ~= "" then truncateCharacters(filtered, 24) else "Shared spell"
		if target.Parent ~= Players then return response(false, SpellStore.GetState(player), nil, "That player left the server.") end
		snapshot.name = name
		local shareId = HttpService:GenerateGUID(false)
		pending[shareId] = { from = player, name = name, graph = snapshot, expiry = os.clock() + SHARE_LIFETIME }
		shareRemote:FireClient(target, "Offer", shareId, player, name, workspace:GetServerTimeNow() + SHARE_LIFETIME)
		task.delay(SHARE_LIFETIME, function()
			if shares[target] then shares[target][shareId] = nil end
		end)
		return response(true, SpellStore.GetState(player), nil, `Offered "{record.name}" to {target.DisplayName}.`)
	elseif action == "AcceptShare" or action == "DeclineShare" then
		local shareId = textOf(payload.shareId, 64)
		local pending = shares[player]
		local share = shareId and pending and pending[shareId]
		if not share then
			return response(false, SpellStore.GetState(player), nil, "That share has expired.")
		end
		local from = share.from
		if share.expiry < os.clock() then
			(pending :: any)[shareId] = nil
			return response(false, SpellStore.GetState(player), nil, "That share has expired.")
		end
		if action == "DeclineShare" then
			(pending :: any)[shareId] = nil
			if from.Parent == Players then shareRemote:FireClient(from, "Answer", player, false, share.name) end
			return response(true, SpellStore.GetState(player), nil, "Declined.")
		end
		-- Keep the offer until saving succeeds. If persistence failed after
		-- inserting the in-session copy, a retry saves that same copy, never
		-- adds a duplicate spell.
		local name = share.name
		local saved, err, state, savedId = SpellStore.SaveSpell(player, share.savedId, name, share.graph)
		share.savedId = savedId or share.savedId
		if saved then
			(pending :: any)[shareId] = nil
			if from.Parent == Players then shareRemote:FireClient(from, "Answer", player, true, share.name) end
		end
		return done(saved, err, state, `Added "{name}" to your library.`)
	end
	return nil
end

local function handleCommand(player: Player, action: any, payload: any)
	if typeof(action) ~= "string" then
		return response(false, nil, nil, "Invalid spell command.")
	end
	local now = os.clock()
	local isSelection = action == "SetActive" or action == "ClearActive"
	local interval = if isSelection and lastCommandWasSelection[player] then 0.05 else COMMAND_INTERVAL
	if lastCommand[player] and now - lastCommand[player] < interval then
		local result = response(false, nil, nil, "Please wait before sending another spell command.")
		result.retryAfter = interval - (now - lastCommand[player])
		return result
	end
	lastCommand[player] = now
	lastCommandWasSelection[player] = isSelection
	if action == "GetState" then
		return response(true, SpellStore.GetState(player))
	end
	if action == "ClearActive" then
		-- (deselect: no spell equipped)
		BeamHandler.Stop(player)
		local ok, err = SpellStore.SetActive(player, nil, false)
		-- Selection changes no graphs: do not copy and resend the entire library.
		local result = response(ok, nil, nil, err or "Spell deselected.")
		result.selection = { slot = SpellStore.GetActiveSlot(player) }
		return result
	end
	if typeof(payload) ~= "table" then
		return response(false, SpellStore.GetState(player), nil, "Invalid spell command payload.")
	end
	local libraryResult = handleLibraryCommand(player, action, payload)
	if libraryResult then
		return libraryResult
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
		return response(ok, state or SpellStore.GetState(player), nil, err or "Taken off the hotbar (it's still in your library).")
	elseif action == "SetActive" then
		BeamHandler.Stop(player)
		local ok, err = SpellStore.SetActive(player, slot, false)
		local result = response(ok, nil, nil, err or "Spell card equipped.")
		result.selection = { slot = SpellStore.GetActiveSlot(player) }
		return result
	end
	return response(false, SpellStore.GetState(player), nil, "Unknown spell command.")
end

local commandBusy: { [Player]: boolean } = {}
command.OnServerInvoke = function(player: Player, action: any, payload: any)
	if commandBusy[player] then return response(false, nil, nil, "A spell command is already in progress.") end
	commandBusy[player] = true
	local ok, result = pcall(handleCommand, player, action, payload)
	commandBusy[player] = nil
	if not ok then
		warn(`[SpellService] command failed: {tostring(result)}`)
		return response(false, nil, nil, "The spell command could not be completed.")
	end
	return result
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

-- Invoke runes cast the spell on one of the caster's hotbar slots.
SpellRuntime.SetResolver(function(player: Player, slot: number): any?
	local record = SpellStore.GetSlotRecord(player, slot)
	return if record then compiledFor(record) else nil
end)

-- Spell circle VFX (client/SpellCircleVFX): the spec is built once per saved
-- record. circleOpen marks a player whose charging circle was broadcast, so
-- a cast that then fails (no mana, cooldown, ...) cancels it.
local circleSpecs: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any
local circleOpen: { [Player]: boolean } = {}
local lastCircleBegin: { [Player]: number } = {}
local CIRCLE_BEGIN_INTERVAL = 0.15

local function circleSpecFor(record: any): any?
	local cached = circleSpecs[record]
	if cached == nil then
		local compiled = compiledFor(record)
		cached = if compiled then SpellCircleLayout.Build(compiled) else false
		circleSpecs[record] = cached
	end
	return cached or nil
end

local function circleBegin(player: Player)
	local now = os.clock()
	if lastCircleBegin[player] and now - lastCircleBegin[player] < CIRCLE_BEGIN_INTERVAL then
		return
	end
	local character = player.Character
	local record = SpellStore.GetActive(player)
	local spec = record and circleSpecFor(record)
	if not character or not spec or not canCastSpells(player) then
		return
	end
	lastCircleBegin[player] = now
	circleOpen[player] = true
	local aim = liveAim[player]
	local compiled = compiledFor(record)
	VisualOffload.Fire("SpellCircle", { Phase = "Begin", Caster = character, Spec = spec, Target = aim and aim.position,
		ManaCost = if compiled then compiled.manaCost else 0 })
end

local function circleClose(player: Player, phase: string)
	local character = player.Character
	if character then
		VisualOffload.Fire("SpellCircle", { Phase = phase, Caster = character })
	end
end

-- Frozen spells (R while charging / T to fire): paid for at freeze time and
-- launched later from where their circle hung, oldest first. One frozen
-- before full charge keeps charging while it hangs, up to 1x (never into
-- overcharge); the extra is paid for when it fires, if the mana is there.
type FrozenSpell = { compiled: any, charge: number, started: number, origin: Vector3, slot: number? }
local frozenSpells: { [Player]: { FrozenSpell } } = {}
local FROZEN_FALLBACK_RANGE = 100 -- auto-fire target when there's no fresh cursor

local function freshAim(player: Player): Vector3?
	local aim = liveAim[player]
	return if aim and os.clock() - aim.time <= LIVE_AIM_MAX_AGE then aim.position else nil
end

local function livingCharacter(player: Player): (Model?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local head = character and (character:FindFirstChild("Head") or character.PrimaryPart)
	if not humanoid or humanoid.Health <= 0 or not head or not head:IsA("BasePart") then
		return nil, nil
	end
	return character, head
end

local function fireFrozen(player: Player, target: Vector3): boolean
	local queue = frozenSpells[player]
	local entry = queue and queue[1]
	local character = livingCharacter(player)
	if not entry or not character or coolingDown(player, entry.slot) then
		return false
	end
	local charge = entry.charge
	if charge < 1 then
		local grown = math.min(SpellRunes.ChargeFromHold(os.clock() - entry.started), 1)
		local extra = entry.compiled.manaCost * (SpellRunes.ChargeEnergyMultiplier(grown) - SpellRunes.ChargeEnergyMultiplier(charge))
		local mana = player:GetAttribute("Mana")
		if grown > charge and typeof(mana) == "number" and mana >= extra then
			if not PlayerResources.Consume(player, "Mana", extra) then return false end
			charge = grown
		end
	end
	table.remove(queue :: { FrozenSpell }, 1)
	player:SetAttribute("SpellFrozenSlot", if queue and queue[1] then queue[1].slot else nil)
	markCast(player, entry.slot, entry.compiled.manaCost * SpellRunes.ChargeEnergyMultiplier(charge))
	VisualOffload.Fire("SpellCircle", { Phase = "FireFrozen", Caster = character, Target = target })
	-- launch once the circle has reassembled on clients (SpellCircleVFX)
	local origin = entry.origin
	task.delay(SpellRunes.Freeze.AssembleTime, function()
		local living = livingCharacter(player)
		if living ~= character then
			return
		end
		local ok, err = pcall(SpellRuntime.Cast, entry.compiled, {
			player = player,
			caster = Entity.Get(character),
			character = character,
			origin = origin,
			cursorPoint = target,
			cursorEntity = aimedEntity(character, origin, target),
			charge = charge,
			live = function()
				return origin, target -- a frozen spell keeps its spot and its T aim
			end,
		})
		if not ok then
			warn(`[SpellService] frozen cast failed: {tostring(err)}`)
		end
	end)
	return true
end

local function freezeSpell(player: Player, rawPosition: any)
	local started = chargeStart[player]
	local character, head = livingCharacter(player)
	if not started or not character or not head or not canCastSpells(player) then
		return
	end
	local record = SpellStore.GetActive(player)
	local compiled = record and compiledFor(record)
	if not record or not compiled or SpellRunes.HasSustain(compiled) then
		return
	end
	local held = os.clock() - started
	if held > SpellRunes.Charge.StaleAfter then
		return
	end
	local existing = frozenSpells[player]
	if existing and #existing >= SpellRunes.Freeze.MaxQueued and coolingDown(player, existing[1].slot) then return end
	local settled = settleCharge(player, compiled, SpellRunes.ChargeFromHold(held), chargePaid[player] or 0)
	if not settled then
		return
	end
	local charge = settled
	chargeStart[player] = nil
	chargePaid[player] = nil
	circleOpen[player] = nil

	-- where the circle hangs: the client's claim if it's near the head,
	-- otherwise where the circle would be (3 studs out along the aim)
	local eye = head.Position - Vector3.new(0, 0.3, 0)
	local aim = freshAim(player)
	local facing = if aim and (aim - eye).Magnitude > 1e-3 then (aim - eye).Unit else character:GetPivot().LookVector
	local origin = eye + facing * 3
	if validPoint(rawPosition) and (rawPosition - head.Position).Magnitude <= SpellRunes.Freeze.MaxDistance then
		origin = rawPosition
	end

	local queue = frozenSpells[player]
	if not queue then
		queue = {}
		frozenSpells[player] = queue
	end
	if #queue >= SpellRunes.Freeze.MaxQueued then
		fireFrozen(player, aim or origin + facing * FROZEN_FALLBACK_RANGE)
	end
	table.insert(queue, { compiled = compiled, charge = charge, started = started, origin = origin, slot = SpellStore.GetActiveSlot(player) })
	player:SetAttribute("SpellFrozenSlot", queue[1].slot)
	VisualOffload.Fire("SpellCircle", {
		Phase = "Freeze",
		Caster = character,
		Position = origin,
		Direction = facing,
		Spec = circleSpecFor(record),
		Charge = charge,
	})
end

local function clearFrozen(player: Player, character: Model?)
	if frozenSpells[player] == nil then
		return
	end
	frozenSpells[player] = nil
	player:SetAttribute("SpellFrozenSlot", nil)
	if character then
		VisualOffload.Fire("SpellCircle", { Phase = "ClearFrozen", Caster = character })
	end
end

-- Frozen spells die with their caster.
local function watchCharacters(player: Player)
	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(function()
				clearFrozen(player, character)
			end)
		end
	end)
	player.CharacterRemoving:Connect(function(character)
		clearFrozen(player, character)
		chargeStart[player], chargePaid[player] = nil, nil
	end)
end
for _, player in Players:GetPlayers() do watchCharacters(player) end
Players.PlayerAdded:Connect(watchCharacters)

-- Live aim relay: while a caster's circle is up (charging, or a channelled
-- Sustain), their streamed cursor goes to every subscribed client at up to
-- 1 / AIM_RELAY_INTERVAL per second.
local AIM_RELAY_INTERVAL = 1 / 15
local aimSubscribers: { [Player]: boolean } = {}
local lastAimRelay: { [Player]: number } = {}

aimRemote.OnServerEvent:Connect(function(player: Player, position: any)
	if not validPoint(position) or not (circleOpen[player] or SpellRuntime.IsSustaining(player)) then
		return
	end
	local character = player.Character
	local now = os.clock()
	if not character or (lastAimRelay[player] and now - lastAimRelay[player] < AIM_RELAY_INTERVAL) then
		return
	end
	lastAimRelay[player] = now
	for subscriber in aimSubscribers do
		if subscriber ~= player then
			aimRelay:FireClient(subscriber, character, position)
		end
	end
end)

channel.OnServerEvent:Connect(function(player: Player, action: any, payload: any)
	if action == "AimSubscribe" then
		aimSubscribers[player] = if payload == true then true else nil
	elseif action == "Stop" then
		BeamHandler.Stop(player)
		circleClose(player, "End")
	elseif action == "KeepAlive" then
		BeamHandler.KeepAlive(player)
	elseif action == "ChargeBegin" then
		if coolingDown(player) or not canCastSpells(player) or not SpellStore.GetActive(player) then return end
		if chargeStart[player] and os.clock() - chargeStart[player] <= SpellRunes.Charge.StaleAfter then return end
		local record = SpellStore.GetActive(player)
		local compiled = record and compiledFor(record)
		if not compiled then return end
		local paid = 0
		if not SpellRunes.HasSustain(compiled) then
			-- (Sustain spells don't charge: they pay when cast)
			if not PlayerResources.Consume(player, "Mana", compiled.manaCost) then return end
			paid = compiled.manaCost
		end
		chargeStart[player] = os.clock()
		chargePaid[player] = paid
		circleBegin(player)
	elseif action == "ChargeCancel" then
		chargeStart[player] = nil
		chargePaid[player] = nil
		if circleOpen[player] then
			circleOpen[player] = nil
			circleClose(player, "Cancel")
		end
	elseif action == "Freeze" then
		freezeSpell(player, payload)
	elseif action == "FireFrozen" then
		if typeof(payload) == "Vector3" and not SafeMath.hasNaN(payload) and canCastSpells(player) then
			if not fireFrozen(player, SafeMath.vector(payload, Vector3.zero)) then rejectCast(player, player:GetAttribute("SpellFrozenSlot")) end
		else
			rejectCast(player)
		end
	end
end)

-- Runs one cast request; true when the spell went off (for the circle VFX).
local function castSpell(player: Player, rawTarget: any): boolean
	-- A NaN aim has no recoverable direction, so reject it; +-inf components
	-- clamp to SafeMath.Limit so an absurd aim still fires the way it points.
	if typeof(rawTarget) ~= "Vector3" or SafeMath.hasNaN(rawTarget) then
		return false
	end
	local targetPoint = SafeMath.vector(rawTarget, Vector3.zero)
	local allowed = canCastSpells(player)
	local character = player.Character
	local root = character and (character.PrimaryPart or character:FindFirstChild("HumanoidRootPart"))
	if not allowed or not character or not root or not root:IsA("BasePart") then
		return false
	end
	local record = SpellStore.GetActive(player)
	if not record then return false end
	local compiled = compiledFor(record)
	if not compiled then return false end

	local now = os.clock()
	if coolingDown(player) then return false end
	if SpellRuntime.IsSustaining(player) then return false end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return false end
	-- Sustain spells cast on press at full charge (holding channels them);
	-- everything else uses the timed hold, and a cast with no (or a stale)
	-- ChargeBegin counts as an instant click.
	local charge = 1
	if not SpellRunes.HasSustain(compiled) then
		local started = chargeStart[player]
		local held = if started then now - started else 0
		charge = if held > 0 and held <= SpellRunes.Charge.StaleAfter
			then SpellRunes.ChargeFromHold(held)
			else SpellRunes.Charge.Min
	end
	chargeStart[player] = nil
	-- what ChargeBegin prepaid (none for a Sustain spell or a click whose
	-- ChargeBegin never arrived: those pay for their charge here)
	local settled = settleCharge(player, compiled, charge, chargePaid[player] or 0)
	chargePaid[player] = nil
	if not settled then return false end
	charge = settled
	markCast(player, SpellStore.GetActiveSlot(player), compiled.manaCost * SpellRunes.ChargeEnergyMultiplier(charge))

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
		charge = charge,
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
	circleOpen[player] = nil
	VisualOffload.Fire("SpellCircle", {
		Phase = "Cast",
		Caster = character,
		Spec = circleSpecFor(record), -- lets a client that missed Begin still draw it
		Target = targetPoint,
		Charge = charge,
		Sustain = SpellRunes.HasSustain(compiled),
		ManaSpent = compiled.manaCost * SpellRunes.ChargeEnergyMultiplier(charge),
	})
	return true
end

cast.OnServerEvent:Connect(function(player: Player, rawTarget: any)
	if not castSpell(player, rawTarget) then
		chargePaid[player] = nil
		rejectCast(player)
		if circleOpen[player] then
			circleOpen[player] = nil
			chargeStart[player] = nil
			circleClose(player, "Cancel")
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	commandBusy[player] = nil
	liveAim[player] = nil
	lastCast[player] = nil
	chargeStart[player] = nil
	chargePaid[player] = nil
	lastCommand[player] = nil
	lastCommandWasSelection[player] = nil
	circleOpen[player] = nil
	lastCircleBegin[player] = nil
	frozenSpells[player] = nil
	aimSubscribers[player] = nil
	lastAimRelay[player] = nil
	shares[player] = nil
end)

print("[Relativity] spell service online")
