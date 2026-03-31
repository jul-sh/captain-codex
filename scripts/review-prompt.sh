#!/usr/bin/env bash
# Builds the augmented review prompt for Codex
# Usage: review-prompt.sh <plan_file_path>
# Outputs the complete review prompt to stdout

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

plan_file="$1"

# Read config
config=$("$SCRIPT_DIR/scripts/config.sh" read)

# ── Gather components ──────────────────────────────────────────────────────

# Plan contents
if [[ -f "$plan_file" ]]; then
  plan_contents=$(cat "$plan_file")
else
  plan_contents="ERROR: Plan file not found at $plan_file"
fi

# Review instructions from config
review_instructions=$(echo "$config" | jq -r '.review_instructions[]' | sed 's/^/- /')

# Git diff of current changes
git_diff=$(git diff HEAD 2>/dev/null || git diff 2>/dev/null || echo "No git diff available")

# Extract worklog section from plan file
worklog=""
if [[ -f "$plan_file" ]]; then
  worklog=$(sed -n '/^## Worklog/,/^## /{ /^## Worklog/d; /^## /d; p; }' "$plan_file")
  if [[ -z "$worklog" ]]; then
    # Try to get everything after ## Worklog if it's the last section
    worklog=$(sed -n '/^## Worklog/,$ { /^## Worklog/d; p; }' "$plan_file")
  fi
fi

# ── Build prompt from template ─────────────────────────────────────────────
cat <<REVIEW_PROMPT
You are reviewing an implementation against a plan.

## Plan & Acceptance Criteria
$plan_contents

## Review Standards
$review_instructions

## Changes
\`\`\`diff
$git_diff
\`\`\`

## Worklog
$worklog

## Instructions
Review the implementation against EVERY acceptance criterion in the plan.
For each criterion, state whether it is MET or NOT MET with specific evidence.

If ANY criterion is not met, or if the review standards are violated:
- Output: VERDICT: REJECT
- Write concrete, specific revision instructions. Reference file paths and line numbers.
- Do NOT give vague feedback like "needs improvement."

If ALL criteria are met:
- Output: VERDICT: APPROVE
REVIEW_PROMPT
