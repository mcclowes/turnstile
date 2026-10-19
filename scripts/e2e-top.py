#!/usr/bin/env python3
"""Drive top through a PTY and report each handshake independently."""
import argparse
import errno
import json
import os
import pty
import re
import select
import signal
import subprocess
import time
from pathlib import Path


def run(project, key, transcript, timeout):
    result = dict(visible=False, paused=False, prompted=False, killed=False, exit=None, restored=False, errors=[])
    output = bytearray()
    last_status = {}
    pid = None
    closed = False

    def pump(seconds=0.05):
        nonlocal closed
        if closed:
            time.sleep(seconds)
            return
        if select.select([fd], [], [], seconds)[0]:
            try:
                chunk = os.read(fd, 65536)
                output.extend(chunk)
                closed = not chunk
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                closed = True

    def status():
        nonlocal last_status
        response = subprocess.run(["turnstile", "status", "--json"], capture_output=True, text=True,
                                  timeout=min(timeout, 2), check=True)
        last_status = json.loads(response.stdout)
        return last_status

    def wait_for(predicate, deadline=None):
        if deadline is None:
            deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            pump()
        return False

    def frame():
        return bytes(output).rsplit(b"\x1b[H", 1)[-1]

    def selected_job():
        match = re.search("▸ +([0-9]+)\\s".encode(), frame())
        return int(match.group(1)) if match else None

    def select_target(job_id):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            selected = selected_job()
            if selected == job_id:
                return True
            if selected is None:
                pump()
                continue
            snapshot = status()
            ids = [job["id"] for section in ("running", "queued") for job in snapshot.get(section, [])]
            if job_id not in ids:
                raise RuntimeError("target disappeared before selection")
            if selected not in ids:
                pump()
                continue
            os.write(fd, b"j" if ids.index(selected) < ids.index(job_id) else b"k")
            if not wait_for(lambda: selected_job() not in (None, selected), deadline):
                return False
        return False

    def finish():
        try:
            os.write(fd, b"q")
        except OSError:
            pass
        deadline = time.monotonic() + timeout
        code = None
        while time.monotonic() < deadline:
            pump()
            exited, child_status = os.waitpid(pid, os.WNOHANG)
            if exited:
                code = child_status
                break
        if code is None:
            result["errors"].append("top did not exit after q")
            os.kill(pid, signal.SIGTERM)
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                pump()
                exited, child_status = os.waitpid(pid, os.WNOHANG)
                if exited:
                    code = child_status
                    break
            if code is None:
                os.kill(pid, signal.SIGKILL)
                _, code = os.waitpid(pid, 0)
        result["exit"] = os.waitstatus_to_exitcode(code)
        deadline = time.monotonic() + timeout
        while not closed and time.monotonic() < deadline:
            pump()
        result["restored"] = bytes(output).rstrip().endswith(b"\x1b[?1049l")
        os.close(fd)

    try:
        jobs = [job for job in status().get("running", []) if job["project"] == project and job["key"] == key]
        if len(jobs) != 1:
            raise RuntimeError("expected exactly one running target job")
        job_id = jobs[0]["id"]
        pid, fd = pty.fork()
        if pid == 0:
            os.execvp("turnstile", ["turnstile", "top"])
        result["visible"] = wait_for(lambda: f"{project} {key}".encode() in frame())
        if result["visible"]:
            if not select_target(job_id):
                raise RuntimeError("target row was not selected before controls")
            os.write(fd, b"p")
            result["paused"] = wait_for(lambda: any(job["id"] == job_id and job.get("pausedBy") == "you"
                                                   for job in status().get("running", [])))
        if result["paused"]:
            os.write(fd, b"x")
            result["prompted"] = wait_for(lambda: b"? y/n" in output)
        if result["prompted"]:
            os.write(fd, b"y")
            result["killed"] = wait_for(lambda: not any(job["id"] == job_id
                                                       for section in ("running", "queued")
                                                       for job in status().get(section, [])))
    except Exception as error:
        if pid == 0:
            os._exit(127)
        result["errors"].append(f"{type(error).__name__}: {error}")
    finally:
        if pid is not None and pid != 0:
            finish()
        Path(transcript).write_bytes(output)
    result["status"] = last_status
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project")
    parser.add_argument("key")
    parser.add_argument("transcript")
    parser.add_argument("--timeout", type=float, default=5)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    print(json.dumps(run(args.project, args.key, args.transcript, args.timeout)))
