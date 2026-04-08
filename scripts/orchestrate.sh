#!/usr/bin/env bash
# captain-codex zellij-native orchestrator
# Runs in a floating "Captain" pane. Coordinates Codex (planning/review) and
# Claude (implementation) across separate zellij tabs.
#
# Usage: orchestrate.sh <task> [options]
#   Options are passed as environment variables:
#     SKIP_PLAN=<path>    — skip planning, use existing plan
#     MAX_ROUNDS=<n>      — cap review iterations
#     SUPERVISED=true     — pause for human approval at checkpoints
#     ADHOC_PLAN=<text>   — ad-hoc planning instructions
#     ADHOC_IMPL=<text>   — ad-hoc implementation instructions
#     ADHOC_REVIEW=<text> — ad-hoc review instructions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# ── Parse arguments ───────────────────────────────────────────────────────────

task="${CAPTAIN_TASK:-${1:-}}"
if [[ -z "$task" ]]; then
  echo "Usage: CAPTAIN_TASK='...' orchestrate.sh  (or: orchestrate.sh <task>)" >&2
  exit 1
fi
skip_plan="${SKIP_PLAN:-}"
max_rounds="${MAX_ROUNDS:-}"
supervised="${SUPERVISED:-false}"
adhoc_plan="${ADHOC_PLAN:-}"
adhoc_impl="${ADHOC_IMPL:-}"
adhoc_review="${ADHOC_REVIEW:-}"

# ── Read config ───────────────────────────────────────────────────────────────

config=$(read_config)
plans_dir=$(echo "$config" | jq -r '.plans.directory // "tasks"')
filename_template=$(echo "$config" | jq -r '.plans.filename_template // "{{slug}}.md"')

if [[ -z "$max_rounds" ]]; then
  max_rounds=$(echo "$config" | jq -r '.max_rounds // 10')
fi

# Merge ad-hoc instructions into config for prompt building
if [[ -n "$adhoc_plan" ]]; then
  config=$(echo "$config" | jq --arg inst "$adhoc_plan" '.plan_instructions += [$inst]')
fi
if [[ -n "$adhoc_review" ]]; then
  config=$(echo "$config" | jq --arg inst "$adhoc_review" '.review_instructions += [$inst]')
fi

# ── Determine plan path ──────────────────────────────────────────────────────

if [[ -n "$skip_plan" ]]; then
  plan_path="$skip_plan"
  if [[ ! -f "$plan_path" ]]; then
    log_status "ERROR: Plan file not found: $plan_path"
    exit 1
  fi
  log_status "Using existing plan: $plan_path"
else
  slug=$(generate_slug "$task")
  plan_filename=$(echo "$filename_template" | sed "s/{{slug}}/$slug/g")
  plan_path="$plans_dir/$plan_filename"
  mkdir -p "$plans_dir"
fi

# Idle prompt patterns (ERE regex)
# These match the input prompt lines of each agent's interactive mode.
# Adjust if the agent CLI changes its prompt format.
CODEX_IDLE_PATTERN='(^>|╰─>|❯)'
CLAUDE_IDLE_PATTERN='(^>|╰─|❯)'

# ── Cleanup on exit ───────────────────────────────────────────────────────────

trap cleanup_tmp EXIT

# ── Tab setup ─────────────────────────────────────────────────────────────────

setup_tabs() {
  local existing
  existing=$(zellij action query-tab-names 2>/dev/null || echo "")

  if ! echo "$existing" | grep -q "^Codex$"; then
    zellij action new-tab -n "Codex"
    log_status "Created Codex tab"
  fi

  if ! echo "$existing" | grep -q "^Claude$"; then
    zellij action new-tab -n "Claude"
    log_status "Created Claude tab"
  fi
}

# ── Start agent sessions ─────────────────────────────────────────────────────

start_codex() {
  log_status "Starting Codex..."
  send_to_tab "Codex" "codex"
  wait_for_idle "Codex" "$CODEX_IDLE_PATTERN" 120 || {
    log_status "ERROR: Codex failed to start"
    exit 1
  }
  log_status "Codex ready."
}

start_claude() {
  log_status "Starting Claude..."
  send_to_tab "Claude" "claude"
  wait_for_idle "Claude" "$CLAUDE_IDLE_PATTERN" 120 || {
    log_status "ERROR: Claude failed to start"
    exit 1
  }
  log_status "Claude ready."
}

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: Planning
# ══════════════════════════════════════════════════════════════════════════════

run_planning() {
  log_status "═══ Planning ═══"

  local plan_prompt
  plan_prompt=$(build_plan_prompt "$task" "$config")

  log_status "Sending plan prompt to Codex..."
  deliver_prompt "Codex" "$plan_prompt" "plan-draft"

  log_status "Codex drafting plan..."
  wait_for_idle "Codex" "$CODEX_IDLE_PATTERN" || {
    log_status "ERROR: Codex planning timed out"
    mark_failed "Codex planning timed out"
    exit 1
  }

  log_status "Formalizing plan..."
  send_to_tab "Codex" "Formalize your plan into a delegatable implementation plan and save it to: $plan_path. Write the file now."

  wait_for_idle "Codex" "$CODEX_IDLE_PATTERN" || {
    log_status "ERROR: Codex formalization timed out"
    mark_failed "Codex formalization timed out"
    exit 1
  }

  # Verify plan file
  if [[ ! -f "$plan_path" ]]; then
    log_status "Plan not found, retrying..."
    send_to_tab "Codex" "The plan file was not created at $plan_path. Please write it now."
    wait_for_idle "Codex" "$CODEX_IDLE_PATTERN" || true
  fi

  if [[ ! -f "$plan_path" ]]; then
    log_status "ERROR: Plan file not created at $plan_path"
    mark_failed "Plan file not created"
    exit 1
  fi

  log_status "Plan: $plan_path"
}

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2: Implementation
# ══════════════════════════════════════════════════════════════════════════════

