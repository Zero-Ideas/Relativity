--!strict
-- Cosmetic preferences only. No workspace listeners or per-projectile
-- frame callbacks; emitter properties refresh only when preferences change.
local Presentation = {
	EffectsIntensity = 1,
	ReducedFlashes = false,
	CameraShake = 1,
}
type EmitterDefaults = {Rate: number, Brightness: number, LightEmission: number, Flash: boolean}
local emitters: {[ParticleEmitter]: EmitterDefaults} = setmetatable({}, {__mode = "k"}) :: any

local function applyEmitter(emitter: ParticleEmitter, original: EmitterDefaults)
	emitter.Rate = original.Rate * Presentation.EffectsIntensity * (if Presentation.ReducedFlashes and original.Flash then 0 else 1)
	emitter.Brightness = if Presentation.ReducedFlashes then math.min(original.Brightness, 0.5) else original.Brightness
	emitter.LightEmission = if Presentation.ReducedFlashes then math.min(original.LightEmission, 0.25) else original.LightEmission
	if Presentation.ReducedFlashes and original.Flash then emitter:Clear() end
end

function Presentation.TrackEmitter(emitter: ParticleEmitter, flash: boolean?)
	local original = emitters[emitter]
	if not original then
		original = {Rate = emitter.Rate, Brightness = emitter.Brightness, LightEmission = emitter.LightEmission, Flash = flash == true}
		emitters[emitter] = original
	end
	applyEmitter(emitter, original)
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
