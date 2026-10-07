--!strict
--!optimize 2
--[[
	Projectile/Spec.luau
	Compiled configs for EFFICIENT projectiles (see Store.luau): everything a
	projectile's normalized config makes constant -- damage, visuals, motion
	constants, bounce/pierce allowances, its raycast filter... -- in one
	frozen table shared by every projectile fired with an equal config, plus
	the handle metatable that reads from it.

	Configs are usually fresh tables per shot, so specs are found by VALUE: a
	trie over the normalized settings (tables by content: IgnoreInstances via
	the shared RaycastParams it produced, Visual by its shallow contents).
	Past MAX_SPECS distinct specs the trie is reset -- live projectiles keep
	theirs, new shots just build new ones.
]]

local Store = require(script.Parent.Store)

local Spec = {}

local MAX_SPECS = 512

local NIL = newproxy() -- (trie key for nil)
local trie: { [any]: any } = {}
local count = 0

-- A shallow table as a key: its sorted contents (nested tables count by
-- identity, so they just don't share).
local function contentKey(value: { [any]: any }): string
	local parts = {}
	for k, v in value do
		table.insert(parts, `{tostring(k)}={typeof(v)}:{tostring(v)}`)
	end
	table.sort(parts)
	return table.concat(parts, "|")
end

-- The spec and handle metatable for these normalized settings (Config.normalize)
-- and movement RaycastParams. `class` is the Projectile class; `lazy` its
-- per-projectile values made on first read (see Store.HandleMetatable).
function Spec.Get(settings: any, rayParams: RaycastParams, class: any, lazy: { [string]: () -> any }): (any, any)
	local visual = settings.Visual
	local keys = {
		settings.Speed, settings.Acceleration, settings.AccelerationDirection, settings.MinSpeed, settings.MaxSpeed,
		settings.Gravity, settings.Radius, settings.Lifetime, settings.MaxRealLifetime, settings.Damage,
		settings.Source, settings.Filter, settings.Bounces, settings.Restitution, settings.Penetration,
		settings.MaxPierces, settings.PierceFalloff, settings.Visualize, settings.VisualRange, settings.Model,
		if visual then contentKey(visual) else nil, settings.VisualScale, settings.DestroyDelay,
		settings.WaitForParticles, settings.WaitForTrails, settings.ActivateParticlesOnCreate, settings.OnBounce,
		rayParams,
	}
	local node = trie
	for index = 1, 28 do
		local key = keys[index]
		if key == nil then
			key = NIL
		end
		local nextNode = node[key]
		if not nextNode then
			nextNode = {}
			node[key] = nextNode
		end
		node = nextNode
	end
	local found = node[NIL]
	if found then
		return found[1], found[2]
	end

	local spec = table.freeze({
		Speed = settings.Speed,
		Acceleration = settings.Acceleration,
		AccelerationDirection = settings.AccelerationDirection,
		MinSpeed = settings.MinSpeed,
		MaxSpeed = settings.MaxSpeed,
		Gravity = settings.Gravity,
		Radius = settings.Radius,
		Lifetime = settings.Lifetime,
		MaxRealLifetime = settings.MaxRealLifetime,
		Damage = settings.Damage,
		DamageMultiplier = 1,
		Source = settings.Source,
		IgnoreInstances = settings.IgnoreInstances,
		Filter = settings.Filter,
		BouncesLeft = settings.Bounces,
		Restitution = settings.Restitution,
		Penetration = settings.Penetration,
		PiercesLeft = settings.MaxPierces,
		PierceFalloff = settings.PierceFalloff,
		HomingDelay = 0,
		ReacquireTimer = 0,
		Visualize = settings.Visualize,
		VisualRange = settings.VisualRange,
		Model = settings.Model,
		Visual = settings.Visual,
		VisualScale = settings.VisualScale,
		DestroyDelay = settings.DestroyDelay,
		WaitForParticles = settings.WaitForParticles,
		WaitForTrails = settings.WaitForTrails,
		ActivateParticlesOnCreate = settings.ActivateParticlesOnCreate,
		OnBounce = settings.OnBounce,
		RewindSeconds = 0,
		_acquireTimer = 0,
		_rewindTime = 0,
		_rayParams = rayParams,
	})
	local metatable = Store.HandleMetatable(spec, class, lazy)
	count += 1
	if count > MAX_SPECS then
		table.clear(trie)
		count = 0
	else
		node[NIL] = { spec, metatable }
	end
	return spec, metatable
end

-- Distinct specs currently cached (Stats).
function Spec.Count(): number
	return count
end

return Spec
