"""Summarizes the newest stats snapshots from logs/stream.jsonl.

    python tools/stats_report.py            # last 10 snapshots
    python tools/stats_report.py 30         # last 30
    python tools/stats_report.py 10 --logs  # and the log lines in between

One line per snapshot: projectile count, frame time, our share, the worker
phase, the main hot spots and the raycast skip rate.
"""
import json
import pathlib
import sys

STREAM = pathlib.Path(__file__).resolve().parent.parent / "logs" / "stream.jsonl"


def n(value) -> float:
    return value if isinstance(value, (int, float)) else 0.0


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 10
    show_logs = "--logs" in sys.argv
    if not STREAM.exists():
        print("no stream yet:", STREAM)
        return
    messages = [json.loads(line) for line in STREAM.read_text(encoding="utf-8").splitlines() if line.strip()]
    stats_seen = 0
    selected = []
    for message in reversed(messages):
        if message.get("kind") == "stats":
            stats_seen += 1
            if stats_seen > count:
                break
        selected.append(message)
    for message in reversed(selected):
        kind = message.get("kind")
        if kind == "stats":
            p = message.get("MainProfile") or {}
            checks = max(n(message.get("RaycastChecks")), 1)
            projectiles = n(message.get("Projectiles"))
            per = f"{n(message.get('StepMs')) / projectiles * 1000:5.2f}" if projectiles > 0 else "    -"
            print(
                f"proj {int(n(message.get('Projectiles'))):>7} | frame {n(message.get('FrameMs')):6.1f} | "
                f"ours {n(p.get('FrameOurs')):6.1f} ({per} us/proj) | "
                f"workers {n(message.get('SlowestWorkerMs')):6.1f}/{n(message.get('WorkerMs')):6.1f} | "
                f"pure {n(p.get('ApplyPlain')):5.1f} serial {n(p.get('ApplySlow')):5.1f} "
                f"pack {n(p.get('DispatchAcquire')):5.1f} homing {n(p.get('HomingDispatch')):5.1f} "
                f"(searches {n(p.get('HomingSearches')):5.0f}, main {n(p.get('HomingSearch')):4.1f} ms) beam {n(message.get('BeamMs')):5.1f} | "
                f"skip {n(message.get('RaycastsSkipped')) / checks * 100:3.0f}%"
                + (" baking" if message.get("OccupancyReady") is False else "")
            )
        elif show_logs and kind in ("log", "ack"):
            print("   ", kind, message.get("level", ""), message.get("text") or message)


main()
