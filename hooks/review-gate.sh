#!/usr/bin/env bash
# captain-codex review gate — Stop hook
# Dispatches an augmented Codex review when Claude tries to stop during an active run.
# Returns {"decision": "block", "reason": "..."} to reject or {"decision": "allow"} to approve.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE=".claude-architect/state.json"

# ── Guard: only act during an active captain-codex run ──────────────────────
if [[ ! -f "$STATE_FILE" ]]; then
  echo '{"decision": "allow"}'
  exit 0
fi

active=$(jq -r '.active // false' "$STATE_FILE")
phase=$(jq -r '.phase // ""' "$STATE_FILE")

if [[ "$active" != "true" ]] || [[ "$phase" != "implementing" && "$phase" != "review" ]]; then
  echo '{"decision": "allow"}'
  exit 0
fi

# ── Read state ──────────────────────────────────────────────────────────────
plan_file=$(jq -r '.plan_file' "$STATE_FILE")
max_rounds=$(jq -r '.max_rounds // 10' "$STATE_FILE")
current_round=$(jq -r '.round // 0' "$STATE_FILE")
session_id=$(jq -r '.codex_session_id // empty' "$STATE_FILE")
supervised=$(jq -r '.supervised // false' "$STATE_FILE")
next_round=$((current_round + 1))

# ── Max rounds check ───────────────────────────────────────────────────────
if [[ "$next_round" -gt "$max_rounds" ]]; then
  # Update state to failed
  jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.active = false | .phase = "failed" | .failure_reason = "Max review rounds exceeded"' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

  echo "{\"decision\": \"block\", \"reason\": \"Max review rounds ($max_rounds) exceeded. Run /captain-codex:status to see the review history and decide how to proceed.\"}"
  exit 0
fi

# ── Update state to review phase ───────────────────────────────────────────
jq --argjson round "$next_round" '.phase = "review" | .round = $round' \
  "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

# ── Build the review prompt ────────────────────────────────────────────────
review_prompt=$("$SCRIPT_DIR/scripts/review-prompt.sh" "$plan_file")

# ── Dispatch to Codex ──────────────────────────────────────────────────────
# Read Codex config
config=$("$SCRIPT_DIR/scripts/config.sh" read)
codex_model=$(echo "$config" | jq -r '.codex.review_model // .codex.model // "gpt-5.4"')
codex_effort=$(echo "$config" | jq -r '.codex.reasoning_effort // "xhigh"')

# Use codex CLI to run the review, resuming the planning session if available
codex_cmd=(codex exec)
if [[ -n "$session_id" ]]; then
  codex_cmd+=(resume "$session_id")
fi
codex_cmd+=(-m "$codex_model" -c "model_reasoning_effort=$codex_effort" --quiet)

review_result=$(echo "$review_prompt" | "${codex_cmd[@]}" 2>/dev/null) || {
  # Codex failed — retry once
  sleep 2
  review_result=$(echo "$review_prompt" | "${codex_cmd[@]}" 2>/dev/null) || {
    echo '{"decision": "block", "reason": "Codex review failed after retry. Check codex CLI authentication and try again."}'
    exit 0
  }
}

# ── Parse verdict ──────────────────────────────────────────────────────────
verdict="REJECT"
if echo "$review_result" | grep -qi "VERDICT: APPROVE"; then
  verdict="APPROVE"
fi

# Extract summary (everything after VERDICT line, or last 500 chars as fallback)
summary=$(echo "$review_result" | sed -n '/VERDICT/,$ p' | tail -n +2 | head -c 2000)
if [[ -z "$summary" ]]; then
  summary=$(echo "$review_result" | tail -c 500)
fi

# ── Update state with review result ────────────────────────────────────────
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
review_entry=$(jq -n \
  --argjson round "$next_round" \
  --arg verdict "$verdict" \
  --arg summary "$summary" \
  --arg timestamp "$timestamp" \
  '{round: $round, verdict: $verdict, summary: $summary, timestamp: $timestamp}')

jq --argjson entry "$review_entry" \
  '.review_history += [$entry]' \
  "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

# ── Return decision ────────────────────────────────────────────────────────
escaped_reason=$(echo "$review_result" | jq -Rs '.')

if [[ "$verdict" == "APPROVE" ]]; then
  if [[ "$supervised" == "true" ]]; then
    # In supervised mode, block so the user sees the approval and confirms
    jq '.phase = "approved_pending"' \
      "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    echo "{\"decision\": \"block\", \"reason\": $(jq -Rs '.' <<< "Codex APPROVED (round $next_round). Review output:\n\n$review_result\n\nSupervised mode: confirm approval by running /captain-codex:status and allowing the stop, or continue implementing.")}"
  else
    jq '.active = false | .phase = "complete"' \
      "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    echo '{"decision": "allow"}'
  fi
else
  if [[ "$supervised" == "true" ]]; then
    # In supervised mode, present the rejection for user review before continuing
    jq '.phase = "rejected_pending"' \
      "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    echo "{\"decision\": \"block\", \"reason\": $(jq -Rs '.' <<< "Codex REJECTED (round $next_round). Review output:\n\n$review_result\n\nSupervised mode: review the feedback above. To continue implementing with this feedback, just proceed. To abort, run /captain-codex:status.")}"
  else
    jq '.phase = "implementing"' \
      "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

    echo "{\"decision\": \"block\", \"reason\": ${escaped_reason}}"
  fi
fi
