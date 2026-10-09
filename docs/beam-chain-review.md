# BeamChain review: why sustained beams choke, and "divide only where needed"

Reviewed 2026-10-09 against `0ae4a4b` ("shitty new system"). This review comes from reading the code. Nothing was run in Studio, so treat the numbers as estimates from the code paths. Confirm them with the Stats tab counters listed at the end.

## Why 12 sweeping beams fall over

Default Beam: 2000 studs/s, 3 s lifetime, radius 0.35.

### 1. Sample count is fixed by `MaxStretch`, not by need

`Chain.GetInterval(2000)` = `(32 - 2) / 2000` = 0.015 s. Each channel therefore launches about 67 samples/s, roughly 200 of them alive at once. With 12 channels that is about **2,400 live samples**, every one of them **awake**, and about 800 launches/s. Each launch runs the full SpellRuntime `launch` path: `Config.normalize`, the ray params, a quota slot, `liveContext` and graph evaluation for the aim, and the OnHit/OnDestroy closures and trigger watches. The lazy-link machinery almost never engages for a steady beam, because consecutive samples are already under 32 studs apart (`needed == 0`). Every link is then an ordinary `ResolveBeamSpan` cast every frame.

### 2. Every sample is stepped serially on the main thread

Samples are plain tables, so `Parallel.Offer` never sees them. Every awake sample runs the full `Projectile.Step` serially: substep planning, chunk sampling, `chunkHasEntities` and `castMovement`. Under the legacy handler, packets were Store projectiles and their movement went to the Actor workers. The new system moved that work back onto the main thread.

### 3. The sleep optimisation can never trigger at default speed

`trySleep`: `window = SLEEP_STUDS / speed = 96 / 2000 = 0.048 s`, but the minimum is `SLEEP_MIN_FRAMES * frame = 3 / 60 = 0.05 s`. Every default beam sample is rejected as "Window" every time. The Stats tab's awake reasons should show `Window` far ahead of every other reason.

### 4. A contact splits the whole link, not the part that touched

When a lazy link's probe fails, `split` inserts **every** joiner along the link (`length / 32`) at once, even when only one end grazes a wall. Each joiner is a fully bound SpellRuntime packet. A sweep makes the far end of the beam fan out: links grow to hundreds of studs and keep touching the map. The per-beam cap (512) and per-frame cap (128) fill up fast. 12 chains × 512 = 6,144 possible joiners on top of the 2,400 samples.

### 5. Wall "strings": links to parked samples never let go

A sample that hits a wall parks there (`_worldStop`), and the sample behind keeps linking to the parked point **for its whole life**. When a sweep carries that sample past the wall's edge, the link stretches sideways and gets joiners. Those joiners hit the wall and park in turn, and each one anchors another stretched link. The result is a fan of strings hanging off every wall the beam swept across, costing CPU for up to 3 s. The only limits are `MaxJoinerSourceAge` and the 1024-stud `Plan` limit. **These are the most likely "artifacts".**

### 6. Budget pressure leaves permanent dashes

When a link can't get joiners (budget, quota, or `Plan` > 32 joiners), `unlink` turns the sample into a 32-stud fragment that **never relinks**. Under load (items 4 and 5 exhaust the budgets), the beam turns into floating 32-stud dashes for the rest of their lifetime. That's the second artifact source.

### 7. Client part budget flickers

`BeamChainVisual` draws at most 2,400 cylinders per frame across all chains, in **hash order**. Past the budget, whichever chains come last lose pieces, and with 12 curved chains (every link is a vertex) that budget is reachable. Each cylinder is also 2 parts + 2 Motor6Ds, and all of them are re-posed every frame.

## The sketch: sweep, detect, divide and repeat

Yes, this works. It is a natural extension of the existing lazy links, and it is now implemented in `BeamChain`.

