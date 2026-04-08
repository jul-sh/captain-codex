#!/usr/bin/env bash
# captain-codex review loop — single review iteration
# Usage: review-loop.sh [--no-post] <pr_number> <plan_file>
#
# Dispatches a Codex review. Codex has full codebase access and inspects
# changes itself (git diff, reading files, etc). By default, posts the review
# to GitHub and updates state. With --no-post, only outputs verdict+body so
# the orchestrator can interpose a supervised check before posting.
#
# Output format:
#   Line 1: machine-parseable verdict (APPROVE, REJECT, or MAX_ROUNDS_EXCEEDED)
#   Line 2+: full Codex review output (may contain its own VERDICT line — that's fine,
#            the orchestrator should parse only line 1 for the verdict)
#
# Exit codes:
#   0 — review completed successfully
#   2 — max rounds exceeded (state updated to failed)
#   1 — other error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE=".claude-architect/state.json"

# Parse flags
no_post=false
if [[ "${1:-}" == "--no-post" ]]; then
  no_post=true
  shift
fi

pr_number="$1"
plan_file="$2"

# ── Max rounds check ──────────────────────────────────────────────────────
next_round=1
if [[ -f "$STATE_FILE" ]]; then
  current_round=$(jq -r '.round // 0' "$STATE_FILE")
  max_rounds=$(jq -r '.max_rounds // 10' "$STATE_FILE")
  next_round=$((current_round + 1))
  if [[ "$next_round" -gt "$max_rounds" ]]; then
    jq '.active = false | .phase = "failed" | .failure_reason = "Max review rounds exceeded"' \
      "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    echo "MAX_ROUNDS_EXCEEDED"
    echo "Max review rounds ($max_rounds) exceeded."
    exit 2
  fi
fi

# ── Ensure correct branch is checked out ──────────────────────────────────
if [[ -f "$STATE_FILE" ]]; then
  branch=$(jq -r '.branch // empty' "$STATE_FILE")
  if [[ -n "$branch" ]]; then
    "$SCRIPT_DIR/scripts/gh-adapter.sh" checkout "$branch" 2>/dev/null || true
  fi
fi

# ── Read config ───────────────────────────────────────────────────────────
config=$("$SCRIPT_DIR/scripts/config.sh" read)
codex_model=$(echo "$config" | jq -r '.codex.review_model // .codex.model // "gpt-5.4"')
codex_effort=$(echo "$config" | jq -r '.codex.reasoning_effort // "xhigh"')

# ── Build review prompt ───────────────────────────────────────────────────
# Pass pr_number so the prompt includes PR context; branch is read from state
review_prompt=$("$SCRIPT_DIR/scripts/review-prompt.sh" "$plan_file" "$pr_number")

# ── Resume Codex session if available ─────────────────────────────────────
session_id=""
if [[ -f "$STATE_FILE" ]]; then
  session_id=$(jq -r '.codex_session_id // empty' "$STATE_FILE")
fi

codex_cmd=(codex exec)
if [[ -n "$session_id" ]]; then
  codex_cmd+=(resume "$session_id")
fi
codex_cmd+=(-m "$codex_model" -c "model_reasoning_effort=$codex_effort" --color never)

# ── Dispatch to Codex ─────────────────────────────────────────────────────
review_result=$(echo "$review_prompt" | "${codex_cmd[@]}" 2>/dev/null) || {
  sleep 2
  review_result=$(echo "$review_prompt" | "${codex_cmd[@]}" 2>/dev/null) || {
    echo "ERROR: Codex review failed after retry." >&2
    exit 1
  }
}

# ── Parse verdict ─────────────────────────────────────────────────────────
verdict="REJECT"
if echo "$review_result" | grep -qi "VERDICT: APPROVE"; then
  verdict="APPROVE"
fi

# ── Update state with review result ───────────────────────────────────────
# Always persist review to state (even in --no-post mode) so the run is resumable
if [[ -f "$STATE_FILE" ]]; then
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  review_entry=$(jq -n \
    --argjson round "$next_round" \
    --arg verdict "$verdict" \
    --arg summary "$(echo "$review_result" | head -c 2000)" \
    --arg timestamp "$timestamp" \
    '{round: $round, verdict: $verdict, summary: $summary, timestamp: $timestamp}')

  if [[ "$no_post" == "true" ]]; then
    # Supervised mode: save pending review body so it can be posted after human approval
    jq --argjson round "$next_round" --argjson entry "$review_entry" --arg body "$review_result" \
      '.round = $round | .phase = "pending_review" | .review_history += [$entry] | .pending_review_body = $body' \
      "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  else
    jq --argjson round "$next_round" --argjson entry "$review_entry" \
      '.round = $round | .phase = "review" | .review_history += [$entry]' \
      "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  fi
fi

# ── Post review to GitHub (unless --no-post) ──────────────────────────────
if [[ "$no_post" == "false" ]]; then
  tmpfile=$(mktemp)
  echo "$review_result" > "$tmpfile"
  "$SCRIPT_DIR/scripts/gh-adapter.sh" post-review "$pr_number" "$verdict" "$tmpfile" || {
    rm -f "$tmpfile"
    echo "ERROR: Failed to post review on PR #${pr_number}." >&2
    exit 1
  }
  rm -f "$tmpfile"
fi

# ── Output verdict and review body ────────────────────────────────────────
echo "$verdict"
echo "$review_result"
