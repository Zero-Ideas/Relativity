--!strict
--[[
	Projectile/Client/BeamRibbon.luau
	A straight piece of beam drawn as two Roblox Beams (a white-hot core and
	a wider translucent glow) between two Attachments -- however long the
	piece. No parts at all: the attachments live on workspace.Terrain (at the
	world origin, so their Position is their world position) and the Beams in
	the caller's container. Terrain outlives every beam, so whoever made a
	pool must Clear it when its beam goes.

	This replaced a pair of neon cylinder parts per piece, each on its own
	Motor6D, capped in length (a long straight link was several of them).
	Moving a piece is now two Attachment writes; nothing is resized or
	rebuilt. FaceCamera ribbons read as round from any side but end-on.
]]

local Ribbon = {}

export type Piece = {
	a0: Attachment,
	a1: Attachment,
	core: Beam,
	glow: Beam,
	from: Vector3?,
	to: Vector3?,
	shown: boolean,
}

local function newBeam(name: string, a0: Attachment, a1: Attachment, color: Color3, width: number,
	transparency: number, parent: Instance): Beam
	local beam = Instance.new("Beam")
	beam.Name = name
	beam.Attachment0, beam.Attachment1 = a0, a1
	beam.Color = ColorSequence.new(color)
	beam.Transparency = NumberSequence.new(transparency)
	beam.Width0, beam.Width1 = width, width
	beam.FaceCamera = true
	beam.Segments = 1
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Texture = ""
	beam.Enabled = false
	beam.Parent = parent
	return beam
end

-- Poses piece `index` of `pool` from `a` to `b` (making it if needed);
-- only writes what moved. `container` (in workspace) holds the Beams;
-- `diameter` and the colours are fixed per pool.
function Ribbon.Set(pool: { Piece }, index: number, container: Instance, a: Vector3, b: Vector3, diameter: number,
	core: Color3, glow: Color3)
	local piece = pool[index]
	if not piece then
		local terrain = workspace.Terrain
		local a0 = Instance.new("Attachment")
		a0.Name = "BeamFrom"
		a0.Position = a
		a0.Parent = terrain
		local a1 = Instance.new("Attachment")
		a1.Name = "BeamTo"
		a1.Position = b
		a1.Parent = terrain
		piece = {
			a0 = a0,
			a1 = a1,
			from = a,
			to = b,
			glow = newBeam("BeamGlow", a0, a1, glow, diameter, .5, container),
			core = newBeam("BeamCore", a0, a1, core, diameter * .55, 0, container),
			shown = false,
		}
		pool[index] = piece
	end
	-- (Terrain sits at the origin: Position is the world position)
	if piece.from ~= a then
		piece.from = a
		piece.a0.Position = a
	end
	if piece.to ~= b then
		piece.to = b
		piece.a1.Position = b
	end
	if not piece.shown then
		piece.shown = true
		piece.core.Enabled, piece.glow.Enabled = true, true
	end
end

-- Hides every piece of `pool` past the first `used`.
function Ribbon.HideAfter(pool: { Piece }, used: number)
	for index = used + 1, #pool do
		local piece = pool[index]
		if piece.shown then
			piece.shown = false
			piece.core.Enabled, piece.glow.Enabled = false, false
		end
	end
end

-- Destroys every piece of `pool` (its attachments are on Terrain, which a
-- beam's own container going away doesn't clean up).
function Ribbon.Clear(pool: { Piece }?)
	if not pool then
		return
	end
	for _, piece in pool do
		piece.core:Destroy()
		piece.glow:Destroy()
		piece.a0:Destroy()
		piece.a1:Destroy()
	end
	table.clear(pool)
end

return Ribbon