- **Divide and repeat (`settle` / `halve`).** A long lazy link stays one body while `ProbeBeamSpan` finds nothing. When the probe fails, the link is halved: one joiner at the middle of its path length, placed, moving, aged and given its energy exactly as the eager split would. Each half is then probed again. A clear half stays a single lazy body. A touching half is halved again, down to pieces under 32 studs, which resolve normally (hits, clipping, joiner deaths). A point contact on a link of length L now costs about log2(L/32) joiners instead of L/32: 4 instead of 15 for 512 studs, 5 instead of 31 for 1024. The untouched pieces are exactly the bodies the eager joiners would have had, so the hit/energy outcome is unchanged. The lazy link whose front died uses the same halving, again with graded ages so it still expires in turn.
- **Launch samples only when needed (channel skipping).** On a lazy chain, a channel tick skips its sample when the aim has turned less than 1° and the launch point has moved less than 2 studs since the last launched sample, and that sample is still alive. The skipped ticks' energy rides on the next launched sample. Its link to the previous sample covers exactly where the skipped samples would have flown: same origin and direction means the same chord. That is the "beamlet that didn't need to exist". Links are capped at 4 × MaxStretch (≈120 studs at default speed). A steady beam drops from ~67 to ~17 samples/s per channel. A sweeping beam still gets a sample wherever the aim actually turned, so shape fidelity is unchanged. The last tick and channel stops flush any pending energy, so total energy is conserved. Chains with OnTimer/OnProximity triggers (not lazy) and the legacy handler are unaffected.
- **Let go of parked fronts (`feeding`).** A link to a sample parked at a wall is kept only while the sample behind still heads into that spot: forward along the link, with lateral offset under MaxStretch. Once a sweep carries it past, it unlinks into an ordinary beam end along its own velocity. No joiners are ever made for such a stretched link, so no strings. A new sample on a lazy chain may link to a previous sample that parked less than 0.15 s ago, but only if it heads there. Without this, skipping would leave a gap in front of walls.
- **No more dashes under budget (lazy chains).** A link that can't be halved (budget, quota) now stays whole and resolves as one body, clipped at the wall, instead of tearing off a permanent fragment.
- **Coast (`coast`).** If Occupancy proves a sample's next frame of flight empty, the sample moves exactly, with constant acceleration and the chord widened by the arc's bow, without running `Projectile.Step`. This is the same reasoning as sleep, applied per frame with a cheap segment test. It only applies under uniform time, with no homing and no speed clamps. Anything else, or any doubt, takes the full step.
- **Sleep fix.** `SLEEP_MIN_FRAMES` 3 → 2, so default-speed samples can sleep. Long diagonal bodies still often fail the 27-cell box test, so expect coast to matter more.
- **Client.** Chains are drawn oldest first, so past the part budget it's always the newest chains that lose pieces, instead of a different set each frame.

Unchanged: the wire format, `materializeAhead` (a lazy link's back dying on a hit still splits eagerly, since that only happens on hits), non-lazy chains' eager split, and the legacy handler.

## How to check it in Studio

Stats tab, beam line: `samples (asleep, coasting), joiners, whole, new`.

1. 12 channels, steady aim into open air: samples should drop to roughly a quarter (~50/channel), with most coasting and joiners near 0.
2. 12 channels sweeping across walls: `new` joiners per frame and the joiner count should be much lower. Wall strings should be gone. `BreakReasons.Parked` counts the let-gos.
3. Beam held on a dummy and on a wall at 20 / 200 / 1000 studs: damage per second should match `LegacyBeams` / the previous build, with no gap or flicker at the impact point.
4. Spells with OnExpire / OnImpact triggers: trigger counts and positions are still spread along the beam.
5. Time-dilation zones: chains fall back to full steps (`Dilated`), and nothing should jump.

## Risks

- Skipping changes **when** a held-on target takes damage (≈15 Hz chunks instead of 67 Hz), not how much. If that matters for feel, lower `SKIP_SPACING`.
- Coast trusts `Occupancy.SegmentClear` exactly as `Projectile.Step` already does for its casts, but it skips the substep planner. If a map edit isn't reflected in Occupancy, coast will miss it in the same way the existing skip does.
- None of this has been run. The regression suites under `tests/` target the legacy handler.
