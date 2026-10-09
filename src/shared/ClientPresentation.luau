--!strict
-- Cosmetic preferences only. No workspace listeners or per-projectile
-- frame callbacks; emitter properties refresh only when preferences change.
local Presentation = {
	EffectsIntensity = 1,
	ReducedFlashes = false,
	CameraShake = 1,
}
-- Scale: a per-emitter multiplier on top of the preferences (the projectile
-- renderer's effects budget, see Projectile/Client).
type EmitterDefaults = {Rate: number, Brightness: number, LightEmission: number, Flash: boolean, Scale: number}
local emitters: {[ParticleEmitter]: EmitterDefaults} = setmetatable({}, {__mode = "k"}) :: any

local function applyEmitter(emitter: ParticleEmitter, original: EmitterDefaults)
	emitter.Rate = original.Rate * Presentation.EffectsIntensity * original.Scale
		* (if Presentation.ReducedFlashes and original.Flash then 0 else 1)
	emitter.Brightness = if Presentation.ReducedFlashes then math.min(original.Brightness, 0.5) else original.Brightness
	emitter.LightEmission = if Presentation.ReducedFlashes then math.min(original.LightEmission, 0.25) else original.LightEmission
	if Presentation.ReducedFlashes and original.Flash then emitter:Clear() end
end

function Presentation.TrackEmitter(emitter: ParticleEmitter, flash: boolean?)
	local original = emitters[emitter]
	if not original then
		original = {Rate = emitter.Rate, Brightness = emitter.Brightness, LightEmission = emitter.LightEmission, Flash = flash == true,
			Scale = 1}
		emitters[emitter] = original
	end
	applyEmitter(emitter, original)
end

-- Scales a tracked emitter's rate (0 stops new particles; ones already out
-- finish naturally). Only writes when the scale changes.
function Presentation.ScaleEmitter(emitter: ParticleEmitter, scale: number)
	local original = emitters[emitter]
	if not original then
		Presentation.TrackEmitter(emitter)
		original = emitters[emitter]
	end
	if original.Scale ~= scale then
		original.Scale = scale
		applyEmitter(emitter, original)
	end
end

function Presentation.BurstCount(count: number): number
	return math.max(0, math.floor(count * Presentation.EffectsIntensity + 0.5))
end

function Presentation.Set(intensity: number, reducedFlashes: boolean, shake: number)
	local changed = Presentation.EffectsIntensity ~= intensity or Presentation.ReducedFlashes ~= reducedFlashes
	Presentation.EffectsIntensity = math.clamp(intensity, 0, 1)
	Presentation.ReducedFlashes = reducedFlashes
	Presentation.CameraShake = math.clamp(shake, 0, 1)
	if changed then
		for emitter, original in emitters do
			if emitter.Parent then applyEmitter(emitter, original) else emitters[emitter] = nil end
		end
	end
end

return Presentation
