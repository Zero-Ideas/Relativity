--!strict
--[[
	Projectile/Client/Types.luau
	Shared shapes for the client renderer's modules. No runtime behaviour.
]]

local Protocol = require(script.Parent.Parent.Parent:WaitForChild("Projectile"):WaitForChild("Protocol"))

-- A visual driven by a Motor6D from an invisible anchored root; see
-- VisualModel.Build.
export type Rig = {
	driver: BasePart,
	motor: Motor6D,
	rootOffset: CFrame,
	model: Instance,
	root: BasePart,
	poolKey: string?,
	-- where `driver` sits (it's never rotated or moved after building, so a
	-- pose's Transform is just pose - origin, no Instance read)
	origin: Vector3?,
	identityOffset: boolean?, -- rootOffset is the identity
	beam: any?, -- bounded cylindrical path geometry (BeamVisual)
	effects: Effects?, -- a styled / authored model's effects (VisualModel)
}

-- Everything in a model the effects budget and retirement touch, gathered
-- once per model (a pooled model keeps it), plus what to restore on reuse.
export type Effects = {
	parts: { BasePart },
	emitters: { ParticleEmitter },
	trails: { Trail },
	lights: { Light },
	decor: { BasePart }, -- parts tagged LodDecor: hidden at the lowest detail
	restoreInstances: { Instance },
	restoreProperties: { string },
	restoreValues: { any },
	lifetime: number, -- see VisualModel.GetLongestEffectLifetime
	pendingTrails: { Trail }?, -- a reused model's trails, held until it's placed
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
	deferredPrediction: boolean,
	synced: boolean, -- homing: driven by ProjMove instead of Prediction

	-- lifetime backstops
	spawnRealTime: number,
	maxRealLifetime: number,
	lastUpdate: number, -- os.clock() of the last authoritative pose
	-- beams: real seconds between ServerTime and receipt of the spawn; every
	-- later ServerTime for this packet is shifted by it (see onSpawn)
	beamTimeOffset: number?,

	-- presentation
	lastRenderStep: number,
	inView: boolean,
	hidden: boolean?, -- beyond the player's render limits (ProjectileClient.SetRenderSettings)
	parked: boolean?, -- moved out of sight while hidden
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
	-- effects budget (ProjectileClient refreshDetail / VisualModel.SetDetail)
	lodTier: number?, -- 1 full, 2 reduced, 3 bare
	lodLight: boolean?,
	lodOff: { Instance }?, -- emitters / trails the bare tier switched off

	-- pass-by sound tracking (ProjectileClient.SetPassByHandler)
	passApproaching: boolean?, -- closing on the camera, on a line within the pass radius
	passDistance: number?, -- that line's closest distance to the camera
	passPoint: Vector3?, -- and where on it
	passDone: boolean?, -- already reported
	suspendedParticles: { ParticleEmitter }?,
	tint: Color3?, -- the spec's colour, for impact effects
	streak: (() -> ())?, -- detaches the speed streak (SetStreakHandler)
}

-- ModuleScripts must return exactly one non-nil value.
return {}
