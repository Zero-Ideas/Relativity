--!strict
--[[
	SpellBody.luau (server)
	Body effects -- the Body Effect vessel (server/SpellRuntime decides the
	target, power and duration -- what the energy paid for; caps come from
	SpellRunes.Effects):

	 Heal      restores health now
	 Cleanse   ends Burn, Stun and every harmful body effect
	 Shield    a pool that soaks up damage until it's spent or runs out
	 Haste / Slow     walk speed (Slow also the jump) up / down
	 Root      can't walk or jump
	 Levitate  gravity almost off: floats
	 Empower / Weaken damage dealt up / damage taken up
	 Quicken / Dilate the body's own flow of time (Entity:SetTimeScale): it
	           moves, acts and shoots faster / slower

	Power is HP for Heal and Shield, and a percentage for the rest (Haste 50:
	walk x1.5; Slow 50: x0.5; Empower 30: +30% damage dealt; Weaken 30: +30%
	damage taken; Quicken / Dilate: the body's time x(1 +/- p)). Reapplying an
	effect keeps the stronger strength and the longer time; Shields stack.
	Effects run on world time where the body stands (not its own, so Quicken
	and Dilate don't stretch themselves). Harmful effects never land on
	someone your magic can't hurt (Entity.CanDamage: your party).

	How bodies change: Humanoid attributes SpellWalk / SpellJump (Entity
	reapplies its walk speed with them; a player's own client --
	client/SpellBodyClient -- applies them to its character), SpellLevitate
	(a lift force: the server's for NPCs, the client's for players), SpellTime
	(a player's client folds it into its personal time), plus damage modifiers
	on the entity. Visuals: VisualOffload "SpellFX" { Kind = "Effect" }.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChunkManager = require(Shared:WaitForChild("ChunkManager"))
local Entity = require(Shared:WaitForChild("Entity"))
local Heartbeat = require(Shared:WaitForChild("Heartbeat"))
local SpellRunes = require(Shared:WaitForChild("SpellRunes"))
local StatusEffectSys = require(Shared:WaitForChild("StatusEffectSys"))
local VisualOffload = require(Shared:WaitForChild("VisualOffload"))

local SpellBody = {}

local LEVITATE_LIFT = 0.92 -- share of gravity a levitating NPC's lift cancels
local HARMFUL = { "Slow", "Root", "Weaken", "Dilate" }

type Active = { strength: number, remaining: number, pool: number? }
type Body = {
	entity: any,
	effects: { [string]: Active },
	baseTime: number, -- the time scale it had before Quicken / Dilate
	timeTouched: boolean,
	connections: { any },
	lift: VectorForce?,
}

local bodies: { [any]: Body } = {}

local function alive(entity: any): boolean
	return typeof(entity) == "table" and not entity.IsDestroyed and (entity.Health == nil or entity.Health > 0)
end

local function strengthOf(body: Body, name: string): number
	local active = body.effects[name]
	return if active then active.strength else 0
end

local function playerOf(entity: any): Player?
	local character = entity.Instance
	return if character then Players:GetPlayerFromCharacter(character) else nil
end

-- Pushes the body's current effects onto its Humanoid / time scale.
local function refresh(body: Body)
	local entity = body.entity
	if entity.IsDestroyed then
		return
	end
	local humanoid: Humanoid? = entity.Humanoid
	local walk = (1 + strengthOf(body, "Haste")) * (1 - strengthOf(body, "Slow"))
	local jump = 1 - strengthOf(body, "Slow")
	if body.effects.Root then
		walk, jump = 0, 0
	end
	local levitating = body.effects.Levitate ~= nil
	local time = (1 + strengthOf(body, "Quicken")) * (1 - strengthOf(body, "Dilate"))
	if humanoid and humanoid.Parent then
		humanoid:SetAttribute("SpellWalk", if math.abs(walk - 1) > 1e-3 then walk else nil)
		humanoid:SetAttribute("SpellJump", if math.abs(jump - 1) > 1e-3 then jump else nil)
		humanoid:SetAttribute("SpellLevitate", if levitating then true else nil)
		humanoid:SetAttribute("SpellTime", if math.abs(time - 1) > 1e-3 then time else nil)
		if entity.RefreshMovement then
			entity:RefreshMovement()
		end
	end
	-- time: an NPC's own clock (a player's comes from their personal ratio)
	if math.abs(time - 1) > 1e-3 or body.timeTouched then
		if not body.timeTouched then
			local player = playerOf(entity)
			local personal = player and player:GetAttribute("PersonalTimeScale")
			body.baseTime = if typeof(personal) == "number" then personal else entity.TimeScale or 1
			body.timeTouched = true
		end
		entity:SetTimeScale(body.baseTime * time)
		if math.abs(time - 1) <= 1e-3 then
			body.timeTouched = false
		end
	end
	-- levitation: NPCs get their lift here (players' clients do their own)
	local root: BasePart? = entity._root
	if levitating and root and root.Parent and not playerOf(entity) then
		if not body.lift then
			local attachment = Instance.new("Attachment")
			attachment.Name = "SpellLift"
			attachment.Parent = root
			local force = Instance.new("VectorForce")
			force.Name = "SpellLift"
			force.Attachment0 = attachment
			force.RelativeTo = Enum.ActuatorRelativeTo.World
			force.ApplyAtCenterOfMass = true
			force.Parent = root
			body.lift = force
		end
		local lift = body.lift :: VectorForce
		lift.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity * LEVITATE_LIFT, 0)
	elseif body.lift then
		local attachment = body.lift.Attachment0
		body.lift:Destroy()
		if attachment then attachment:Destroy() end
		body.lift = nil
	end
end

local function release(body: Body)
	table.clear(body.effects)
	refresh(body)
	for _, connection in body.connections do
		connection:Disconnect()
	end
	bodies[body.entity] = nil
end

local function bodyOf(entity: any): Body
	local body = bodies[entity]
	if body then
		return body
	end
	local created: Body = {
		entity = entity,
		effects = {},
		baseTime = entity.TimeScale or 1,
		timeTouched = false,
		connections = {},
		lift = nil,
	}
	bodies[entity] = created
	-- incoming: Weaken makes it hurt more, then Shield soaks what it can
	table.insert(created.connections, entity:AddDamageModifier(function(amount: number)
		local weaken = strengthOf(created, "Weaken")
		amount *= 1 + weaken
		local shield = created.effects.Shield
		if shield and shield.pool and amount > 0 then
			local soaked = math.min(shield.pool, amount)
			shield.pool -= soaked
			amount -= soaked
			if shield.pool <= 1e-3 then
				created.effects.Shield = nil
				task.defer(refresh, created)
			end
		end
		return amount
	end))
	-- outgoing: Empower
	table.insert(created.connections, entity:AddOutgoingModifier(function(amount: number)
		return amount * (1 + strengthOf(created, "Empower"))
	end))
	table.insert(created.connections, entity.Destroyed:Connect(function()
		bodies[entity] = nil
	end))
	return created
end

-- Is `entity` under body effect `name` (Shield, Haste, Slow, Root,
-- Levitate, Empower, Weaken, Quicken, Dilate)?
function SpellBody.Has(entity: any, name: string): boolean
	local body = bodies[entity]
	return body ~= nil and body.effects[name] ~= nil
end

local function visual(entity: any, name: string, seconds: number, amount: number?)
	local instance = entity.Instance
	if not instance then
		return
	end
	local def = SpellRunes.Effects[name]
	VisualOffload.Fire("SpellFX", {
		Kind = "Effect",
		Target = instance,
		Effect = name,
		Duration = seconds,
		Amount = amount,
		Color = if def then def.Color else Color3.new(1, 1, 1),
	})
end

-- Applies body effect `name` to `target` at `power` (HP or percent, see
-- above) for `duration` seconds, cast by `caster`. Returns whether it took.
function SpellBody.Apply(caster: any, target: any, name: string, power: number, duration: number): boolean
	local def = SpellRunes.Effects[name]
	if not def or not alive(target) then
		return false
	end
	if not def.Helpful and target ~= caster and not Entity.CanDamage(caster, target) then
		return false -- (never on your party)
	end
	power = SpellRunes.EffectPower(name, power)
	local seconds = duration
	-- HP for Heal / Shield, a fraction for the rest; Timed effects are on/off
	local strength = if def.Kind == "Scale" then power / 100 elseif def.Kind == "Timed" then 1 else power
	if def.Kind ~= "Timed" and name ~= "Cleanse" and power <= 0 then
		return false
	end
	if name == "Heal" then
		target:Heal(strength)
		visual(target, name, 0.8, strength)
		return true
	elseif name == "Cleanse" then
		StatusEffectSys:RemoveEffect(target, "Burn")
		StatusEffectSys:RemoveEffect(target, "Stun")
		local body = bodies[target]
		if body then
			for _, harmful in HARMFUL do
				body.effects[harmful] = nil
			end
			refresh(body)
		end
		visual(target, name, 0.8)
		return true
	end
	if seconds <= 0 or strength <= 0 then
		return false
	end
	local body = bodyOf(target)
	local active = body.effects[name]
	if def.Kind == "Pool" then
		if active then
			active.pool = (active.pool or 0) + strength
			active.remaining = math.max(active.remaining, seconds)
		else
			body.effects[name] = { strength = 1, remaining = seconds, pool = strength }
		end
	elseif active then
		active.strength = math.max(active.strength, strength)
		active.remaining = math.max(active.remaining, seconds)
	else
		body.effects[name] = { strength = strength, remaining = seconds }
	end
	refresh(body)
	visual(target, name, seconds, if def.Kind == "Pool" then strength else nil)
	return true
end

-- Effects wear off on world time where the body stands.
Heartbeat.Connect(function(dt)
	for entity, body in bodies do
		if entity.IsDestroyed then
			bodies[entity] = nil
			continue
		end
		local scale = ChunkManager.GetTimeScaleAt(entity:GetPosition())
		local changed = false
		for name, active in body.effects do
			active.remaining -= dt * scale
			if active.remaining <= 0 then
				body.effects[name] = nil
				changed = true
			end
		end
		if changed then
			refresh(body)
		end
		if next(body.effects) == nil and not body.timeTouched and not body.lift then
			release(body)
		end
	end
end, { Name = "SpellBody", Priority = 5 })

-- A body that dies loses its effects (and its lift).
Players.PlayerRemoving:Connect(function(player)
	for entity, body in bodies do
		if entity.Instance == player.Character then
			release(body)
		end
	end
end)

return SpellBody
