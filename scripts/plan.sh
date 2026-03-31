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

# Build acceptance criteria string
acceptance_criteria=$(echo "$config" | jq -r '.acceptance_criteria[]' | sed 's/^/- [ ] /')

# Ensure tasks directory exists
mkdir -p "$plans_dir"

# ── Codex Call 1: Read codebase and draft plan ────────────────────────────
plan_prompt=$(cat "$SCRIPT_DIR/templates/plan-prompt.md" | sed "s|{{task_description}}|$task|g")

draft=$(echo "$plan_prompt" | codex exec -m "$codex_model" -c "model_reasoning_effort=$codex_effort" --quiet 2>/dev/null) || {
  echo "ERROR: Codex planning call 1 failed. Retrying..." >&2
  sleep 2
  draft=$(echo "$plan_prompt" | codex exec -m "$codex_model" -c "model_reasoning_effort=$codex_effort" --quiet 2>/dev/null) || {
    echo "ERROR: Codex planning call 1 failed after retry." >&2
    exit 1
  }
}

# ── Codex Call 2: Formalize into delegatable plan ─────────────────────────
formalize_prompt="Based on the plan you just drafted, create a formal delegatable implementation plan.

Save it to: $plan_path

The plan file must include these sections:
# $task

## Overview
<high-level description of the goal and approach>

## Scope
<what is in scope and what is explicitly out of scope>

## Implementation Steps
<numbered, detailed steps with file-by-file changes where applicable>

## Edge Cases & Pitfalls
<things to watch out for>

## Acceptance Criteria
$acceptance_criteria

## Worklog
<empty — to be filled during implementation>

Write the file now."

formalized=$(echo "$formalize_prompt" | codex exec -m "$codex_model" -c "model_reasoning_effort=$codex_effort" --quiet 2>/dev/null) || {
  echo "ERROR: Codex planning call 2 failed. Retrying..." >&2
  sleep 2
  formalized=$(echo "$formalize_prompt" | codex exec -m "$codex_model" -c "model_reasoning_effort=$codex_effort" --quiet 2>/dev/null) || {
    echo "ERROR: Codex planning call 2 failed after retry." >&2
    exit 1
  }
}

# ── Verify plan file was created ──────────────────────────────────────────
if [[ ! -f "$plan_path" ]]; then
  echo "ERROR: Plan file not found at $plan_path after Codex calls." >&2
  echo "Codex may not have written the file. Check Codex output." >&2
  exit 1
fi

# Verify it has acceptance criteria
if ! grep -q "Acceptance Criteria" "$plan_path"; then
  echo "WARNING: Plan file missing Acceptance Criteria section." >&2
fi

echo "$plan_path"
