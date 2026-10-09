# Projectile performance review

Reviewed 2026-10-08. Investigation and recommendations only; gameplay code was not changed.

The largest architectural issue is that beam geometry subdivisions are full gameplay projectiles. They incur movement, collision, lifecycle, spell-trigger, replication, and client-prediction costs independently. Movement already runs on Actors when eligible; the additional beam topology/body-collision pass is serial.

## Evidence and limits

- Inspected the server projectile, beam handler, worker, replication, spell integration, and client beam paths, plus existing beam regression tests.
- Historical `logs/stream.jsonl`, lines 11410–11411, contains two useful beam samples:

| Snapshot | Active at snapshot | Average links/frame | Movement/dispatch ms | Beam ms | Body resolution ms | Replication ms |
|---|---:|---:|---:|---:|---:|---:|
| 11410 | 41 | 28.24 | 0.740 | 0.532 | 0.314 | 0.232 |
| 11411 | 31 | 35.61 | 0.509 | 0.612 | 0.356 | 0.249 |

Body resolution accounts for approximately 58–59% of the beam phase in these samples. Active counts are instantaneous; timings/link counts are interval averages. These are historical, uncontrolled samples, not a reproduction of the reported worst case and not a basis for claiming a particular speedup. `BeamResolve` also includes hit callbacks, occupancy work, and allocations, so it is not a pure engine-raycast timer.

All live Studio sampling windows were idle (zero active projectiles), so no current heavy-beam workload was captured. Performance recommendations below follow confirmed code paths; improvements require controlled before/after measurements.

## Highest-priority findings

### 1. Default emission spacing creates unnecessary subdivision pressure

Locations: `src/server/Projectile/BeamProjectileHandler.luau:22`, `src/shared/Projectile/BeamPath.luau:8`, `src/shared/SpellRunes.luau:1043`.

`GetInterval(2000)` returns 1/60 because the interval has a 1/60 lower bound. A normally moving packet travels about 33.33 studs between emissions, exceeding `MaxStretch = 32`. `BeamPath.Plan` requests one joiner for that straight gap. Thus the default straight stream can approach one extra projectile per emitted packet, even without flicks, bounces, or differential time dilation. Actual counts depend on frame timing and collisions.

At 60 emissions/s and the default three-second lifetime, uninterrupted flight can retain roughly 180 emitted packets plus a similar number of first-generation joiners per channel. Quantity multiplies channels. Slow regions, sharp turns, and moving/stopped endpoints can require further refinement.

Recommendation: decouple the maximum collision/sample span from a visual segment length. Choose physical subdivision from curvature, time boundaries, collision accuracy, and divergence between neighboring trajectories. As a smaller experiment, increase the straight-link threshold enough to accommodate default spacing and frame jitter, then compare hit/trigger behavior. Raising it changes the number of independently hitting samples, so this is a gameplay-sensitive change, not a free constant tweak. Raising emission frequency would avoid this particular gap but also creates more emitted projectiles.

### 2. Every live link receives another serial collision pass every frame

Locations: `BeamProjectileHandler.luau:139`, `Projectile/init.luau:1286`, `Projectile/init.luau:1509`.

After movement is applied, the handler rebuilds live-node arrays, updates incoming links, plans every adjacent path, allocates connection/path tables, and resolves every body. Body casts use the existing occupancy skip, so they do not necessarily become engine calls, but their geometry and occupancy work still run. Contacts may repeat casts with expanded exclusions, up to 16 contacts per resolution.

This work is additional to each node's movement sweep. It is semantically necessary for a body that can strike targets away from its moving tip; simply removing it would break gameplay.

Recommendations:

1. Implement a dedicated common path for an unchanged two-endpoint link with no required subdivision. Avoid constructing `corners`, `chain`, and a second filled path solely to recover the same endpoints. Return before filter preparation for paths with fewer than two points.
2. Reuse per-stream scratch arrays and per-node output storage, with explicit snapshot ownership. Replication queues and retired/impact paths must never reference a buffer that is later overwritten.
3. Maintain topology versions and a pierced-set version instead of repeatedly discovering changes. `spanParams` currently counts every pierced entity on every resolution just to validate its cache.
4. Separate pure body queries from authoritative damage/trigger application. Batch independent queries by stream or spatial region on workers; resolve resulting contacts serially in a defined order. Further casts after a pierce/filter rejection still need a continuation policy.
5. Cache unchanged static-world clipping only with sound geometry/world invalidation. Continue dynamic-entity checks; a stationary or frozen beam can have a target or wall move into it.

