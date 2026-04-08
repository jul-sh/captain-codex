#!/usr/bin/env bash
# captain-codex zellij-native orchestrator
# Runs in the "Captain" tab. Coordinates Codex (planning/review) and Claude (implementation)
# across separate zellij tabs.
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

task="${1:?Usage: orchestrate.sh <task description>}"
skip_plan="${SKIP_PLAN:-}"
max_rounds="${MAX_ROUNDS:-}"
supervised="${SUPERVISED:-false}"
adhoc_plan="${ADHOC_PLAN:-}"
adhoc_impl="${ADHOC_IMPL:-}"
adhoc_review="${ADHOC_REVIEW:-}"

# ── Read config ───────────────────────────────────────────────────────────────

config=$(read_config)
codex_model=$(echo "$config" | jq -r '.codex.plan_model // .codex.model // "gpt-5.4"')
# Note: codex.review_model is not used in zellij mode because Codex keeps a
# single interactive session for both planning and review (retaining context).
# The session uses the plan_model throughout.
codex_effort=$(echo "$config" | jq -r '.codex.reasoning_effort // "xhigh"')
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

  # Ensure the tab we're running in is named "Captain"
  if ! echo "$existing" | grep -q "^Captain$"; then
    zellij action rename-tab "Captain"
    log_status "Renamed current tab to Captain"
  fi

  if ! echo "$existing" | grep -q "^Codex$"; then
    zellij action new-tab -n "Codex"
    log_status "Created Codex tab"
  fi

  if ! echo "$existing" | grep -q "^Claude$"; then
    zellij action new-tab -n "Claude"
    log_status "Created Claude tab"
  fi

  # Return focus to Captain tab
  zellij action go-to-tab-name "Captain"
}

# ── Start agent sessions ─────────────────────────────────────────────────────

start_codex() {
  log_status "Starting Codex interactive session..."
  send_to_tab "Codex" "codex -m $codex_model -c \"model_reasoning_effort=$codex_effort\""
  log_status "Waiting for Codex to initialize..."
  wait_for_idle "Codex" "$CODEX_IDLE_PATTERN" 120 || {
    log_status "ERROR: Codex failed to start within 120s"
    exit 1
  }
  # Return to Captain
  zellij action go-to-tab-name "Captain"
  log_status "Codex is ready."
}

start_claude() {
  log_status "Starting Claude interactive session..."
  send_to_tab "Claude" "claude"
  log_status "Waiting for Claude to initialize..."
  wait_for_idle "Claude" "$CLAUDE_IDLE_PATTERN" 120 || {
    log_status "ERROR: Claude failed to start within 120s"
    exit 1
  }
  zellij action go-to-tab-name "Captain"
  log_status "Claude is ready."
}

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: Planning
# ══════════════════════════════════════════════════════════════════════════════

run_planning() {
  log_status "═══ Phase 1: Planning ═══"

  # Build planning prompt
  local plan_prompt
  plan_prompt=$(build_plan_prompt "$task" "$config")

  # Deliver planning prompt to Codex
  log_status "Sending planning prompt to Codex..."
  deliver_prompt "Codex" "$plan_prompt" "plan-draft"

  log_status "Codex is drafting the plan. Watch the Codex tab for progress."
  wait_for_idle "Codex" "$CODEX_IDLE_PATTERN" || {
    log_status "ERROR: Codex planning timed out"
    mark_failed "Codex planning timed out"
    exit 1
  }
  zellij action go-to-tab-name "Captain"

  # Send formalize prompt
  log_status "Asking Codex to formalize the plan..."
  send_to_tab "Codex" "Formalize your plan into a delegatable implementation plan and save it to: $plan_path. Write the file now."

  wait_for_idle "Codex" "$CODEX_IDLE_PATTERN" || {
    log_status "ERROR: Codex formalization timed out"
    mark_failed "Codex formalization timed out"
    exit 1
  }
  zellij action go-to-tab-name "Captain"

  # Verify plan file
  if [[ ! -f "$plan_path" ]]; then
    log_status "Plan file not found. Asking Codex to retry..."
    send_to_tab "Codex" "The plan file was not created at $plan_path. Please write it now."
    wait_for_idle "Codex" "$CODEX_IDLE_PATTERN" || true
    zellij action go-to-tab-name "Captain"
  fi

  if [[ ! -f "$plan_path" ]]; then
    log_status "ERROR: Plan file still not found at $plan_path"
    mark_failed "Plan file not created"
    exit 1
  fi

  log_status "Plan created: $plan_path"
}

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2: Implementation
# ══════════════════════════════════════════════════════════════════════════════

run_implementation() {
  log_status "═══ Phase 2: Implementation ═══"

  # Build implementation prompt
  local impl_prompt
  impl_prompt=$(build_impl_prompt "$plan_path" "$config" "$adhoc_impl")

  # Deliver to Claude
  log_status "Sending implementation prompt to Claude..."
  deliver_prompt "Claude" "$impl_prompt" "implement"

  log_status "Claude is implementing. Watch the Claude tab for progress."
  wait_for_idle "Claude" "$CLAUDE_IDLE_PATTERN" || {
    log_status "ERROR: Claude implementation timed out"
    mark_failed "Claude implementation timed out"
    exit 1
  }
  zellij action go-to-tab-name "Captain"
  log_status "Claude finished implementation."
}

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3: Review Loop
# ══════════════════════════════════════════════════════════════════════════════

