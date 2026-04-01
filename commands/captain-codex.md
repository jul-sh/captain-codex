# /captain-codex

Full pipeline: Codex plans, Claude implements, Codex reviews until satisfied.

## Usage

```
/captain-codex <task description>
/captain-codex --skip-plan <path> <task description>
```

## Flags

- `--skip-plan <path>` — Skip planning, use an existing plan file
- `--max-rounds <n>` — Cap review iterations (default: from config)
- `--supervised` — Pause after planning and after each review for human approval

## Behavior

### Phase 1: Planning

1. Read config using `scripts/config.sh read`.

2. If `--skip-plan <path>` was provided, verify the plan file exists and skip to Phase 2.

3. Run `scripts/plan.sh "<task description>"`. It outputs a tab-separated line: `<plan_path>\t<session_id>`. Parse both values.

4. Verify the plan file exists. If missing, retry once, then report failure.

5. If `--supervised` was specified: present the plan and ask for confirmation before continuing.

6. Initialize state tracking:
   ```bash
   scripts/config.sh init-state "<task description>" "<plan file path>" <max_rounds> "<session_id>" <true|false for --supervised>
   ```

### Phase 2: Implementation

Read the plan file and `templates/implement-prompt.md`. Read config to get `implementation_instructions`.

Substitute the placeholders in the template:
- `{{plan_contents}}` → contents of the plan file
- `{{implementation_instructions}}` → from config
- `{{plan_file}}` → path to the plan file

Execute the resulting prompt.

The review gate hook fires automatically when implementation tries to stop. It resumes the Codex planning session to review, and blocks or allows the stop based on the verdict. The loop continues until Codex approves or max rounds (from config) is hit.

### Phase 3: Completion

1. Read the final state from `.claude-architect/state.json`
2. Present a summary: task, plan path, rounds, final verdict, review history.
3. If max rounds exceeded, offer to continue with `--skip-plan`.
4. Update state to "complete" or "failed".
