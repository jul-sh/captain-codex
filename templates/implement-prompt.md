{{plan_contents}}

## Instructions
{{implementation_instructions}}

## Commit Discipline

You are working on a branch that will become a pull request. Commit frequently with clear, descriptive messages. Each commit should represent a logical unit of work.

**Do NOT commit pipeline artifacts.** Never stage or commit `.claude-architect/`, `tasks/`, or any state/plan files. Only commit your implementation changes.

## Autonomy

You are running in an automated pipeline. Keep moving without unnecessary pauses:
- The plan above is already approved — do NOT ask for approval of it. Execute it directly.
- You may create sub-plans for complex steps, but execute them immediately without waiting for approval.
- Default to making reasonable decisions and proceeding. Only ask a question if the answer is truly unguessable and blocking — not for confirmation or preference.

## MANDATORY: Bash Timeout

**Every Bash tool call MUST set `timeout: 2700000` (45 minutes).** The default timeout is too short and will kill your commands mid-execution.
