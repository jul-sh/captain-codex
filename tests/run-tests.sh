#!/usr/bin/env bash
# captain-codex test suite
#
# Usage:
#   ./tests/run-tests.sh          # run unit tests only (fast, no zellij needed)
#   ./tests/run-tests.sh --all    # include integration tests (needs real terminal + zellij)

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

  if [[ ! -f "$HOME/.claude-architect/config.json" ]]; then
    mkdir -p "$HOME/.claude-architect"
    cp "$PROJECT_ROOT/templates/default-config.json" "$HOME/.claude-architect/config.json"
  fi
}

teardown() {
  rm -rf "$MOCK_BIN"
  [[ -n "${TEST_WORKDIR:-}" ]] && rm -rf "$TEST_WORKDIR"
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
    | PATH="$MOCK_BIN:$PATH" codex > /dev/null 2>&1

  assert_file_exists "plan file created" "$plan_path"
  assert_contains "plan has content" "$(cat "$plan_path")" "Objective"
}

test_mock_codex_approves() {
  echo "Test: mock codex VERDICT: APPROVE"

  local output
  output=$(echo "Review this implementation against the plan." \
    | PATH="$MOCK_BIN:$PATH" MOCK_CODEX_REVIEW_VERDICT=APPROVE codex 2>/dev/null)

  assert_contains "contains APPROVE" "$output" "VERDICT: APPROVE"
}

test_mock_codex_rejects_then_approves() {
  echo "Test: mock codex rejects N rounds then approves"

  local output
  output=$(printf 'Review implementation against plan\nReview implementation against plan\n' \
    | PATH="$MOCK_BIN:$PATH" MOCK_CODEX_REJECT_ROUNDS=1 codex 2>/dev/null)

  local rejects approves
  rejects=$(echo "$output" | grep -c "VERDICT: REJECT" || true)
  approves=$(echo "$output" | grep -c "VERDICT: APPROVE" || true)

  assert_eq "1 reject" "1" "$rejects"
  assert_eq "1 approve" "1" "$approves"
}

