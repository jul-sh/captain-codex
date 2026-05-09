#!/usr/bin/env bash
# captain-codex shared helpers
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Resolve project root if not pre-set by the entry script.
CAPTAIN_ROOT="${CAPTAIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Temp directory for this orchestration run. The entry script sets this
# to a session-specific path; if we're sourced standalone (e.g. tests),
# fall back to a per-pid path.
CAPTAIN_TMP="${CAPTAIN_TMP:-/tmp/captain-codex-$$}"
mkdir -p "$CAPTAIN_TMP"

# Whether the orchestrator drives agent panes via zellij. When false,
# agents run as direct subprocesses inheriting the orchestrator's TTY.
CAPTAIN_USE_ZELLIJ="${CAPTAIN_USE_ZELLIJ:-false}"

if [[ "$CAPTAIN_USE_ZELLIJ" == "true" ]]; then
  # shellcheck disable=SC1091
  source "$CAPTAIN_ROOT/scripts/pane.sh"
fi

# ── Slug generation ───────────────────────────────────────────────────────────

generate_slug() {
  local task="$1"
  # Strip CR/LF/TAB before lowercasing so multi-line task descriptions
  # don't break downstream sed substitutions (the slug feeds a
  # filename_template via `sed s/{{slug}}/$slug/g`, which fails on
  # unescaped newlines).
  printf '%s' "$task" \
    | tr '\n\r\t' '   ' \
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

# ── Agent runners ────────────────────────────────────────────────────────────
#
# In zellij mode the orchestrator runs in the "captain" pane and
# dispatches agent invocations into the "codex" / "claude" panes via
# fifos. The runners (agent-runner.sh) exec the actual CLI with the
# prompt on stdin.
#
# In inline mode (--no-zellij) the runners exec the CLI directly,
# inheriting this process's TTY. Both paths leave the orchestrator with
# an output file containing the agent's stdout, ready for parsing.

run_codex() {
  local prompt_file="$1"
  local output_file="$2"

  if [[ "$CAPTAIN_USE_ZELLIJ" == "true" ]]; then
    pane_dispatch codex "$prompt_file" "$output_file"
  else
    codex exec -o "$output_file" --full-auto - < "$prompt_file"
  fi
}

run_claude() {
  local prompt_file="$1"
  local output_file="$2"

  if [[ "$CAPTAIN_USE_ZELLIJ" == "true" ]]; then
    pane_dispatch claude "$prompt_file" "$output_file"
  else
    claude -p --output-format text --dangerously-skip-permissions \
      < "$prompt_file" | tee "$output_file"
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
  # Only clean up if we own this temp dir. In zellij mode the entry
  # script created CAPTAIN_TMP and is responsible for cleanup; the
  # orchestrator only owns it in inline mode.
  if [[ "$CAPTAIN_USE_ZELLIJ" != "true" ]]; then
    rm -rf "$CAPTAIN_TMP"
  fi
}

# Verdict matcher anchored to a line start. Without anchoring, a phrase
# like 'criteria for VERDICT: APPROVE would be...' inside a REJECT body
# could flip the verdict.
verdict_is_approve() {
  local content="$1"
  printf '%s\n' "$content" | grep -qE '^[[:space:]]*VERDICT:[[:space:]]*APPROVE\b'
}
