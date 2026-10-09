--!strict
--!native
--!optimize 2
-- Called ONLY after occupancy failed to prove the cast empty. The entire
-- radius-expanded segment must be in entity-free chunks to use a ray.
-- Occupied boundaries retain full radius. Bound the lookup cost instead
-- of scanning a huge box for a long diagonal or an unusually wide projectile.
local CollisionLOD = {}
local floor, min, max = math.floor, math.min, math.max
local MAX_CELLS = 8

function CollisionLOD.Radius(occupied: { [Vector3]: boolean }, size: number, useY: boolean,
	origin: Vector3, displacement: Vector3, radius: number): number
	if radius <= 0 or next(occupied) == nil then return 0 end
	local cx, cy, cz = floor(origin.X / size), if useY then floor(origin.Y / size) else 0, floor(origin.Z / size)
	if occupied[Vector3.new(cx, cy, cz)] then return radius end
	local finish = origin + displacement
	local lx, hx = floor((min(origin.X, finish.X)-radius)/size), floor((max(origin.X, finish.X)+radius)/size)
	local lz, hz = floor((min(origin.Z, finish.Z)-radius)/size), floor((max(origin.Z, finish.Z)+radius)/size)
	local ly, hy = 0, 0
	if useY then
		ly, hy = floor((min(origin.Y, finish.Y)-radius)/size), floor((max(origin.Y, finish.Y)+radius)/size)
	end
	if lx == hx and ly == hy and lz == hz then return 0 end
	if (hx-lx+1)*(hy-ly+1)*(hz-lz+1) > MAX_CELLS then return radius end
	for x = lx, hx do
		for z = lz, hz do
			for y = ly, hy do
				if occupied[Vector3.new(x,y,z)] then return radius end
			end
		end
	end
	return 0
end

return CollisionLOD
