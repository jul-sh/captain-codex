---
description: "Full pipeline: Codex plans, Claude implements, Codex reviews until satisfied."
argument-hint: "<task description>"
---

# /captain-codex

Full pipeline: Codex plans, Claude implements, Codex reviews until satisfied.

## Usage

```
/captain-codex <task description and any ad-hoc instructions>
/captain-codex --skip-plan <path> <task description>
```

## Flags

- `--skip-plan <path>` — Skip planning, use an existing plan file
- `--max-rounds <n>` — Cap review iterations (default: from config)
- `--supervised` — Pause after planning and after each review for human approval

## Important: Timeouts

All Bash calls to codex scripts (`${CLAUDE_PLUGIN_ROOT}/scripts/plan.sh`, `${CLAUDE_PLUGIN_ROOT}/scripts/config.sh`, and any `codex exec` invocations) can take a long time. **Always use a 45-minute timeout (2700000ms)** for these calls by setting the `timeout` parameter on the Bash tool.

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

1. If `--skip-plan <path>` was provided, verify the plan file exists and skip to Phase 2.

2. Run `${CLAUDE_PLUGIN_ROOT}/scripts/plan.sh "<task description>"`. Before calling, write the merged plan instructions into a temporary config override if ad-hoc plan instructions were provided. The script outputs a tab-separated line: `<plan_path>\t<session_id>`. Parse both values.

3. Verify the plan file exists. If missing, retry once, then report failure.

4. If `--supervised` was specified: present the plan and ask for confirmation before continuing.

5. Initialize state tracking:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/config.sh init-state "<task description>" "<plan file path>" <max_rounds> "<session_id>" <true|false for --supervised>
   ```

### Phase 2: Implementation

Read the plan file and `${CLAUDE_PLUGIN_ROOT}/templates/implement-prompt.md`.

Substitute the placeholders in the template:
- `{{plan_contents}}` → contents of the plan file
- `{{implementation_instructions}}` → merged config + ad-hoc implementation instructions, joined by newlines
- `{{plan_file}}` → path to the plan file

Execute the resulting prompt.

The review gate hook fires automatically when implementation tries to stop. It resumes the Codex planning session to review, and blocks or allows the stop based on the verdict. The loop continues until Codex approves or max rounds (from config) is hit.

Note: ad-hoc review instructions need to be available to the hook. Write them to `.claude-architect/state.json` under an `adhoc_review_instructions` key during init-state so the hook can merge them with the config values.

### Phase 3: Completion

1. Read the final state from `.claude-architect/state.json`
2. Present a summary: task, plan path, rounds, final verdict, review history.
3. If max rounds exceeded, offer to continue with `--skip-plan`.
4. Update state to "complete" or "failed".