run_implementation() {
  log_status "═══ Implementing ═══"

  local impl_prompt
  impl_prompt=$(build_impl_prompt "$plan_path" "$config" "$adhoc_impl")

  log_status "Sending plan to Claude..."
  deliver_prompt "Claude" "$impl_prompt" "implement"

  log_status "Claude implementing..."
  wait_for_idle "Claude" "$CLAUDE_IDLE_PATTERN" || {
    log_status "ERROR: Claude timed out"
    mark_failed "Claude implementation timed out"
    exit 1
  }
  log_status "Implementation done."
}

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3: Review Loop
# ══════════════════════════════════════════════════════════════════════════════

run_review_loop() {
  log_status "═══ Review Loop ═══"

  local round=0

  while true; do
    round=$((round + 1))

    if [[ "$round" -gt "$max_rounds" ]]; then
      log_status "Max rounds ($max_rounds) exceeded."
      mark_failed "Max review rounds exceeded"
      return 1
    fi

    log_status "── Round $round/$max_rounds ──"
    update_phase "review"
    update_round "$round"

    local review_prompt
    review_prompt=$(build_review_prompt "$plan_path")

    log_status "Codex reviewing..."
    deliver_prompt "Codex" "$review_prompt" "review-round-$round"

    local review_marker="review-round-$round"

    wait_for_idle "Codex" "$CODEX_IDLE_PATTERN" || {
      log_status "ERROR: Review timed out (round $round)"
      mark_failed "Codex review timed out"
      return 1
    }

    # Extract only this round's output
    local screen_content
    screen_content=$(dump_screen_since "Codex" "$review_marker")

    # Parse verdict
    local verdict="REJECT"
    if echo "$screen_content" | grep -qi "VERDICT: APPROVE"; then
      verdict="APPROVE"
    fi

    local summary
    summary=$(echo "$screen_content" | sed -n '/VERDICT/,$ p' | head -c 2000)
    if [[ -z "$summary" ]]; then
      summary=$(echo "$screen_content" | tail -c 500)
    fi

    add_review_entry "$round" "$verdict" "$summary"
    log_status "Round $round: $verdict"

    if [[ "$verdict" == "APPROVE" ]]; then
      if [[ "$supervised" == "true" ]]; then
        log_status "APPROVED. Press Enter to accept, or type 'reject' to override."
        read -r user_input
        if [[ "$user_input" == "reject" ]]; then
          log_status "User overrode approval."
          update_phase "implementing"
          send_to_tab "Claude" "The review was approved by Codex but overridden by the user. Please continue refining the implementation."
          wait_for_idle "Claude" "$CLAUDE_IDLE_PATTERN" || {
            mark_failed "Claude timed out"
            return 1
          }
          continue
        fi
      fi

      mark_complete
      log_status "APPROVED on round $round."
      return 0
    else
      # REJECT — send feedback to Claude
      local feedback
      feedback=$(echo "$screen_content" | sed -n '/VERDICT: REJECT/,$ p' | tail -n +2 | head -c 3000)
      if [[ -z "$feedback" ]]; then
        feedback="Review rejected. Check Codex tab for details."
      fi

      if [[ "$supervised" == "true" ]]; then
        log_status "REJECTED. Press Enter to send feedback, or type custom feedback."
        read -r user_input
        if [[ -n "$user_input" ]]; then
          feedback="$user_input"
        fi
      fi

      update_phase "implementing"
      log_status "Sending feedback to Claude..."

      local feedback_text="The Codex reviewer has REJECTED the implementation (round $round/$max_rounds). Address the following feedback and continue:

$feedback"

      deliver_prompt "Claude" "$feedback_text" "feedback-round-$round"

      log_status "Claude fixing..."
      wait_for_idle "Claude" "$CLAUDE_IDLE_PATTERN" || {
        mark_failed "Claude timed out"
        return 1
      }
      log_status "Round $round fixes done."
    fi
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

main() {
  log_status "captain-codex"
  log_status "Task: $task"
  log_status "Rounds: $max_rounds | Supervised: $supervised"
  echo ""

  wait_for_session || exit 1
  setup_tabs
  start_codex
  start_claude

  "$CAPTAIN_ROOT/scripts/config.sh" init-state "$task" "$plan_path" "$max_rounds" "$supervised" "$adhoc_review"

  if [[ -z "$skip_plan" ]]; then
    run_planning

    if [[ "$supervised" == "true" ]]; then
      log_status "Plan ready: $plan_path"
      log_status "Press Enter to proceed."
      read -r
    fi
  fi

  update_phase "implementing"
  run_implementation

  local result=0
  run_review_loop || result=$?

  echo ""
  log_status "════════════════════"
  log_status "Done"
  log_status "════════════════════"
  log_status "Task:   $task"
  log_status "Plan:   $plan_path"

  if [[ -f "$STATE_FILE" ]]; then
    log_status "Phase:  $(jq -r '.phase' "$STATE_FILE")"
    log_status "Rounds: $(jq -r '.round' "$STATE_FILE")"

    local history_count
    history_count=$(jq '.review_history | length' "$STATE_FILE")
    if [[ "$history_count" -gt 0 ]]; then
      echo ""
      jq -r '.review_history[] | "  R\(.round): \(.verdict) (\(.timestamp))"' "$STATE_FILE"
    fi
  fi

  return $result
}

main
