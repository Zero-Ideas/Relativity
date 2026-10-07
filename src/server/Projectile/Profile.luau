--!strict
--!native
--!optimize 2
--[[
	Projectile/Profile.luau
	Where the main thread's projectile time goes, for the debug panel's Stats
	tab: named sections accumulate seconds, and Take() returns each as average
	ms per frame since the last call.

	Per-projectile parts are SAMPLED (one projectile in SAMPLE is timed and the
	result scaled up) so the timer calls don't distort the very loops being
	measured; those sections are estimates, labelled as such in the Stats tab.
]]

local Profile = {}

Profile.SAMPLE = 32 -- time one projectile in this many in per-projectile loops

local totals: { [string]: number } = {}
local counts: { [string]: number } = {}
local frames = 0

function Profile.Add(name: string, seconds: number)
	totals[name] = (totals[name] or 0) + seconds
end

-- A per-frame count (reported as the average per frame, not ms).
function Profile.Count(name: string, n: number)
	counts[name] = (counts[name] or 0) + n
end

-- Lua heap at the last frame, and how much the garbage collector freed
-- since the last Take (heap drops between frames).
local lastHeap = gcinfo()
local freedKB = 0

-- One server frame passed (called once per projectile Heartbeat step).
function Profile.Frame()
	frames += 1
	local heap = gcinfo()
	if heap < lastHeap then
		freedKB += lastHeap - heap
	end
	lastHeap = heap
end

-- { [section] = average ms per frame, [count] = average per frame } since
-- the last call, then resets.
function Profile.Take(): { [string]: number }
	local result = {}
	local count = math.max(frames, 1)
	for name, seconds in totals do
		result[name] = seconds / count * 1000
	end
	for name, n in counts do
		result[name] = n / count
	end
	result.HeapMB = lastHeap / 1024
	result.GcFreedMB = freedKB / 1024 / count
	freedKB = 0
	table.clear(totals)
	table.clear(counts)
	frames = 0
	return result
end

return Profile
