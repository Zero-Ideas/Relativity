--!optimize 2
--[[
	Entity.luau
	Turns any Model / BasePart / Humanoid rig — or nothing at all — into an
	entity with Entity.new(). Entities carry arbitrary custom variables and
	functions, a damage pipeline with stackable modifiers, tags, per-entity
	time scale, and automatic spatial chunk membership.

	Time model (per entity):
	   effectiveScale = Heartbeat global scale * chunk scale * entity.TimeScale
	OnUpdate callbacks receive a dt already dilated by all three. Entities in
	frozen (unloaded) chunks are skipped entirely.

	API summary:
	 Entity.new(instance?, props?) -> entity
	 Entity.Get(instance) -> entity?          (walks up ancestors)
	 Entity.GetAll() -> {entity}
	 Entity.GetTagged(tag) -> {entity}

	 entity:GetPosition() / :SetPosition(pos)   (SetPosition for data-only entities)
	 entity:GetPositionAt(realTime) -> Vector3  (rewound position; see history below)
	 entity:OnUpdate(fn(dt, entity)) -> connection-like {Disconnect}
	 entity:SetTimeScale(scale) / :GetEffectiveTimeScale()
	 entity:RefreshMovement()                 (reapply walk/jump after a Humanoid
	                                         SpellWalk / SpellJump attribute change)
	 entity:AddTag(tag) / :RemoveTag(tag) / :HasTag(tag)
	 entity:AddDamageModifier(fn) / :AddOutgoingModifier(fn) -> {Disconnect}
	 entity:TakeDamage(amount, info?) -> finalAmount
	 entity:DealDamage(target, amount, info?) -> finalAmount
	 entity:Heal(amount)
	 entity:IsActive() -> boolean            (false when chunk-frozen or destroyed)
	 Entity.RespawnDelay / Entity.SetRespawnHandler(fn)  -- forced respawn after
	                                         death; see "Forced respawn" below
	 entity:GetChunk() -> Chunk?
	 entity:Destroy()

	 Hurtbox debug visualization: set Entity.ShowHurtboxes = true (or call
	 Entity.SetShowHurtboxes(true)) to stream every entity's HitboxRadius sphere to
	 clients; call Entity.EnableHurtboxRendering() once on the client to draw them.
	 Entity.ShowHurtboxHistory = true (+ Entity.EnableHurtboxHistoryRendering() on
	 the client) shows the ENTIRE retained history as a trail of hurtboxes, colored
	 green while a sample is still within HurtboxValidWindow (fresh enough to be
	 usable for lag compensation) and red once it's older than that.

	 Signals: entity.Damaged(amount, info), entity.Died(info?),
	          entity.ChunkChanged(newChunk, oldChunk), entity.Destroyed()

	 Config props (all optional, passed in `props`; everything else in props is
	 copied onto the entity as custom data):
	   Health / MaxHealth (numbers)
	   HitboxRadius (number, default 2 — Body/Torso hurtbox radius)
	   HeadRadius (number, default Entity.HeadRadius — Head hurtbox radius)
	   HeadshotMultiplier (number, default Entity.HeadshotMultiplier)
	   HeadOffset / BodyOffset (Vector3, default zero — manual nudge on top of
	              the auto-calibrated Head position / the root position, for
	              rigs where the automatic placement isn't quite right)
	   TimeScale (number, default 1)
	   ScaleHumanoid (boolean — scale WalkSpeed/JumpPower with time dilation)
	   DestroyOnDeath (boolean — auto :Destroy() when Died fires)
	   Team / anything else -> stored as custom variables

	 Head + Body hurtboxes: purely data, no extra Instances -- every humanoid
	 entity has an independent Head sphere (radius HeadRadius) and Body sphere
	 (radius HitboxRadius), see entity:GetHeadPosition() / :GetBodyPosition()
	 (live) and :GetHeadPositionAt(t) / :GetBodyPositionAt(t) (rewound). The
	 two spheres are NOT required to nest or overlap -- HeadRadius,
	 HitboxRadius, HeadOffset and BodyOffset are independent knobs, each
	 applied as configured with no cross-clamping (an earlier version
	 auto-clamped HeadRadius to force geometric nesting; that was removed --
	 it existed only to support a since-abandoned physical-raycast design and
	 was silently zeroing HeadRadius out for any BodyOffset/HitboxRadius
	 combination it didn't like). Projectile.luau's lag-compensated rewind
	 check tests both spheres directly against these positions (Head first);
	 its live raycast path classifies a hit as "Head" by checking whether the
	 hit point falls within HeadRadius of GetHeadPosition() (real rig
	 geometry is untouched -- no CanQuery/CollisionGroup tricks, since
	 CollisionGroup-based hiding was tried and reverted after it broke
	 player-vs-floor collision).

	 Last grounded position (server): every living humanoid entity remembers
	 where it last stood on solid ground -- entity.LastGroundedCFrame (its
	 root's CFrame then) / entity.LastGroundedPosition, checked every
	 Entity.GroundCheckInterval seconds (the Humanoid has a floor and a short
	 ray down hits something). If it ever falls below Entity.VoidHeight it's
	 put back there, stopped, and entity.RescuedFromVoid fires. Set
	 Entity.VoidRescue = false to turn that off.

	 Position history (for lag-compensated hit detection, see Projectile.luau):
	 every entity's real-world position is sampled on a real-time (not dilated)
	 cadence and kept for Entity.HistoryWindow seconds, so entity:GetPositionAt(t)
	 can answer "where was this entity at real time t". Sampling is throttled by
	 Entity.HistorySnapshotInterval and skipped when the entity hasn't moved at
	 least Entity.HistoryMinDelta studs, so a stationary entity's buffer stays tiny.
]]

local RunService = game:GetService("RunService")
local FrameProfiler = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("FrameProfiler"))
local Players = game:GetService("Players")

local Heartbeat = require(script.Parent.Heartbeat)
local ChunkManager = require(script.Parent.ChunkManager)
local Signal = require(script.Parent.Signal)
local VisualOffload = require(script.Parent.VisualOffload)

local Entity = {}
Entity.__index = Entity

-- Position-history tuning (real seconds, not dilated) -- see GetPositionAt below.
Entity.PositionVersion = 0 -- invalidates frame-shared rewind broadphases
Entity.HistoryWindow = 0.5 -- how far back samples are retained
Entity.HistorySnapshotInterval = 0.01 -- minimum real time between recorded samples
Entity.HistoryMinDelta = 0.5 -- studs; skip recording if barely moved since the last sample

-- Void rescue (server): below VoidHeight an entity goes back to where it last
-- stood (see "Last grounded position" above).
Entity.VoidHeight = -27
Entity.VoidRescue = true
Entity.GroundCheckInterval = 0.1 -- seconds between grounded checks / void checks
Entity.GroundProbe = 4 -- studs below the feet the ground ray reaches

-- Debug: when true, every entity's hurtbox (HitboxRadius sphere) is streamed to
-- clients and rendered as a translucent sphere. Flip this constant directly (or
-- call Entity.SetShowHurtboxes(true) at runtime) -- no keybind needed.
Entity.ShowHurtboxes = false

-- Debug: when true, the FULL position history of every entity streams to clients
-- as a trail of hurtboxes (see EnableHurtboxHistoryRendering). Independent of
-- ShowHurtboxes above, which only shows the single live hurtbox.
Entity.ShowHurtboxHistory = false

-- How recent (real seconds) a history sample must be to render green ("valid" --
-- still fresh enough to matter for lag-compensated hit detection) rather than red
-- ("stale" -- retained for GetPositionAt's interpolation, but old). Matches this
-- project's Shooter.server.luau MAX_REWIND by default so the debug view reflects
-- what's actually usable; tune to taste if that budget changes.
Entity.HurtboxValidWindow = 0.3

-- Head hurtbox defaults (see the module doc comment's "Hurtbox debug
-- visualization" section and GetHeadPosition/GetBodyPosition below). Copied
-- onto each entity at construction (like HitboxRadius already is), so a
-- prop override (props.HeadRadius / props.HeadshotMultiplier) still works
-- per-entity without touching these globals.
Entity.HeadRadius = 1.5 -- studs; independent of HitboxRadius, no nesting requirement
Entity.HeadshotMultiplier = 2 -- damage multiplier applied by Shooter.server.luau on a Head hit

-- Forced respawn (server only): every entity that dies is respawned this many
-- REAL seconds later -- real, not dilated, so a frozen chunk can't keep anyone
-- dead -- by the first of:
--   1. the handler from Entity.SetRespawnHandler(fn(entity) -> boolean?),
--      if it returns true;
--   2. player characters: player:LoadCharacter(), unless the player has
--      already respawned (their Character is no longer the dead one);
--   3. an entity with a Respawn function prop: entity:Respawn();
--   4. data-only entities (no Humanoid): revived in place at MaxHealth.
-- Humanoid NPCs need 1 or 3 (a dead Humanoid can't be revived in place).
-- Set Entity.RespawnDelay = nil to turn forced respawn off.
Entity.RespawnDelay = 5 :: number?
local respawnHandler: ((any) -> boolean?)? = nil
local deathHandler: ((any, any?) -> ())? = nil

-- Server-owned physical death behavior, without coupling shared Entity to
-- a server-only ragdoll module. Runs before entity-specific death listeners.
function Entity.SetDeathHandler(fn: ((any, any?) -> ())?)
	deathHandler = fn
end

function Entity.SetRespawnHandler(fn: ((any) -> boolean?)?)
	respawnHandler = fn
end

local entities = {} -- flat array for fast iteration
local entityIndex = {} -- [entity] = array index (O(1) swap-remove)
local byInstance: { [Instance]: any } = {}
local byTag: { [string]: { [any]: boolean } } = {}
local nextId = 0

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local RESERVED = {
	Instance = true,
	Humanoid = true,
	Id = true,
	Damaged = true,
	Died = true,
	ChunkChanged = true,
	Destroyed = true,
}

function Entity.new(instance: Instance?, props: { [string]: any }?)
	-- Idempotent: a second registration of the SAME instance returns the
	-- existing entity instead of creating a duplicate. Without this, the newer
	-- entity wins byInstance (Entity.Get resolves to it), but the older one is
	-- STILL in chunk.Entities, still tagged, still bound to the same Humanoid --
	-- a "ghost" that Projectile.Source (which points at the new entity) can't
	-- reference-equal against, so the projectile's self-exclusion in acquireTarget
	-- / _resolveEntityHit fails and it homes onto / damages its own creator.
	-- Any re-registration path (CharacterAdded/PlayerAdded timing, respawn,
	-- double-connect) converges to one live entity instead.
	if instance ~= nil and byInstance[instance] then
		return byInstance[instance]
	end

	nextId += 1
	local self = setmetatable({
		Id = nextId,
		Instance = instance,
		Humanoid = nil,
		Health = 100,
		MaxHealth = 100,
		HitboxRadius = 2,
		HeadRadius = Entity.HeadRadius,
		HeadshotMultiplier = Entity.HeadshotMultiplier,
		HeadOffset = Vector3.zero, -- manual nudge on top of the auto-calibrated head offset
		BodyOffset = Vector3.new(0, -1, 0), -- manual nudge on top of the root position
		TimeScale = 1,
		ScaleHumanoid = false,
		DestroyOnDeath = false,
		IsDestroyed = false,

		Damaged = Signal.new(),
		Died = Signal.new(),
		ChunkChanged = Signal.new(),
		Destroyed = Signal.new(),
		RescuedFromVoid = Signal.new(),

		LastGroundedCFrame = nil :: CFrame?, -- (server) the root's CFrame when last on solid ground
		LastGroundedPosition = nil :: Vector3?,

		_position = Vector3.zero, -- used when there is no instance
		_root = nil :: BasePart?,
		_headOffset = nil :: Vector3?, -- auto-calibrated Head-relative-to-root offset; nil if no Head part
		_chunk = nil,
		_updateFns = {},
		_damageModifiers = {},
		_outgoingModifiers = {},
		_tags = {},
		_baseWalkSpeed = nil,
		_baseJumpPower = nil,
		_lastHumanoidScale = 1,
		_instanceConnections = {},
		_history = {}, -- chronological { {Time, Position}, ... }; see GetPositionAt
		_lastSnapshotTime = -math.huge,
	}, Entity)

	-- resolve physical root + humanoid
	if instance then
		if instance:IsA("BasePart") then
			self._root = instance
		elseif instance:IsA("Model") then
			local humanoid = instance:FindFirstChildOfClass("Humanoid")
			self._root = instance.PrimaryPart
				or (humanoid and instance:FindFirstChild("HumanoidRootPart") :: BasePart?)
				or instance:FindFirstChildWhichIsA("BasePart", true)
			if humanoid then
				if RunService:IsServer() then humanoid.BreakJointsOnDeath = false end
				self.Humanoid = humanoid
				self.Health = humanoid.Health
				self.MaxHealth = humanoid.MaxHealth
				self._baseWalkSpeed = humanoid.WalkSpeed
				self._baseJumpPower = humanoid.UseJumpPower and humanoid.JumpPower or humanoid.JumpHeight
				self._root = humanoid.RootPart

				-- Auto-calibrated Head offset, measured once at spawn (see
				-- entity:GetHeadPosition() / HeadOffset). Self-calibrates to
				-- whatever rig/scale this instance actually has instead of a
				-- hardcoded magic number. Bounded WaitForChild, not a plain
				-- FindFirstChild -- a live player's accessories/appearance can
				-- still be streaming in when CharacterAdded fires (the same
				-- class of race humanoid.RootPart above already guards
				-- against for the root), so Head may not exist on the very
				-- first frame yet.
				local head = instance:FindFirstChild("Head") or instance:WaitForChild("Head", 2)
				if head and head:IsA("BasePart") and self._root then
					self._headOffset = head.Position - self._root.Position
				end

				table.insert(
					self._instanceConnections,
					humanoid.HealthChanged:Connect(function(health)
						self.Health = health
						-- Some deaths (e.g. Health set to 0 server-side on a
						-- client-owned character) never fire Died here; a
						-- health of 0 is a death either way. _handleDeath is
						-- idempotent.
						if health <= 0 then
							self:_handleDeath(nil)
						end
					end)
				)
				table.insert(
					self._instanceConnections,
					humanoid.Died:Connect(function()
						self:_handleDeath(nil)
					end)
				)
			end
		end
		byInstance[instance] = self
		table.insert(
			self._instanceConnections,
			instance.Destroying:Connect(function()
				self:Destroy()
			end)
		)
	end

	-- merge custom props (variables AND functions) onto the entity
	if props then
		for key, value in props do
			if RESERVED[key] then
				warn(`[Entity] prop "{key}" is reserved and was ignored`)
			else
				self[key] = value
			end
		end
		if props.Health and not props.MaxHealth then
			self.MaxHealth = props.Health
		end
	end

	-- registry + initial chunk
	table.insert(entities, self)
	Entity.PositionVersion += 1
	entityIndex[self] = #entities
	self._chunk = ChunkManager._addEntity(self, self:GetPosition())

	return self
end

-- Finds the entity owning `instance`, walking up the ancestor chain
-- (so a raycast hitting a limb resolves to the character's entity).
function Entity.Get(instance: Instance?)
	while instance do
		local entity = byInstance[instance]
		if entity then
			return entity
		end
		instance = instance.Parent
	end
	return nil
end

function Entity.GetAll()
	return table.clone(entities)
end

function Entity.GetTagged(tag: string)
	local result = {}
	local set = byTag[tag]
	if set then
		for entity in set do
			table.insert(result, entity)
		end
	end
	return result
end

--------------------------------------------------------------------------------
-- Position & chunks
--------------------------------------------------------------------------------

-- Binary search over a chronologically-ordered history array: returns the index
-- of the last sample with Time <= target, or 0 if every sample is newer.
local function findBeforeIndex(history: { any }, target: number): number
	local lo, hi = 1, #history
	local result = 0
	while lo <= hi do
		local mid = (lo + hi) // 2
		if history[mid].Time <= target then
			result = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	return result
end

-- Records a position sample for lag-compensated rewinding, throttled by
-- HistorySnapshotInterval and skipped if the entity barely moved since its last
-- sample. `now` is real time (os.clock()), not dilated Heartbeat time.
function Entity:_recordPositionSnapshot(now: number)
	if now - self._lastSnapshotTime < Entity.HistorySnapshotInterval then
		return
	end
	self._lastSnapshotTime = now

	local history = self._history
	local position = self:GetPosition()
	local last = history[#history]
	if last and (position - last.Position).Magnitude < Entity.HistoryMinDelta then
		return -- hasn't moved enough to justify a new sample
	end

	table.insert(history, { Time = now, Position = position })
	while history[1] and history[1].Time < now - Entity.HistoryWindow do
		table.remove(history, 1)
	end
end

-- Where was this entity at real time `time` (an os.clock() value)? Interpolates
-- between the two recorded samples bracketing `time`, falls back to the live
-- position for times at/after "now" (or if no history exists), and clamps to
-- the oldest sample for times older than the retained window.
function Entity:GetPositionAt(time: number): Vector3
	local history = self._history
	local now = os.clock()
	if #history == 0 or time >= now then
		return self:GetPosition()
	end

	local idx = findBeforeIndex(history, time)
	if idx == 0 then
		return history[1].Position -- predates all history; clamp to oldest
	end

	local before = history[idx]
	local after = history[idx + 1] or { Time = now, Position = self:GetPosition() }
	local span = after.Time - before.Time
	local alpha = span > 1e-6 and math.clamp((time - before.Time) / span, 0, 1) or 0
	return before.Position:Lerp(after.Position, alpha)
end

-- Rewound Body hurtbox center at real time `time` -- GetPositionAt() plus
-- the manual BodyOffset nudge, matching GetBodyPosition()'s live equivalent.
function Entity:GetBodyPositionAt(time: number): Vector3
	return self:GetPositionAt(time) + self.BodyOffset
end

-- Rewound Head hurtbox center at real time `time`, or nil if this entity has
-- no Head hurtbox. Only the tracked root position is actually rewound; the
-- auto-calibrated/manual offsets are applied on top of that (rotation isn't
-- tracked, matching the rest of this system) -- same approximation as the
-- live GetHeadPosition().
function Entity:GetHeadPositionAt(time: number): Vector3?
	local headOffset = self._headOffset
	if not headOffset then
		return nil
	end
	return self:GetPositionAt(time) + headOffset + self.HeadOffset
end

function Entity:GetPosition(): Vector3
	local root = self._root
	if root and root.Parent then
		return root.Position
	end
	local instance = self.Instance
	if instance and instance:IsA("Model") and instance.Parent then
		return instance:GetPivot().Position
	end
	return self._position
end

function Entity:SetPosition(position: Vector3)
	Entity.PositionVersion += 1
	if self._root then
		self._root.Position = position
	else
		self._position = position
	end
end

-- Center of the Body/Torso hurtbox -- GetPosition() plus the manual nudge
-- (BodyOffset). This is what the Body hurtbox sphere (live + debug) and
-- Projectile.luau's rewind check use; unrelated systems (homing, AOE,
-- ChunkManager) keep using plain GetPosition().
function Entity:GetBodyPosition(): Vector3
	return self:GetPosition() + self.BodyOffset
end

-- Center of the Head hurtbox, or nil if this entity has no Head part (a
-- non-humanoid entity, or a humanoid rig with no Head child at construction
-- time). GetPosition() plus the auto-calibrated offset plus the manual
-- nudge (HeadOffset).
function Entity:GetHeadPosition(): Vector3?
	local headOffset = self._headOffset
	if not headOffset then
		return nil
	end
	return self:GetPosition() + headOffset + self.HeadOffset
end

function Entity:GetChunk()
	return self._chunk
end

function Entity:IsActive(): boolean
	if self.IsDestroyed then
		return false
	end
	local chunk = self._chunk
	return chunk == nil or ChunkManager.IsChunkActive(chunk)
end

--------------------------------------------------------------------------------
-- Time dilation
--------------------------------------------------------------------------------

function Entity:SetTimeScale(scale: number)
	self.TimeScale = math.max(scale, 0)
	self:_refreshHumanoidScale()
end

function Entity:GetEffectiveTimeScale(): number
	return Heartbeat.GetGlobalTimeScale() * ChunkManager.GetTimeScaleAt(self:GetPosition()) * self.TimeScale
end

-- New undilated walk speed / jump power (e.g. server PlayerDefaults
-- changing mid-life); reapplied at the current time scale right away.
function Entity:SetMovementBase(walkSpeed: number, jumpPower: number)
	self._baseWalkSpeed = walkSpeed
	self._baseJumpPower = jumpPower
	self._lastHumanoidScale = nil
	self:_refreshHumanoidScale()
end

function Entity:_refreshHumanoidScale()
	if not self.ScaleHumanoid then
		return
	end
	local humanoid = self.Humanoid
	if not humanoid or not humanoid.Parent then
		return
	end
	local scale = self:GetEffectiveTimeScale()
	if scale == self._lastHumanoidScale then
		return
	end
	self._lastHumanoidScale = scale
	-- SpellWalk / SpellJump: body-effect multipliers (server/SpellBody: Haste,
	-- Slow, Root); a player's own client applies them to its character too
	local spellWalk = humanoid:GetAttribute("SpellWalk")
	local spellJump = humanoid:GetAttribute("SpellJump")
	local walk = if typeof(spellWalk) == "number" then spellWalk else 1
	local jump = if typeof(spellJump) == "number" then spellJump else 1
	humanoid.WalkSpeed = (self._baseWalkSpeed or 16) * (humanoid:GetAttribute("SprintMultiplier") or 1) * walk * scale
	if humanoid.UseJumpPower then
		humanoid.JumpPower = (self._baseJumpPower or 50) * jump * scale
	else
		-- jump height scales with time² (h = v²/2g with both v and g dilated)
		humanoid.JumpHeight = (self._baseJumpPower or 7.2) * jump * jump * scale * scale
	end
end

-- Reapplies walk speed / jump now (after the Humanoid's SpellWalk /
-- SprintMultiplier attributes changed), not just on the next time-scale change.
function Entity:RefreshMovement()
	self._lastHumanoidScale = nil
	self:_refreshHumanoidScale()
end

--------------------------------------------------------------------------------
-- Tags
--------------------------------------------------------------------------------

function Entity:AddTag(tag: string)
	if self._tags[tag] then
		return
	end
	self._tags[tag] = true
	local set = byTag[tag]
	if not set then
		set = {}
		byTag[tag] = set
	end
	set[self] = true
end

function Entity:RemoveTag(tag: string)
	if not self._tags[tag] then
		return
	end
	self._tags[tag] = nil
	local set = byTag[tag]
	if set then
		set[self] = nil
	end
end

function Entity:HasTag(tag: string): boolean
	return self._tags[tag] == true
end

--------------------------------------------------------------------------------
-- Damage pipeline
--------------------------------------------------------------------------------

local function addModifier(list, fn)
	table.insert(list, fn)
	return {
		Disconnect = function()
			local idx = table.find(list, fn)
			if idx then
				table.remove(list, idx)
			end
		end,
	}
end

-- Incoming: fn(amount, info, entity) -> newAmount. Runs on :TakeDamage().
function Entity:AddDamageModifier(fn: (amount: number, info: any, entity: any) -> number)
	return addModifier(self._damageModifiers, fn)
end

-- Outgoing: fn(amount, info, entity, target) -> newAmount. Runs on :DealDamage().
function Entity:AddOutgoingModifier(fn: (amount: number, info: any, entity: any, target: any) -> number)
	return addModifier(self._outgoingModifiers, fn)
end

-- Global gate over every hit: fn(source, target) -> false blocks the damage
-- (server/Parties uses it so party members can't hurt each other).
local damageGate: ((source: any, target: any) -> boolean)? = nil

function Entity.SetDamageGate(fn: ((source: any, target: any) -> boolean)?)
	damageGate = fn
end

-- Whether `source` (an Entity, Player or nil) may damage `target`.
function Entity.CanDamage(source: any, target: any): boolean
	return source == nil or damageGate == nil or damageGate(source, target)
end

-- info is a free-form table (e.g. { Type = "Fire", Source = attacker, Crit = true }).
function Entity:TakeDamage(amount: number, info: any?): number
	if self.IsDestroyed or self.Health <= 0 then
		return 0
	end
	info = info or {}
	if not Entity.CanDamage(info.Source, self) then
		return 0
	end

	for _, modifier in self._damageModifiers do
		amount = modifier(amount, info, self)
		if amount <= 0 then
			return 0
		end
	end

	local humanoid = self.Humanoid
	if humanoid and humanoid.Parent then
		local before = humanoid.Health
		humanoid:TakeDamage(amount) -- respects ForceFields
		amount = before - humanoid.Health
		self.Health = humanoid.Health
	else
		amount = math.min(amount, self.Health)
		self.Health -= amount
	end

	if amount > 0 then
		self.Damaged:Fire(amount, info)
	end
	if self.Health <= 0 and not humanoid then
		self:_handleDeath(info)
	end
	return amount
end

function Entity:DealDamage(target: any, amount: number, info: any?): number
	info = info or {}
	info.Source = info.Source or self
	for _, modifier in self._outgoingModifiers do
		amount = modifier(amount, info, self, target)
		if amount <= 0 then
			return 0
		end
	end
	return target:TakeDamage(amount, info)
end

function Entity:Heal(amount: number)
	local humanoid = self.Humanoid
	if humanoid and humanoid.Parent then
		humanoid.Health = math.min(humanoid.Health + amount, humanoid.MaxHealth)
		self.Health = humanoid.Health
	else
		self.Health = math.min(self.Health + amount, self.MaxHealth)
	end
end

local function respawn(entity)
	local instance = entity.Instance
	print(`[Entity][respawn-debug] timer fired for {instance and instance:GetFullName() or "data entity"} #{entity.Id}`) -- TEMP
	if respawnHandler and respawnHandler(entity) == true then
		return
	end
	-- Resolves only while this is still the player's current character, so a
	-- player who already respawned (Roblox's own timer, a reset) is skipped.
	local player = instance and Players:GetPlayerFromCharacter(instance)
	print(`[Entity][respawn-debug] player={player} currentCharacterIsDead={player and player.Character == instance}`) -- TEMP
	if player then
		if player.Parent then
			player:LoadCharacter()
			print(`[Entity][respawn-debug] LoadCharacter called for {player.Name}`) -- TEMP
		end
		return
	end
	local custom = entity.Respawn
	if typeof(custom) == "function" then
		custom(entity)
		return
	end
	-- A dead Humanoid can't be revived in place: an old (already replaced)
	-- player character or an NPC without a Respawn prop is left alone.
	if not entity.Humanoid and not entity.IsDestroyed then
		entity.Health = entity.MaxHealth
		entity._dead = false
	end
end

function Entity:_handleDeath(info: any?)
	if self._dead then
		return
	end
	self._dead = true
	if RunService:IsServer() and deathHandler then
		local ok, err = pcall(deathHandler, self, info)
		if not ok then warn("[Entity] death handler failed: " .. tostring(err)) end
	end
	self.Died:Fire(info)
	print(`[Entity][respawn-debug] death detected: {self.Instance and self.Instance:GetFullName() or "data entity"} #{self.Id} server={RunService:IsServer()} delay={Entity.RespawnDelay}`) -- TEMP

	local delay = Entity.RespawnDelay
	if delay and RunService:IsServer() then
		task.delay(delay, respawn, self)
	end

	if self.DestroyOnDeath then
		self:Destroy()
	end
end

--------------------------------------------------------------------------------
-- Per-entity update callbacks (driven by one shared heartbeat connection)
--------------------------------------------------------------------------------

function Entity:OnUpdate(fn: (dt: number, entity: any) -> ())
	local fns = self._updateFns
	table.insert(fns, fn)
	return {
		Disconnect = function()
			local idx = table.find(fns, fn)
			if idx then
				local n = #fns
				fns[idx] = fns[n]
				fns[n] = nil
			end
		end,
	}
end

--------------------------------------------------------------------------------
-- Destruction
--------------------------------------------------------------------------------

function Entity:Destroy()
	if self.IsDestroyed then
		return
	end
	self.IsDestroyed = true
	Entity.PositionVersion += 1

	local idx = entityIndex[self]
	if idx then
		local last = #entities
		local moved = entities[last]
		entities[idx] = moved
		entities[last] = nil
		entityIndex[moved] = idx ~= last and idx or nil
		entityIndex[self] = nil
	end

	ChunkManager._removeEntity(self, self._chunk)
	self._chunk = nil

	for tag in self._tags do
		local set = byTag[tag]
		if set then
			set[self] = nil
		end
	end

	if self.Instance then
		byInstance[self.Instance] = nil
	end
	for _, connection in self._instanceConnections do
		connection:Disconnect()
	end
	table.clear(self._instanceConnections)
	table.clear(self._updateFns)

	self.Destroyed:Fire()
	self.Damaged:Destroy()
	self.Died:Destroy()
	self.ChunkChanged:Destroy()
	self.Destroyed:Destroy()
end

--------------------------------------------------------------------------------
-- System loops
--------------------------------------------------------------------------------

-- Frame loop: run OnUpdate callbacks with fully-dilated dt.
-- dt here is already global-scaled by the Heartbeat.
Heartbeat.Connect(function(dt)
	for i = 1, #entities do
		local entity = entities[i]
		local fns = entity._updateFns
		if #fns > 0 then
				local chunk = entity._chunk
				if chunk == nil or ChunkManager.IsChunkActive(chunk) then
					local scale = ChunkManager.GetTimeScaleAt(entity:GetPosition()) * entity.TimeScale
				if scale > 0 then
					local entityDt = dt * scale
					for j = 1, #fns do
						fns[j](entityDt, entity)
					end
				end
			end
		end
	end
end, { Name = "EntitySystem.Update", Priority = 0 })

-- History loop: real-time (not dilated) position sampling for lag-compensated
-- hit detection (see Projectile.luau). Runs every real frame -- the callback
-- ignores `dt` and reads os.clock() directly, since real network latency
-- doesn't scale with in-game time dilation. Each entity's own throttling
-- (HistorySnapshotInterval / HistoryMinDelta) keeps the actual recording cost low.
Heartbeat.Connect(function()
	local now = os.clock()
	for i = 1, #entities do
		local entity = entities[i]
		local chunk = entity._chunk
		if chunk == nil or ChunkManager.IsChunkActive(chunk) then
			entity:_recordPositionSnapshot(now)
		end
	end
end, { Name = "EntitySystem.History", Priority = -60 })

-- Grounding loop (server): remembers where each humanoid entity last stood on
-- solid ground, and puts it back there if it falls below VoidHeight.
if RunService:IsServer() then
	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	groundParams.IgnoreWater = false
	local function rescue(entity: any, root: BasePart)
		local target = entity.LastGroundedCFrame :: CFrame
		local model = entity.Instance
		-- (a little above where it stood, so it doesn't land inside the floor)
		local lifted = target + Vector3.new(0, 0.5, 0)
		if model and model:IsA("Model") then
			local offset = root.CFrame:ToObjectSpace(model:GetPivot())
			model:PivotTo(lifted * offset)
		else
			root.CFrame = lifted
		end
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		print(`[Entity] {model and model:GetFullName() or "entity"} fell below Y={Entity.VoidHeight}; returned to its last grounded position {target.Position}`)
		entity.RescuedFromVoid:Fire(target)
	end
	-- (real time, not dilated: a frozen or slowed world doesn't stop a fall)
	local sinceCheck = 0
	FrameProfiler.Connect(RunService.Heartbeat, "Entity.Heartbeat", function(dt: number)
		sinceCheck += dt
		if sinceCheck < Entity.GroundCheckInterval then
			return
		end
		sinceCheck = 0
		for i = 1, #entities do
			local entity = entities[i]
			local humanoid = entity.Humanoid
			local root = entity._root
			if entity.IsDestroyed or not humanoid or not root or not root.Parent or humanoid.Health <= 0 then
				continue
			end
			local position = root.Position
			if position.Y < Entity.VoidHeight then
				if Entity.VoidRescue and entity.LastGroundedCFrame then
					rescue(entity, root)
				end
				continue
			end
			if humanoid.FloorMaterial == Enum.Material.Air then
				continue
			end
			-- (the floor must really be there: a ray from the root to just past the feet)
			groundParams.FilterDescendantsInstances = { entity.Instance or root }
			local reach = humanoid.HipHeight + root.Size.Y * 0.5 + Entity.GroundProbe
			local hit = workspace:Raycast(position, Vector3.new(0, -reach, 0), groundParams)
			if hit and hit.Position.Y >= Entity.VoidHeight then
				entity.LastGroundedCFrame = root.CFrame
				entity.LastGroundedPosition = position
			end
		end
	end)
end

-- Slow loop: re-bucket moved entities into chunks, refresh humanoid dilation.
Heartbeat.ConnectInterval(0.1, function()
	for i = 1, #entities do
		local entity = entities[i]
		local newChunk, changed = ChunkManager._updateEntity(entity, entity._chunk, entity:GetPosition())
		if changed then
			local oldChunk = entity._chunk
			entity._chunk = newChunk
			entity.ChunkChanged:Fire(newChunk, oldChunk)
		end
		entity:_refreshHumanoidScale()
	end
end, { Name = "EntitySystem.ChunkTracking", Priority = -50 })

--------------------------------------------------------------------------------
-- Hurtbox debug visualization
--------------------------------------------------------------------------------

function Entity.SetShowHurtboxes(enabled: boolean)
	Entity.ShowHurtboxes = enabled and true or false
	if RunService:IsServer() and not Entity.ShowHurtboxes then
		VisualOffload.Fire("HurtboxSnapshot", {}) -- clear any spheres already drawn
	end
end

function Entity.SetShowHurtboxHistory(enabled: boolean)
	Entity.ShowHurtboxHistory = enabled and true or false
	if RunService:IsServer() and not Entity.ShowHurtboxHistory then
		VisualOffload.Fire("HurtboxHistorySnapshot", {}) -- clear any trails already drawn
	end
end

if RunService:IsServer() then
	task.spawn(function()
		while true do
			if Entity.ShowHurtboxes then
				local snapshot = {}
				for i = 1, #entities do
					local entity = entities[i]
					if not entity.IsDestroyed then
						table.insert(snapshot, {
							Id = entity.Id,
							Position = entity:GetBodyPosition(),
							Radius = entity.HitboxRadius,
							HeadPosition = entity:GetHeadPosition(),
							HeadRadius = entity.HeadRadius,
						})
					end
				end
				VisualOffload.Fire("HurtboxSnapshot", snapshot)
			end

			if Entity.ShowHurtboxHistory then
				local now = os.clock()
				local snapshot = {}
				for i = 1, #entities do
					local entity = entities[i]
					if not entity.IsDestroyed then
						local samples = {}
						for _, sample in entity._history do
							table.insert(samples, {
								Position = sample.Position,
								Valid = (now - sample.Time) <= Entity.HurtboxValidWindow,
							})
						end
						-- the live position is always the newest, always-valid sample
						table.insert(samples, { Position = entity:GetPosition(), Valid = true })
						table.insert(snapshot, { Id = entity.Id, Radius = entity.HitboxRadius, Samples = samples })
					end
				end
				VisualOffload.Fire("HurtboxHistorySnapshot", snapshot)
			end

			task.wait(0.1) -- real time; this is a debug view, not gameplay
		end
	end)
end

local HURTBOX_BODY_COLOR = Color3.fromRGB(255, 90, 90)
local HURTBOX_HEAD_COLOR = Color3.fromRGB(255, 170, 60)

local hurtboxParts: { [string]: BasePart }? = nil -- ["{id}_Body" | "{id}_Head"] = debug sphere

local function ensureHurtboxPart(key: string, color: Color3): BasePart
	local part = hurtboxParts[key]
	if part then
		return part
	end
	part = Instance.new("Part")
	part.Name = `Hurtbox_{key}`
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.ForceField
	part.Color = color
	part.Transparency = 0.55
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = workspace
	hurtboxParts[key] = part
	return part
end

local hurtboxRenderingEnabled = false

-- Call once on the client to draw every entity's Body (+ Head, if present)
-- hurtbox whenever Entity.ShowHurtboxes is true on the server. No-ops on the
-- server.
function Entity.EnableHurtboxRendering()
	if hurtboxRenderingEnabled or RunService:IsServer() then
		return
	end
	hurtboxRenderingEnabled = true
	hurtboxParts = {}

	VisualOffload.On("HurtboxSnapshot", function(snapshot)
		local seen: { [string]: boolean } = {}
		for _, info in snapshot do
			local bodyKey = `{info.Id}_Body`
			seen[bodyKey] = true
			local body = ensureHurtboxPart(bodyKey, HURTBOX_BODY_COLOR)
			body.Size = Vector3.one * (info.Radius * 2)
			body.Position = info.Position

			if info.HeadPosition then
				local headKey = `{info.Id}_Head`
				seen[headKey] = true
				local head = ensureHurtboxPart(headKey, HURTBOX_HEAD_COLOR)
				head.Size = Vector3.one * (info.HeadRadius * 2)
				head.Position = info.HeadPosition
			end
		end
		for key, part in hurtboxParts do
			if not seen[key] then
				part:Destroy()
				hurtboxParts[key] = nil
			end
		end
	end)
end

-- History-trail rendering: every retained sample per entity, colored green while
-- still within HurtboxValidWindow, red once older. Overlapping spheres are
-- expected (denser overlap = the entity lingered there) -- kept more transparent
-- than the single live hurtbox so the trail doesn't turn into a solid blob.
local HURTBOX_VALID_COLOR = Color3.fromRGB(90, 230, 120)
local HURTBOX_INVALID_COLOR = Color3.fromRGB(230, 70, 70)

local historyParts: { [string]: BasePart }? = nil -- ["entityId_index"] = debug sphere

local function ensureHistoryPart(key: string): BasePart
	local part = historyParts[key]
	if part then
		return part
	end
	part = Instance.new("Part")
	part.Name = `HurtboxHistory_{key}`
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.ForceField
	part.Transparency = 0.8
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = workspace
	historyParts[key] = part
	return part
end

local hurtboxHistoryRenderingEnabled = false

-- Call once on the client to draw every entity's FULL hurtbox history whenever
-- Entity.ShowHurtboxHistory is true on the server. No-ops on the server.
function Entity.EnableHurtboxHistoryRendering()
	if hurtboxHistoryRenderingEnabled or RunService:IsServer() then
		return
	end
	hurtboxHistoryRenderingEnabled = true
	historyParts = {}

	VisualOffload.On("HurtboxHistorySnapshot", function(snapshot)
		local seen: { [string]: boolean } = {}
		for _, info in snapshot do
			for index, sample in info.Samples do
				local key = `{info.Id}_{index}`
				seen[key] = true
				local part = ensureHistoryPart(key)
				part.Size = Vector3.one * (info.Radius * 2)
				part.Position = sample.Position
				part.Color = sample.Valid and HURTBOX_VALID_COLOR or HURTBOX_INVALID_COLOR
			end
		end
		for key, part in historyParts do
			if not seen[key] then
				part:Destroy()
				historyParts[key] = nil
			end
		end
	end)
end

return Entity
