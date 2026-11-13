#!/usr/bin/env python3
"""Isolated real-PTY driver. Token bytes come only from private fixture files.

Arguments identify the tool, action, and a nonsecret JSON interaction plan.
Terminal/output artifacts stay in the disposable plan directory. Only status
and assertion booleans are printed, including on failure.
"""

import copy
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import termios
import time


class ProbeFailure(Exception):
    pass


def require(condition, code):
    if not condition:
        raise ProbeFailure(code)


def main():
    require(len(sys.argv) == 4, "driver-arguments")
    tool, action, plan_name = sys.argv[1:]
    plan_path = Path(plan_name)
    plan = json.loads(plan_path.read_text())
    os.umask(0o077)
    token_path = Path(plan.get("token_file", os.environ["K8S_TEST_SENTINEL_FILE"]))
    token = token_path.read_bytes()
    root = plan_path.parent
    stdout_path = root / (plan_path.stem + "-stdout")
    stderr_path = root / (plan_path.stem + "-stderr")
    terminal_path = root / (plan_path.stem + "-terminal")
    master, slave = pty.openpty()
    # Deliberately non-default state proves exact restoration, not just ECHO.
    initial = copy.deepcopy(termios.tcgetattr(slave))
    initial[0] |= termios.IXON | termios.ICRNL
    initial[3] |= termios.ECHO | termios.ECHONL | termios.ICANON | termios.IEXTEN
    if not plan.get("initial_echonl", True):
        initial[3] &= ~termios.ECHONL
    if not plan.get("initial_echo", True):
        initial[3] &= ~(termios.ECHO | termios.ECHONL)
    initial[6][termios.VERASE] = b"\x08"
    initial[6][termios.VMIN] = b"\x05"
    initial[6][termios.VTIME] = b"\x02"
    termios.tcsetattr(slave, termios.TCSANOW, initial)
    initial = copy.deepcopy(termios.tcgetattr(slave))
    stream = bytearray()
    secrets = [token, token.replace(b"\0", b"")]
    redirected = plan.get("redirect_stderr", False)
    stdout_file = stdout_path.open("wb")
    stderr_file = stderr_path.open("wb") if redirected else None

    def attach_terminal():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    command = [tool, action]
    if "bash" in plan:
        command.insert(0, plan["bash"])
    process = subprocess.Popen(
        command,
        stdin=slave,
        stderr=stderr_file if redirected else slave,
        stdout=stdout_file,
        env=os.environ.copy(),
        preexec_fn=attach_terminal,
    )
    deadline = time.monotonic() + plan.get("timeout", 30)
    paused = False
    echo_gap = False
    failure = None
    restored = False
    status = None
    cursor = 0

    def receive(timeout=0.01):
        if select.select([master], [], [], timeout)[0]:
            try:
                stream.extend(os.read(master, 65536))
            except OSError:
                pass

    def visible():
        return bytes(stream) + (stderr_path.read_bytes() if redirected else b"")

    def echo_disabled():
        return not (termios.tcgetattr(slave)[3] & (termios.ECHO | termios.ECHONL))

    def wait_for(text, secret=False):
        nonlocal cursor
        needle = text.encode("utf-8")
        while time.monotonic() < deadline:
            data = visible()
            position = data.find(needle, cursor)
            if position >= 0 and (not secret or echo_disabled()):
                cursor = position + len(needle)
                return
            require(process.poll() is None, "prompt-not-reached")
            receive()
        raise ProbeFailure("prompt-timeout")

    def write(data, secret=False):
        if secret:
            secrets.extend((data, data.replace(b"\0", b"")))
        os.write(master, data)

    try:
        for step in plan["steps"]:
            if "wait" in step:
                wait_for(step["wait"], step.get("secret", False))
            if "input" in step:
                write(step["input"].encode("utf-8"))
            if step.get("token", False):
                write(token, secret=True)
            if "token_range" in step:
                start, end = step["token_range"]
                write(token[start:end], secret=True)
            if "sample_echo" in step:
                # Sample immediately after a character, catching the reviewed
                # inter-read window. Freeze scheduling before entering the
                # remaining private segment if a genuine ECHO gap is found.
                end = time.monotonic() + step["sample_echo"]
                while time.monotonic() < end:
                    if not echo_disabled():
                        os.killpg(process.pid, signal.SIGSTOP)
                        paused = True
                        if not echo_disabled():
                            echo_gap = True
                            write(token[1:], secret=True)
                            os.killpg(process.pid, signal.SIGCONT)
                            paused = False
                            break
                        os.killpg(process.pid, signal.SIGCONT)
                        paused = False
                    receive(0)
                if not echo_gap:
                    write(token[1:], secret=True)
            if "after" in step:
                write(step["after"].encode("utf-8"))
            if "signal" in step:
                # Signal the tool PID alone: restoration must not depend on a
                # separate key-reader subprocess also receiving the signal.
                os.kill(process.pid, getattr(signal, "SIG" + step["signal"]))
        while process.poll() is None and time.monotonic() < deadline:
            receive(0.02)
        if process.poll() is None:
            # Private, noncredential diagnostics for intermittent signal/read
            # scheduling failures. Inspect only this driver's own child.
            diagnostics = {}
            process_root = Path("/proc") / str(process.pid)
            if process_root.exists():
                diagnostics["status"] = [
                    line for line in (process_root / "status").read_text().splitlines()
                    if line.startswith(("Name:", "State:", "SigPnd:", "ShdPnd:", "SigIgn:", "SigCgt:"))
                ]
                diagnostics["wait_channel"] = (process_root / "wchan").read_text()
                diagnostics["children"] = (process_root / "task" / str(process.pid) / "children").read_text()
            (root / (plan_path.stem + "-process.json")).write_text(json.dumps(diagnostics))
            raise ProbeFailure("operation-timeout")
        status = process.wait(timeout=3)
    except (ProbeFailure, OSError, subprocess.TimeoutExpired) as error:
        failure = str(error) if isinstance(error, ProbeFailure) else "driver-io"
    finally:
        if paused:
            os.killpg(process.pid, signal.SIGCONT)
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        for _ in range(4):
            receive(0)
        restored = termios.tcgetattr(slave) == initial
        terminal_path.write_bytes(stream)
        os.close(slave)
        os.close(master)
        stdout_file.close()
        if stderr_file:
            stderr_file.close()
        else:
            stderr_path.write_bytes(stream)

    public = bytes(stream) + stdout_path.read_bytes() + stderr_path.read_bytes()
    leaked = any(len(value) >= 8 and value in public for value in secrets)
    expected = plan.get("expected_status", 0)
    try:
        require(failure is None, failure or "driver")
        require(restored, "terminal-not-restored")
        require(not leaked, "secret-in-output")
        require(not echo_gap, "inter-character-echo-gap")
        if expected == "failure":
            require(status != 0, "operation-should-fail")
        else:
            require(status == expected, "unexpected-operation-status")
        if "error" in plan:
            require(plan["error"].encode("utf-8") in public, "controlled-error-missing")
        if plan.get("expect_mask", False):
            require(b"Token: *" in public, "mask-not-rendered")
    except ProbeFailure as error:
        failure = str(error)
    print(json.dumps({
        "status": status,
        "terminal_restored": restored,
        "echo_gap": echo_gap,
        "secret_in_output": leaked,
        "assertion": failure,
    }))
    return 1 if failure else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ProbeFailure as error:
        print(json.dumps({"assertion": str(error)}))
        raise SystemExit(1)
