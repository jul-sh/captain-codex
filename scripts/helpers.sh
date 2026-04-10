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

# Wait until zellij action commands work. The session may not be ready
# immediately when a layout pane command starts.
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

# ── Agent execution ──────────────────────────────────────────────────────────
#
# Agents run as background processes from the Captain pane. Their output
# streams to log files that the Codex/Claude panes are tailing, so you
# can watch progress live. The orchestrator polls for a sentinel file to
# know when an agent is done. No pane focusing or write-chars needed.

# Wait for a sentinel file to appear, with timeout.
# Returns 0 when the file exists, 1 on timeout.
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

# Run codex exec as a background process.
#   $1 — prompt file to pass via stdin
#   $2 — output file for the last message (-o)
#   $3 — sentinel file (touched on completion)
run_codex() {
  local prompt_file="$1"
  local output_file="$2"
  local done_file="$3"

  rm -f "$done_file"
  (
    codex exec -o "$output_file" --full-auto - < "$prompt_file" \
      >> "$CAPTAIN_TMP/codex.log" 2>&1
    touch "$done_file"
  ) &
}

# Run claude -p as a background process.
#   $1 — prompt file to pass via stdin
#   $2 — output file for the response
#   $3 — sentinel file (touched on completion)
run_claude() {
  local prompt_file="$1"
  local output_file="$2"
  local done_file="$3"

  rm -f "$done_file"
  (
    claude -p --output-format text --dangerously-skip-permissions \
      < "$prompt_file" 2>> "$CAPTAIN_TMP/claude.log" \
      | tee "$output_file" >> "$CAPTAIN_TMP/claude.log"
    touch "$done_file"
  ) &
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
