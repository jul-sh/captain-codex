#!/usr/bin/env python3
"""Run a command under a pseudo-tty.

Used by the test suite to drive zellij headlessly: zellij requires a real
TTY (it calls TIOCGWINSZ at startup), so we wrap the command in pty.spawn
which gives it a TTY but still lets us capture/discard its output.

We also enforce a wall-clock timeout — zellij sessions don't necessarily
exit on their own, and we want tests to fail fast.

Usage:
    with-pty.py <timeout_seconds> -- <command> [args...]

Output: forwards the wrapped command's output to stdout. Exits with the
wrapped command's exit code, or 124 on timeout (mirroring `timeout(1)`).
"""
import os
import pty
import select
import signal
import subprocess
import sys
import termios
import time


def main() -> int:
    if "--" not in sys.argv:
        print("usage: with-pty.py <timeout_seconds> -- <command> [args...]", file=sys.stderr)
        return 2
    sep = sys.argv.index("--")
    try:
        timeout = float(sys.argv[1])
    except (IndexError, ValueError):
        print("usage: with-pty.py <timeout_seconds> -- <command> [args...]", file=sys.stderr)
        return 2
    cmd = sys.argv[sep + 1 :]
    if not cmd:
        print("usage: with-pty.py <timeout_seconds> -- <command> [args...]", file=sys.stderr)
        return 2

    # Open a pty master/slave pair. The child gets the slave as its
    # stdin/stdout/stderr; we read from the master and forward to our
    # actual stdout so test logs still capture the output.
    master, slave = pty.openpty()

    # Set sensible terminal size so zellij doesn't blow up on (0, 0).
    try:
        import fcntl
        import struct

        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    except Exception:
        pass

    proc = subprocess.Popen(
        cmd,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
        start_new_session=True,
    )
    os.close(slave)

    deadline = time.monotonic() + timeout
    rc: int | None = None

    try:
        while True:
            now = time.monotonic()
            remaining = deadline - now
            if remaining <= 0:
                # Timeout: kill the process group so any spawned panes
                # die too.
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                    time.sleep(0.5)
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                rc = 124
                break

            r, _, _ = select.select([master], [], [], min(remaining, 0.1))
            if r:
                try:
                    data = os.read(master, 4096)
                except OSError:
                    data = b""
                if not data:
                    break
                try:
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                except BrokenPipeError:
                    pass
            else:
                if proc.poll() is not None:
                    # Drain any remaining output before exiting.
                    try:
                        while True:
                            r, _, _ = select.select([master], [], [], 0.05)
                            if not r:
                                break
                            chunk = os.read(master, 4096)
                            if not chunk:
                                break
                            sys.stdout.buffer.write(chunk)
                    except OSError:
                        pass
                    sys.stdout.buffer.flush()
                    break
    finally:
        try:
            os.close(master)
        except OSError:
            pass

    if rc is None:
        rc = proc.wait()
    return rc


if __name__ == "__main__":
    sys.exit(main())
