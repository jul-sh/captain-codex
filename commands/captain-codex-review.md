---
description: "Trigger Codex review of the current implementation."
---

## MANDATORY TIMEOUT

**Every Bash tool call MUST include `timeout: 2700000` (45 minutes).** No exceptions.

# /captain-codex:review

Triggers a Codex review of the current implementation. Call this when you have finished implementing the plan (or a review round's feedback) and are ready for review.

## Behavior

1. Verify `.claude-architect/state.json` exists and `active == true`. If not, report that there is no active run.

2. Read the state file. Verify phase is `"implementing"` or `"review"`. If not, report the current phase and do not proceed.

3. Read `plan_file`, `max_rounds`, `round`, `codex_session_id`, and `supervised` from the state.

4. Compute `next_round = round + 1`. If `next_round > max_rounds`:
   - Update state: `active = false`, `phase = "failed"`, `failure_reason = "Max review rounds exceeded"`
   - Report that max rounds were exceeded and suggest running `/captain-codex:status`.
   - Stop here.

5. Update state: `phase = "review"`, `round = next_round`.

6. Build the review prompt:
   ```bash
   review_prompt=$("${CLAUDE_PLUGIN_ROOT}/scripts/review-prompt.sh" "<plan_file>")
   ```

7. Read Codex config:
   ```bash
   config=$("${CLAUDE_PLUGIN_ROOT}/scripts/config.sh" read)
   ```
   Extract `codex.review_model` (fallback: `codex.model`, then `"gpt-5.4"`) and `codex.reasoning_effort` (fallback: `"xhigh"`).

8. Dispatch to Codex:
   ```bash
   codex_cmd=(codex exec)
   # If session_id is set, resume that session
   if [[ -n "$session_id" ]]; then
     codex_cmd+=(resume "$session_id")
   fi
   codex_cmd+=(--sandbox workspace-write -m "$codex_model" -c "model_reasoning_effort=$codex_effort" --color never)
   echo "$review_prompt" | "${codex_cmd[@]}"
   ```
   If the first attempt fails, retry once after a 2-second pause. If both fail, update state phase back to `"implementing"` and report the failure.

9. Parse the verdict from the Codex output:
   - Look for `VERDICT: APPROVE` or `VERDICT: REJECT` (case-insensitive).
   - Default to `REJECT` if neither is found.
   - Extract the summary (text after the VERDICT line, up to 2000 chars).

10. Record the review in state:
    ```bash
    jq --argjson entry '{"round": <next_round>, "verdict": "<verdict>", "summary": "<summary>", "timestamp": "<ISO timestamp>"}' \
      '.review_history += [$entry]' .claude-architect/state.json
    ```

11. Act on the verdict:

    **APPROVE:**
    - If `supervised == true`: update phase to `"approved_pending"`, present the review output, and tell the user that Codex approved and they should confirm.
    - If `supervised == false`: update state to `active = false`, `phase = "complete"`. Present the approval summary. You are done — stop working.

    **REJECT:**
    - If `supervised == true`: update phase to `"rejected_pending"`, present the review feedback, and ask the user whether to continue implementing with this feedback or abort.
    - If `supervised == false`: update phase to `"implementing"`. Present the Codex feedback, then **continue implementing** based on that feedback. When done addressing the feedback, call `/captain-codex:review` again.
