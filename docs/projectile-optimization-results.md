# Projectile optimization results

Implemented and tested 2026-10-08. Here, **unloaded means a chunk with no entities**, as requested; the chunk's `Loaded` flag is not used for collision selection.

## Changes

- Entity-free spans use centerline raycasts after the existing occupancy test fails to prove them empty. A span's radius-expanded bounds must avoid occupied chunks; occupied boundaries and unusually broad/long spans retain spherecasts. The scan has an eight-cell cap, so a large diagonal never causes an unbounded search.
- The server maintains an entity-chunk membership mask on entity transitions. Workers reuse their existing per-frame entity-chunk snapshot; no new Actor messages or load-state snapshots were added. Already-known occupied movement steps bypass the new lookup entirely.
- Beam links needing no children skip temporary chain construction, path filling/copying, and child-creation setup. Live-node arrays compact in place. Unobstructed body queries keep their immutable input path; clipped paths allocate an independent snapshot.
- Body entity hits apply pierce/trigger effects without temporarily moving the tip. They no longer dirty worker movement solely to restore the same state. Genuine callback motion edits remain intact and still invalidate worker results.
- Piercing invalidates the body-filter cache when the pierced set actually changes, instead of recounting that set for every body query.
- Quantity channels calculate one spread direction per emission instead of rebuilding all N directions for each of N channels. Independent beamlet identity, energy, triggers, quotas, and clocks are retained; emission rate and stretch limits are unchanged.

## Measurements

Seven alternating baseline/current rounds in the same running Studio server, with warmups. Table values are median microseconds per call. The beam cases measure the entire link/refinement/body pass for **1,024 live beamlets**, not one beamlet. No visual rendering or network traffic was generated. Baseline/current fixtures used the same occupancy stub to select either the skipped-cast or forced-engine-cast path; actual engine Raycast/Spherecast calls were used. A separate entity was present in a remote chunk during the individual cast measurements.

| Case | Before (µs) | After (µs) | Change |
|---|---:|---:|---:|
| CastEmptyChunkWall | 6.718 | 1.763 | -73.8% |
| Beam1024EngineMiss | 4007.387 | 2843.538 | -29.0% |
| CastOccupancySkipped | 0.125 | 0.131 | 4.1% |
| CastOccupiedBody | 6.037 | 6.263 | 3.8% |
| Beam1024OccupancySkipped | 2885.483 | 2093.870 | -27.4% |
| CastEmptyChunkMiss | 0.980 | 0.864 | -11.8% |
| CastOccupiedKnown | 6.388 | 6.243 | -2.3% |
| CastEmptyCrossChunkMiss | 0.911 | 0.935 | 2.6% |

The beam pass improved from **2.89 ms to 2.09 ms** with casts skipped, and **4.01 ms to 2.84 ms** with engine misses: approximately **27–29% less time**. Empty-chunk wall casts improved from **6.72 µs to 1.76 µs** (approximately 74% less time).

The tradeoff is visible rather than hidden: occupied body queries added about 0.23 µs, and a forced cross-chunk engine miss added about 0.024 µs in this run. Those small lookup costs were outweighed by the measured beam-pass savings. Occupancy-skipped casts execute the same early-return path, with timing differences at noise scale. These are isolated kernel measurements, not a promise of the same percentage improvement in total server frame time or every possible map.

Indexed spread generation matched the original output in **1,548 comparisons** (fan/ring/stream, several counts/spreads, and vertical/nonvertical aims). A single microbenchmark of 100 × 32-channel ring emissions took 42.59 ms before versus 1.73 ms after; treat this as a directional result, not a whole-spell benchmark.

## Validation

- New serial regression: **26 checks passed**, covering entity entry/exit, negative coordinates, XZ/XYZ boundaries, radius grazing, bounded checks, actual engine cast selection, body piercing, dirty flags, callback motion changes, and clipped snapshot ownership.
- Real Actor test: **six workers**, 64 shots per phase. Empty chunks retained all 64 grazing shots; occupied chunks stopped all 64; removing entities restored the raycast behavior. Both phases applied real worker results; the occupied phase resumed 64 contacts. No late results or serial fallbacks were reported in the captured worker results.
- Existing beam suites passed: stretch, moving joiners, entity children, continuity, independent children, steady quota, and first-frame replication. Independent children produced three separate explosions; first-frame spawn batches remained 1000/1000/501.
- Updated stale regression fixtures to use current `Sustain.Seconds` and explosion `Radius`/`Edge` parameters, and to decode binary move batches. The old parameter failures reproduced on the baseline. A timing-sensitive freeze check failed on an early baseline/current run and passed on the final run; the separate moving-joiner and continuity suites also covered freeze/thaw.
- Luau syntax compilation and Rojo build validate the final source tree. The generated `src/Projectile.txt` bundle was refreshed.

Tests live under `tests/ProjectileOptimizationRegression.server.luau`, `tests/ProjectileCollisionLODWorkers.server.luau`, and `tests/ProjectileOptimizationBenchmark.server.luau`. They follow the repository's isolated Studio-fixture convention (`_ProjectileOptimizationOld*` / `_ProjectileOptimizationNew*`), with separate module caches, fake visual transport, and conservative occupancy. The benchmark fixture exposes the registered beam phase as `_TestBeamStep`; that hook is not shipped in production code. Local raw samples and the initial source snapshot are in ignored `logs/projectile-optimization-results.json` and `logs/projectile-optimization-baseline.json`.
