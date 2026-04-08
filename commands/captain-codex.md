---
description: "Info about the captain-codex zellij-native pipeline."
---

# /captain-codex

The captain-codex pipeline is now a standalone CLI that runs in zellij with separate tabs for each agent.

## Usage

Run from your terminal (not as a Claude Code slash command):

```
captain-codex <task description> [--skip-plan <path>] [--max-rounds <n>] [--supervised]
```

This creates a zellij session with three tabs:
- **Captain** — orchestrator showing status and progress
- **Codex** — interactive Codex session for planning and reviewing
- **Claude** — interactive Claude session for implementing

## Flags

- `--skip-plan <path>` — Skip planning, use an existing plan file
- `--max-rounds <n>` — Cap review iterations (default: from config)
- `--supervised` — Pause after planning and after each review for human approval

## How it works

1. **Planning**: The orchestrator sends the task to Codex in its tab. Codex drafts and formalizes a plan.
2. **Implementation**: The orchestrator sends the plan to Claude in its tab. Claude implements autonomously.
3. **Review loop**: When Claude finishes, the orchestrator sends the review prompt to Codex. Codex reviews and issues APPROVE/REJECT. On rejection, feedback is sent back to Claude. Loop continues until approval or max rounds.

## Configuration

Use `/captain-codex:config` and `/captain-codex:instructions` to manage settings — these still work as before.

## Status

Use `/captain-codex:status` to check the current run state.
