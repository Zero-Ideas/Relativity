--!strict
-- Shared *physical* centerline of a continuous stream. A newer sample is the
-- back of its section; the preceding sample is its front. Turning the input
-- therefore bends the stream instead of emitting unrelated parallel bars.
-- Both server collision and client cylinders use these exact endpoints.
local BeamPath = {}

function BeamPath.Connect(back: Vector3, front: Vector3, backTurns: { Vector3 }?, frontTurns: { Vector3 }?): { Vector3 }?
	local behind, ahead = backTurns or {}, frontTurns or {}
	if #behind > #ahead then return nil end -- separate bounce branches, not a shortcut
	local points = { back }
	for index = #behind + 1, #ahead do
		local contact = ahead[index]
		if (contact - points[#points]).Magnitude > 1e-4 then table.insert(points, contact) end
	end
	if (front - points[#points]).Magnitude > 1e-4 then table.insert(points, front) end
	return points
end

return BeamPath
