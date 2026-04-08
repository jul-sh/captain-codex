#!/usr/bin/env bash
# Builds the augmented review prompt for Codex
# Usage: review-prompt.sh <plan_file_path> [<pr_number> <branch>]
# Outputs the complete review prompt to stdout

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE=".claude-architect/state.json"

plan_file="$1"
pr_number="${2:-}"
branch="${3:-}"

# Try to read PR context from state if not provided as args
if [[ -z "$pr_number" && -f "$STATE_FILE" ]]; then
  pr_number=$(jq -r '.pr_number // empty' "$STATE_FILE")
fi
if [[ -z "$branch" && -f "$STATE_FILE" ]]; then
  branch=$(jq -r '.branch // empty' "$STATE_FILE")
fi

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

# Merge ad-hoc review instructions from state if present
if [[ -f "$STATE_FILE" ]]; then
  adhoc=$(jq -r '.adhoc_review_instructions // empty' "$STATE_FILE")
  if [[ -n "$adhoc" ]]; then
    review_instructions="${review_instructions}
- ${adhoc}"
  fi
fi

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
template=$(cat "$SCRIPT_DIR/templates/review-prompt.md")

# Substitute placeholders
prompt="${template//\{\{plan_contents\}\}/$plan_contents}"
prompt="${prompt//\{\{review_instructions\}\}/$review_instructions}"
prompt="${prompt//\{\{worklog\}\}/$worklog}"
prompt="${prompt//\{\{pr_number\}\}/${pr_number:-unknown}}"
prompt="${prompt//\{\{branch\}\}/${branch:-unknown}}"

echo "$prompt"
