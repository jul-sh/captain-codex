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
template=$(cat "$SCRIPT_DIR/templates/review-prompt.md")

# Substitute placeholders
prompt="${template//\{\{plan_contents\}\}/$plan_contents}"
prompt="${prompt//\{\{review_instructions\}\}/$review_instructions}"
prompt="${prompt//\{\{worklog\}\}/$worklog}"
prompt="${prompt//\{\{pushback\}\}/$pushback}"

echo "$prompt"
