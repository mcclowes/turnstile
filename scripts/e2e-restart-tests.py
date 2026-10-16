#!/usr/bin/env python3
"""Check the real restart handshake with a fake status CLI, without a daemon."""
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).with_name("e2e.sh").read_text()
HELPER = re.search(r"(?ms)^wait_for_replacement\(\) \{.*?^\}", SOURCE).group()
PREVIOUS_PID = 1234
REPLACEMENT = json.dumps({"daemonPid": 4321})
FAKE_CLI = r'''#!/bin/bash
[ "$#" = 2 ] && [ "$1" = status ] && [ "$2" = --json ] || exit 64
read -r index < "$FAKE_RESTART_STATE/calls"
printf '%s\n' "$((index + 1))" > "$FAKE_RESTART_STATE/calls"
if [ "$index" -ge "$FAKE_RESTART_COUNT" ]; then index=$((FAKE_RESTART_COUNT - 1)); fi
cat "$FAKE_RESTART_STATE/$index.stdout"
read -r status < "$FAKE_RESTART_STATE/$index.status"
exit "$status"
'''
FAKE_SLEEP = r'''#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_RESTART_STATE/sleeps"
'''


class RestartHandshakeTests(unittest.TestCase):
    def poll(self, snapshots, statuses=None):
        with tempfile.TemporaryDirectory(prefix="turnstile restart test ") as temporary:
            root = Path(temporary)
            executable = root / "turnstile"
            executable.write_text(FAKE_CLI)
            executable.chmod(0o755)
            sleep = root / "sleep"
            sleep.write_text(FAKE_SLEEP)
            sleep.chmod(0o755)
            (root / "calls").write_text("0\n")
            (root / "sleeps").write_text("")
            for index, snapshot in enumerate(snapshots):
                (root / f"{index}.stdout").write_text(snapshot)
                (root / f"{index}.status").write_text(str(statuses[index] if statuses else 0) + "\n")
            environment = dict(os.environ, PATH=f"{root}:/usr/bin:/bin",
                               FAKE_RESTART_STATE=str(root), FAKE_RESTART_COUNT=str(len(snapshots)))
            # Load only the real helper so the suite never builds or starts the E2E daemon.
            result = subprocess.run(["/bin/bash", "-c", HELPER + '\nwait_for_replacement "$1"',
                                     "e2e-restart-test", str(PREVIOUS_PID)],
                                    env=environment, capture_output=True, text=True, timeout=30)
            return result, int((root / "calls").read_text()), (root / "sleeps").read_text().splitlines()

    def test_missing_pid_retries_without_a_traceback(self):
        result, calls, sleeps = self.poll(["{}", REPLACEMENT])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, 2)
        self.assertEqual(sleeps, ["0.05"])
        self.assertEqual(result.stderr, "")

    def test_invalid_snapshots_cannot_satisfy_the_handshake(self):
        snapshots = ["", "{", "null", "[]", "17", '"snapshot"']
        snapshots += [json.dumps({"daemonPid": value})
                      for value in [None, False, True, 0, -1, 4321.0, "4321"]]
        for snapshot in snapshots:
            with self.subTest(snapshot=snapshot):
                result, calls, sleeps = self.poll([snapshot, REPLACEMENT])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, 2)
                self.assertEqual(sleeps, ["0.05"])
                self.assertEqual(result.stderr, "")

    def test_failed_status_command_cannot_supply_the_replacement(self):
        result, calls, sleeps = self.poll([REPLACEMENT, REPLACEMENT], statuses=[17, 0])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, 2)
        self.assertEqual(sleeps, ["0.05"])
        self.assertEqual(result.stderr, "")

    def test_ready_replacement_returns_without_sleeping(self):
        result, calls, sleeps = self.poll([REPLACEMENT])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, 1)
        self.assertEqual(sleeps, [])
        self.assertEqual(result.stderr, "")

    def test_unchanged_pid_is_retried(self):
        unchanged = json.dumps({"daemonPid": PREVIOUS_PID})
        result, calls, sleeps = self.poll([unchanged, unchanged, REPLACEMENT])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, 3)
        self.assertEqual(sleeps, ["0.05"] * 2)
        self.assertEqual(result.stderr, "")

    def test_an_unready_daemon_still_exhausts_the_retry_limit(self):
        result, calls, sleeps = self.poll([json.dumps({"daemonPid": PREVIOUS_PID})])
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(calls, 100)
        self.assertEqual(sleeps, ["0.05"] * 100)
        self.assertEqual(result.stderr, "")

    def test_the_final_attempt_can_observe_the_replacement(self):
        unchanged = json.dumps({"daemonPid": PREVIOUS_PID})
        result, calls, sleeps = self.poll([unchanged] * 99 + [REPLACEMENT])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, 100)
        self.assertEqual(sleeps, ["0.05"] * 99)
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
