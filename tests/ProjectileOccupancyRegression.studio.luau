-- Run through Studio MCP execute_luau in a running server (needs Source access).
-- Inject into the live Actor VMs rather than requiring a second module cache
-- from the plugin. No projectile visuals or damage; remove every test instance.
local root = game.ServerScriptService:WaitForChild("Server")
local folder = root:WaitForChild("ProjectileActors")
local part = Instance.new("Part")
part.Name = "OccupancyRegressionTarget"
part.Anchored = true
part.Size = Vector3.new(8, 8, 8)
part.Position = Vector3.new(12000, 12000, 12000)
part.Parent = workspace
local reply = Instance.new("BindableEvent")
reply.Name = "OccupancyRegressionReply"
reply.Parent = folder
local request = Instance.new("BindableEvent")
request.Name = "OccupancyRegressionRequest"
request.Parent = folder
local scripts, failures, responses = {}, {}, {}
reply.Event:Connect(function(worker, label, clear, expected, ready)
	responses[worker .. label] = true
	if clear ~= expected or not ready then table.insert(failures, worker .. ": incorrect occupancy at " .. label) end
end)
local source = [[
local actor = script:GetActor()
local folder = actor.Parent
local O = require(folder.Parent.Projectile.Occupancy)
folder.OccupancyRegressionRequest.Event:Connect(function(label, origin, displacement, expected)
	folder.OccupancyRegressionReply:Fire(actor.Name, label, O.SegmentClear(origin, displacement, 0), expected, O.TakeStats().Ready)
end)
]]
for _, actor in folder:GetChildren() do
	if actor:IsA("Actor") then
		local probe = Instance.new("Script")
		probe.Name = "OccupancyRegressionProbe"
		probe.Source = source
		probe.Parent = actor
		table.insert(scripts, probe)
	end
end
local function check(label, empty)
	local offset = if empty then Vector3.yAxis * 512 else Vector3.zero
	request:Fire(label, part.Position + offset - Vector3.xAxis * 20, Vector3.xAxis * 40, empty == true)
	task.wait(.15)
	for _, probe in scripts do
		if not responses[probe.Parent.Name .. label] then table.insert(failures, "missing " .. probe.Parent.Name .. label) end
	end
end
local ok, err = pcall(function()
	task.wait(.3)
	-- This scene has no terrain; fail rather than silently testing an unready
	-- grid whose conservative fallback would always return false.
	check("empty space", true)
	check("initial import")
	-- A missing delta must disable skipping and trigger a full catch-up,
	-- never leave an incomplete grid enabled for collision avoidance.
	for _, probe in scripts do
		probe.Parent:SendMessage("OccupancyBake", {Version = 1000000000, Full = false})
	end
	task.wait(.3)
	check("snapshot recovery", true)
	part.Position += Vector3.xAxis * 128
	check("moved immediately")
	task.wait(.2)
	check("moved after delta")
	part.Size = Vector3.one * 20
	check("resized")
	part.Anchored = false
	part.AssemblyLinearVelocity = Vector3.xAxis * 100
	check("unanchored")
end)
for _, probe in scripts do probe:Destroy() end
request:Destroy(); reply:Destroy(); part:Destroy()
assert(ok, err)
assert(#failures == 0, table.concat(failures, "\n"))
print(string.format("[OccupancyRegression] PASS: %d live Actors, initial/moved/resized/unanchored geometry", #scripts))
return "Occupancy regression passed"
