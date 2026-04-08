# captain-codex

Zellij-native orchestrator: Codex plans, Claude implements, Codex reviews — each in their own tab.

## Layout

- `captain-codex` — standalone entry point script
- `scripts/` — shell utilities (orchestrate, helpers, config, review prompt)
- `templates/` — prompt skeletons, default config, zellij layout

## Architecture

Three zellij tabs: Captain (orchestrator), Codex (planning/review), Claude (implementation).
The orchestrator in `scripts/orchestrate.sh` drives everything via `zellij action write-chars` and `dump-screen`.

## Config resolution

`templates/default-config.json` <- `~/.claude-architect/config.json` <- `.claude-architect/config.json`
