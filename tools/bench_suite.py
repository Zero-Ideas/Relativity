"""Runs ProjectileBench configurations one after another and reports them.

    python tools/bench_suite.py b1:basic f1:full            # 60000 for 20 s each
    python tools/bench_suite.py b2:basic Target=30000 Seconds=15

Each LABEL:MODE starts a run (tools/send_command.py bench ...), waits for its
"end" marker in logs/stream.jsonl, then the next one starts. Finally prints
tools/bench_report.py for all of them. Needs tools/stats_server.py running
and the game connected.
"""
import json
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
STREAM = ROOT / "logs" / "stream.jsonl"
COMMANDS = ROOT / "logs" / "commands.jsonl"


def send(fields: dict):
    with COMMANDS.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(fields) + "\n")


def wait_for_end(label: str, offset: int, timeout: float) -> int:
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(1)
        if not STREAM.exists():
            continue
        with STREAM.open(encoding="utf-8") as handle:
            handle.seek(offset)
            chunk = handle.read()
        for line in chunk.splitlines():
            if '"bench"' in line and label in line:
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if message.get("label") == label and message.get("phase") in ("end", "error"):
                    return STREAM.stat().st_size
    print(f"timed out waiting for {label}")
    return STREAM.stat().st_size if STREAM.exists() else 0


def wait_ready(timeout: float = 45):
    """Until the game streams again and its occupancy grid is fully refined."""
    offset = STREAM.stat().st_size if STREAM.exists() else 0
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(1)
        with STREAM.open(encoding="utf-8") as handle:
            handle.seek(offset)
            chunk = handle.read()
        if "occupancy refinement complete" in chunk:
            time.sleep(2)
            return
    print("warning: never saw occupancy refinement complete; running anyway")


def main():
    if "--wait" in sys.argv:
        wait_ready()
    runs = [a for a in sys.argv[1:] if ":" in a and "=" not in a]
    extra = dict(a.split("=", 1) for a in sys.argv[1:] if "=" in a)
    target = int(extra.get("Target", 60000))
    seconds = int(extra.get("Seconds", 20))
    for run in runs:
        label, mode = run.split(":", 1)
        offset = STREAM.stat().st_size if STREAM.exists() else 0
        send({"cmd": "bench", "Mode": mode, "Target": target, "Seconds": seconds, "Label": label})
        wait_for_end(label, offset, seconds + 60)
        time.sleep(3)  # let the last projectiles die before the next run
    subprocess.run([sys.executable, str(ROOT / "tools" / "bench_report.py"), *[r.split(":", 1)[0] for r in runs]])


main()
