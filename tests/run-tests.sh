#!/usr/bin/env bash
# captain-codex test suite
#
# Usage:
#   ./tests/run-tests.sh          # run unit tests only (fast)
#   ./tests/run-tests.sh --all    # include integration tests (runs mock agents)

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
MOCK_BIN="$TESTS_DIR/mock-bin"
TEST_WORKDIR=""
PASSED=0
FAILED=0
ERRORS=()
RUN_INTEGRATION=false

[[ "${1:-}" == "--all" ]] && RUN_INTEGRATION=true

# ── Setup / Teardown ─────────────────────────────────────────────────────────

setup() {
  mkdir -p "$MOCK_BIN"
  cp "$TESTS_DIR/mock-codex" "$MOCK_BIN/codex"
  cp "$TESTS_DIR/mock-claude" "$MOCK_BIN/claude"
  chmod +x "$MOCK_BIN/codex" "$MOCK_BIN/claude"

  TEST_WORKDIR=$(mktemp -d /tmp/captain-codex-test-XXXXXX)
  mkdir -p "$TEST_WORKDIR/.claude-architect"
  mkdir -p "$TEST_WORKDIR/tasks"

  # Isolate $HOME so tests don't read or write the developer's real
  # ~/.claude-architect/config.json. config.sh ensures the user config
  # exists by copying the default into it; we redirect that into the
  # workdir.
  TEST_HOME=$(mktemp -d /tmp/captain-codex-home-XXXXXX)
  export HOME="$TEST_HOME"
  mkdir -p "$HOME/.claude-architect"
  cp "$PROJECT_ROOT/templates/default-config.json" "$HOME/.claude-architect/config.json"
}

teardown() {
  rm -rf "$MOCK_BIN"
  [[ -n "${TEST_WORKDIR:-}" ]] && rm -rf "$TEST_WORKDIR"
  [[ -n "${TEST_HOME:-}" ]] && rm -rf "$TEST_HOME"
}

trap teardown EXIT

# ── Helpers ──────────────────────────────────────────────────────────────────

pass() { PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); ERRORS+=("$1: $2"); echo "  FAIL: $1 — $2"; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label" "expected='$expected' got='$actual'"
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then pass "$label"; else fail "$label" "file not found: $path"; fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -Fq -- "$needle"; then
    pass "$label"
  else
    fail "$label" "output does not contain '$needle'"
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -Fq -- "$needle"; then
    fail "$label" "output unexpectedly contains '$needle'"
  else
    pass "$label"
  fi
}

# ── Unit Tests ───────────────────────────────────────────────────────────────

