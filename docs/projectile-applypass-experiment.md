# Native ApplyPass experiment

This experiment extracts the resident workers' time-budget updates and result writeback into `Projectile/ApplyPass.luau`, annotated `--!native`. It preserves worker ownership and the existing main-thread contact path. It does not restore the old main-thread ApplyPass architecture.

Native ApplyPass is enabled by default. Only an explicit `ServerScriptService.ProjectileApplyPass = false` selects the baseline path. Workers read the flag once per batch, so it can change with projectiles already active. Admin access is checked on the server. ReplicatedStorage mirrors the flag for the UI.

## Published-server comparison

1. Publish the updated Studio place and join a fresh server containing the change. Existing servers will retain their previous code.
2. Let occupancy refinement and the core probe settle. Record the worker count and keep the scene, time scale and projectile population steady.
3. Open Debug Panel > Admin > Projectile performance experiment. Turn **Native projectile ApplyPass** off for the baseline.
4. Use the existing Benchmarks tab to reproduce the load. For a stable batch, use zero damage, a long lifetime and a sufficient MaxRealLifetime. Preserve the original visualization settings when reproducing the reported regression; a separate server-only test can isolate simulation cost.
5. Measure off, on, on, off, allowing a few seconds after each switch before recording at least 15 seconds per window. Record active projectiles, worker count, server frame average/worst, slowest/all worker ms, main movement ms and engine casts per frame. Keep detailed ProjectileProfile timing off for the primary comparison.
6. The Stats tab displays **Native ApplyPass / prepare / writeback ms (all workers)**. Prepare is included in worker setup; writeback is separately measured in the replacement. The baseline's inline writeback remains included in its loop measurement, so baseline writeback displays zero rather than a comparable isolated value.

Success means consistently lower server frame time at equivalent load, supported by worker timings. A smaller main movement number alone does not establish success. Switch off to return to the baseline immediately. The flag is not persisted between servers.

For the existing Studio analytics benchmark, `ApplyPass=0` or `ApplyPass=1` can be supplied to `tools/send_command.py bench`; the prior setting is restored when that run ends.

## Validation

- All changed Luau files compile; Rojo builds successfully.
- `tests/ProjectileApplyPassRegression.luau` passes in Roblox: scaled/carried budgets, frozen time, exact record layout, contacts, expiry, invalid positions, homing changes/timers and empty batches.
- Live Studio Actors pass off/on/off motion continuity and expiry of 100 homing shots while 20,000 ordinary shots remain active.
- One short Studio ABBA run with 20,000 straight, server-only shots and eight workers showed slowest-worker means of 4.18/3.55/3.45/4.27 ms and summed-worker means of 28.74/24.21/23.77/29.61 ms. Whole-frame means were 12.35/14.57/14.03/17.45 ms with large spikes and concurrent scene changes. These are exploratory local results, not evidence of a published-server FPS improvement.

Published-server performance has not yet been measured.
