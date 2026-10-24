#!/usr/bin/env python3
"""只转发 Claude Code 的 Stop 信号；不读取或转发会话正文。"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import sys
import uuid

MAX_INPUT_BYTES = 64 * 1024


def fail(message: str) -> int:
    print("X Nook: " + message, file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", type=Path, default=Path("/tmp") / ("xnook-activity-%d" % os.geteuid()) / "claude.sock")
    args = parser.parse_args()
    raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        return fail("hook input is too large")
    try:
        event = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return fail("invalid hook input")
    if not isinstance(event, dict) or not isinstance(event.get("hook_event_name"), str):
        return fail("invalid hook event")
    if event["hook_event_name"] != "Stop":
        return 0

    try:
        directory = args.socket.parent.lstat()
        endpoint = args.socket.lstat()
    except FileNotFoundError:
        return 0  # 应用退出或开关关闭时不打扰 Claude。
    except OSError:
        return fail("local endpoint is unavailable")
    if (not stat.S_ISDIR(directory.st_mode) or directory.st_uid != os.geteuid()
            or stat.S_IMODE(directory.st_mode) != 0o700
            or not stat.S_ISSOCK(endpoint.st_mode) or endpoint.st_uid != os.geteuid()
            or stat.S_IMODE(endpoint.st_mode) != 0o600):
        return fail("local endpoint permissions are unsafe")

    session, prompt = event.get("session_id"), event.get("prompt_id")
    if all(isinstance(value, str) and 0 < len(value) <= 128 for value in (session, prompt)):
        identity = hashlib.sha256((session + "\0" + prompt + "\0Stop").encode("utf-8")).hexdigest()
    else:
        identity = str(uuid.uuid4())
    payload = {
        "version": 1,
        "source": "claude-code",
        "id": identity,
        "title": "Claude Code response ended",
        "result": "success",  # 表示收到 Stop；不推断用户的整个任务成功。
        "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
    }
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(0.5)
            client.connect(str(args.socket))
            client.sendall(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
            client.shutdown(socket.SHUT_WR)
    except (FileNotFoundError, ConnectionRefusedError):
        return 0
    except OSError:
        return fail("completion notice could not be delivered")
    return 0


if __name__ == "__main__":
    sys.exit(main())
