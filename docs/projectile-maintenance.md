Projectile maintenance fixes
============================

Worker filters now follow resident-slot reference counts. Unused entries have a
60-second grace period; collection scans at most 64 entries per frame, with a
five-second interval between completed passes. Retirement prunes the Instance
trie and tells every worker to remove its params and occupancy ignore set.
Worker-set changes explicitly reset surviving workers' filters. IDs remain
monotonic so cached handle metadata cannot alias a replacement filter.

Rewind hit detection uses a shared, lazy 3D spatial index per projectile frame.
An entity's retained root history and current position form an envelope padded
by its body/head offsets and radii. Queries include projectile radius and the
whole segment, including intermediate and neighboring chunks. Explicit entity
creation, destruction and SetPosition invalidate the index within a frame.
Queries and entity envelopes above 256 cells use a conservative fallback instead
of allocating an enormous grid. The actual sphere tests, exclusions, callback
filter, head precedence, nearest-candidate ordering and line of sight remain.

Parallel mode enters at 32 projectiles and exits below 16. Global freezes keep
resident slots and pending edits without consuming simulation debt; real-time
expiry and destruction still release slots. Debug-ray mode still switches to
serial simulation and releases residents. Serial stepping and worker dispatch
consume the same PreSimulation budget and global-scale snapshot for each frame.
This intentionally uses simulation time, which can differ from wall time on an
overloaded server.

Gameplay quota remains 15,000 per player, with a configurable 100,000 global
ceiling. Departed players' surviving shots retain their reservations until
destruction. Administrator benchmarks continue to bypass these gameplay quotas.
VisualOffload ingress permits a burst of 240 registered messages and replenishes
120 per real second per player, before creating handler tasks. Payload checks
remain the responsibility of handlers. Global projectile debug switches require
Admin permission and boolean payloads.

Spawn wire format and worker occupancy watchers are unchanged: neither was a
demonstrated correctness bug. Local watchers preserve conservative behavior when
geometry changes before a publisher update arrives.

Validation
----------

Run `python tools/test_projectile_maintenance.py`. This executes the production
registry, rewind, packed Store, dispatch and ApplyPass code using deterministic
Roblox service/Actor/Vector3 doubles and real Luau buffers. It covers filter
retirement and prefix pruning, bounded cleanup, border and historical hits,
hurtbox offsets, long-segment/teleport fallbacks, exclusions and LOS, quotas,
ingress throttling, freeze/resume without repacking, slot removal during freeze,
direct spawn packing, threshold hysteresis and debug serial transitions. It also
runs the existing ApplyPass regression.

These checks do not measure Roblox Actor scheduling, engine raycasts or live
server FPS. Verify those in Studio and a published server when connected. No
rbxlx build is part of this workflow.
