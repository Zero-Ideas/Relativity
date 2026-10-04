--!strict
--[[
	ProjectileClient/Types.luau
	Shared shapes for the client renderer's modules. No runtime behaviour.
]]

local Protocol = require(script.Parent.Parent:WaitForChild("ProjectileProtocol"))

-- A visual driven by a Motor6D from an invisible anchored root; see
-- VisualModel.Build.
export type Rig = {
	driver: BasePart,
	motor: Motor6D,
	rootOffset: CFrame,
	model: Instance,
	root: BasePart,
	poolKey: string?,
}

-- One rendered projectile. Physics fields mirror the server projectile and
-- are advanced by Prediction; the rest is presentation state.
export type Visual = {
	id: number,
	model: Instance,
	rig: Rig?,
	destroyDelay: number,
	waitForParticles: boolean,
	waitForTrails: boolean,

	-- physics mirror (see Prediction)
	position: Vector3,
	velocity: Vector3,
	gravity: Protocol.Acceleration,
	acceleration: Protocol.Acceleration,
	accelerationDirection: Vector3?,
	minSpeed: number,
	maxSpeed: number,
	life: number, -- dilated seconds remaining
	simulationDebt: number, -- personal/global seconds carried across visits
	timeScale: number, -- combined Source * projectile TimeScale
	lastSimulationTime: number, -- global simulation clock the pose corresponds to
	synced: boolean, -- homing: driven by ProjMove instead of Prediction

	-- lifetime backstops
	spawnRealTime: number,
	maxRealLifetime: number,
	lastUpdate: number, -- os.clock() of the last authoritative pose

	-- presentation
	lastRenderStep: number,
	inView: boolean,
	offscreenSince: number?,
	culled: boolean,
	effectCullDelay: number,
	resumeEffectsOnNextUpdate: number?,
	smoothTransform: boolean,
	lastSmoothStep: number?,
	lastSmoothTarget: number?,
	transformFrom: CFrame?,
	transformTo: CFrame?,
	transformElapsed: number,
	transformDuration: number,
	suspendedTrails: { Trail }?,
	suspendedParticles: { ParticleEmitter }?,
}

-- ModuleScripts must return exactly one non-nil value.
return {}