test_mock_claude_responds() {
  echo "Test: mock claude responds to prompts"

  local output
  output=$(echo "Implement the plan." | PATH="$MOCK_BIN:$PATH" claude 2>/dev/null)
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

test_entry_point_flags() {
  echo "Test: entry point flag parsing"

  # Test that no args shows usage
  local output
  output=$("$PROJECT_ROOT/captain-codex" 2>&1 || true)
  assert_contains "no args shows usage" "$output" "Usage"

  # Test that --supervised flag is parsed (check env export)
  # We can't fully test flag parsing without launching zellij,
  # so just verify the usage message format
  assert_contains "usage mentions skip-plan" "$output" "skip-plan"
}

test_entry_point_dep_check() {
  echo "Test: entry point dependency checks"

  # Run with a PATH that has bash but not the required deps
  local output
  output=$(PATH="/usr/bin:/bin" "$PROJECT_ROOT/captain-codex" "test" 2>&1 || true)
  assert_contains "missing dep error" "$output" "required but not found"
}

test_entry_point_uses_single_layout_launch_path() {
  echo "Test: entry point always launches via zellij layout"

  local mock_bin
  mock_bin=$(mktemp -d /tmp/captain-codex-zellij-mock-XXXXXX)
  local zellij_log="$mock_bin/zellij.log"
  local captured_layout="$mock_bin/captured-layout.kdl"
  local jq_bin
  jq_bin=$(command -v jq)

  cat > "$mock_bin/zellij" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '---' >> "$zellij_log"
printf '%s\n' "\$@" >> "$zellij_log"
args=( "\$@" )
for ((i=0; i<\${#args[@]}; i++)); do
  if [[ "\${args[i]}" == "-l" || "\${args[i]}" == "--layout" ]]; then
    cp "\${args[i+1]}" "$captured_layout"
    break
  fi
done
SCRIPT
  cat > "$mock_bin/codex" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
  cat > "$mock_bin/claude" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
  chmod +x "$mock_bin/zellij" "$mock_bin/codex" "$mock_bin/claude"
  ln -s "$jq_bin" "$mock_bin/jq"

  PATH="$mock_bin:$PATH" "$PROJECT_ROOT/captain-codex" "tabs should actually exist" >/dev/null 2>&1

  local outside_log outside_layout outside_launcher
  outside_log=$(cat "$zellij_log")
  outside_layout=$(cat "$captured_layout")
  assert_contains "outside zellij uses layout flag" "$outside_log" $'---\n-l'
  assert_not_contains "outside zellij does not use action subcommands" "$outside_log" "action"
  assert_contains "outside layout has Captain tab" "$outside_layout" 'tab name="Captain"'
  assert_contains "outside layout has Codex tab" "$outside_layout" 'tab name="Codex"'
  assert_contains "outside layout has Claude tab" "$outside_layout" 'tab name="Claude"'

  outside_launcher=$(sed -n 's/.*args "-c" "\(.*\)"/\1/p' "$captured_layout")
  assert_contains "outside launcher runs orchestrator" "$(cat "$outside_launcher")" "scripts/orchestrate.sh"
  assert_contains "outside launcher passes task inline" "$(cat "$outside_launcher")" "tabs\\ should\\ actually\\ exist"

  : > "$zellij_log"
  rm -f "$captured_layout"
  PATH="$mock_bin:$PATH" ZELLIJ=1 "$PROJECT_ROOT/captain-codex" "tabs should actually exist" >/dev/null 2>&1

  local inside_log inside_layout inside_launcher
  inside_log=$(cat "$zellij_log")
  inside_layout=$(cat "$captured_layout")
  assert_contains "inside zellij still uses layout flag" "$inside_log" $'---\n-l'
  assert_not_contains "inside zellij does not use action subcommands" "$inside_log" "action"
  assert_contains "inside layout has Captain tab" "$inside_layout" 'tab name="Captain"'
  assert_contains "inside layout has Codex tab" "$inside_layout" 'tab name="Codex"'
  assert_contains "inside layout has Claude tab" "$inside_layout" 'tab name="Claude"'

  inside_launcher=$(sed -n 's/.*args "-c" "\(.*\)"/\1/p' "$captured_layout")
  assert_contains "inside launcher runs orchestrator" "$(cat "$inside_launcher")" "scripts/orchestrate.sh"
  assert_contains "inside launcher passes task inline" "$(cat "$inside_launcher")" "tabs\\ should\\ actually\\ exist"

  rm -rf "$mock_bin"
}

test_layout_generation() {
  echo "Test: layout template substitution"

  local layout_template="$PROJECT_ROOT/templates/zellij-layout.kdl"
  local generated="/tmp/captain-codex-test-layout-$$.kdl"
  local test_cmd="/path/to/orchestrate.sh 'my task'"

  sed "s|CAPTAIN_CMD_PLACEHOLDER|$test_cmd|g" "$layout_template" > "$generated"

  assert_contains "layout has command" "$(cat "$generated")" "/path/to/orchestrate.sh"
  assert_contains "layout has Captain tab" "$(cat "$generated")" 'tab name="Captain"'
  assert_contains "layout has Codex tab" "$(cat "$generated")" 'tab name="Codex"'
  assert_contains "layout has Claude tab" "$(cat "$generated")" 'tab name="Claude"'
  rm -f "$generated"
}

# ── Integration Tests (zellij + mock agents via PTY) ─────────────────────────

WITH_PTY="$TESTS_DIR/with-pty.py"

# Helper: run a command inside a fresh zellij session via a layout.
# Uses with-pty.py to allocate a pseudo-terminal so zellij can start
# even without a controlling TTY (CI, Claude Code, etc.).
#
# Args:
#   $1 — test script path to run inside a zellij pane
#   $2 — timeout in seconds (default: 15)
ZELLIJ_TEST_SESSION=""

run_in_zellij() {
  local test_script="$1"
  local timeout="${2:-15}"
  local layout_file="/tmp/captain-zellij-test-layout-$$.kdl"
  ZELLIJ_TEST_SESSION="captain-test-$$-$(date +%s)"

  cat > "$layout_file" <<LAYOUT
layout {
    tab name="TestRunner" focus=true {
        pane {
            command "bash"
            args "-c" "$test_script"
        }
    }
}
LAYOUT

  # pty.spawn blocks until zellij exits. Since zellij waits for a
  # keypress after the pane command finishes, we rely on PTY_TIMEOUT
  # to kill it. The test results are written to files before the
  # timeout, so assertions still work. Exit code 124 = expected timeout.
  PTY_TIMEOUT="$timeout" python3 "$WITH_PTY" \
    zellij -s "$ZELLIJ_TEST_SESSION" -n "$layout_file" \
    >/dev/null 2>&1 || true

  # Cleanup any leftover session
  zellij kill-session "$ZELLIJ_TEST_SESSION" 2>/dev/null || true

  rm -f "$layout_file"
}

test_zellij_session_lifecycle() {
  echo "Test: zellij session starts and exits cleanly"

  # Simple test: start zellij, verify we can query tabs, exit
  local test_script="/tmp/captain-zellij-test-lifecycle-$$.sh"
  cat > "$test_script" <<'SCRIPT'
#!/usr/bin/env bash
sleep 1
tabs=$(zellij action query-tab-names 2>&1)
echo "$tabs" > /tmp/captain-zellij-lifecycle-result.txt
echo "done" >> /tmp/captain-zellij-lifecycle-result.txt
SCRIPT
  chmod +x "$test_script"

  rm -f /tmp/captain-zellij-lifecycle-result.txt
  run_in_zellij "$test_script" 5

  if [[ -f /tmp/captain-zellij-lifecycle-result.txt ]]; then
    local result
    result=$(cat /tmp/captain-zellij-lifecycle-result.txt)
    assert_contains "session has TestRunner tab" "$result" "TestRunner"
    assert_contains "lifecycle completes" "$result" "done"
  else
    fail "zellij lifecycle" "result file not created — zellij may not have started"
  fi

  rm -f "$test_script" /tmp/captain-zellij-lifecycle-result.txt
}

test_zellij_tab_communication() {
  echo "Test: zellij tab creation and write-chars"

  local test_script="/tmp/captain-zellij-test-tabs-$$.sh"
  local result_file="/tmp/captain-zellij-tabs-result-$$.txt"

  cat > "$test_script" <<SCRIPT
#!/usr/bin/env bash
sleep 1

# Create a second tab
zellij action new-tab -n "AgentTab"
sleep 0.5

# Verify both tabs exist
tabs=\$(zellij action query-tab-names 2>&1)
echo "tabs=\$tabs" > $result_file

# Switch to AgentTab and write characters
zellij action go-to-tab-name "AgentTab"
sleep 0.3
zellij action write-chars "echo HELLO_FROM_AGENT"
zellij action write 13  # Enter
sleep 1

# Dump AgentTab screen
zellij action dump-screen /tmp/captain-zellij-tabs-screen-$$.txt -f 2>/dev/null
if [[ -f /tmp/captain-zellij-tabs-screen-$$.txt ]]; then
  echo "screen_content=\$(cat /tmp/captain-zellij-tabs-screen-$$.txt)" >> $result_file
  if grep -q "HELLO_FROM_AGENT" /tmp/captain-zellij-tabs-screen-$$.txt; then
    echo "write_chars_worked=yes" >> $result_file
  else
    echo "write_chars_worked=no" >> $result_file
  fi
fi

echo "done" >> $result_file

# Close the extra tab
zellij action close-tab
SCRIPT
  chmod +x "$test_script"

  rm -f "$result_file" "/tmp/captain-zellij-tabs-screen-$$.txt"
  run_in_zellij "$test_script" 8

  if [[ -f "$result_file" ]]; then
    local result
    result=$(cat "$result_file")
    assert_contains "second tab created" "$result" "AgentTab"
    assert_contains "write-chars delivered" "$result" "write_chars_worked=yes"
    assert_contains "tab test completes" "$result" "done"
  else
    fail "tab communication" "result file not created"
  fi

  rm -f "$test_script" "$result_file" "/tmp/captain-zellij-tabs-screen-$$."*
}

test_zellij_orchestrator_flow() {
  echo "Test: orchestrator flow with mock agents in zellij"

  local test_workdir
  test_workdir=$(mktemp -d /tmp/captain-codex-integ-XXXXXX)
  mkdir -p "$test_workdir/.claude-architect" "$test_workdir/tasks"

  # Copy default config
  cp "$PROJECT_ROOT/templates/default-config.json" "$test_workdir/.claude-architect/config.json"

  local result_file="/tmp/captain-zellij-orch-result-$$.txt"
  local mock_bin_abs="$TESTS_DIR/mock-bin"

  # The test script runs inside zellij as the "Captain" pane.
  # It sets up tabs with mock agents, sends prompts, and verifies the flow.
  local test_script="/tmp/captain-zellij-test-orch-$$.sh"
  # Use full paths to mock agents — new tabs get their own shell with default PATH
  local mock_codex="$mock_bin_abs/codex"
  local mock_claude="$mock_bin_abs/claude"

  cat > "$test_script" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

cd "$test_workdir"
sleep 1

# Create Codex tab and start mock codex (using full path)
zellij action new-tab -n "Codex"
sleep 0.5
zellij action write-chars "$mock_codex"
zellij action write 13
sleep 1

# Create Claude tab and start mock claude (using full path)
zellij action new-tab -n "Claude"
sleep 0.5
zellij action write-chars "$mock_claude"
zellij action write 13
sleep 1

# Verify all tabs exist
tabs=\$(zellij action query-tab-names 2>&1)
echo "tabs=\$tabs" > $result_file

# Send a plan prompt to Codex
zellij action go-to-tab-name "Codex"
sleep 0.3
zellij action write-chars "Formalize your plan and save it to: $test_workdir/tasks/test-plan.md. Write the file now."
zellij action write 13
sleep 2

# Check if plan file was created
if [[ -f "$test_workdir/tasks/test-plan.md" ]]; then
  echo "plan_created=yes" >> $result_file
else
  echo "plan_created=no" >> $result_file
fi

# Send implement prompt to Claude
zellij action go-to-tab-name "Claude"
sleep 0.3
zellij action write-chars "Implement the plan. plan_contents here."
zellij action write 13
sleep 2

# Dump Claude screen to verify it responded
zellij action dump-screen /tmp/captain-zellij-claude-screen-$$.txt -f 2>/dev/null
if grep -q "Implementing" /tmp/captain-zellij-claude-screen-$$.txt 2>/dev/null; then
  echo "claude_responded=yes" >> $result_file
else
  echo "claude_responded=no" >> $result_file
fi

# Send review prompt to Codex
zellij action go-to-tab-name "Codex"
sleep 0.3
zellij action write-chars "Review this implementation against the plan."
zellij action write 13
sleep 2

# Dump Codex screen to check for verdict
zellij action dump-screen /tmp/captain-zellij-codex-screen-$$.txt -f 2>/dev/null
if grep -q "VERDICT: APPROVE" /tmp/captain-zellij-codex-screen-$$.txt 2>/dev/null; then
  echo "review_verdict=APPROVE" >> $result_file
else
  echo "review_verdict=missing" >> $result_file
fi

echo "done" >> $result_file

# Close extra tabs
zellij action go-to-tab-name "Claude"
sleep 0.2
zellij action close-tab
zellij action go-to-tab-name "Codex"
sleep 0.2
zellij action close-tab
SCRIPT
  chmod +x "$test_script"

  rm -f "$result_file" /tmp/captain-zellij-*-screen-$$.txt
  run_in_zellij "$test_script" 15

  if [[ -f "$result_file" ]]; then
    local result
    result=$(cat "$result_file")
    assert_contains "tabs created" "$result" "Codex"
    assert_contains "plan file created by mock codex" "$result" "plan_created=yes"
    assert_contains "claude responded to prompt" "$result" "claude_responded=yes"
    assert_contains "codex review returned verdict" "$result" "review_verdict=APPROVE"
    assert_contains "orchestrator flow completes" "$result" "done"
  else
    fail "orchestrator flow" "result file not created — zellij may not have started"
  fi

  rm -rf "$test_workdir" "$test_script" "$result_file" /tmp/captain-zellij-*-screen-$$.*
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  echo "captain-codex test suite"
  echo "========================"
  echo ""

  setup

  echo "── Unit Tests ──"
  test_slug_generation
  test_config_read
  test_config_init_state
  test_state_helpers
  test_mock_codex_writes_plan
  test_mock_codex_approves
  test_mock_codex_rejects_then_approves
  test_mock_claude_responds
  test_prompt_builders
  test_entry_point_flags
  test_entry_point_dep_check
  test_entry_point_uses_single_layout_launch_path
  test_layout_generation

  if [[ "$RUN_INTEGRATION" == "true" ]]; then
    if [[ -n "${ZELLIJ:-}" ]]; then
      echo ""
      echo "SKIP: Integration tests cannot run inside zellij."
    elif ! command -v zellij &>/dev/null; then
      echo ""
      echo "SKIP: Integration tests need zellij installed."
    elif ! command -v python3 &>/dev/null; then
      echo ""
      echo "SKIP: Integration tests need python3 (for PTY allocation)."
    else
      echo ""
      echo "── Integration Tests (zellij + mock agents) ──"
      test_zellij_session_lifecycle
      test_zellij_tab_communication
      test_zellij_orchestrator_flow
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
