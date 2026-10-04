--!strict
--[[
	ProjectileProtocol.luau
	The wire format between the server projectile system
	(ServerScriptService.Server.Projectile/Replication.luau, sending) and
	ProjectileClient (receiving). Channel names and payload shapes live here
	so both sides are type-checked against one definition.

	Every server pose (spawn, bounce snap, sync transition, homing stream) is
	an end-of-server-frame snapshot; the client adopts each as "now" -- see
	the Projectile module doc comment (init.luau) for the full protocol.
]]

local Protocol = {}

Protocol.Channels = {
	SpawnBatch = "ProjSpawnBatch", -- { SpawnPayload }
	Move = "ProjMove", -- { MovePayload }
	HitBatch = "ProjHitBatch", -- { HitPayload }
	Sync = "ProjSync", -- SyncPayload
	TimeScale = "ProjTimeScale", -- TimeScalePayload
	Ray = "ProjRay", -- RayPayload
}

export type Acceleration = number | Vector3

export type VisualSpec = {
	Shape: string?,
	Size: Vector3?,
	Color: Color3?,
	Style: string?,
	Core: Color3?,
}

-- Optional fields are omitted when equal to the client default (noted),
-- because remote events serialize every key name per entry.
export type SpawnPayload = {
	Id: number,
	Position: Vector3,
	Velocity: Vector3,
	Lifetime: number, -- dilated seconds remaining
	MaxRealLifetime: number, -- real seconds remaining
	AccelerationDirection: Vector3?,
	Model: Instance?,
	Visual: VisualSpec?,
	Gravity: Acceleration?, -- 0
	Acceleration: Acceleration?, -- 0
	MinSpeed: number?, -- 0
	MaxSpeed: number?, -- math.huge
	Synced: boolean?, -- false
	TimeScale: number?, -- 1
	VisualScale: number?, -- 1
	DestroyDelay: number?, -- 0
	WaitForParticles: boolean?, -- true
	WaitForTrails: boolean?, -- true
	ActivateParticlesOnCreate: boolean?, -- false
}

-- Either a homing pose (Bounced nil) or a one-shot bounce snap.
export type MovePayload = {
	Id: number,
	Position: Vector3,
	Velocity: Vector3,
	Bounced: boolean?,
	Point: Vector3?, -- bounce contact point
	Normal: Vector3?, -- bounce surface normal
}

export type HitPayload = {
	Id: number,
	Position: Vector3,
	Normal: Vector3,
	Kind: string?, -- nil: expired without hitting anything
}

export type SyncPayload = {
	Id: number,
	Synced: boolean,
	Position: Vector3,
	Velocity: Vector3,
}

export type TimeScalePayload = {
	Id: number,
	TimeScale: number,
}

export type RayPayload = {
	From: Vector3,
	To: Vector3,
	LowRes: boolean,
}

return Protocol
