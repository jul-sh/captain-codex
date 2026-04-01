#!/usr/bin/env bash
# captain-codex config helper
# Usage:
#   config.sh read                          — output merged config as JSON
#   config.sh write <key> <value>           — set a config value (dot notation)
#   config.sh init-state <task> <plan> <max> — initialize run state

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_CONFIG="$HOME/.claude-architect/config.json"
PROJECT_CONFIG=".claude-architect/config.json"
DEFAULT_CONFIG="$SCRIPT_DIR/templates/default-config.json"
STATE_FILE=".claude-architect/state.json"

# Ensure user config directory exists
ensure_user_config() {
  if [[ ! -f "$USER_CONFIG" ]]; then
    mkdir -p "$(dirname "$USER_CONFIG")"
    cp "$DEFAULT_CONFIG" "$USER_CONFIG"
  fi
}

# Merge configs: defaults ← user ← project
read_config() {
  ensure_user_config

  local merged
  merged=$(jq -s '.[0] * .[1]' "$DEFAULT_CONFIG" "$USER_CONFIG")

  if [[ -f "$PROJECT_CONFIG" ]]; then
    merged=$(echo "$merged" | jq -s '.[0] * .[1]' - "$PROJECT_CONFIG")
  fi

  echo "$merged"
}

# Write a value to user config using dot notation
# e.g., config.sh write codex.model "gpt-5.4"
write_config() {
  local key="$1"
  local value="$2"

  ensure_user_config

  # Convert dot notation to jq path
  local jq_path
  jq_path=$(echo "$key" | sed 's/\./"."/g')
  jq_path=".\"$jq_path\""

  # Try to parse value as JSON; if it fails, treat as string
  if echo "$value" | jq . >/dev/null 2>&1; then
    jq "$jq_path = $value" "$USER_CONFIG" > "${USER_CONFIG}.tmp" && mv "${USER_CONFIG}.tmp" "$USER_CONFIG"
  else
    jq "$jq_path = \"$value\"" "$USER_CONFIG" > "${USER_CONFIG}.tmp" && mv "${USER_CONFIG}.tmp" "$USER_CONFIG"
  fi
}

# Initialize state for a new run
init_state() {
  local task="$1"
  local plan_file="$2"
  local max_rounds="${3:-10}"
  local session_id="${4:-}"
  local supervised="${5:-false}"

  mkdir -p "$(dirname "$STATE_FILE")"

  jq -n \
    --arg task "$task" \
    --arg plan "$plan_file" \
    --argjson max "$max_rounds" \
    --arg session "${session_id:-null}" \
    --argjson supervised "$supervised" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      active: true,
      phase: "implementing",
      plan_file: $plan,
      task_description: $task,
      round: 0,
      max_rounds: $max,
      supervised: $supervised,
      codex_session_id: (if $session == "null" or $session == "" then null else $session end),
      review_history: [],
      started_at: $ts
    }' > "$STATE_FILE"
}

# ── Main dispatch ──────────────────────────────────────────────────────────
case "${1:-read}" in
  read)
    read_config
    ;;
  write)
    write_config "$2" "$3"
    ;;
  init-state)
    init_state "$2" "$3" "${4:-10}"
    ;;
  *)
    echo "Usage: config.sh {read|write <key> <value>|init-state <task> <plan> <max>}" >&2
    exit 1
    ;;
esac
