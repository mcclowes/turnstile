#!/usr/bin/env python3
"""Isolated startup and admission checks; never use the installed home or tools."""
import os
import json
import shlex
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest


BINARY = str(Path(os.environ.get("TURNSTILE_BIN", ".build/debug/turnstile")).resolve())


class InvocationTests(unittest.TestCase):
    def test_supported_commands_wait_for_real_admission(self):
        with tempfile.TemporaryDirectory(prefix="ts-admit-", dir="/tmp") as root:
            home = Path(root)
            gate = home / "gate"
            tools = home / "tools"
            tools.mkdir()
            (home / "config").mkdir()
            (home / "config/config.json").write_text('{"reserve":"0MB"}')
            env = {"HOME": root, "PATH": str(tools) + ":/usr/bin:/bin", "SHELL": "/bin/zsh",
                   "TURNSTILE_HOME": str(gate), "TURNSTILE_CONFIG_DIR": root + "/config",
                   "TURNSTILE_AGENT": "1", "RUNS": root + "/runs", "RELEASE": root + "/release"}
            for key, value in (("MEMORY_LEVEL", "90"), ("PRESSURE_LEVEL", "0"), ("SWAP_USED", "0")):
                path = home / key
                path.write_text(value)
                env["TURNSTILE_" + key + "_FILE"] = str(path)
            for tool in ("node", "swift", "npm", "vitest"):
                path = tools / tool
                path.write_text('#!/bin/bash\nprintf "%s|%s|%s\\n" "${0##*/}" "$*" "${TURNSTILE_TOKEN:-none}" >> "$RUNS"\n'
                                'if [ "${NESTED:-}" = 1 ]; then NESTED= swift build nested; fi\n'
                                'while [ ! -e "$RELEASE" ]; do /bin/sleep 0.02; done\nexit 23\n')
                path.chmod(0o755)

            def cli(*args):
                return subprocess.run([BINARY, *args], env=env, cwd=root, capture_output=True,
                                      text=True, timeout=10)

            # macOS path_helper otherwise puts real system tools ahead of the fake tools at login.
            for startup in (".zlogin", ".bash_profile"):
                (home / startup).write_text("export PATH=" + shlex.quote(str(tools)) + ':"$PATH"\n')
            for shell in ("zsh", "bash"):
                self.assertEqual(cli("init", "--shell", shell).returncode, 0)
            codex = os.environ.get("TURNSTILE_CODEX_BIN")
            if codex:
                codex_home = home / "codex"
                codex_home.mkdir()
                (codex_home / "config.toml").write_text(
                    'default_permissions = "fixture"\n[permissions.fixture.filesystem]\n'
                    '"/" = "read"\n' + json.dumps(root) + ' = "write"\n'
                    '[permissions.fixture.network]\nenabled = false\n')
                env["CODEX_HOME"] = str(codex_home)
            # Require a functioning socket before starting any invocation. Never interpret fail-open as admission.
            with socket.socket(socket.AF_UNIX) as probe:
                probe.bind(str(home / "probe.sock"))
            with open(home / "daemon.log", "w") as log:
                daemon = subprocess.Popen([BINARY, "daemon"], env=env, cwd=root, stdout=log, stderr=log)
                try:
                    self.wait_for(lambda: (gate / "turnstiled.sock").exists())
                    with socket.socket(socket.AF_UNIX) as probe:
                        probe.connect(str(gate / "turnstiled.sock"))
                    # Direct Node is deliberately unshimmed; watch commands also pass through.
                    (home / "release").touch()
                    for command in ([str(tools / "node"), "node_modules/vitest/vitest.mjs", "run"],
                                    ["/bin/zsh", "-lc", "vitest --watch"]):
                        (home / "runs").unlink(missing_ok=True)
                        result = subprocess.run(command, env=env, cwd=root, capture_output=True,
                                                text=True, timeout=10)
                        self.assertEqual(result.returncode, 23, result.stderr)
                        self.assertTrue((home / "runs").read_text().strip().endswith("|none"))
                    if codex:
                        (home / "runs").unlink()
                        result = subprocess.run(
                            [codex, "sandbox", BINARY, "run", "--class", "test", "--",
                             str(tools / "node"), "fixture.mjs"], env=env, cwd=root,
                            capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, 23, result.stderr)
                        self.assertIn("inside this sandbox", result.stderr)
                        self.assertTrue((home / "runs").read_text().strip().endswith("|none"))
                        (gate / "ungated.log").unlink()
                    cases = [
                        (["/bin/zsh", "-lc", "swift test"], "test", False),
                        (["/bin/bash", "-lc", "npm test"], "test", False),
                        (["/bin/bash", "-c", 'eval "$("$1" env --shell bash)"; swift test', "fixture", BINARY], "test", False),
                        ([BINARY, "run", "--class", "test", "--", "node", "node_modules/vitest/vitest.mjs", "run"], "test", True),
                        ([BINARY, "run", "--class", "compile", "--", str(tools / "node"), "node_modules/typescript/bin/tsc"], "compile", False),
                        ([BINARY, "run", "--class", "browser", "--", "node", "node_modules/@playwright/test/cli.js", "test"], "browser", False),
                    ]
                    if codex:
                        cases.append(([codex, "sandbox", "--allow-unix-socket", str(gate / "turnstiled.sock"),
                                       BINARY, "run", "--class", "test", "--", str(tools / "node"),
                                       "node_modules/vitest/vitest.mjs", "run"], "test", False))
                    for command, resource, nested in cases:
                        with self.subTest(command=command):
                            (home / "runs").unlink(missing_ok=True)
                            (home / "release").unlink(missing_ok=True)
                            (gate / "queue-paused").touch()
                            child = subprocess.Popen(command, env=dict(env, NESTED="1" if nested else ""),
                                                     cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                            try:
                                def jobs(section):
                                    result = cli("status", "--json")
                                    self.assertEqual(result.returncode, 0, result.stderr)
                                    return json.loads(result.stdout).get(section, [])

                                self.wait_for(lambda: jobs("queued"))
                                self.assertFalse((home / "runs").exists(), "tool ran before admission")
                                self.assertEqual(jobs("queued")[0]["resourceClass"], resource)
                                (gate / "queue-paused").unlink()
                                self.wait_for(lambda: (home / "runs").exists()
                                              and len((home / "runs").read_text().splitlines()) == (2 if nested else 1))
                                lines = (home / "runs").read_text().splitlines()
                                self.assertTrue(all(not line.endswith("|none") for line in lines), lines)
                                self.assertEqual(len({line.rsplit("|", 1)[1] for line in lines}), 1)
                                self.assertEqual(len(jobs("running")), 1, "nested command requested another slot")
                                (home / "release").touch()
                                _, errors = child.communicate(timeout=10)
                                self.assertEqual(child.returncode, 23, errors)
                                self.assertNotIn("ungated", errors)
                            finally:
                                (home / "release").touch()
                                if child.poll() is None:
                                    child.terminate()
                                child.communicate(timeout=10)
                    self.assertFalse((gate / "ungated.log").exists())
                    # A wrapper cannot grant socket access. Preserve the explicit fail-open policy.
                    (home / "runs").unlink()
                    result = subprocess.run(
                        ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
                         BINARY, "run", "--class", "test", "--", str(tools / "node"), "fixture.mjs"],
                        env=env, cwd=root, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 23, result.stderr)
                    self.assertIn("inside this sandbox", result.stderr)
                    self.assertTrue((home / "runs").read_text().strip().endswith("|none"))
                    self.assertIn("sandbox blocked", (gate / "ungated.log").read_text())
                finally:
                    daemon.terminate()
                    daemon.wait(timeout=10)

    def wait_for(self, predicate):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.05)
        self.fail("timed out waiting for isolated daemon/tool state")

    def test_bash_install_preserves_login_precedence(self):
        for login in (".bash_profile", ".bash_login", ".profile", None):
            with self.subTest(login=login), tempfile.TemporaryDirectory(prefix="ts-invoke-", dir="/tmp") as root:
                home = Path(root)
                env = {"HOME": root, "PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh",
                       "TURNSTILE_HOME": root + "/gate", "TURNSTILE_CONFIG_DIR": root + "/config"}
                if login:
                    (home / login).write_text("export LOGIN_SENTINEL=preserved\n")
                (home / ".bashrc").write_text("case $- in *i*) ;; *) return ;; esac\n")
                subprocess.run([BINARY, "init", "--shell", "zsh"], env=env,
                               check=True, capture_output=True, timeout=10)
                before = subprocess.run(["/bin/bash", "-lc", "command -v swift"], env=env,
                                        capture_output=True, text=True, check=True, timeout=10)
                self.assertNotEqual(before.stdout.strip(), root + "/gate/shims/swift")
                for _ in range(2):
                    subprocess.run([BINARY, "init", "--shell", "bash"], env=env,
                                   check=True, capture_output=True, timeout=10)
                result = subprocess.run(["/bin/bash", "-lc",
                                         'printf "%s\\n%s\\n" "${LOGIN_SENTINEL:-missing}" "$(command -v swift)"'],
                                        env=env, capture_output=True, text=True, check=True, timeout=10)
                self.assertEqual(result.stdout.splitlines(),
                                 ["preserved" if login else "missing", root + "/gate/shims/swift"])
                active = home / (login or ".bash_profile")
                self.assertEqual(active.read_text().count("# >>> turnstile >>>"), 1)
                if login in (".bash_login", ".profile"):
                    self.assertFalse((home / ".bash_profile").exists())
                if login == ".profile":
                    result = subprocess.run(["/bin/zsh", "-fc", '. "$HOME/.profile"; printf "%s" "$LOGIN_SENTINEL"'],
                                            env=env, capture_output=True, text=True, check=True, timeout=10)
                    self.assertEqual(result.stdout, "preserved")
                    self.assertEqual(result.stderr, "")
                subprocess.run([BINARY, "uninstall"], env=env, check=True, capture_output=True, timeout=10)
                self.assertNotIn("# >>> turnstile >>>", active.read_text())
                if login:
                    self.assertEqual(active.read_text(), "export LOGIN_SENTINEL=preserved\n")


if __name__ == "__main__":
    unittest.main()
