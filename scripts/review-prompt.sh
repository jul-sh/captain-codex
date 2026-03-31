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

# Structural summary of changes (not full diff — keeps Codex focused on architecture)
BASE="HEAD"
files_changed=$(git diff --stat "$BASE" 2>/dev/null || echo "No diff available")
new_modules=$(git diff "$BASE" --name-only --diff-filter=A 2>/dev/null || echo "None")
arch_changes=$(git diff "$BASE" -- '*.swift' '*.kt' '*.ts' '*.py' '*.go' '*.rs' '*.java' 2>/dev/null | \
  grep -E '^(@@|protocol |class |struct |import |func .*public|extension |interface |abstract |export |type |trait |pub )' | \
  head -200 || echo "None")

# Extract worklog section from plan file
worklog=""
if [[ -f "$plan_file" ]]; then
  worklog=$(sed -n '/^## Worklog/,/^## /{ /^## Worklog/d; /^## /d; p; }' "$plan_file")
  if [[ -z "$worklog" ]]; then
    # Try to get everything after ## Worklog if it's the last section
    worklog=$(sed -n '/^## Worklog/,$ { /^## Worklog/d; p; }' "$plan_file")
  fi
fi

# Extract pushback section from worklog (between ### Pushback and next ##/### heading, or EOF)
pushback=""
if [[ -f "$plan_file" ]]; then
  pushback=$(sed -n '/^### Pushback/,/^##/ { /^### Pushback/d; /^##/d; p; }' "$plan_file")
  if [[ -z "$pushback" ]]; then
    pushback=$(sed -n '/^### Pushback/,$ { /^### Pushback/d; p; }' "$plan_file")
  fi
fi
if [[ -z "$pushback" ]]; then
  pushback="None"
fi

# ── Build prompt from template ─────────────────────────────────────────────
cat <<REVIEW_PROMPT
You are reviewing an implementation against a plan.
You are seeing a structural summary, not the full diff. Review at the architectural level only.

## Plan & Acceptance Criteria
$plan_contents

## Review Standards
$review_instructions

## Structural Summary

### Files Changed
$files_changed

### New Modules/Types Introduced
$new_modules

### Architecture-Relevant Changes (public interfaces, protocols, module boundaries)
$arch_changes

## Worklog
$worklog

## Pushback (if any)
$pushback

If pushback is present, evaluate it before issuing your verdict.
Address each pushback item explicitly in your review.

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
