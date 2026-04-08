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

# ── Zellij tab interaction ────────────────────────────────────────────────────

send_to_tab() {
  local tab_name="$1"
  local text="$2"

  zellij action go-to-tab-name "$tab_name"
  sleep 0.5  # let focus settle
  zellij action write-chars "$text"
  zellij action write 13  # Enter
}

# Deliver a long prompt by writing it to a temp file and instructing the agent
# to read it. Returns the temp file path.
deliver_prompt() {
  local tab_name="$1"
  local prompt_text="$2"
  local label="${3:-prompt}"

  local prompt_file="$CAPTAIN_TMP/${label}-$(date +%s).md"
  printf '%s\n' "$prompt_text" > "$prompt_file"

  send_to_tab "$tab_name" "Read and follow the instructions in $prompt_file"
}

# ── Idle detection via screen polling ─────────────────────────────────────────
#
# Polls dump-screen until:
#   1. Screen content hash is stable across 2 consecutive polls
#   2. The last non-empty lines match the agent's idle prompt pattern
#
# Args:
#   $1 — tab name to monitor
#   $2 — regex pattern for the idle prompt (ERE)
#   $3 — timeout in seconds (optional, defaults to PHASE_TIMEOUT)
#
# Returns 0 on idle detected, 1 on timeout.

wait_for_idle() {
  local tab_name="$1"
  local prompt_pattern="$2"
  local timeout="${3:-$PHASE_TIMEOUT}"

  local screen_file="$CAPTAIN_TMP/screen-${tab_name}.txt"
  local prev_hash=""
  local start_time
  start_time=$(date +%s)

  while true; do
    sleep "$POLL_INTERVAL"

    local elapsed=$(( $(date +%s) - start_time ))
    if [[ "$elapsed" -ge "$timeout" ]]; then
      echo "TIMEOUT: $tab_name did not become idle within ${timeout}s" >&2
      return 1
    fi

    # Switch to target tab before each dump — dump-screen captures the focused pane,
    # so we must ensure we're on the right tab even if the user navigated away.
    zellij action go-to-tab-name "$tab_name" 2>/dev/null || true
    zellij action dump-screen "$screen_file" -f 2>/dev/null || continue

    local current_hash
    current_hash=$(md5 -q "$screen_file" 2>/dev/null || md5sum "$screen_file" | cut -d' ' -f1)

    # Screen must have stabilized
    if [[ "$current_hash" == "$prev_hash" ]]; then
      # Check the last non-empty lines for the prompt pattern
      local tail_content
      tail_content=$(grep -v '^[[:space:]]*$' "$screen_file" | tail -5)
      if echo "$tail_content" | grep -qE "$prompt_pattern"; then
        return 0
      fi
    fi

    prev_hash="$current_hash"
  done
}

# ── Screen content extraction ─────────────────────────────────────────────────

# Dump full screen scrollback and return content
dump_screen_content() {
  local tab_name="$1"
  local screen_file="$CAPTAIN_TMP/screen-${tab_name}-$(date +%s).txt"

  zellij action go-to-tab-name "$tab_name"
  sleep 0.3
  zellij action dump-screen "$screen_file" -f
  cat "$screen_file"
}

# Dump screen and return only content after the last occurrence of a marker.
# Prevents matching stale output from earlier rounds.
dump_screen_since() {
  local tab_name="$1"
  local marker="$2"

  local full_content
  full_content=$(dump_screen_content "$tab_name")

  # Find the LAST occurrence of marker and return everything after it
  local line_num
  line_num=$(echo "$full_content" | grep -n "$marker" | tail -1 | cut -d: -f1)
  if [[ -n "$line_num" ]]; then
    echo "$full_content" | tail -n +"$line_num"
  else
    # Marker not found — return full content as fallback
    echo "$full_content"
  fi
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
