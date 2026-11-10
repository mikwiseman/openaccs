#!/usr/bin/env python3
"""Exercise the built Debug CLI against an isolated control socket.

Usage: scripts/test-cli-selection.py /path/to/Debug/OpenAccs.app/Contents/MacOS/OpenAccs
No real profiles are opened. Release binaries are rejected before any action.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest


BINARY = str(Path(sys.argv.pop(1)).resolve())
WORK_ID = "00000000-0000-4000-8000-000000000002"
OTHER_ID = "00000000-0000-4000-8000-000000000001"


def account(account_id, label, left):
    return {
        "id": account_id, "provider": "claude", "label": label,
        "state": "idle", "windows": [{"kind": "fiveHour", "leftPercent": left, "usedPercent": 100 - left}],
        "needsSignIn": False, "pendingSessions": 0, "pendingChanges": 0,
        "best": left == 100, "windowIDs": [],
    }


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory(prefix="oa-cli-", dir="/tmp")
        self.env = dict(os.environ, OPENACCS_HOME=self.home.name)
        self.socket_path = Path(self.home.name) / "Library/Application Support/OpenAccs/control.sock"
        self.socket_path.parent.mkdir(parents=True)
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(self.socket_path))
        self.server.listen()
        self.requests = []
        self.opened = False
        self.mode = "normal"
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
        # A Release binary ignores OPENACCS_HOME. Check before issuing any open command.
        status = self.run_cli("status", "--json")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertEqual({a["id"] for a in json.loads(status.stdout)["accounts"]}, {WORK_ID, OTHER_ID},
                         "Use a Debug binary: refusing to act on real accounts")
        self.requests.clear()

    def tearDown(self):
        self.server.close()
        self.home.cleanup()

    def serve(self):
        while True:
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            with connection:
                data = b""
                while b"\n" not in data:
                    part = connection.recv(4096)
                    if not part:
                        break
                    data += part
                if not data:
                    continue
                request = json.loads(data.split(b"\n", 1)[0])
                self.requests.append(request)
                if request["command"] == "open":
                    self.opened = True
                work = account(WORK_ID, "Work", 100)
                other = account(OTHER_ID, "Personal", 0)
                other.update(state="open", pid=111, windowIDs=[11])
                rows = [other, work]
                if self.opened:
                    work.update(state="open", pid=222, windowIDs=[22, 23])
                    rows = [work, other]  # Position changes; the selected ID must stay authoritative.
                    if self.mode == "missing":
                        rows = [other]
                    elif self.mode == "closed":
                        work.pop("pid")
                        work.update(state="idle", windowIDs=[])
                response = {"accounts": rows}
                if request["command"] == "open" and self.mode == "failed":
                    response["error"] = "Profile is busy"
                elif request["command"] == "open" and self.mode == "membership":
                    response["error"] = "Select Work in Claude’s account menu. This window is using another membership."
                connection.sendall(json.dumps(response).encode() + b"\n")

    def run_cli(self, *args):
        return subprocess.run([BINARY, "cli", *args], env=self.env, text=True,
                              capture_output=True, timeout=10)

    def test_selected_profile_returns_current_target(self):
        for selection in [("use", "Work"), ("use", "claude:Work"), ("use", "2"),
                          ("use", "--best", "claude"), ("switch", "Work"), ("open", "Work")]:
            with self.subTest(selection=selection):
                self.opened = False
                self.requests.clear()
                result = self.run_cli(*selection, "--json")
                self.assertEqual(result.returncode, 0, result.stderr)
                selected = json.loads(result.stdout)
                self.assertEqual(selected["id"], WORK_ID)
                self.assertEqual(selected["pid"], 222)
                self.assertEqual(selected["windowIDs"], [22, 23])
                self.assertEqual([r["id"] for r in self.requests if r["command"] == "open"], [WORK_ID])

    def test_missing_or_closed_target_never_returns_stale_selection(self):
        for mode in ["missing", "closed"]:
            with self.subTest(mode=mode):
                self.opened = False
                self.mode = mode
                result = self.run_cli("use", "Work", "--json")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertTrue(result.stderr.strip())

    def test_open_error_is_not_reported_as_success(self):
        self.mode = "failed"
        result = self.run_cli("use", "Work", "--json")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("Profile is busy", result.stderr)

    def test_membership_selection_error_never_reports_success(self):
        self.mode = "membership"
        for command in ["use", "open", "switch"]:
            for options in [[], ["--json"]]:
                with self.subTest(command=command, options=options):
                    self.opened = False
                    result = self.run_cli(command, "Work", *options)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("Select Work in Claude’s account menu.", result.stderr)
                    self.assertIn("This window is using another membership.", result.stderr)

    def test_plain_use_keeps_its_existing_message(self):
        result = self.run_cli("use", "Work")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Opened Work.\n")


if __name__ == "__main__":
    unittest.main()
