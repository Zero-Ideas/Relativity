--!strict
--[[
	Projectile/Types.luau
	Shared type definitions for the server projectile modules. No runtime
	behaviour. Entity.luau and Signal.luau are not strictly typed, so the
	parts of them this system relies on are described structurally here.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ProjectileMotion = require(Shared:WaitForChild("ProjectileMotion"))
local Protocol = require(Shared:WaitForChild("ProjectileProtocol"))

export type Acceleration = ProjectileMotion.Acceleration
export type VisualSpec = Protocol.VisualSpec

export type Hurtbox = "Head" | "Body"

export type EntityLike = {
	Instance: Instance?,
	TimeScale: number?,
	IsDestroyed: boolean,
	Health: number,
	HeadRadius: number,
	HitboxRadius: number,
	GetPosition: (self: any) -> Vector3,
	GetHeadPosition: (self: any) -> Vector3?,
	GetBodyPositionAt: (self: any, time: number) -> Vector3,
	GetHeadPositionAt: (self: any, time: number) -> Vector3?,
	HasTag: (self: any, tag: string) -> boolean,
}

export type Connection = {
	Disconnect: (self: any) -> (),
}

export type Signal<T> = {
	Connect: (self: any, fn: (T) -> ()) -> Connection,
	Fire: (self: any, value: T) -> (),
	Destroy: (self: any) -> (),
}

export type HomingTarget = EntityLike | Instance | Vector3

-- A world contact: a RaycastResult converted to a plain table, or a
-- synthetic contact (lag-compensated hit, bounce, expiry).
export type Contact = {
	Position: Vector3,
	Normal: Vector3,
	Instance: Instance?,
	Distance: number?,
}

-- Payload of projectile.OnHit -- see the "Events" section in init.luau.
export type HitInfo = {
	CFrame: CFrame,
	Part: Instance?,
	Entity: EntityLike?,
	Hurtbox: Hurtbox?,
}

-- Payload of projectile.OnDestroy.
export type DestroyInfo = {
	Position: Vector3,
	Normal: Vector3,
	Kind: string?,
}

-- Caller-facing homing options. Every field is optional and unvalidated.
export type HomingOptions = {
	Target: HomingTarget?,
	TargetTag: string?,
	TargetTags: { string }?,
	AcquireRadius: number?,
	Retarget: boolean?,
	ReacquireRate: number?,
	AcquireInterval: number?,
	Permalock: boolean?,
	TurnRate: number?,
	Delay: number?,
}

-- Validated homing settings (see Config.normalizeHoming).
export type Homing = {
	Target: HomingTarget?,
	TargetTag: string?,
	TargetTags: { string }?,
	AcquireRadius: number?,
	Retarget: boolean,
	ReacquireRate: number,
	AcquireInterval: number,
	Permalock: boolean,
	TurnRate: number,
	Delay: number,
}

-- Caller-facing Projectile.new config -- see the module doc comment in
-- init.luau for what each field means. Every value is treated as untrusted
-- and normalized by Config.normalize before use.
export type Config = {
	Origin: Vector3?,
	Direction: Vector3?,
	TargetPosition: Vector3?,
	Speed: number?,
	Acceleration: Acceleration?,
	AccelerationDirection: Vector3?,
	MinSpeed: number?,
	MaxSpeed: number?,
	Lifetime: number?,
	MaxRealLifetime: number?,
	TimeScale: number?,
	Damage: number?,
	Source: EntityLike?,
	-- `{ any }` rather than `{ Instance }`: table types are invariant, so a
	-- caller's `{ Model }` would not type-check. Non-Instances are dropped
	-- by Config.normalize.
	IgnoreInstances: { any }?,
	Filter: ((entity: EntityLike) -> boolean)?,
	Gravity: Acceleration?,
	Radius: number?,
	Bounces: number?,
	Restitution: number?,
	Penetration: number?,
	MaxPierces: number?,
	PierceFalloff: number?,
	Homing: HomingOptions?,
	Visualize: boolean?,
	VisualRange: number?,
	Model: Instance?,
	Visual: VisualSpec?,
	VisualScale: number?,
	Beam: { Length: number?, ChannelId: number?, PreviousId: number? }?, -- linked sustained stream
	DestroyDelay: number?,
	WaitForParticles: boolean?,
	WaitForTrails: boolean?,
	ActivateParticlesOnCreate: boolean?,
	OnBounce: ((projectile: any, contact: Contact) -> ())?,
	RewindSeconds: number?,
	Spread: number?, -- Projectile.Burst only
}

-- Live projectile state. Public (PascalCase) fields are readable and
-- writable by abilities; underscore fields are internal bookkeeping.
export type State = {
	Id: number,
	Position: Vector3,
	Velocity: Vector3,
	Speed: number,
	Acceleration: Acceleration,
	AccelerationDirection: Vector3?,
	MinSpeed: number,
	MaxSpeed: number,
	Gravity: Acceleration,
	Radius: number,

	Lifetime: number,
	Age: number,
	MaxRealLifetime: number,
	TimeScale: number,

	Damage: number,
	DamageMultiplier: number,
	Source: EntityLike?,
	IgnoreInstances: { Instance }?,
	Filter: ((entity: EntityLike) -> boolean)?,

	BouncesLeft: number,
	Restitution: number,
	Penetration: number,
	PiercesLeft: number,
	PierceFalloff: number,

	Homing: Homing?,
	HomingDelay: number,
	HomingTarget: HomingTarget?,
	ReacquireTimer: number,

	Visualize: boolean,
	VisualRange: number,
	Model: Instance?,
	Visual: VisualSpec?,
	VisualScale: number,
	Beam: { Length: number, ChannelId: number?, PreviousId: number? }?,
	DestroyDelay: number,
	WaitForParticles: boolean,
	WaitForTrails: boolean,
	ActivateParticlesOnCreate: boolean,

	OnHit: Signal<HitInfo>,
	OnDestroy: Signal<DestroyInfo>,
	OnBounce: ((projectile: any, contact: Contact) -> ())?,

	RewindSeconds: number,
	Dead: boolean,

	_spawnRealTime: number,
	_acquireTimer: number,
	_ignore: { [EntityLike]: boolean },
	_rewindTime: number,
	_rewindCache: { [EntityLike]: { Body: Vector3, Head: Vector3? } },
	_simulationDebt: number,
	_rayParams: RaycastParams,
	_spawnStreamed: boolean,
	_streamedSynced: boolean,
	_lastStreamedTimeScale: number,
	_beamOrigin: Vector3?,
	_beamTurns: { Vector3 }?,
	_beamPrevious: any?,
	_beamBodyHit: boolean?,
	_beamSpan: { Vector3 }?,
	_beamSpanClipped: boolean?,
	_beamJoiner: boolean?, -- independently simulated/colliding subdivision
	_beamJoinerWorldStop: boolean?,
	_beamReserveChildren: ((number) -> boolean)?,
	_beamBindChild: ((any, number) -> ())?,
	_beamScaleEnergy: ((number) -> ())?,
}

-- What a hit resolver decided:
--  "pass"        keeps flying on the same trajectory (pierce, penetration,
--                or nudging past an ignored/rewound-away entity)
--  "bounce"      reflected; the client is re-baselined by a bounce snap
--  "destroy"     the caller must Destroy() with the returned kind
--  "fallthrough" entity filtered out; resolve as world geometry instead
export type Verdict = "pass" | "bounce" | "destroy" | "fallthrough"

-- ModuleScripts must return exactly one non-nil value.
return {}
