--!strict
--[[
	EngineStats (shared): what Roblox exposes about engine-side load that
	isn't our scripts -- for the debug panel's Stats tab, on the server and
	the client alike. Every read is guarded: a property this engine version
	doesn't have reads as nil.

	  EngineStats.Physics() -> { RealFps, AwakeParts, Throttling,
	                             Primitives, MovingPrimitives, Contacts }
	      RealFps: physics steps per second actually achieved; Throttling:
	      the percentage of physics work the engine is skipping (0 = none)
	  EngineStats.Memory(count) -> { { Tag, Mb } }
	      the biggest DeveloperMemoryTag categories (graphics, physics,
	      scripts, sounds, instances...), largest first
]]

local Stats = game:GetService("Stats")

local EngineStats = {}

local function read(fn: () -> any): number?
	local ok, value = pcall(fn)
	return if ok and typeof(value) == "number" then value else nil
end

function EngineStats.Physics(): { [string]: number? }
	return {
		RealFps = read(function() return workspace:GetRealPhysicsFPS() end),
		AwakeParts = read(function() return workspace:GetNumAwakeParts() end),
		Throttling = read(function() return workspace:GetPhysicsThrottling() end),
		Primitives = read(function() return (Stats :: any).PrimitivesCount end),
		MovingPrimitives = read(function() return (Stats :: any).MovingPrimitivesCount end),
		Contacts = read(function() return (Stats :: any).ContactsCount end),
	}
end

function EngineStats.Memory(count: number): { { Tag: string, Mb: number } }
	local result = {}
	for _, tag in Enum.DeveloperMemoryTag:GetEnumItems() do
		local mb = read(function() return Stats:GetMemoryUsageMbForTag(tag) end)
		if mb and mb >= 0.5 then
			table.insert(result, { Tag = tag.Name, Mb = mb })
		end
	end
	table.sort(result, function(a, b)
		return a.Mb > b.Mb
	end)
	for index = #result, count + 1, -1 do
		result[index] = nil
	end
	return result
end

return EngineStats
