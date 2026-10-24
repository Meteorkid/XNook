import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "claude-stop-hook.py"


class HookTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="xnook-hook-")
        self.root = Path(self.directory.name)
        self.path = self.root / "claude.sock"
        self.received = []
        self.stopping = threading.Event()
        self.server = None
        self.thread = None

    def tearDown(self):
        self.stopping.set()
        if self.thread:
            self.thread.join(timeout=2)
            self.assertFalse(self.thread.is_alive())
        if self.server:
            self.server.close()
        self.directory.cleanup()

    def listen(self):
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.path))
        os.chmod(self.path, 0o600)
        self.server.listen(4)
        self.server.settimeout(0.05)

        def receive():
            while not self.stopping.is_set():
                try:
                    client, _ = self.server.accept()
                except socket.timeout:
                    continue
                with client:
                    client.settimeout(1)
                    body = bytearray()
                    while True:
                        part = client.recv(65537)
                        if not part:
                            break
                        body.extend(part)
                    self.received.append(bytes(body))

        self.thread = threading.Thread(target=receive, daemon=True)
        self.thread.start()

    def run_hook(self, event=None, raw=None, path=None):
        if raw is None:
            raw = json.dumps(event).encode("utf-8")
        result = subprocess.run([sys.executable, str(SCRIPT), "--socket", str(path or self.path)],
                                input=raw, capture_output=True, timeout=3)
        self.assertEqual(result.stdout, b"")
        return result

    def messages(self, count):
        deadline = time.monotonic() + 1
        while len(self.received) < count and time.monotonic() < deadline:
            self.stopping.wait(0.005)
        self.assertEqual(len(self.received), count)
        return [json.loads(message) for message in self.received]

    def test_stop_sends_only_minimal_envelope_without_private_fields(self):
        self.listen()
        result = self.run_hook({"hook_event_name": "Stop", "session_id": "session", "prompt_id": "prompt",
                                "cwd": "/private/project", "transcript_path": "/private/transcript",
                                "last_assistant_message": "SECRET_MUST_NOT_BE_FORWARDED", "future_field": {"nested": True}})
        self.assertEqual(result.returncode, 0)
        payload = self.messages(1)[0]
        self.assertEqual(set(payload), {"version", "source", "id", "title", "result", "createdAt"})
        self.assertEqual(payload["source"], "claude-code")
        self.assertEqual(payload["title"], "Claude Code response ended")
        self.assertEqual(payload["result"], "success")
        self.assertNotIn(b"SECRET", self.received[0] + result.stderr)

    def test_same_prompt_has_stable_identity_but_next_prompt_is_distinct(self):
        self.listen()
        for prompt in ["first", "first", "second"]:
            self.assertEqual(self.run_hook({"hook_event_name": "Stop", "session_id": "session", "prompt_id": prompt}).returncode, 0)
        first, replay, second = self.messages(3)
        self.assertEqual(first["id"], replay["id"])
        self.assertNotEqual(first["id"], second["id"])

    def test_old_client_without_prompt_id_does_not_dedupe_the_whole_session(self):
        self.listen()
        for _ in range(2):
            self.assertEqual(self.run_hook({"hook_event_name": "Stop", "session_id": "session"}).returncode, 0)
        first, second = self.messages(2)
        self.assertNotEqual(first["id"], second["id"])

    def test_stop_hook_active_is_not_interpreted_as_task_success(self):
        self.listen()
        self.assertEqual(self.run_hook({"hook_event_name": "Stop", "stop_hook_active": True}).returncode, 0)
        self.assertEqual(self.messages(1)[0]["title"], "Claude Code response ended")

    def test_unrelated_events_do_not_connect(self):
        self.listen()
        for event in ["StopFailure", "SubagentStop", "Notification"]:
            self.assertEqual(self.run_hook({"hook_event_name": event}).returncode, 0)
        self.assertEqual(self.received, [])

    def test_missing_endpoint_is_a_quiet_noop(self):
        result = self.run_hook({"hook_event_name": "Stop"})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b"")
        self.assertFalse(self.path.exists())

    def test_malformed_and_oversized_input_do_not_connect(self):
        self.listen()
        for raw in [b"{broken", b"[]", b"{}", b'{"hook_event_name":1}', b"x" * 65537]:
            self.assertEqual(self.run_hook(raw=raw).returncode, 1)
        self.assertEqual(self.received, [])

    def test_unsafe_directory_is_not_changed_or_used(self):
        self.listen()
        os.chmod(self.root, 0o755)
        self.assertEqual(self.run_hook({"hook_event_name": "Stop"}).returncode, 1)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.received, [])

    def test_symlink_endpoint_is_not_followed(self):
        self.listen()
        link = self.root / "link.sock"
        link.symlink_to(self.path)
        self.assertEqual(self.run_hook({"hook_event_name": "Stop"}, path=link).returncode, 1)
        self.assertTrue(link.is_symlink())
        self.assertEqual(self.received, [])

    def test_regular_file_endpoint_is_not_modified(self):
        self.path.write_bytes(b"keep this file")
        os.chmod(self.path, 0o600)
        self.assertEqual(self.run_hook({"hook_event_name": "Stop"}).returncode, 1)
        self.assertEqual(self.path.read_bytes(), b"keep this file")

    def test_unsafe_socket_mode_is_rejected(self):
        self.listen()
        os.chmod(self.path, 0o666)
        self.assertEqual(self.run_hook({"hook_event_name": "Stop"}).returncode, 1)
        self.assertEqual(self.received, [])


if __name__ == "__main__":
    unittest.main()
