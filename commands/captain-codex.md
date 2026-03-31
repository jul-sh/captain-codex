# /captain-codex

Full pipeline: Codex plans, Claude implements, Codex reviews until satisfied.

## Usage

```
/captain-codex <task description>
```

## Flags

- `--plan-only` — Stop after planning phase, output the plan for human review
- `--skip-plan <path>` — Skip planning, use an existing plan file
- `--no-team` — Forbid spawning subagent teams during implementation
- `--max-rounds <n>` — Cap review iterations (default: from config, typically 10)
- `--supervised` — Pause after planning for human approval before implementation

## Behavior

You are orchestrating a full plan-implement-review pipeline. Follow these phases exactly.

### Phase 1: Planning (Codex does the work)

Parse the flags from the user's input. Extract the `<task description>` (everything after flags).

1. Read config using `scripts/config.sh read`.

2. If `--skip-plan <path>` was provided:
   - Verify the plan file exists at `<path>`
   - Skip to Phase 2

3. Dispatch to Codex via `/codex:rescue`:
   ```
   Read the full codebase. Write a detailed implementation plan for: <task description>
   ```
   Wait for completion by polling via `/codex:status`.

4. Dispatch second Codex call (resume same thread):
   ```
   Turn this into a detailed delegatable plan. Save to tasks/<slug>.md.

   Include these acceptance criteria at the end of the plan:

   ## Acceptance Criteria
   <acceptance_criteria from config, one per line as a checkbox>

   The plan must include:
   - Clear scope and goals
   - Step-by-step implementation instructions
   - File-by-file change descriptions where applicable
   - Edge cases and potential pitfalls
   - A ## Worklog section (empty, to be filled during implementation)
   - A ## Acceptance Criteria section with checkboxes
   ```
   Wait for completion.

5. Verify the plan file exists in the `tasks/` directory and contains an "Acceptance Criteria" section.
   - If missing: retry the second Codex call once. If still missing, report failure to user.

6. If `--plan-only` was specified: present the plan contents to the user and stop.
   If `--supervised` was specified: present the plan and ask for confirmation before continuing.

7. Initialize state tracking:
   ```bash
   scripts/config.sh init-state "<task description>" "<plan file path>" <max_rounds>
   ```

### Phase 2: Gate Setup

1. Check if `codex-plugin-cc`'s review gate is already enabled via `/codex:status`.
2. The captain-codex Stop hook (hooks/review-gate.sh) will handle reviews automatically.
3. If `codex-plugin-cc`'s built-in review gate is also active, warn the user:
   ```
   ⚠ codex-plugin-cc review gate is also active. For best results, disable it:
   /codex:setup --disable-review-gate
   ```
4. Update state to phase "implementing".

### Phase 3: Implementation (Claude does the work)

Read the plan file. Then execute the implementation with these instructions:

```
## Your Task

Implement the following plan completely and autonomously.

<contents of plan file>

## Implementation Instructions
<implementation_instructions from config>

## Requirements

- Follow the plan exactly. Do not skip steps.
- After completing each major step, append to the ## Worklog section of the plan file:
  - What was done
  - Any blockers encountered and how they were resolved
  - Tradeoffs made and why
  - Verification status (tests run, results)
- When all work is complete, append a final worklog entry summarizing:
  - All tests run and their results
  - Each acceptance criterion and whether it is met with evidence
- Do NOT mark yourself as done until every acceptance criterion is addressed in the worklog.
```

If `--no-team` was specified, add: "Do not spawn subagent teams. Work sequentially."

The review gate hook will fire automatically when implementation tries to stop. It will:
- Send the plan + diff + worklog to Codex for review
- If Codex rejects: block the stop and inject feedback
- If Codex approves: allow the stop

The loop continues until Codex approves or `--max-rounds` is hit.

### Phase 4: Completion

When the loop finishes:

1. Read the final state from `.claude-architect/state.json`
2. Present a summary:
   ```
   ## captain-codex Complete

   **Task:** <task description>
   **Plan:** <plan file path>
   **Rounds:** <N> review iterations
   **Final Verdict:** APPROVED / MAX_ROUNDS_EXCEEDED

   ### Review History
   <table of round number, verdict, summary for each round>
   ```
3. If max rounds were exceeded, ask the user:
   ```
   Max review rounds (<N>) exceeded. Options:
   1. Continue for N more rounds: /captain-codex --skip-plan <plan-path> --max-rounds <N>
   2. Review the feedback and implement manually
   3. Abort
   ```
4. Clean up: update state to "complete" or "failed".
