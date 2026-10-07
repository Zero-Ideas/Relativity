"""Receives the game's debug stream over a WebSocket and writes it to disk.

    python tools/stats_server.py            # ws://127.0.0.1:8765

Every message the game's server sends (DebugStream.luau: stats snapshots,
log lines, command acks...) is appended to logs/stream.jsonl with the time it
arrived, and the newest message of each kind is kept in logs/latest.json.

Commands go the other way: every line appended to logs/commands.jsonl (see
tools/send_command.py) is forwarded to the connected game, which runs the
matching DebugStream.OnCommand handler.
"""
import asyncio
import json
import pathlib
import time

import websockets

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs"
LOGS.mkdir(exist_ok=True)
STREAM = LOGS / "stream.jsonl"
LATEST = LOGS / "latest.json"
COMMANDS = LOGS / "commands.jsonl"

latest: dict[str, dict] = {}
clients: set = set()


async def handle(socket):
    peer = socket.remote_address
    clients.add(socket)
    print(f"connected: {peer}", flush=True)
    try:
        async for raw in socket:
            try:
                message = json.loads(raw)
            except json.JSONDecodeError:
                message = {"kind": "text", "text": raw}
            if not isinstance(message, dict):
                message = {"kind": "value", "value": message}
            message["received"] = time.time()
            with STREAM.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(message) + "\n")
            latest[str(message.get("kind", "unknown"))] = message
            LATEST.write_text(json.dumps(latest, indent=1), encoding="utf-8")
    except websockets.ConnectionClosed:
        pass
    finally:
        clients.discard(socket)
    print(f"disconnected: {peer}", flush=True)


async def forward_commands():
    # start at the end: only commands written after the server started
    offset = COMMANDS.stat().st_size if COMMANDS.exists() else 0
    while True:
        await asyncio.sleep(0.2)
        if not COMMANDS.exists():
            continue
        size = COMMANDS.stat().st_size
        if size < offset:
            offset = 0
        if size == offset:
            continue
        with COMMANDS.open("r", encoding="utf-8") as file:
            file.seek(offset)
            lines = file.read().splitlines()
            offset = file.tell()
        for line in lines:
            if line.strip():
                for socket in list(clients):
                    try:
                        await socket.send(line)
                    except websockets.ConnectionClosed:
                        clients.discard(socket)
                print(f"sent command to {len(clients)} client(s): {line}", flush=True)


async def main():
    async with websockets.serve(handle, "127.0.0.1", 8765, max_size=8 * 1024 * 1024):
        print("listening on ws://127.0.0.1:8765, writing", STREAM, flush=True)
        await forward_commands()


if __name__ == "__main__":
    asyncio.run(main())
