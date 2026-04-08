---
description: "Full pipeline: Codex plans, Claude implements, Codex reviews — all on GitHub."
argument-hint: "<task description>"
---

## MANDATORY TIMEOUT — READ BEFORE ANY BASH CALL

**Every single Bash tool call in this entire skill MUST include `timeout: 2700000` (45 minutes).** No exceptions. Not even for `config.sh read`. The default 2-minute timeout will kill long-running commands like `plan.sh` and `codex exec`, destroying the user's work. Copy-paste this into every Bash call: `"timeout": 2700000`

# /captain-codex

Full pipeline: Codex plans, Claude implements, Codex reviews — all on GitHub.

The planner creates a GitHub issue with the plan. The implementor creates a PR. The reviewer posts PR reviews requesting changes until LGTM.

## Usage

```
/captain-codex <task description and any ad-hoc instructions>
/captain-codex --skip-plan <path> <task description>
```

## Flags

- `--skip-plan <path>` — Skip planning and issue creation, use an existing plan file
- `--max-rounds <n>` — Cap review iterations (default: from config)
- `--supervised` — Pause after planning and after each review for human approval

## Behavior

### Parsing Input

Parse flags from the user's input. Everything else is natural language.

The user may include ad-hoc instructions for any phase inline. Look for cues like "for planning...", "when implementing...", "for review...", "the reviewer should...", "the planner should...", "make sure to...", or similar natural language directing a specific phase.

Extract:
- **task description** — the core task
- **ad-hoc plan instructions** — anything directing the planning phase
- **ad-hoc implementation instructions** — anything directing the implementation phase
- **ad-hoc review instructions** — anything directing the review phase

Read config using `${CLAUDE_PLUGIN_ROOT}/scripts/config.sh read`. For each phase, merge ad-hoc instructions (if any) with the config values by appending the ad-hoc instructions to the config array.

### Phase 1: Planning

1. If `--skip-plan <path>` was provided:
   - Verify the plan file exists.
   - Check if `.claude-architect/state.json` already exists **and** `plan_file` matches the provided `--skip-plan` path.
   - If state exists and plan matches: **reuse all existing state** (issue_number, pr_number, branch, etc.) — do NOT re-initialize. Just update `phase` to `"implementing"` and `active` to `true`.
   - If state exists but `plan_file` doesn't match: this is a different task. Initialize fresh state (discard old state), do NOT create a GitHub issue.
   - If no prior state: initialize fresh state (same as step 5 below, no session_id), and **do NOT create a GitHub issue**.
   - If `branch` is set in state, check out that branch before proceeding:
     ```bash
     ${CLAUDE_PLUGIN_ROOT}/scripts/gh-adapter.sh checkout <branch>
     ```
   - If `pr_number` is set, fetch outstanding review feedback from GitHub to include in the implementation prompt:
     ```bash
     ${CLAUDE_PLUGIN_ROOT}/scripts/gh-adapter.sh get-review-feedback <pr_number>
     ```
     If feedback is returned, prepend it to the implementation prompt as: "The reviewer previously requested the following changes:\n\n<feedback>\n\nAddress this feedback in addition to any remaining plan items."
   - Skip to Phase 2. Always go through implementation (Phase 2) even if `pr_number` exists — the user is resuming to apply more changes. Phase 2 will skip branch/PR creation if they already exist, but still run the implementation prompt and push.

2. Run `${CLAUDE_PLUGIN_ROOT}/scripts/plan.sh "<task description>"`. Before calling, write the merged plan instructions into a temporary config override if ad-hoc plan instructions were provided. The script outputs a tab-separated line: `<plan_path>\t<session_id>`. Parse both values.

3. Verify the plan file exists. If missing, retry once, then report failure.

4. If `--supervised` was specified: present the plan and ask for confirmation before continuing.

5. Initialize state tracking (pass all 7 positional args, including adhoc review instructions if any):
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/config.sh init-state "<task description>" "<plan file path>" <max_rounds> "<session_id>" <true|false for --supervised> "<adhoc_review_instructions>"
   ```

6. **Create GitHub issue** with the plan. Read labels and assignee from config:
   ```bash
   config=$(${CLAUDE_PLUGIN_ROOT}/scripts/config.sh read)
   # Build --label flags from github.issue_labels array
   # Build --assign flag from github.implementor_assign if non-null
   ${CLAUDE_PLUGIN_ROOT}/scripts/gh-adapter.sh create-issue "<task title>" "<plan_file>" <label flags> [--assign <user>]
   ```
   Parse the output (tab-separated: `<issue_number>\t<issue_url>`). Save to state:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/config.sh update-state issue_number <number>
   ${CLAUDE_PLUGIN_ROOT}/scripts/config.sh update-state issue_url "<url>"
   ```

