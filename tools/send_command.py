"""Sends a command to the running game through tools/stats_server.py.

    python tools/send_command.py stress Count=10000 ServerOnly=true
    python tools/send_command.py stress Count=2000 ServerOnly=true Homing=true

The first argument is the command (a DebugStream.OnCommand name); the rest are
Key=value fields (true/false and numbers are converted).
"""
import json
import pathlib
import sys

COMMANDS = pathlib.Path(__file__).resolve().parent.parent / "logs" / "commands.jsonl"


def value(text: str):
    if text in ("true", "false"):
        return text == "true"
    try:
        return int(text)
    except ValueError:
        try:
            return float(text)
        except ValueError:
            return text


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    message = {"cmd": sys.argv[1]}
    for field in sys.argv[2:]:
        key, _, text = field.partition("=")
        message[key] = value(text)
    COMMANDS.parent.mkdir(exist_ok=True)
    with COMMANDS.open("a", encoding="utf-8") as file:
        file.write(json.dumps(message) + "\n")
    print("queued", message)


main()
