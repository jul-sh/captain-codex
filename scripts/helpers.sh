#!/usr/bin/env bash
# captain-codex shared helpers for zellij-native orchestration
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Resolve project root
CAPTAIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Temp directory for this orchestration run
CAPTAIN_TMP="${CAPTAIN_TMP:-/tmp/captain-codex-$$}"
mkdir -p "$CAPTAIN_TMP"

# Polling config
POLL_INTERVAL="${POLL_INTERVAL:-3}"
PHASE_TIMEOUT="${PHASE_TIMEOUT:-2700}"  # 45 minutes in seconds

# ── Zellij session readiness ──────────────────────────────────────────────────

wait_for_session() {
  local max_attempts=20
  local attempt=0
  while [[ $attempt -lt $max_attempts ]]; do
    if zellij action query-tab-names &>/dev/null; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.5
  done
  echo "ERROR: zellij session not ready after ${max_attempts} attempts" >&2
  return 1
}

# ── Slug generation ───────────────────────────────────────────────────────────

generate_slug() {
  local task="$1"
  echo "$task" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//' \
    | cut -c1-60
}

# ── Config helpers ────────────────────────────────────────────────────────────

read_config() {
  "$CAPTAIN_ROOT/scripts/config.sh" read
}

# ── Prompt builders ───────────────────────────────────────────────────────────

build_plan_prompt() {
  local task="$1"
  local config="$2"

  local plan_instructions
  plan_instructions=$(echo "$config" | jq -r '.plan_instructions[]' | sed 's/^/- /')

  local template
  template=$(cat "$CAPTAIN_ROOT/templates/plan-prompt.md")
  template="${template//\{\{task_description\}\}/$task}"
  template="${template//\{\{plan_instructions\}\}/$plan_instructions}"
  echo "$template"
}

build_impl_prompt() {
  local plan_path="$1"
  local config="$2"
  local adhoc_impl_instructions="${3:-}"

  local plan_contents
  plan_contents=$(cat "$plan_path")

  local impl_instructions
  impl_instructions=$(echo "$config" | jq -r '.implementation_instructions[]' | sed 's/^/- /')
  if [[ -n "$adhoc_impl_instructions" ]]; then
    impl_instructions="${impl_instructions}
- ${adhoc_impl_instructions}"
  fi

  local template
  template=$(cat "$CAPTAIN_ROOT/templates/implement-prompt.md")
  template="${template//\{\{plan_contents\}\}/$plan_contents}"
  template="${template//\{\{implementation_instructions\}\}/$impl_instructions}"
  template="${template//\{\{plan_file\}\}/$plan_path}"
  echo "$template"
}

build_review_prompt() {
  local plan_path="$1"
  "$CAPTAIN_ROOT/scripts/review-prompt.sh" "$plan_path"
}

# ── Pane interaction ─────────────────────────────────────────────────────────
#
# Layout: Captain (left) | Codex (middle) | Claude (right)
# We focus panes via move-focus, type commands with write-chars (preserving
# full TTY colors/errors), and poll sentinel files for completion.

focus_pane() {
  local target="$1"
  case "$target" in
    Captain)
      zellij action move-focus left 2>/dev/null || true
      zellij action move-focus left 2>/dev/null || true
      ;;
    Codex)
      zellij action move-focus left 2>/dev/null || true
      zellij action move-focus left 2>/dev/null || true
      zellij action move-focus right 2>/dev/null || true
      ;;
    Claude)
      zellij action move-focus right 2>/dev/null || true
      zellij action move-focus right 2>/dev/null || true
      ;;
  esac
}

send_to_pane() {
  local pane_name="$1"
  local text="$2"

  focus_pane "$pane_name"
  sleep 0.2
  zellij action write-chars "$text"
  zellij action write 13  # Enter
  sleep 0.2
  focus_pane "Captain"
}

# ── Sentinel-based completion ────────────────────────────────────────────────

# Wait for a sentinel file to appear, with timeout.
wait_for_file() {
  local filepath="$1"
  local timeout="${2:-$PHASE_TIMEOUT}"
  local start_time
  start_time=$(date +%s)

  while true; do
    if [[ -f "$filepath" ]]; then
      return 0
    fi
    local elapsed=$(( $(date +%s) - start_time ))
    if [[ "$elapsed" -ge "$timeout" ]]; then
      echo "TIMEOUT: $filepath not created within ${timeout}s" >&2
      return 1
    fi
    sleep "$POLL_INTERVAL"
  done
}

# Read the exit code left by a pane command. Returns 0 if the agent exited 0.
check_exit_code() {
  local exit_file="$1"
  if [[ -f "$exit_file" ]]; then
    local code
    code=$(cat "$exit_file")
    return "${code:-1}"
  fi
  return 1
}

# ── Agent runners ────────────────────────────────────────────────────────────
#
# Each runner types a one-shot command into its pane. The command:
#   1. Runs the agent CLI (full TTY — colors, progress, errors all visible)
#   2. Saves the exit code to a file
#   3. Touches a sentinel file so the orchestrator knows it's done

run_codex() {
  local prompt_file="$1"
  local output_file="$2"
  local done_file="$3"
  local exit_file="${done_file}.exit"

  rm -f "$done_file" "$exit_file"
  send_to_pane "Codex" "codex exec -o '$output_file' --full-auto - < '$prompt_file'; echo \$? > '$exit_file'; touch '$done_file'"
}

run_claude() {
  local prompt_file="$1"
  local output_file="$2"
  local done_file="$3"
  local exit_file="${done_file}.exit"

  rm -f "$done_file" "$exit_file"
  send_to_pane "Claude" "claude -p --output-format text --dangerously-skip-permissions < '$prompt_file' | tee '$output_file'; echo \${PIPESTATUS[0]} > '$exit_file'; touch '$done_file'"
}

# ── State management ──────────────────────────────────────────────────────────

STATE_FILE=".claude-architect/state.json"

update_phase() {
  local phase="$1"
  jq --arg phase "$phase" '.phase = $phase' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

update_round() {
  local round="$1"
  jq --argjson round "$round" '.round = $round' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

add_review_entry() {
  local round="$1"
  local verdict="$2"
  local summary="$3"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local entry
  entry=$(jq -n \
    --argjson round "$round" \
    --arg verdict "$verdict" \
    --arg summary "$summary" \
    --arg timestamp "$timestamp" \
    '{round: $round, verdict: $verdict, summary: $summary, timestamp: $timestamp}')

  jq --argjson entry "$entry" \
    '.review_history += [$entry]' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

mark_complete() {
  jq '.active = false | .phase = "complete"' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

mark_failed() {
  local reason="$1"
  jq --arg reason "$reason" \
    '.active = false | .phase = "failed" | .failure_reason = $reason' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# ── Logging ───────────────────────────────────────────────────────────────────

log_status() {
  local msg="$1"
  local timestamp
  timestamp=$(date +%H:%M:%S)
  echo "[$timestamp] $msg"
}

# ── Cleanup ───────────────────────────────────────────────────────────────────

cleanup_tmp() {
  rm -rf "$CAPTAIN_TMP"
}
