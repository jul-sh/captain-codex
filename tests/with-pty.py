#!/usr/bin/env python3
"""Run a command with a real PTY (pseudo-terminal).

Zellij requires a TTY to start. This wrapper allocates one via Python's
pty module, so integration tests can launch zellij even from environments
without a controlling terminal (CI, Claude Code, etc.).

Usage: python3 with-pty.py <command> [args...]

Exits with the child process's exit code.
"""

import os
import sys
import pty
import signal

if len(sys.argv) < 2:
    print("Usage: with-pty.py <command> [args...]", file=sys.stderr)
    sys.exit(1)

# Timeout from env (seconds), default 30
timeout = int(os.environ.get("PTY_TIMEOUT", "30"))

def alarm_handler(signum, frame):
    print(f"with-pty.py: timeout after {timeout}s", file=sys.stderr)
    sys.exit(124)

signal.signal(signal.SIGALRM, alarm_handler)
signal.alarm(timeout)

# Fork with a PTY. The child execs the command; the parent copies I/O.
# pty.spawn handles the read loop internally.
exit_status = pty.spawn(sys.argv[1:])

# pty.spawn returns the raw waitpid status
if os.WIFEXITED(exit_status):
    sys.exit(os.WEXITSTATUS(exit_status))
else:
    sys.exit(1)
