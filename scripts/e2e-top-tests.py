#!/usr/bin/env python3
"""Check the PTY driver with a fake top command, without a daemon."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

DRIVER = Path(__file__).with_name("e2e-top.py")
FAKE_CLI = r'''#!/usr/bin/python3
import json, os, sys, termios, time, tty
from pathlib import Path
state = Path(os.environ["FAKE_TOP_STATE"])
if sys.argv[1:] == ["status", "--json"]:
    print(state.read_text())
    sys.exit(0)
if sys.argv[1:] != ["top"]:
    sys.exit(64)
saved = termios.tcgetattr(0)
tty.setraw(0)
selected = json.loads(state.read_text())["running"][0]["id"]
def draw(snapshot):
    sys.stdout.write("\x1b[H")
    for job in snapshot["running"] + snapshot.get("queued", []):
        label = f'{job["id"]} {job["project"]} {job["key"]}'
        sys.stdout.write(("\x1b[7m▸ " + label + "\x1b[0m" if job["id"] == selected else "  " + label) + "\r\n")
    sys.stdout.flush()
sys.stdout.write("\x1b[?1049h")
draw(json.loads(state.read_text()))
while True:
    key = sys.stdin.read(1)
    snapshot = json.loads(state.read_text())
    jobs = snapshot["running"] + snapshot.get("queued", [])
    index = next((index for index, job in enumerate(jobs) if job["id"] == selected), 0)
    if key in ("j", "k"):
        index = max(0, min(len(jobs) - 1, index + (1 if key == "j" else -1)))
        selected = jobs[index]["id"]
    elif key == "p":
        if os.environ.get("FAKE_OTHER_JOB"):
            snapshot["running"].append(dict(id=99, project="other", key="swift build", pausedBy="you"))
        else:
            next(job for job in snapshot["running"] if job["id"] == selected)["pausedBy"] = "you"
    elif key == "x":
        sys.stdout.write(f"kill #{selected}? y/n")
        sys.stdout.flush()
    elif key == "y":
        snapshot["running"] = [job for job in snapshot["running"] if job["id"] != selected]
        if snapshot["running"]:
            selected = snapshot["running"][0]["id"]
    elif key == "q":
        if os.environ.get("FAKE_IGNORE_QUIT"):
            continue
        time.sleep(float(os.environ.get("FAKE_QUIT_DELAY", "0")))
        sys.stdout.write("\x1b[?25h\x1b[?1049l")
        sys.stdout.flush()
        termios.tcsetattr(0, termios.TCSAFLUSH, saved)
        sys.exit(0)
    pending = state.with_suffix(".pending")
    pending.write_text(json.dumps(snapshot))
    pending.replace(state)
    draw(snapshot)
'''


class TopDriverTests(unittest.TestCase):
    def drive(self, **overrides):
        with tempfile.TemporaryDirectory(prefix="turnstile-top-test-") as temporary:
            root = Path(temporary)
            executable = root / "turnstile"
            executable.write_text(FAKE_CLI)
            executable.chmod(0o755)
            state = root / "state.json"
            jobs = [dict(id=11, project="a", key="swift build")]
            if overrides.get("FAKE_INITIAL_OTHER_JOB"):
                jobs.insert(0, dict(id=99, project="other", key="swift build"))
            state.write_text(json.dumps(dict(running=jobs, queued=[])))
            environment = dict(os.environ, PATH=f"{root}:/usr/bin:/bin", FAKE_TOP_STATE=str(state), **overrides)
            transcript = root / "transcript"
            response = subprocess.run(["/usr/bin/python3", str(DRIVER), "a", "swift build", str(transcript),
                                       "--timeout", "2"], env=environment, capture_output=True, text=True, timeout=15)
            self.assertEqual(response.returncode, 0, response.stderr)
            return json.loads(response.stdout), transcript.read_bytes()

    def test_delayed_exit_drains_terminal_restoration(self):
        result, transcript = self.drive(FAKE_QUIT_DELAY="0.75")
        for field in ("visible", "paused", "prompted", "killed", "restored"):
            self.assertTrue(result[field], (field, result))
        self.assertEqual(result["exit"], 0)
        self.assertEqual(result["errors"], [])
        self.assertTrue(transcript.endswith(b"\x1b[?1049l"))

    def test_selects_the_target_before_controlling_a_row(self):
        result, transcript = self.drive(FAKE_INITIAL_OTHER_JOB="1")
        for field in ("visible", "paused", "prompted", "killed", "restored"):
            self.assertTrue(result[field], (field, result))
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["exit"], 0)
        self.assertEqual([job["id"] for job in result["status"]["running"]], [99])
        self.assertNotIn("pausedBy", result["status"]["running"][0])
        self.assertIn(b"kill #11? y/n", transcript)
        self.assertNotIn(b"kill #99? y/n", transcript)

    def test_pausing_another_job_does_not_satisfy_the_target_handshake(self):
        result, _ = self.drive(FAKE_OTHER_JOB="1")
        self.assertTrue(result["visible"])
        self.assertFalse(result["paused"])
        self.assertFalse(result["prompted"])
        self.assertFalse(result["killed"])
        self.assertTrue(result["restored"])
        self.assertEqual(result["exit"], 0)

    def test_unresponsive_top_is_terminated_and_reported(self):
        result, _ = self.drive(FAKE_IGNORE_QUIT="1")
        self.assertTrue(result["killed"])
        self.assertEqual(result["exit"], -15)
        self.assertFalse(result["restored"])
        self.assertIn("top did not exit after q", result["errors"])


if __name__ == "__main__":
    unittest.main()
