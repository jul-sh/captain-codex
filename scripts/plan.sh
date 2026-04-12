#!/usr/bin/env bash
# captain-codex planning phase orchestrator
# Usage: plan.sh <task_description> [--plan-model <model>]
#
# Dispatches two Codex calls:
#   1. Read codebase and draft plan
#   2. Formalize into delegatable plan with acceptance criteria
#
# Outputs the path to the created plan file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

task="$1"
shift

# Read config
config=$("$SCRIPT_DIR/scripts/config.sh" read)
codex_model=$(echo "$config" | jq -r '.codex.plan_model // .codex.model // "gpt-5.4"')
codex_effort=$(echo "$config" | jq -r '.codex.reasoning_effort // "xhigh"')
plans_dir=$(echo "$config" | jq -r '.plans.directory // "tasks"')
filename_template=$(echo "$config" | jq -r '.plans.filename_template // "{{slug}}.md"')

# Parse optional overrides
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-model) codex_model="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Generate slug from task description
slug=$(echo "$task" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-60)
plan_filename=$(echo "$filename_template" | sed "s/{{slug}}/$slug/g")
plan_path="$plans_dir/$plan_filename"

# Build plan instructions string
plan_instructions=$(echo "$config" | jq -r '.plan_instructions[]' | sed 's/^/- /')

# Ensure tasks directory exists
mkdir -p "$plans_dir"

# ── Codex Call 1: Read codebase and draft plan ────────────────────────────
plan_prompt=$(cat "$SCRIPT_DIR/templates/plan-prompt.md")
plan_prompt="${plan_prompt//\{\{task_description\}\}/$task}"
plan_prompt="${plan_prompt//\{\{plan_instructions\}\}/$plan_instructions}"

json_output=$(echo "$plan_prompt" | codex exec --sandbox workspace-write -m "$codex_model" -c "model_reasoning_effort=$codex_effort" --json 2>/dev/null) || {
  echo "ERROR: Codex planning call 1 failed. Retrying..." >&2
  sleep 2
  json_output=$(echo "$plan_prompt" | codex exec --sandbox workspace-write -m "$codex_model" -c "model_reasoning_effort=$codex_effort" --json 2>/dev/null) || {
    echo "ERROR: Codex planning call 1 failed after retry." >&2
    exit 1
  }
}

# Extract thread ID from JSON Lines output
session_id=$(echo "$json_output" | jq -r 'select(.type == "thread.started") | .thread_id // empty' | head -1)
if [[ -z "$session_id" ]]; then
  # Fallback: try other event shapes
  session_id=$(echo "$json_output" | jq -r 'select(.thread_id) | .thread_id' | head -1)
fi

if [[ -z "$session_id" ]]; then
  echo "WARNING: Could not extract session ID from Codex output." >&2
fi

# ── Codex Call 2: Resume session to formalize plan ───────────────────────
formalize_prompt="Formalize your plan into a delegatable implementation plan and save it to: $plan_path

Write the file now."

if [[ -n "$session_id" ]]; then
  formalized=$(echo "$formalize_prompt" | codex exec resume "$session_id" --sandbox workspace-write -m "$codex_model" -c "model_reasoning_effort=$codex_effort" 2>/dev/null) || {
    echo "ERROR: Codex planning call 2 failed. Retrying..." >&2
    sleep 2
    formalized=$(echo "$formalize_prompt" | codex exec resume "$session_id" --sandbox workspace-write -m "$codex_model" -c "model_reasoning_effort=$codex_effort" 2>/dev/null) || {
      echo "ERROR: Codex planning call 2 failed after retry." >&2
      exit 1
    }
  }
else
  formalized=$(echo "$formalize_prompt" | codex exec --sandbox workspace-write -m "$codex_model" -c "model_reasoning_effort=$codex_effort" 2>/dev/null) || {
    echo "ERROR: Codex planning call 2 failed. Retrying..." >&2
    sleep 2
    formalized=$(echo "$formalize_prompt" | codex exec --sandbox workspace-write -m "$codex_model" -c "model_reasoning_effort=$codex_effort" 2>/dev/null) || {
      echo "ERROR: Codex planning call 2 failed after retry." >&2
      exit 1
    }
  }
fi

# ── Verify plan file was created ──────────────────────────────────────────
if [[ ! -f "$plan_path" ]]; then
  echo "ERROR: Plan file not found at $plan_path after Codex calls." >&2
  echo "Codex may not have written the file. Check Codex output." >&2
  exit 1
fi


# Output plan path and session ID (tab-separated)
echo "${plan_path}	${session_id:-}"
