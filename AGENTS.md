# captain-codex — Operating Guidelines

This is a Claude Code plugin that orchestrates a Codex-plans-Claude-implements-Codex-reviews loop.

## Architecture

- **Commands** (`commands/`): Markdown skill files that define `/captain-codex` and sub-commands
- **Hooks** (`hooks/`): Shell scripts registered as Claude Code hooks (Stop event)
- **Scripts** (`scripts/`): Shared shell utilities for config management, planning orchestration, and review prompt construction
- **Templates** (`templates/`): Prompt templates and default configuration

## Key Flows

### Planning Phase
`scripts/plan.sh` dispatches two Codex calls via the `codex` CLI: one to analyze the codebase and draft a plan, one to formalize it with acceptance criteria. Output is a plan file in `tasks/`.

### Implementation Phase
Claude receives the plan contents and implements autonomously. The Stop hook (`hooks/review-gate.sh`) fires whenever Claude tries to stop.

### Review Gate
`hooks/review-gate.sh` reads the plan and config, builds an augmented review prompt via `scripts/review-prompt.sh`, dispatches it to Codex, parses the VERDICT, and returns a hook decision (block/allow). State is tracked in `.claude-architect/state.json`.

## Dependencies

- `codex-plugin-cc` must be installed (provides the Codex dispatch infrastructure)
- `codex` CLI must be installed and authenticated
- `jq` must be available on PATH

## Config Resolution

Configs merge in order: `templates/default-config.json` ← `~/.claude-architect/config.json` ← `.claude-architect/config.json` (project-level). Later values override earlier ones.