test_slug_generation() {
  echo "Test: slug generation"
  source "$PROJECT_ROOT/scripts/helpers.sh" 2>/dev/null

  assert_eq "lowercase + hyphens" "add-a-hello-world-endpoint" "$(generate_slug 'Add a Hello World Endpoint')"
  assert_eq "strip special chars" "refactor-auth-module" "$(generate_slug 'refactor auth -- module!!!')"
  assert_eq "truncate at 60" 60 "$(printf '%s' "$(generate_slug "$(printf 'a%.0s' {1..80})")" | wc -c | tr -d ' ')"

  # Regression: multi-line task description must produce a single-line
  # slug. Previously the embedded newlines flowed through and broke the
  # downstream `sed s/{{slug}}/$slug/g` substitution.
  local multiline_slug
  multiline_slug=$(generate_slug 'first line
second line
third')
  assert_eq "single line slug from multiline input" "first-line-second-line-third" "$multiline_slug"
}

test_verdict_anchor() {
  echo "Test: verdict_is_approve is anchored"
  source "$PROJECT_ROOT/scripts/helpers.sh" 2>/dev/null

  # Plain APPROVE on its own line -> approve
  if verdict_is_approve "VERDICT: APPROVE"; then pass "literal APPROVE"; else fail "literal APPROVE" "expected approve"; fi

  # APPROVE inside a REJECT body must not flip the verdict
  local sneaky="The implementation has issues.
VERDICT: REJECT
(For comparison, criteria for VERDICT: APPROVE would be ...)"
  if verdict_is_approve "$sneaky"; then
    fail "embedded APPROVE in REJECT body" "expected reject"
  else
    pass "embedded APPROVE in REJECT body"
  fi

  # Leading whitespace is permitted (some agents indent)
  if verdict_is_approve "  VERDICT: APPROVE"; then pass "indented APPROVE"; else fail "indented APPROVE" "expected approve"; fi
}

test_config_init_state() {
  echo "Test: config.sh init-state"

  (cd "$TEST_WORKDIR" && "$PROJECT_ROOT/scripts/config.sh" init-state "test task" "tasks/test.md" 5 false "")

  local sf="$TEST_WORKDIR/.claude-architect/state.json"
  assert_file_exists "state file created" "$sf"
  assert_eq "phase=planning" "planning" "$(jq -r '.phase' "$sf")"
  assert_eq "active=true" "true" "$(jq -r '.active' "$sf")"
  assert_eq "max_rounds=5" "5" "$(jq -r '.max_rounds' "$sf")"
  assert_eq "round=0" "0" "$(jq -r '.round' "$sf")"
  assert_eq "supervised=false" "false" "$(jq -r '.supervised' "$sf")"
}

test_config_read() {
  echo "Test: config.sh read merges defaults"

  local config
  config=$(cd "$TEST_WORKDIR" && "$PROJECT_ROOT/scripts/config.sh" read)
  assert_eq "has codex.model" "gpt-5.4" "$(echo "$config" | jq -r '.codex.model')"
  assert_eq "has max_rounds" "10" "$(echo "$config" | jq -r '.max_rounds')"
}

test_state_helpers() {
  echo "Test: state management helpers"

  # Init state first
  (cd "$TEST_WORKDIR" && "$PROJECT_ROOT/scripts/config.sh" init-state "test" "tasks/t.md" 10 false "")

  # Source helpers in the test workdir context
  (
    cd "$TEST_WORKDIR"
    source "$PROJECT_ROOT/scripts/helpers.sh" 2>/dev/null

    update_phase "implementing"
    echo "phase=$(jq -r '.phase' "$STATE_FILE")"

    update_round 3
    echo "round=$(jq -r '.round' "$STATE_FILE")"

    add_review_entry 1 "REJECT" "needs work"
    echo "history_len=$(jq '.review_history | length' "$STATE_FILE")"
    echo "verdict=$(jq -r '.review_history[0].verdict' "$STATE_FILE")"

    mark_complete
    echo "final_phase=$(jq -r '.phase' "$STATE_FILE")"
    echo "active=$(jq -r '.active' "$STATE_FILE")"
  ) > /tmp/state-test-output.txt 2>/dev/null

  local out
  out=$(cat /tmp/state-test-output.txt)
  assert_contains "update_phase" "$out" "phase=implementing"
  assert_contains "update_round" "$out" "round=3"
  assert_contains "add_review_entry" "$out" "history_len=1"
  assert_contains "review verdict" "$out" "verdict=REJECT"
  assert_contains "mark_complete phase" "$out" "final_phase=complete"
  assert_contains "mark_complete active" "$out" "active=false"
  rm -f /tmp/state-test-output.txt
}

test_mock_codex_writes_plan() {
  echo "Test: mock codex writes plan file"

  local plan_path="$TEST_WORKDIR/tasks/mock-plan-test.md"
  echo "Formalize your plan and save it to: $plan_path. Write the file now." \
    | PATH="$MOCK_BIN:$PATH" codex exec -o /dev/null --full-auto - > /dev/null 2>&1

  assert_file_exists "plan file created" "$plan_path"
  assert_contains "plan has content" "$(cat "$plan_path")" "Objective"
}

test_mock_codex_approves() {
  echo "Test: mock codex VERDICT: APPROVE"

  local output
  output=$(echo "Review this implementation against the plan." \
    | PATH="$MOCK_BIN:$PATH" MOCK_CODEX_REVIEW_VERDICT=APPROVE codex exec -o /dev/null --full-auto - 2>/dev/null)

  assert_contains "contains APPROVE" "$output" "VERDICT: APPROVE"
}

test_mock_codex_rejects_then_approves() {
  echo "Test: mock codex rejects N rounds then approves"

  local state_file="/tmp/mock-codex-review-test-$$"
  rm -f "$state_file"

  # Round 1: reject
  local output1
  output1=$(echo "Review implementation against plan" \
    | PATH="$MOCK_BIN:$PATH" MOCK_CODEX_REJECT_ROUNDS=1 MOCK_CODEX_STATE_FILE="$state_file" \
      codex exec -o /dev/null --full-auto - 2>/dev/null)

  # Round 2: approve
  local output2
  output2=$(echo "Review implementation against plan" \
    | PATH="$MOCK_BIN:$PATH" MOCK_CODEX_REJECT_ROUNDS=1 MOCK_CODEX_STATE_FILE="$state_file" \
      codex exec -o /dev/null --full-auto - 2>/dev/null)

  assert_contains "round 1 rejects" "$output1" "VERDICT: REJECT"
  assert_contains "round 2 approves" "$output2" "VERDICT: APPROVE"
  rm -f "$state_file"
}

test_mock_claude_responds() {
  echo "Test: mock claude responds to prompts"

  local output
  output=$(echo "Implement the plan." | PATH="$MOCK_BIN:$PATH" claude -p --output-format text --dangerously-skip-permissions 2>/dev/null)
  assert_contains "claude responds" "$output" "Implementing"
}

test_prompt_builders() {
  echo "Test: prompt builders produce output"

  (
    cd "$TEST_WORKDIR"
    source "$PROJECT_ROOT/scripts/helpers.sh" 2>/dev/null

    local config
    config=$(read_config)

    local plan_prompt
    plan_prompt=$(build_plan_prompt "test task" "$config")
    echo "plan_has_task=$(echo "$plan_prompt" | grep -c 'test task')"

    # Create a plan file for impl prompt
    echo "# Test Plan" > "$TEST_WORKDIR/tasks/builder-test.md"
    local impl_prompt
    impl_prompt=$(build_impl_prompt "$TEST_WORKDIR/tasks/builder-test.md" "$config" "extra instruction")
    echo "impl_has_plan=$(echo "$impl_prompt" | grep -c 'Test Plan')"
    echo "impl_has_adhoc=$(echo "$impl_prompt" | grep -c 'extra instruction')"
  ) > /tmp/prompt-test-output.txt 2>/dev/null

  local out
  out=$(cat /tmp/prompt-test-output.txt)
  assert_contains "plan prompt has task" "$out" "plan_has_task=1"
  assert_contains "impl prompt has plan" "$out" "impl_has_plan=1"
  assert_contains "impl prompt has adhoc" "$out" "impl_has_adhoc=1"
  rm -f /tmp/prompt-test-output.txt
}

test_pane_dispatch() {
  echo "Test: pane_dispatch round-trips through a fifo"

  # Synthesize a temp dir mimicking $CAPTAIN_TMP, with a "fake-agent" fifo
  # and a tiny runner that mirrors agent-runner.sh's protocol: read one
  # TSV line, write a sentinel with exit code 0, write some output to
  # the named output file.
  local tmp
  tmp=$(mktemp -d /tmp/captain-codex-pane-XXXXXX)
  mkfifo "$tmp/fake.fifo"

  # Background fake runner.
  (
    IFS=$'\t' read -r prompt out sentinel < "$tmp/fake.fifo"
    cp "$prompt" "$out"
    printf '0\n' > "$sentinel.tmp"
    mv "$sentinel.tmp" "$sentinel"
  ) &
  local runner_pid=$!

  # Drive the dispatcher.
  printf 'hello\n' > "$tmp/prompt"
  (
    export CAPTAIN_TMP="$tmp"
    export CAPTAIN_ROOT="$PROJECT_ROOT"
    export PANE_POLL_INTERVAL=0.05
    export PANE_POLL_TIMEOUT=5
    source "$PROJECT_ROOT/scripts/pane.sh"
    pane_dispatch fake "$tmp/prompt" "$tmp/output"
    echo "rc=$?"
  ) > "$tmp/dispatch.log" 2>&1

  wait "$runner_pid" 2>/dev/null || true

  assert_contains "dispatch returned 0" "$(cat "$tmp/dispatch.log")" "rc=0"
  assert_file_exists "output produced" "$tmp/output"
  assert_eq "output contents" "hello" "$(cat "$tmp/output")"

  rm -rf "$tmp"
}

test_pane_dispatch_propagates_exit_code() {
  echo "Test: pane_dispatch returns the agent's exit code"

  local tmp
  tmp=$(mktemp -d /tmp/captain-codex-pane-XXXXXX)
  mkfifo "$tmp/fake.fifo"

  (
    IFS=$'\t' read -r _ _ sentinel < "$tmp/fake.fifo"
    printf '7\n' > "$sentinel.tmp"
    mv "$sentinel.tmp" "$sentinel"
  ) &
  local runner_pid=$!

  printf 'hi\n' > "$tmp/prompt"
  local rc=0
  (
    export CAPTAIN_TMP="$tmp"
    export CAPTAIN_ROOT="$PROJECT_ROOT"
    export PANE_POLL_INTERVAL=0.05
    export PANE_POLL_TIMEOUT=5
    source "$PROJECT_ROOT/scripts/pane.sh"
    pane_dispatch fake "$tmp/prompt" "$tmp/output"
  ) || rc=$?

  wait "$runner_pid" 2>/dev/null || true
  assert_eq "exit code propagated" "7" "$rc"
  rm -rf "$tmp"
}

test_pane_dispatch_timeout() {
  echo "Test: pane_dispatch times out when no runner answers"

  local tmp
  tmp=$(mktemp -d /tmp/captain-codex-pane-XXXXXX)
  mkfifo "$tmp/fake.fifo"

  # No runner consumes the fifo. We open + immediately close a reader
  # so the orchestrator's write doesn't itself block forever; then the
  # runner-equivalent never produces a sentinel and we expect a timeout.
  ( read -r _ < "$tmp/fake.fifo" ) &
  local sink_pid=$!

  printf 'hi\n' > "$tmp/prompt"
  local rc=0
  (
    export CAPTAIN_TMP="$tmp"
    export CAPTAIN_ROOT="$PROJECT_ROOT"
    export PANE_POLL_INTERVAL=0.05
    export PANE_POLL_TIMEOUT=0.3
    source "$PROJECT_ROOT/scripts/pane.sh"
    pane_dispatch fake "$tmp/prompt" "$tmp/output"
  ) > "$tmp/dispatch.log" 2>&1 || rc=$?

  wait "$sink_pid" 2>/dev/null || true
  assert_eq "timeout exit code" "124" "$rc"
  assert_contains "timeout message" "$(cat "$tmp/dispatch.log")" "timed out"
  rm -rf "$tmp"
}

test_entry_point_flags() {
  echo "Test: entry point flag parsing"

  local output
  output=$("$PROJECT_ROOT/captain-codex" 2>&1 || true)
  assert_contains "no args shows usage" "$output" "Usage"
  assert_contains "usage mentions skip-plan" "$output" "skip-plan"
}

test_entry_point_dep_check() {
  echo "Test: entry point dependency checks"

  local output
  output=$(PATH="/usr/bin:/bin" "$PROJECT_ROOT/captain-codex" "test" 2>&1 || true)
  assert_contains "missing dep error" "$output" "required but not found"
}

test_entry_point_env_passthrough() {
  echo "Test: entry point honors MAX_ROUNDS / SUPERVISED / SKIP_PLAN env vars"

  local workdir
  workdir=$(mktemp -d /tmp/captain-codex-env-XXXXXX)
  mkdir -p "$workdir/.claude-architect" "$workdir/tasks"

  # Run with MAX_ROUNDS=2 in the env (no flag) and a mock that always rejects.
  local output
  output=$(
    cd "$workdir"
    PATH="$MOCK_BIN:$PATH" \
    MAX_ROUNDS=2 \
    MOCK_CODEX_REJECT_ROUNDS=999 \
    MOCK_CODEX_STATE_FILE="/tmp/mock-codex-env-$$" \
      "$PROJECT_ROOT/captain-codex" --no-zellij "env passthrough check" 2>&1
  ) || true

  local sf="$workdir/.claude-architect/state.json"
  assert_eq "max_rounds env propagated" "2" "$(jq -r '.max_rounds' "$sf")"
  assert_eq "phase failed (max exceeded)" "failed" "$(jq -r '.phase' "$sf")"

  rm -rf "$workdir" "/tmp/mock-codex-env-$$"
}

# ── Integration Tests (full orchestration with mock agents) ──────────────────

test_full_orchestration_approve() {
  echo "Test: full orchestration flow — plan, implement, approve"

  local workdir
  workdir=$(mktemp -d /tmp/captain-codex-integ-XXXXXX)
  mkdir -p "$workdir/.claude-architect" "$workdir/tasks"

  local output
  output=$(
    cd "$workdir"
    PATH="$MOCK_BIN:$PATH" \
    MOCK_CODEX_REVIEW_VERDICT=APPROVE \
    MOCK_CODEX_STATE_FILE="/tmp/mock-codex-integ-$$" \
      "$PROJECT_ROOT/scripts/orchestrate.sh" "test integration task" 2>&1
  ) || true

  local sf="$workdir/.claude-architect/state.json"

  assert_contains "shows planning phase" "$output" "Planning"
  assert_contains "shows implementing phase" "$output" "Implementing"
  assert_contains "shows review phase" "$output" "Review Loop"
  assert_contains "approved" "$output" "APPROVED"
  assert_file_exists "state file exists" "$sf"
  assert_eq "final phase is complete" "complete" "$(jq -r '.phase' "$sf")"
  assert_eq "active is false" "false" "$(jq -r '.active' "$sf")"

  # Check plan file was created
  local plan_files
  plan_files=$(find "$workdir/tasks" -name "*.md" 2>/dev/null | head -1)
  if [[ -n "$plan_files" ]]; then
    pass "plan file created"
  else
    fail "plan file created" "no .md files in tasks/"
  fi

  rm -rf "$workdir" "/tmp/mock-codex-integ-$$"
}

test_full_orchestration_reject_then_approve() {
  echo "Test: full orchestration — reject once, then approve"

  local workdir
  workdir=$(mktemp -d /tmp/captain-codex-integ-XXXXXX)
  mkdir -p "$workdir/.claude-architect" "$workdir/tasks"

  local state_file="/tmp/mock-codex-integ-reject-$$"
  rm -f "$state_file"

  local output
  output=$(
    cd "$workdir"
    PATH="$MOCK_BIN:$PATH" \
    MOCK_CODEX_REJECT_ROUNDS=1 \
    MOCK_CODEX_STATE_FILE="$state_file" \
      "$PROJECT_ROOT/scripts/orchestrate.sh" "test reject flow" 2>&1
  ) || true

  local sf="$workdir/.claude-architect/state.json"

  assert_contains "shows rejection" "$output" "REJECT"
  assert_contains "sends feedback" "$output" "Sending feedback"
  assert_contains "eventually approved" "$output" "APPROVED"
  assert_eq "final phase is complete" "complete" "$(jq -r '.phase' "$sf")"

  local history_count
  history_count=$(jq '.review_history | length' "$sf")
  assert_eq "2 review rounds" "2" "$history_count"
  assert_eq "round 1 rejected" "REJECT" "$(jq -r '.review_history[0].verdict' "$sf")"
  assert_eq "round 2 approved" "APPROVE" "$(jq -r '.review_history[1].verdict' "$sf")"

  rm -rf "$workdir" "$state_file"
}

test_skip_plan() {
  echo "Test: --skip-plan skips planning phase"

  local workdir
  workdir=$(mktemp -d /tmp/captain-codex-integ-XXXXXX)
  mkdir -p "$workdir/.claude-architect" "$workdir/tasks"

  # Create a pre-existing plan
  cat > "$workdir/tasks/existing-plan.md" <<'PLAN'
# Existing Plan

## Objective
Do the thing.

## Steps
1. Step one
PLAN

  local output
  output=$(
    cd "$workdir"
    PATH="$MOCK_BIN:$PATH" \
    SKIP_PLAN="tasks/existing-plan.md" \
    MOCK_CODEX_REVIEW_VERDICT=APPROVE \
    MOCK_CODEX_STATE_FILE="/tmp/mock-codex-integ-skip-$$" \
      "$PROJECT_ROOT/scripts/orchestrate.sh" "(resuming)" 2>&1
  ) || true

  assert_not_contains "no planning phase" "$output" "Planning (Codex)"
  assert_contains "has implementing phase" "$output" "Implementing"
  assert_contains "approved" "$output" "APPROVED"

  rm -rf "$workdir" "/tmp/mock-codex-integ-skip-$$"
}

test_zellij_full_run() {
  echo "Test: full orchestration in zellij mode (pty-driven)"

  local workdir
  workdir=$(mktemp -d /tmp/captain-codex-zellij-XXXXXX)
  mkdir -p "$workdir/.claude-architect" "$workdir/tasks"

  local session="captain-codex-test-$$"
  local mock_state="/tmp/mock-codex-zellij-$$"
  rm -f "$mock_state"

  # Background watcher: when the orchestrator marks the run done,
  # kill the zellij session so with-pty.py drains and exits.
  local sf="$workdir/.claude-architect/state.json"
  (
    for _ in $(seq 1 300); do  # ~30s
      if [[ -f "$sf" ]] && jq -e '.active == false' "$sf" >/dev/null 2>&1; then
        sleep 0.5  # let the captain pane print its summary
        zellij kill-session "$session" >/dev/null 2>&1 || true
        return 0
      fi
      sleep 0.1
    done
    zellij kill-session "$session" >/dev/null 2>&1 || true
  ) &
  local watcher_pid=$!

  # Drive captain-codex under a pty so zellij has a TTY.
  (
    cd "$workdir"
    PATH="$MOCK_BIN:$PATH" \
    MOCK_CODEX_REVIEW_VERDICT=APPROVE \
    MOCK_CODEX_STATE_FILE="$mock_state" \
    CAPTAIN_SESSION="$session" \
    python3 "$TESTS_DIR/with-pty.py" 35 -- \
      "$PROJECT_ROOT/captain-codex" "test zellij integration" >/dev/null 2>&1
  ) || true

  wait "$watcher_pid" 2>/dev/null || true
  # Force-kill in case the watcher missed it.
  zellij kill-session "$session" >/dev/null 2>&1 || true

  local sf="$workdir/.claude-architect/state.json"
  assert_file_exists "state file written" "$sf"
  if [[ -f "$sf" ]]; then
    assert_eq "final phase" "complete" "$(jq -r '.phase' "$sf")"
    assert_eq "active false" "false" "$(jq -r '.active' "$sf")"
  fi

  rm -rf "$workdir" "$mock_state"
}

test_max_rounds_exceeded() {
  echo "Test: max rounds exceeded results in failure"

  local workdir
  workdir=$(mktemp -d /tmp/captain-codex-integ-XXXXXX)
  mkdir -p "$workdir/.claude-architect" "$workdir/tasks"

  local output
  output=$(
    cd "$workdir"
    PATH="$MOCK_BIN:$PATH" \
    MAX_ROUNDS=1 \
    MOCK_CODEX_REJECT_ROUNDS=999 \
    MOCK_CODEX_STATE_FILE="/tmp/mock-codex-integ-max-$$" \
      "$PROJECT_ROOT/scripts/orchestrate.sh" "test max rounds" 2>&1
  ) || true

  local sf="$workdir/.claude-architect/state.json"

  assert_contains "shows max rounds" "$output" "Max rounds"
  assert_eq "phase is failed" "failed" "$(jq -r '.phase' "$sf")"

  rm -rf "$workdir" "/tmp/mock-codex-integ-max-$$"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  echo "captain-codex test suite"
  echo "========================"
  echo ""

  setup

  echo "── Unit Tests ──"
  test_slug_generation
  test_verdict_anchor
  test_config_read
  test_config_init_state
  test_state_helpers
  test_mock_codex_writes_plan
  test_mock_codex_approves
  test_mock_codex_rejects_then_approves
  test_mock_claude_responds
  test_prompt_builders
  test_pane_dispatch
  test_pane_dispatch_propagates_exit_code
  test_pane_dispatch_timeout
  test_entry_point_flags
  test_entry_point_dep_check
  test_entry_point_env_passthrough

  if [[ "$RUN_INTEGRATION" == "true" ]]; then
    echo ""
    echo "── Integration Tests (mock agents, inline mode) ──"
    test_full_orchestration_approve
    test_full_orchestration_reject_then_approve
    test_skip_plan
    test_max_rounds_exceeded

    if command -v zellij >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
      echo ""
      echo "── Integration Tests (zellij mode via pty) ──"
      test_zellij_full_run
    else
      echo ""
      echo "── Skipping zellij integration tests (need zellij + python3) ──"
    fi
  fi

  # Summary
  echo ""
  echo "========================"
  echo "Passed: $PASSED"
  echo "Failed: $FAILED"

  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
      echo "  - $err"
    done
  fi

  echo ""
  [[ $FAILED -eq 0 ]] && echo "All tests passed." && exit 0
  echo "Some tests failed." && exit 1
}

main
