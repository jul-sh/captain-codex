#!/usr/bin/env bash
# Pane driver: dispatch agent runs into named zellij panes via fifos,
# poll for completion via sentinel files, and (rarely) inject text into
# a pane via zellij write-chars under an advisory lock.
#
# This file is meant to be sourced, not executed:
#   source "$CAPTAIN_ROOT/scripts/pane.sh"
#
# Required env: CAPTAIN_TMP, CAPTAIN_ROOT
#
# Public API:
#   pane_dispatch <pane> <prompt_file> <output_file>   # runs agent in pane, blocks until done, returns agent's exit code
#   pane_send <pane> <text>                            # type text into pane (write-chars), advisory-locked
#   pane_status_log <text>                             # convenience: log to captain pane (just stdout, since orchestrator IS captain)
#
# Implementation notes:
#
# - Dispatch uses fifos written by the orchestrator and read by
#   agent-runner.sh, not zellij write-chars. This sidesteps the input
#   contention problem: the user's keystrokes go to whatever process
#   owns the pane's foreground process group (the agent during a run,
#   the runner between runs), and the orchestrator never types into the
#   pane.
#
# - pane_send is the escape hatch for cases where we genuinely need to
#   inject characters mid-run (currently unused; kept for future
#   supervised-mode messaging). It acquires a lockfile to avoid two
#   orchestrator code paths racing to write to the same pane, and to
#   make the lock window inspectable.

if [[ -z "${CAPTAIN_TMP:-}" || -z "${CAPTAIN_ROOT:-}" ]]; then
  echo "pane.sh: CAPTAIN_TMP and CAPTAIN_ROOT must be set" >&2
  return 1 2>/dev/null || exit 1
fi

PANE_LOCK_DIR="$CAPTAIN_TMP/locks"
mkdir -p "$PANE_LOCK_DIR"

# pane_dispatch <pane> <prompt_file> <output_file>
#
# Sends a TSV dispatch line into the pane's fifo, then polls the
# sentinel file until it appears (or until POLL_TIMEOUT seconds pass).
# Returns the agent's exit code (read from the sentinel file).
pane_dispatch() {
  local pane="$1"
  local prompt_file="$2"
  local output_file="$3"

  local fifo="$CAPTAIN_TMP/${pane}.fifo"
  if [[ ! -p "$fifo" ]]; then
    echo "pane_dispatch: fifo missing for pane '$pane' at $fifo" >&2
    return 1
  fi

  # Sentinel is per-dispatch so we never confuse rounds.
  local sentinel
  sentinel="$CAPTAIN_TMP/${pane}.sentinel.$$.$(date +%s%N)"
  rm -f "$sentinel"

  # Write the dispatch line. The runner reads with `read -r < "$fifo"`,
  # which blocks until a writer connects. Opening the fifo for write
  # here unblocks it; the kernel pairs us up.
  printf '%s\t%s\t%s\n' "$prompt_file" "$output_file" "$sentinel" > "$fifo"

  # Poll for sentinel. Default timeout is generous because real agents
  # take minutes; tests override via PANE_POLL_TIMEOUT.
  local timeout="${PANE_POLL_TIMEOUT:-2700}"  # 45 min
  local interval="${PANE_POLL_INTERVAL:-0.5}"
  local elapsed=0
  while [[ ! -f "$sentinel" ]]; do
    sleep "$interval"
    # Bash arithmetic doesn't handle float, so step in interval units.
    # Use a separate counter to avoid floating-point in pure bash.
    elapsed=$(awk -v e="$elapsed" -v i="$interval" 'BEGIN { printf "%.2f", e + i }')
    if awk -v e="$elapsed" -v t="$timeout" 'BEGIN { exit !(e >= t) }'; then
      echo "pane_dispatch: timed out after ${timeout}s waiting for $pane" >&2
      return 124
    fi
  done

  local rc
  rc=$(cat "$sentinel" 2>/dev/null || echo "1")
  rm -f "$sentinel"
  return "$rc"
}

# pane_send <pane> <text>
#
# Inject text into the pane via zellij write-chars, advisory-locked so
# two callers don't interleave. Used sparingly — most agent input goes
# via pane_dispatch through the fifo.
#
# Caveat: zellij has no addressable focus-by-name; write-chars goes to
# the currently-focused pane. We don't try to move focus from here
# because doing so would also yank focus away from whatever the user
# was looking at. Treat this as best-effort: the caller should know the
# right pane is focused, or use pane_dispatch (which doesn't need focus).
pane_send() {
  local pane="$1"
  local text="$2"
  local lockfile="$PANE_LOCK_DIR/${pane}.lock"

  if ! command -v zellij >/dev/null 2>&1; then
    echo "pane_send: zellij not on PATH" >&2
    return 1
  fi

  # Lock primitive: mkdir is atomic on every POSIX filesystem we care
  # about. flock is Linux-only; O_EXCL on regular files is NFS-flaky.
  local waited=0
  while ! mkdir "$lockfile" 2>/dev/null; do
    sleep 0.05
    waited=$((waited + 1))
    if [[ "$waited" -gt 200 ]]; then  # ~10s
      echo "pane_send: timed out acquiring lock on $pane" >&2
      return 1
    fi
  done

  local rc=0
  zellij action write-chars -- "$text" || rc=$?
  rmdir "$lockfile" 2>/dev/null || true
  return "$rc"
}

# pane_status_log <text>
#
# The orchestrator IS the captain pane (it's the foreground process in
# that pane), so logging to stdout reaches the user directly.
pane_status_log() {
  local timestamp
  timestamp=$(date +%H:%M:%S)
  printf '[%s] %s\n' "$timestamp" "$1"
}
