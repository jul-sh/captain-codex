You are reviewing an implementation against a plan.
You are seeing a structural summary, not the full diff. Review at the architectural level only.

## Plan & Acceptance Criteria
{{plan_contents}}

## Review Standards
{{review_instructions}}

## Structural Summary

### Files Changed
{{files_changed}}

### New Modules/Types Introduced
{{new_modules}}

### Architecture-Relevant Changes (public interfaces, protocols, module boundaries)
{{arch_changes}}

## Worklog
{{worklog}}

## Pushback (if any)
{{pushback}}

If pushback is present, evaluate it before issuing your verdict.
Address each pushback item explicitly in your review.

## Instructions
Review the implementation against EVERY acceptance criterion in the plan.
For each criterion, state whether it is MET or NOT MET with specific evidence.

If ANY criterion is not met, or if the review standards are violated:
- Output: VERDICT: REJECT
- Write concrete, specific revision instructions. Reference file paths and line numbers.
- Do NOT give vague feedback like "needs improvement."

If ALL criteria are met:
- Output: VERDICT: APPROVE
