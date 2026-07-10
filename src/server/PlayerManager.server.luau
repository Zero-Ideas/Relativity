--[[
	PlayerManager (server)
	Owns the link between player characters and the Entity system:
	 - registers every spawned character as an Entity (so projectiles can hit it
	   and homing can find it),
	 - tags it "Player" (the shooter's homing locks onto this tag alongside
	   "Enemy"),
	 - scales the character's Humanoid with time dilation inside slow chunks,
	 - destroys the PREVIOUS character's Entity registration on respawn/leave.

	Without this, raycasts that hit a player limb resolve to no entity (Entity.Get
	walks ancestors looking for one in byInstance -- see Entity.luau), so the
	Projectile system falls back to treating the hit as world geometry and never
	deals damage. It also leaves Projectile.Source nil for player-fired shots,
	which is what prevents homing from locking onto its own creator: acquireTarget
	and _resolveEntityHit both hard-exclude projectile.Source (see Projectile.luau),
	but that comparison is only meaningful once Source is a real entity -- which
	only happens once the firing character is registered here. CharacterAdded does
	NOT fire for a character that already exists at connection time (e.g. the
	solo-test host), so the initial player.Character check below is required, not
	optional -- skipping it leaves that player's Source nil for its entire first
	life, with nothing excluding its own hurtbox from its own raycasts.

	The stale-entity cleanup matters more than it looks: Entity.new only tears
	itself down automatically via the character instance's Destroying signal (see
	Entity.luau), but Roblox does NOT destroy a character's corpse on death by
	default -- it just sits in the workspace until the next respawn. DummyManager
	explicitly destroys its corpse in its Died handler for exactly this reason;
	without the equivalent here, every player death would leave a permanent ghost
	Entity behind -- still tagged "Player", still live in the spatial index and
	still hit/homing-testable -- at the death location, distinct from (and
	invisible to) the player's new Source. A shot fired near a spawn point that
	doubles as a death spot could then appear to "hit yourself" via that leftover
	corpse even though the raycast correctly excludes your CURRENT character.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Entity = require(Shared.Entity)

local Players = game:GetService("Players")

local playerEntities: { [Player]: any } = {} -- most recent Entity per player

local function registerCharacter(player: Player, character: Model)
	local previous = playerEntities[player]
	if previous and not previous.IsDestroyed then
		previous:Destroy() -- drop the old corpse from the hit/homing index
	end

	local entity = Entity.new(character, {
		ScaleHumanoid = true, -- moves in dilated time inside slow chunks
	})
	entity:AddTag("Player") -- homing targets this tag

	-- Reapply this player's own personal time ratio (see
	-- example/init.server.luau's "RequestPersonalTimeScale" handler) -- a
	-- fresh Entity otherwise starts at 1x, silently resetting it on every
	-- respawn even though the client's slider still shows the old value.
	entity:SetTimeScale(player:GetAttribute("PersonalTimeScale") or 1)

	playerEntities[player] = entity
end

local function onPlayer(player: Player)
	-- CharacterAdded does not fire for a character that already exists at
	-- connection time (e.g. the solo-test host), so register it explicitly and
	-- then connect for subsequent respawns.
	if player.Character then
		registerCharacter(player, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		registerCharacter(player, character)
	end)
end

for _, player in Players:GetPlayers() do
	onPlayer(player)
end
Players.PlayerAdded:Connect(onPlayer)

Players.PlayerRemoving:Connect(function(player)
	local entity = playerEntities[player]
	if entity and not entity.IsDestroyed then
		entity:Destroy()
	end
	playerEntities[player] = nil
end)

print("[Relativity] player manager online")
