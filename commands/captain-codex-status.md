---
description: "Show current phase, round, and review history."
---

# /captain-codex:status

Shows current pipeline state for an active captain-codex run.

## Behavior

1. Check if `.claude-architect/state.json` exists in the current project directory.

2. If no state file exists:
   ```
   No active captain-codex run in this project.
   ```

3. If state file exists, read it and display:

   ```
   ## captain-codex Status

   **Phase:** <phase>
   **Task:** <task_description>
   **Plan:** <plan_file>
   **Round:** <round> / <max_rounds>
   **Zellij Session:** <zellij_session>
   **Started:** <started_at>

   ### Review History
   | Round | Verdict | Summary | Time |
   |-------|---------|---------|------|
   | 1     | REJECT  | ...     | ...  |
   | 2     | REJECT  | ...     | ...  |
   ```

4. If phase is "review" or "implementing":
   ```
   **Tip:** Switch to the Codex or Claude tab in zellij to watch the agents work in real-time.
   ```

5. If phase is "complete":
   ```
   **Status:** Complete — Codex approved on round <N>
   ```

6. If phase is "failed":
   ```
   **Status:** Failed — <reason from state>
   ```
