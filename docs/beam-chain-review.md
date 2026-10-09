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

Two separate passes at this were merged. Each one covers what the other missed.

From the dormant-packet pass (`master`, "upd"–"upd3"):

- **Dormant packets.** A packet on a lazy chain starts as a record that moves by formula. Its SpellRuntime binding (triggers, damage) is deferred, and it gets no `Projectile.Step` and no per-link cast. Each frame, the dormant stretch of a beam is joined into one simplified line and cast. Only the packets either side of a contact are made real and go through the normal link pass. A packet that never meets anything never becomes one. This replaces the old sleep system (and the Occupancy box queries it needed) entirely.

From this review:

- **Divide and repeat (`settle` / `halve`).** When a real packet's long lazy link touches something, it is halved, and only the touching half keeps halving. Halving stops once pieces are short enough to need no joiners, and those resolve normally. Splitting the whole link made length / 32 joiners; this makes about log2(length / 32). The same halving applies when a lazy link's front dies, with graded ages so it still expires in turn.
- **Launch samples only when needed (channel skipping).** On a lazy chain, a tick skips its sample while the aim turns less than 1° and the launch point moves less than 2 studs since the last launched sample, as long as that sample still flies. The skipped energy rides on the next launch, whose link covers exactly where the skipped samples would have flown. Links are capped at 4 × MaxStretch (≈120 studs at default speed). A steady beam goes from ~67 to ~17 packets/s per channel. That means fewer dormant records and Spawn messages. A sweep still gets a packet wherever the aim turned. The final tick and channel stops flush any pending energy.
- **Let go of parked fronts (`feeding`).** A link to a packet parked at a wall is kept only while the packet behind still heads into that spot. Once a sweep carries it past, it unlinks into an ordinary beam end, with no joiners and no strings. A new packet on a lazy chain may link to one that parked less than 0.15 s ago, but only if it heads there. Without this, skipping would leave a gap in front of walls.
- **No more dashes under budget (lazy chains).** A link that can't be halved now stays whole and resolves as one body, clipped at the wall, instead of tearing off a permanent fragment.
- **Client.** Chains are drawn oldest first, so past the part budget it's always the newest chains that lose pieces, instead of a different set each frame.

Dropped in the merge: this review's per-frame "coast" and the sleep-window fix. Dormant drift does both jobs.

## How to check it in Studio

Stats tab, beam line: `packets (dormant), joiners, whole, new, casts`, plus the made-real reasons.

1. 12 channels, steady aim into open air: packets should drop to roughly a quarter (~50/channel), nearly all dormant, with joiners near 0 and a handful of casts.
2. 12 channels sweeping across walls: `new` joiners per frame and the joiner count should be much lower. Wall strings should be gone. `BreakReasons.Parked` counts the let-gos.
3. Beam held on a dummy and on a wall at 20 / 200 / 1000 studs: damage per second should match `LegacyBeams` / the previous build, with no gap or flicker at the impact point.
4. Spells with OnExpire / OnImpact triggers: trigger counts and positions are still spread along the beam.
5. Time-dilation zones: packets are made real (`Dilated`), and nothing should jump.

## Risks

- Skipping changes **when** a held-on target takes damage (≈15 Hz chunks instead of 67 Hz), not how much. If that matters for feel, lower `SKIP_SPACING`.
- A dormant strand is cast at frame ends, not swept between them. A thin object that a sweeping beam crosses entirely within one frame can be missed. The old per-sample casts had a similar gap, but this one is wider.
- None of this has been run. The regression suites under `tests/` target the legacy handler.