### 3. Joiners duplicate substantial spell/lifecycle state

Locations: `Projectile/init.luau:590`, `SpellRuntime.luau:1173`, `Signal.luau:74`.

Each joiner clones a full projectile, receives a Store slot, new signals, copied bounce/pierce state, and new spell closures/watches. Movement RaycastParams are already shared by content, which is worth retaining. Energy is divided, but the fixed CPU cost of each hit, trigger, explosion, and lifecycle event is not. A hundred tiny-energy children can still execute a hundred expensive effects.

Recommendation: use compact beam-sample records with shared immutable cast/spell/visual configuration. Keep independent ID, energy, age, velocity, pierced state, and trigger progress, but represent common trigger behavior as data plus shared functions. Materialize the general public projectile wrapper/signals only when required by external consumers. Pool scratch records with generation checks; do not reuse publicly retained projectile identities.

Do not replace all joiners with cosmetic points under the current contract. `BeamIndependentChildrenRegression.server.luau` explicitly requires independent time clocks, surviving siblings, conserved energy, quota ownership, and child explosions. Those behaviors can survive a storage rewrite.

### 4. Beam body resolution can invalidate otherwise usable worker results

Locations: `Projectile/init.luau:1339`, `Projectile/Store.luau:155`, `Projectile/init.luau:1201`.

For an entity body contact, resolution temporarily changes `Velocity`, invokes the ordinary hit resolver, then restores both `Position` and `Velocity`. Store marks motion writes dirty even when the final value is unchanged. A surviving pierced/rejected body contact can therefore leave a dirty slot after the beam phase. The next worker result goes through serial fallback, redoing movement before repacking.

Recommendation: split entity-hit effects from movement/nudging. Pass body-contact direction explicitly and let body resolution apply pierce/energy effects without temporarily changing motion. Preserve genuinely callback-induced state changes; blindly clearing the dirty flag would hide real mutations.

### 5. Homing and interest handling multiply per-node network work

Locations: `Projectile/Replication.luau:57`, `:318`, `:502`.

Ballistic beams already receive sparse 0.5-second refreshes. Homing beams return `true` from `beamDue` every frame, so each can request a pose containing position, velocity, lifetime, time data, topology, and path. The 2,500-pose cap bounds sends, not the full candidate scan. Range checks separately visit up to 2,500 interest entries and iterate players for each entry. Many nodes share the same channel, owner, visual, and recipients.

Recommendations:

- Replicate stream-level shared metadata once, with compact node births/deaths/topology deltas.
- Use explicit topology/clipping versions and a scheduled refresh queue instead of checking every ballistic node for a due refresh every frame.
- Apply an error-based, capped cadence to homing corrections; test prediction error under sharp turns and dilation. Keep immediate authoritative discontinuities.
- Share broad-phase interest by channel/spatial section, retaining per-section visibility where a long beam crosses range boundaries.
- Maintain separate priority for lifecycle/topology events versus replaceable motion snapshots, and measure bytes per recipient, not only entry counts.

## Other concrete opportunities

