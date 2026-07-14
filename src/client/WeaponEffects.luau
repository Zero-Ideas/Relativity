--!optimize 2
--[[
	WeaponEffects (client, purely cosmetic)
	Renders one-shot weapon VFX broadcast by the server over VisualOffload.
	This exists because ParticleEmitter:Emit() is a method call and method
	calls never replicate -- the server can't burst particles for anyone, so
	weapon modules (see src/server/Weapons/Railgun.luau) broadcast the shot
	instead and every client emits locally. Self-registers its listeners at
	require time (no .start()), same as AmmoState.luau.

	"MuzzleBlast" payload (server -> all clients):
	 - Template: Instance -- the effect template to clone (e.g. the Tool's
	   "Flash" part); sent by reference, resolves to this client's replica.
	   May be a single BasePart, a Model, or a Folder of emitter parts.
	 - Origin: Vector3, Direction: Vector3 -- the projectile's OWN spawn
	   ray (server-resolved), so the effect sits exactly on the bullet path.
	 - Distance: number? -- studs along that ray to place the effect
	   (default DEFAULT_BLAST_DISTANCE).
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VisualOffload = require(Shared.VisualOffload)

local WeaponEffects = {}

local DEFAULT_BLAST_DISTANCE = 8
local DEFAULT_EMIT_COUNT = 20
local MIN_BLAST_LIFETIME = 0.5 -- floor for the cleanup delay if no ParticleEmitter reports a Lifetime

-- The template's own "facing" CFrame before repositioning -- used to compute
-- ONE rigid delta transform applied to every BasePart in the clone, so the
-- effect works regardless of whether the template is a single Part, a Model
-- (multiple parts), or a Folder grouping several emitter parts: BasePart ->
-- its own CFrame; Model -> its computed pivot; Folder (no pivot concept) ->
-- its first descendant BasePart's CFrame.
local function referenceCFrame(instance: Instance): CFrame?
	if instance:IsA("BasePart") then
		return instance.CFrame
	end
	if instance:IsA("Model") then
		return instance:GetPivot()
	end
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			return descendant.CFrame
		end
	end
	return nil
end

-- Clones the template, rigidly moves the CLONE (never the original) onto the
-- target CFrame, bursts every ParticleEmitter under it by its own EmitCount
-- attribute (default DEFAULT_EMIT_COUNT), and Debris-cleans it after the
-- longest emitter Lifetime so already-emitted particles finish fading
-- naturally. Every JointInstance and Constraint in the clone is destroyed
-- first: a cloned joint keeps referencing whatever EXTERNAL part the
-- ORIGINAL template was attached to (the real Handle/character, not a clone
-- of it), and an anchored clone rigidly jointed to an unanchored character
-- snaps the character to the blast position, rotated by the joint's
-- authored offset, and freezes it there. The class checks are the BASE
-- classes deliberately: Studio's own weld tools create ManualWeld/Snap,
-- for which IsA("Weld") is FALSE (they're JointInstance siblings of Weld,
-- not subclasses) -- an earlier version filtered Weld/WeldConstraint/
-- Motor6D by name and let a ManualWeld through, causing exactly that
-- teleport/rotate/freeze glitch. IsA("JointInstance") covers Weld,
-- ManualWeld, Snap, Motor, Motor6D, Glue; IsA("Constraint") covers
-- WeldConstraint, RigidConstraint, and every other constraint type -- none
-- of which a fire-and-forget VFX clone ever needs.
local function playBlast(template: Instance, targetCFrame: CFrame)
	local from = referenceCFrame(template)
	if not from then
		return -- no BasePart anywhere in the template -- nothing to place/emit from
	end
	local delta = targetCFrame * from:Inverse()

	local blast = template:Clone()
	local parts = if blast:IsA("BasePart") then { blast } else {}
	for _, descendant in blast:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		elseif descendant:IsA("JointInstance") or descendant:IsA("Constraint") then
			descendant:Destroy()
		end
	end
	for _, part in parts do
		part.CFrame = delta * part.CFrame
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
	end
	blast.Parent = Workspace

	local lifetime = MIN_BLAST_LIFETIME
	for _, child in blast:GetDescendants() do
		if child:IsA("ParticleEmitter") then
			child:Emit(child:GetAttribute("EmitCount") or DEFAULT_EMIT_COUNT)
			lifetime = math.max(lifetime, child.Lifetime.Max)
		end
	end
	Debris:AddItem(blast, lifetime)
end

VisualOffload.On("MuzzleBlast", function(data)
	if typeof(data) ~= "table" then
		return
	end
	local template = data.Template
	local origin = data.Origin
	local direction = data.Direction
	if typeof(template) ~= "Instance" or typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return
	end
	if direction.Magnitude < 1e-3 then
		return -- degenerate ray; also guards the Unit below
	end
	direction = direction.Unit
	local distance = if typeof(data.Distance) == "number" then data.Distance else DEFAULT_BLAST_DISTANCE

	local position = origin + direction * distance
	-- ParticleEmitters emit along their part's +Y by default (EmitDirection
	-- = Top), so the template's UP axis is what belongs on the shot ray --
	-- aligning its LookVector left the whole effect pointing 90 degrees off
	-- the bullet path. lookAt puts -Z on the ray; the -90-degree X roll then
	-- maps +Y onto it (the reference part lands EXACTLY on this frame, so
	-- this holds regardless of how the template was oriented at authoring
	-- time). The explicit up hint keeps lookAt stable when firing straight
	-- up/down (its default +Y up hint degenerates there).
	local upHint = if math.abs(direction.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local target = CFrame.lookAt(position, position + direction, upHint) * CFrame.Angles(-math.pi / 2, 0, 0)
	playBlast(template, target)
end)

return WeaponEffects