run_review_loop() {
  log_status "═══ Phase 3: Review Loop ═══"

  local round=0

  while true; do
    round=$((round + 1))

    if [[ "$round" -gt "$max_rounds" ]]; then
      log_status "Max review rounds ($max_rounds) exceeded."
      mark_failed "Max review rounds exceeded"
      return 1
    fi

    log_status "── Review round $round/$max_rounds ──"
    update_phase "review"
    update_round "$round"

    # Build and deliver review prompt to Codex
    local review_prompt
    review_prompt=$(build_review_prompt "$plan_path")

    log_status "Sending review prompt to Codex..."
    deliver_prompt "Codex" "$review_prompt" "review-round-$round"

    # Use the temp file path as a marker to extract only this round's output
    local review_marker="review-round-$round"

    log_status "Codex is reviewing. Watch the Codex tab."
    wait_for_idle "Codex" "$CODEX_IDLE_PATTERN" || {
      log_status "ERROR: Codex review timed out on round $round"
      mark_failed "Codex review timed out"
      return 1
    }
    zellij action go-to-tab-name "Captain"

    # Extract only this round's review output (avoids matching earlier rounds' VERDICTs)
    local screen_content
    screen_content=$(dump_screen_since "Codex" "$review_marker")
    zellij action go-to-tab-name "Captain"

    # Parse verdict from this round's output only
    local verdict="REJECT"
    if echo "$screen_content" | grep -qi "VERDICT: APPROVE"; then
      verdict="APPROVE"
    fi

    # Extract summary (content around the VERDICT line)
    local summary
    summary=$(echo "$screen_content" | sed -n '/VERDICT/,$ p' | head -c 2000)
    if [[ -z "$summary" ]]; then
      summary=$(echo "$screen_content" | tail -c 500)
    fi

    add_review_entry "$round" "$verdict" "$summary"
    log_status "Round $round verdict: $verdict"

    if [[ "$verdict" == "APPROVE" ]]; then
      if [[ "$supervised" == "true" ]]; then
        log_status "Codex APPROVED. Supervised mode — press Enter to accept, or type 'reject' to continue."
        read -r user_input
        if [[ "$user_input" == "reject" ]]; then
          log_status "User overrode approval. Continuing implementation..."
          update_phase "implementing"
          send_to_tab "Claude" "The review was approved by Codex but overridden by the user. Please continue refining the implementation."
          wait_for_idle "Claude" "$CLAUDE_IDLE_PATTERN" || {
            log_status "ERROR: Claude timed out after user override"
            mark_failed "Claude timed out"
            return 1
          }
          zellij action go-to-tab-name "Captain"
          continue
        fi
      fi

      mark_complete
      log_status "Implementation APPROVED on round $round."
      return 0
    else
      # REJECT — extract feedback and send to Claude
      local feedback
      feedback=$(echo "$screen_content" | sed -n '/VERDICT: REJECT/,$ p' | tail -n +2 | head -c 3000)
      if [[ -z "$feedback" ]]; then
        feedback="The review was rejected. Please review the Codex tab for details and address the issues."
      fi

      if [[ "$supervised" == "true" ]]; then
        log_status "Codex REJECTED. Review feedback above. Press Enter to send feedback to Claude, or type custom feedback."
        read -r user_input
        if [[ -n "$user_input" ]]; then
          feedback="$user_input"
        fi
      fi

      update_phase "implementing"
      log_status "Sending rejection feedback to Claude..."

      local feedback_text="The Codex reviewer has REJECTED the implementation (round $round/$max_rounds). Address the following feedback and continue:

$feedback"

      deliver_prompt "Claude" "$feedback_text" "feedback-round-$round"

      log_status "Claude is addressing feedback. Watch the Claude tab."
      wait_for_idle "Claude" "$CLAUDE_IDLE_PATTERN" || {
        log_status "ERROR: Claude timed out addressing feedback on round $round"
        mark_failed "Claude timed out"
        return 1
      }
      zellij action go-to-tab-name "Captain"
      log_status "Claude finished addressing round $round feedback."
    fi
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

main() {
  log_status "Captain Codex — Zellij-native orchestrator"
  log_status "Task: $task"
  log_status "Max rounds: $max_rounds | Supervised: $supervised"
  echo ""

  # Setup
  setup_tabs
  start_codex
  start_claude

  # Initialize state
  "$CAPTAIN_ROOT/scripts/config.sh" init-state "$task" "$plan_path" "$max_rounds" "$supervised" "$adhoc_review"

  # Phase 1: Planning (unless skipped)
  if [[ -z "$skip_plan" ]]; then
    run_planning

    if [[ "$supervised" == "true" ]]; then
      log_status "Plan ready at: $plan_path"
      log_status "Review it, then press Enter to proceed to implementation."
      read -r
    fi
  fi

  # Phase 2: Implementation
  update_phase "implementing"
  run_implementation

  # Phase 3: Review loop (capture exit code without set -e killing us)
  local result=0
  run_review_loop || result=$?

  # Summary
  echo ""
  log_status "══════════════════════════════════"
  log_status "Captain Codex — Run Complete"
  log_status "══════════════════════════════════"
  log_status "Task:     $task"
  log_status "Plan:     $plan_path"

  if [[ -f "$STATE_FILE" ]]; then
    local final_phase
    final_phase=$(jq -r '.phase' "$STATE_FILE")
    local total_rounds
    total_rounds=$(jq -r '.round' "$STATE_FILE")
    log_status "Phase:    $final_phase"
    log_status "Rounds:   $total_rounds"

    # Print review history
    local history_count
    history_count=$(jq '.review_history | length' "$STATE_FILE")
    if [[ "$history_count" -gt 0 ]]; then
      log_status ""
      log_status "Review History:"
      jq -r '.review_history[] | "  Round \(.round): \(.verdict) (\(.timestamp))"' "$STATE_FILE"
    fi
  fi

  return $result
}

main