### Phase 2: Implementation

1. **Create branch** (skip if `branch` is already set in state). Starting from the default branch, use `issue_number` as the suffix if available, otherwise generate a slug from the task description:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/gh-adapter.sh create-branch <issue_number_or_slug>
   ```
   Save the branch name to state:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/config.sh update-state branch "<branch_name>"
   ${CLAUDE_PLUGIN_ROOT}/scripts/config.sh update-state phase "implementing"
   ```

2. Read the plan file and `${CLAUDE_PLUGIN_ROOT}/templates/implement-prompt.md`.

3. Substitute the placeholders in the template:
   - `{{plan_contents}}` → contents of the plan file
   - `{{implementation_instructions}}` → merged config + ad-hoc implementation instructions, joined by newlines
   - `{{plan_file}}` → path to the plan file

4. Execute the resulting prompt (Claude implements the plan).

5. After implementation, **push changes**. Then **create PR** if `pr_number` is not already set in state. Pass `--issue` only if `issue_number` is set:
   ```bash
   # If no PR yet:
   ${CLAUDE_PLUGIN_ROOT}/scripts/gh-adapter.sh push-and-pr "<branch>" [--issue <issue_number>]
   # If PR already exists (resume path):
   ${CLAUDE_PLUGIN_ROOT}/scripts/gh-adapter.sh push "<branch>"
   ```
   Parse output (tab-separated: `<pr_number>\t<pr_url>`) if creating new PR. Save to state:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/config.sh update-state pr_number <number>
   ${CLAUDE_PLUGIN_ROOT}/scripts/config.sh update-state pr_url "<url>"
   ```

### Phase 3: Review Loop

Loop up to `max_rounds` times:

1. **Run review.** In normal mode, review-loop.sh handles posting to GitHub and updating state. In `--supervised` mode, use `--no-post` so the human can review before posting:
   ```bash
   # Normal mode:
   ${CLAUDE_PLUGIN_ROOT}/scripts/review-loop.sh <pr_number> <plan_file>

   # Supervised mode:
   ${CLAUDE_PLUGIN_ROOT}/scripts/review-loop.sh --no-post <pr_number> <plan_file>
   ```
   Parse output: first line is the verdict (`APPROVE`, `REJECT`, or `MAX_ROUNDS_EXCEEDED`), remaining lines are the review body.

   If exit code is 2 (max rounds exceeded), go to step 6.

2. If `--supervised`: present the review verdict and body to the user. Ask for confirmation before continuing. Then post the review and update state:
   ```bash
   # Write review body to temp file, then:
   ${CLAUDE_PLUGIN_ROOT}/scripts/gh-adapter.sh post-review <pr_number> <verdict> <temp_file>
   ```
   Update `.claude-architect/state.json` with the round and review history entry:
   ```bash
   jq --argjson round <N> --argjson entry '{"round":<N>,"verdict":"<V>","summary":"<first 2000 chars>","timestamp":"<ISO 8601>"}' \
     '.round = $round | .phase = "review" | .review_history += [$entry]' \
     .claude-architect/state.json > .claude-architect/state.json.tmp \
     && mv .claude-architect/state.json.tmp .claude-architect/state.json
   ```

4. If **APPROVE**:
   - Read config to check `github.auto_close_issue`. If true **and** `issue_number` is set (not null):
     ```bash
     ${CLAUDE_PLUGIN_ROOT}/scripts/gh-adapter.sh close-issue <issue_number>
     ```
   - Update state to complete:
     ```bash
     ${CLAUDE_PLUGIN_ROOT}/scripts/config.sh update-state phase "complete"
     ${CLAUDE_PLUGIN_ROOT}/scripts/config.sh update-state active false
     ```
   - Break out of loop.

5. If **REJECT**:
   - Update state phase to implementing:
     ```bash
     ${CLAUDE_PLUGIN_ROOT}/scripts/config.sh update-state phase "implementing"
     ```
   - Feed the review feedback to Claude as a continuation prompt: "The reviewer requested changes. Address this feedback:\n\n<review_body>"
   - After Claude fixes, push the changes:
     ```bash
     ${CLAUDE_PLUGIN_ROOT}/scripts/gh-adapter.sh push "<branch>"
     ```
   - Continue loop.

6. If max rounds exceeded (exit code 2 from review-loop.sh): the script already updated state to failed. Proceed to Phase 4.

### Phase 4: Completion

1. Read the final state from `.claude-architect/state.json`
2. Present a summary: task, plan path, GitHub issue link, PR link, rounds, final verdict, review history.
3. If max rounds exceeded, offer to continue with `--skip-plan`.
