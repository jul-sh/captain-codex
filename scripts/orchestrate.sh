#!/usr/bin/env bash
# captain-codex zellij-native orchestrator
# Runs in the "Captain" pane. Coordinates Codex (planning/review) and
# Claude (implementation) via one-shot CLI commands in their own panes.
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

# ── Cleanup on exit ───────────────────────────────────────────────────────────

trap cleanup_tmp EXIT

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: Planning
# ══════════════════════════════════════════════════════════════════════════════

run_planning() {
  log_status "═══ Planning ═══"

  # Build the plan prompt and write it to a file
  local plan_prompt
  plan_prompt=$(build_plan_prompt "$task" "$config")

  # Append instruction to save the plan to the expected path
  plan_prompt="${plan_prompt}

IMPORTANT: When you are done, save your complete implementation plan to: $plan_path"

  local prompt_file="$CAPTAIN_TMP/plan-prompt.md"
  printf '%s\n' "$plan_prompt" > "$prompt_file"

  local output_file="$CAPTAIN_TMP/plan-output.md"
  local done_file="$CAPTAIN_TMP/plan-done"

  log_status "Running Codex planning..."
  run_codex "$prompt_file" "$output_file" "$done_file"

  wait_for_file "$done_file" || {
    log_status "ERROR: Codex planning timed out"
    mark_failed "Codex planning timed out"
    exit 1
  }

  # Verify plan file was created
  if [[ ! -f "$plan_path" ]]; then
    log_status "Plan not at $plan_path, checking output..."
    # Codex might have written the plan to the output file instead
    if [[ -f "$output_file" ]]; then
      cp "$output_file" "$plan_path"
      log_status "Copied Codex output to $plan_path"
    else
      log_status "ERROR: Plan file not created at $plan_path"
      mark_failed "Plan file not created"
      exit 1
    fi
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

  local prompt_file="$CAPTAIN_TMP/impl-prompt.md"
  printf '%s\n' "$impl_prompt" > "$prompt_file"

  local output_file="$CAPTAIN_TMP/impl-output.md"
  local done_file="$CAPTAIN_TMP/impl-done"

  log_status "Running Claude implementation..."
  run_claude "$prompt_file" "$output_file" "$done_file"

  wait_for_file "$done_file" || {
    log_status "ERROR: Claude implementation timed out"
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

    # ── Review ──
    local review_prompt
    review_prompt=$(build_review_prompt "$plan_path")

    local review_prompt_file="$CAPTAIN_TMP/review-prompt-r${round}.md"
    printf '%s\n' "$review_prompt" > "$review_prompt_file"

    local review_output="$CAPTAIN_TMP/review-output-r${round}.md"
    local review_done="$CAPTAIN_TMP/review-done-r${round}"

    log_status "Codex reviewing..."
    run_codex "$review_prompt_file" "$review_output" "$review_done"

    wait_for_file "$review_done" || {
      log_status "ERROR: Review timed out (round $round)"
      mark_failed "Codex review timed out"
      return 1
    }

    # Parse verdict from the output file
    local review_content=""
    if [[ -f "$review_output" ]]; then
      review_content=$(cat "$review_output")
    fi

    local verdict="REJECT"
    if echo "$review_content" | grep -qi "VERDICT: APPROVE"; then
      verdict="APPROVE"
    fi

    local summary
    summary=$(echo "$review_content" | sed -n '/VERDICT/,$ p' | head -c 2000)
    if [[ -z "$summary" ]]; then
      summary=$(echo "$review_content" | tail -c 500)
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

          local override_prompt="The review was approved by Codex but overridden by the user. Please continue refining the implementation."
          local override_file="$CAPTAIN_TMP/override-r${round}.md"
          printf '%s\n' "$override_prompt" > "$override_file"
          local override_output="$CAPTAIN_TMP/override-output-r${round}.md"
          local override_done="$CAPTAIN_TMP/override-done-r${round}"

          run_claude "$override_file" "$override_output" "$override_done"
          wait_for_file "$override_done" || {
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
      feedback=$(echo "$review_content" | sed -n '/VERDICT: REJECT/,$ p' | tail -n +2 | head -c 3000)
      if [[ -z "$feedback" ]]; then
        feedback="Review rejected. See review output for details."
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

      local fb_file="$CAPTAIN_TMP/feedback-r${round}.md"
      printf '%s\n' "$feedback_text" > "$fb_file"
      local fb_output="$CAPTAIN_TMP/feedback-output-r${round}.md"
      local fb_done="$CAPTAIN_TMP/feedback-done-r${round}"

      run_claude "$fb_file" "$fb_output" "$fb_done"

      log_status "Claude fixing..."
      wait_for_file "$fb_done" || {
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
