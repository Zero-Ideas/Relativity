"""Summarises one ProjectileBench run from logs/stream.jsonl, compactly.

    python tools/bench_report.py              # the newest run
    python tools/bench_report.py b0           # the newest run labelled b0
    python tools/bench_report.py b0 f0        # two runs side by side
    python tools/bench_report.py --runs       # list runs

Only stats snapshots inside the run's window count, minus the first WARMUP
seconds (population ramp). Every number is the mean over those snapshots.
Main-thread profile sections (ms/frame) and counts are listed largest first;
worker sections (WorkerProfile) likewise. Log lines in the window are
deduplicated and capped.
"""
import json
import pathlib
import sys
from collections import Counter

STREAM = pathlib.Path(__file__).resolve().parent.parent / "logs" / "stream.jsonl"
WARMUP = 4.0
TOP = 20

# Profile names that are counts per frame, not ms (Profile.Count)
COUNTS = {
    "Acquired", "BeamCreated", "BeamDormant", "BeamHeads", "BeamSamples", "BeamStrandCasts", "BeamFlowEngineStuds",
    "CastRay", "CastSphere", "FastAcquired", "FastMissed", "HomingSearches", "Released", "SerialContacts", "Slots",
    "Spawned", "TransferKB", "HeapMB", "GcFreedMB", "Items", "Casts", "Rays", "Spheres", "Checks", "Skipped",
}

SCALARS = [
    ("Projectiles", "proj", 0), ("Fps", "fps", 1), ("FrameMs", "frame", 2), ("StepMs", "step", 2),
    ("SlowestWorkerMs", "worker max", 2), ("WorkerMs", "workers sum", 2), ("PhysicsMs", "physics", 2),
    ("HeartbeatMs", "heartbeat", 2), ("ReplicationMs", "replication", 2), ("CastsRay", "rays/frame", 0),
    ("CastsSphere", "spheres/frame", 0), ("ParallelSteps", "parallel", 0), ("ResumedSteps", "resumed", 0),
    ("SerialSteps", "serial", 0), ("FallbackSteps", "fallback", 0), ("LateSteps", "late", 0),
    ("SendKbps", "send KB/s", 1), ("MemoryMb", "memory MB", 0), ("OccupancyDynamic", "moving parts", 0),
    ("EffectiveCores", "cores used", 1), ("CoreProbeCores", "cores (probe)", 1),
]


def num(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def load():
    if not STREAM.exists():
        sys.exit(f"no stream: {STREAM}")
    with STREAM.open(encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    pass


def runs():
    """[(label, mode, target, start_clock, end_clock, messages)] in order."""
    found, current = [], None
    for message in load():
        kind = message.get("kind")
        if kind == "bench" and message.get("phase") == "start":
            current = {"label": message.get("label"), "mode": message.get("mode"), "target": message.get("target"),
                       "start": message.get("clock", 0), "end": None, "messages": []}
            found.append(current)
        elif kind == "bench" and message.get("phase") == "end" and current:
            current["end"] = message.get("clock")
            current = None
        elif current is not None and kind in ("stats", "log"):
            current["messages"].append(message)
    return found


def summarise(run):
    stats = [m for m in run["messages"] if m.get("kind") == "stats" and m.get("clock", 0) - run["start"] >= WARMUP]
    logs = [m for m in run["messages"] if m.get("kind") == "log"]
    out = {"n": len(stats), "scalars": {}, "main": {}, "worker": {}, "reasons": None, "skip": None, "logs": logs}
    if not stats:
        return out
    def mean(values):
        values = [v for v in values if v is not None]
        return sum(values) / len(values) if values else None
    for key, _, _ in SCALARS:
        out["scalars"][key] = mean([num(s.get(key)) for s in stats])
    for field, target in (("MainProfile", "main"), ("WorkerProfile", "worker")):
        keys = set()
        for s in stats:
            keys.update((s.get(field) or {}).keys())
        for key in keys:
            value = mean([num((s.get(field) or {}).get(key, 0)) for s in stats])
            if value:
                out[target][key] = value
    checks = mean([num(s.get("RaycastChecks")) for s in stats]) or 0
    skipped = mean([num(s.get("RaycastsSkipped")) for s in stats]) or 0
    out["skip"] = skipped / checks * 100 if checks else None
    reasons = [s.get("RaycastReasons") for s in stats if isinstance(s.get("RaycastReasons"), list)]
    if reasons:
        out["reasons"] = [sum(r[i] for r in reasons if len(r) > i) / len(reasons) for i in range(5)]
    return out


def fmt(value, digits):
    if value is None:
        return "-"
    return f"{value:,.{digits}f}"


def is_count(key):
    return key in COUNTS or key.endswith("Count")


def section(title, entries, top=TOP):
    ms = sorted(((k, v) for k, v in entries.items() if not is_count(k)), key=lambda kv: -kv[1])
    counts = sorted(((k, v) for k, v in entries.items() if is_count(k)), key=lambda kv: -kv[1])
    lines = []
    if ms:
        lines.append(f"  {title} ms/frame: " + "  ".join(f"{k} {v:.2f}" for k, v in ms[:top]))
        if len(ms) > top:
            lines.append(f"    (+{len(ms) - top} smaller, total {sum(v for _, v in ms[top:]):.2f})")
    if counts:
        lines.append(f"  {title} counts: " + "  ".join(f"{k} {v:,.0f}" for k, v in counts[:top]))
    return lines


def show(run):
    s = summarise(run)
    head = f"== {run['label']} ({run['mode']}, target {run['target']}) -- {s['n']} snapshots"
    print(head)
    if not s["n"]:
        print("  (no steady-state snapshots: is the run still going, or the stream disconnected?)")
        return
    print("  " + "  ".join(f"{label} {fmt(s['scalars'].get(key), d)}" for key, label, d in SCALARS[:10]))
    print("  " + "  ".join(f"{label} {fmt(s['scalars'].get(key), d)}" for key, label, d in SCALARS[10:]))
    if s["skip"] is not None:
        reasons = s["reasons"] or [0] * 5
        print(f"  casts skipped {s['skip']:.0f}%  not skipped (not baked / too wide / outside / near geometry / moving): "
              + " / ".join(f"{r:,.0f}" for r in reasons))
    for line in section("main", s["main"]) + section("worker", s["worker"]):
        print(line)
    texts = Counter(f"{m.get('level', '')}: {str(m.get('text', ''))[:140]}" for m in s["logs"]
                    if m.get("level") in ("warn", "error", "Warning", "Error", "MessageWarning", "MessageError"))
    for text, count in texts.most_common(5):
        print(f"  log x{count}: {text}")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    all_runs = runs()
    if "--runs" in sys.argv:
        for run in all_runs[-20:]:
            print(run["label"], run["mode"], run["target"], "open" if run["end"] is None else "")
        return
    if not all_runs:
        sys.exit("no bench runs in the stream yet")
    chosen = []
    for label in args or [None]:
        matches = [r for r in all_runs if label is None or r["label"] == label]
        if not matches:
            print(f"no run labelled {label}")
            continue
        chosen.append(matches[-1])
    for run in chosen:
        show(run)


main()
