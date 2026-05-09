#!/usr/bin/env bash
# Per-pane agent runner.
#
# Runs in a zellij pane and blocks on a fifo waiting for dispatch
# requests. When the orchestrator wants to invoke an agent, it writes
# three tab-separated lines into the fifo:
#
#     <prompt-file>\t<output-file>\t<sentinel-file>
#
# This script reads that, exec's the agent with prompt-file on stdin and
# output-file capturing output, then writes the agent's exit code into
# sentinel-file. The orchestrator polls the sentinel to know when to
# proceed.
#
# Why a fifo and not zellij write-chars?
# - The pane process IS this runner; the agent runs as a foreground
#   child. User keystrokes go to whichever process owns the TTY's
#   foreground process group — the agent during a run, the runner
#   between runs (where they're harmlessly discarded by `read`).
# - The orchestrator never injects characters into the pane, so there's
#   no contention with user input.
#
# Usage: agent-runner.sh <codex|claude>

set -euo pipefail

agent="${1:?agent name required}"

if [[ -z "${CAPTAIN_TMP:-}" ]]; then
  echo "ERROR: CAPTAIN_TMP not set; this runner must be launched by captain-codex" >&2
  exit 1
fi

fifo="$CAPTAIN_TMP/${agent}.fifo"

# Ensure fifo exists. The entry script creates it before launching zellij,
# but be defensive in case the runner is restarted.
if [[ ! -p "$fifo" ]]; then
  mkfifo "$fifo"
fi

clear
cat <<EOF
captain-codex / ${agent} pane

Waiting for the orchestrator to dispatch a task here.

While an agent is running, your keystrokes go to the agent (Ctrl-C will
interrupt it). Between runs, keystrokes are discarded by this runner.

EOF

while true; do
  # Block until the orchestrator writes one line of TSV. read -r preserves
  # the literal data; IFS=$'\t' splits the three fields.
  IFS=$'\t' read -r prompt_file output_file sentinel_file < "$fifo" || {
    # If the fifo is closed (orchestrator exited), break and exit cleanly.
    break
  }

  if [[ -z "$prompt_file" || -z "$output_file" || -z "$sentinel_file" ]]; then
    echo "[runner] malformed dispatch (skipping): prompt=$prompt_file output=$output_file sentinel=$sentinel_file" >&2
    continue
  fi

  if [[ ! -f "$prompt_file" ]]; then
    echo "[runner] prompt file missing: $prompt_file" >&2
    echo "1" > "$sentinel_file"
    continue
  fi

  echo ""
  echo "── ${agent} ── $(date +%H:%M:%S) ──"
  echo ""

  # Run the agent with the prompt on stdin. Output is teed so the user
  # sees it live AND the orchestrator can read it from the file.
  set +e
  case "$agent" in
    codex)
      codex exec -o "$output_file" --full-auto - < "$prompt_file"
      rc=$?
      ;;
    claude)
      claude -p --output-format text --dangerously-skip-permissions \
        < "$prompt_file" | tee "$output_file"
      # tee's exit code is what's left of pipefail; we want claude's.
      rc=${PIPESTATUS[0]}
      ;;
    *)
      echo "[runner] unknown agent: $agent" >&2
      rc=2
      ;;
  esac
  set -e

  echo ""
  echo "── ${agent} done (exit ${rc}) ──"
  echo ""

  # Write sentinel last so the orchestrator only proceeds after output is flushed.
  printf '%s\n' "$rc" > "${sentinel_file}.tmp"
  mv "${sentinel_file}.tmp" "$sentinel_file"
done