| Finding | Evidence | Recommendation |
|---|---|---|
| Quantity beams calculate the entire spread once per channel. N channels each build N directions per emission, then select one. | `SpellRuntime.luau:1089`, `:1237`, `:1758` | Add a direction-at-index function, or evaluate a shared simultaneous emission once. Preserve staggered live aim and graph evaluation semantics. |
| Every spell shot creates a fresh filter closure. Filter identity is part of the shared-spec key; any filter also disables worker-side homing acquisition. | `SpellRuntime.luau:1158`, `Projectile/Spec.luau:48`, `Projectile/Parallel.luau:407`, `:797` | Express common source/alive/tag rules as data or a built-in predicate. Keep arbitrary callbacks as an explicit slower path. Cache immutable cast configuration. |
| Worker homing search scans the entire target-position array per search. | `Projectile/Sweep.luau:101`, `Projectile/Parallel.luau:93` | Give worker target snapshots spatial buckets and cached tag bits. Nearby projectiles may share candidate lists, but must still select targets from their own positions. |
| Trigger watches are all scanned every frame, and middle removals shift the array. | `SpellRuntime.luau:2081` | Swap-remove when ordering is irrelevant; stagger/bucket proximity checks. Schedule timers in each projectile's simulation-time domain, not a simple wall-clock heap that breaks dilation. |
| Admission is a 15,000-projectile limit per player, not a server CPU budget. A beam body and a simple bullet consume the same quota unit. | `ProjectileQuota.luau:11`, `BeamProjectileHandler.luau:15` | Add server-wide and per-player work budgets that account for active links, spawn/refinement rate, homing, and trigger expansion. Reserve expected subdivision capacity before starting a cast. Do not arbitrarily skip authoritative hits to meet the budget. |
| Parallel dispatch toggles at 32 active projectiles and releases all slots below the threshold. | `Projectile/Parallel.luau:135`, `:702` | Benchmark a workload-aware threshold with hysteresis. A beam with costly movement is different from an empty-space bullet. Avoid repeated slot teardown when counts hover near the cutoff. |
| The occupancy system rebuilds dynamic bounds separately in each querying VM; static marks only accumulate. | `Projectile/Occupancy.luau:285`, module design comments | Profile whether one packed dynamic snapshot per physics phase beats repeated bound construction. Add dirty-region rebaking/removal for long-lived mutable maps; keep conservative correctness. Increasing worker count is not automatically a win. |
| Parallel filter IDs retain strong instance-keyed tries, and motion specs accumulate to a permanent 65,535-ID ceiling. | `Projectile/Parallel.luau:201`, `:296`, `:420` | Add refcounted retirement or safe cache epochs mirrored to workers. Do not recycle IDs while dispatched batches can reference them. Test repeated respawns/barrier/config churn. |
| Actual weapon shots with rewind enabled are excluded from workers; stress tests default to no rewind and use compiled firing. | `Shooter.server.luau:324`, `:491`, `Projectile/init.luau:1166`, `ProjectileBenchmark.luau:52` | Benchmark real weapon/spell constructors and callbacks. Consider separating parallel world movement from serialized rewind hit processing, with matching time/trajectory semantics. |
| Beam prediction bypasses the ordinary client update budget and marks groups dirty every frame, including no-motion cases. | `Client/init.luau:683`, `Client/BeamVisual.luau:31`, `:173` | Budget coherent groups/sections at one presentation epoch, add distance-based update cadence, and only rebuild merged geometry when endpoints/topology/visibility change. Do not mix endpoint epochs within one visible link. |

Actor messaging is not free shared memory: Roblox copies buffers passed through its APIs. Keep worker batches coarse enough to amortize transfers, and measure transfer volume before adding another pass. See [Roblox buffer documentation](https://create.roblox.com/docs/reference/engine/libraries/buffer).

## Correctness issues to cover during optimization

- `ResolveBeamSpan` uses a shape sweep as a body query. Add regressions for a joiner initially overlapping a target, a stationary body, and rapid sideways movement across an entity. A current-frame centerline plus endpoint movement sweeps does not inherently cover the entire swept body between frames.
- Standalone beams without `ChannelId` are not registered in the handler's streams, while the client draws a traveled tail. Verify whether that tail is intended to damage entities entering behind the tip; the current body-resolution path is stream-driven.
- Normalize public projectile radii to supported engine-query limits or reject unsupported shapes clearly. `Config.normalize` permits radii much larger than Spherecast's documented maximum. Roblox also documents a maximum Spherecast travel distance. See [WorldRoot reference](https://create.roblox.com/docs/reference/engine/classes/WorldRoot#Spherecast).
- Preserve immediate completed spawn geometry, world-stop anchors, independent child hits, energy/quota conservation, and client/server time agreement. The existing beam regression suite is valuable coverage for the rewrite.

## Suggested implementation order

1. Capture one reproducible beam setup and add separate counters for emitted packets, active joiners, movement casts, body casts, skipped casts, hit callbacks, trigger expansions, network bytes, and dirty fallbacks. Use one stats collector: existing `Take*` APIs reset their measurements. Report p50/p95/p99 frame costs, not just averages.
2. Implement the behavior-preserving reductions: indexed spread direction, common data-based filters, two-endpoint beam fast path, reusable scratch storage, versioned pierced sets, removal of temporary motion mutations, and cheaper watch removal.
3. Benchmark a compact sample store and shared cast data. Retain the general projectile engine for ordinary projectiles and external API compatibility.
4. Add channel/section replication and interest handling. Then evaluate parallel body-query batches; maintain serialized gameplay effects and generation/topology validation.
5. Tune physical sample density and admission limits using the resulting measurements. Treat lower simulation frequency or fewer independently hitting samples as explicit gameplay changes.

Suggested matrix: one/many channels; equal active-node counts and equal cast energy; straight/flicking/bouncing/homing beams; open sky/walls/dense targets; normal/slow/frozen time; no triggers/impact explosions/proximity triggers; visuals on/off; and repeated respawns/long-running map changes. Compare worker and serial modes, and run server/client profiling separately so local Studio contention is not mistaken for production server cost.
