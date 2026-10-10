-- Run in an isolated Studio server, or the CLI fixture with real buffer APIs.
local P = require(game.ServerScriptService.Server.Projectile.ApplyPass)
local count = 7
local records, scales, timers = buffer.create(count * 48), buffer.create(count * 8), buffer.create(count * 24)
local result, homingIn, homingOut = buffer.create(count * 44), buffer.create(count * 48), buffer.create(count * 32)
buffer.fill(records, 0, 0x55)
buffer.fill(timers, 0, 0x66)
buffer.fill(homingIn, 0, 0x77)
for i = 0, count - 1 do
	buffer.writef64(records, i * 48 + 40, 0.125)
	buffer.writef64(scales, i * 8, i)
	buffer.writeu8(homingIn, i * 48, if i == 1 or i == 5 then 1 else 0)
	for axis = 0, 5 do buffer.writef32(result, i * 44 + 4 + axis * 4, i * 10 + axis) end
	buffer.writef64(result, i * 44 + 28, i + 0.25)
	buffer.writef64(result, i * 44 + 36, 0.0625)
end
buffer.writeu8(result, 44, 1) -- contact: serial code owns its continuation
buffer.writeu8(result, 88, 2) -- expired: never commit
buffer.writef32(result, 3 * 44 + 4, 0 / 0)
buffer.writef32(result, 4 * 44 + 4, math.huge)
buffer.writef32(result, 5 * 44 + 4, 1e9) -- accepted boundary
buffer.writef64(homingOut, 32 + 24, 3) -- contact found target 3
buffer.writef64(homingOut, 5 * 32 + 24, -1) -- plain result lost target
for axis = 0, 2 do buffer.writef64(homingOut, 5 * 32 + axis * 8, axis + 0.5) end

local before = buffer.tostring(records)
P.Prepare(records, scales, timers, count, 0.25, homingIn)
for i = 0, count - 1 do
	assert(buffer.readf64(records, i * 48 + 40) == 0.125 + 0.25 * i, "time budget lost or scaled incorrectly")
	local h = buffer.tostring(homingIn):sub(i * 48 + 25, i * 48 + 48)
	assert(h == string.rep(if i == 1 or i == 5 then string.char(0x66) else string.char(0x77), 24), "homing state crossed items")
end
local prepared = buffer.tostring(records)
local timerBefore = buffer.tostring(timers)
local exceptions, changes = {}, {}
P.Commit(records, timers, result, count, homingIn, homingOut, exceptions, changes)
assert(#exceptions == 4 and exceptions[1] == 2 and exceptions[2] == 3 and exceptions[3] == 4 and exceptions[4] == 5,
	"contact/expiry/invalid results must be returned in item order")
assert(#changes == 4 and changes[1] == 2 and changes[2] == 3 and changes[3] == 6 and changes[4] == -1,
	"target changes were lost or reordered")
for i = 0, count - 1 do
	local record = buffer.tostring(records):sub(i * 48 + 1, (i + 1) * 48)
	assert(record:sub(1, 8) == before:sub(i * 48 + 1, i * 48 + 8), "spec/filter IDs changed")
	if i == 0 or i == 5 or i == 6 then
		assert(record:sub(9, 32) == buffer.tostring(result):sub(i * 44 + 5, i * 44 + 28), "pose not committed exactly")
		assert(buffer.readf64(records, i * 48 + 32) == i + 0.25, "age lost")
		assert(buffer.readf64(records, i * 48 + 40) == 0.0625, "carried debt lost")
	else
		assert(record == prepared:sub(i * 48 + 1, (i + 1) * 48), "exception record was overwritten")
	end
	local timer = buffer.tostring(timers):sub(i * 24 + 1, (i + 1) * 24)
	assert(timer == (if i == 5 then buffer.tostring(homingOut):sub(i * 32 + 1, i * 32 + 24)
		else timerBefore:sub(i * 24 + 1, (i + 1) * 24)), "exception/inactive timers were overwritten")
end
-- No homing buffers and empty batches are valid, including frozen budgets.
local snapshot = buffer.tostring(records)
P.Prepare(records, scales, timers, count, 0, nil)
assert(buffer.tostring(records) == snapshot, "zero time advanced a record")
P.Prepare(records, scales, timers, 0, 1, nil)
P.Commit(records, timers, result, 0, nil, nil, {}, {})
P.Commit(records, timers, result, count, nil, nil, {}, {})
assert(buffer.tostring(timers) == timerBefore:sub(1, 5 * 24) .. buffer.tostring(homingOut):sub(5 * 32 + 1, 5 * 32 + 24)
	.. timerBefore:sub(6 * 24 + 1), "non-homing pass changed timers")
print("[ProjectileApplyPassRegression] PASS: budgets, frozen time, homing, contacts, expiry, invalid poses, layout and empty batches")
