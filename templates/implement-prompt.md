## Your Task

Implement the following plan completely and autonomously.

{{plan_contents}}

## Implementation Instructions
{{implementation_instructions}}

## Requirements

- Follow the plan exactly. Do not skip steps.
- After completing each major step, append to the **## Worklog** section of the plan file (`{{plan_file}}`):
  - What was done
  - Any blockers encountered and how they were resolved
  - Tradeoffs made and why
  - Verification status (tests run, results)
- When all work is complete, append a final worklog entry summarizing:
  - All tests run and their results
  - Each acceptance criterion and whether it is met with evidence
- Do NOT mark yourself as done until every acceptance criterion is addressed in the worklog.

## Pushing Back on the Plan

If during implementation you encounter a reason the plan's
architecture is wrong, write a PUSHBACK section in the worklog:

### Pushback

#### [Concern title]
- **Plan says:** [what the plan prescribes]
- **Problem:** [why it doesn't work in practice]
- **Evidence:** [concrete: compile error, circular dependency,
  API limitation, test that can't be written]
- **Proposed alternative:** [what you'd do instead and why]

Only push back when you have concrete evidence, not preference.
"I'd rather use X" is not pushback. "The plan's module boundary
creates a circular dependency between A and B" is pushback.

You may implement your proposed alternative IF you document it
in the pushback section. The reviewer will evaluate whether
the deviation is justified.
