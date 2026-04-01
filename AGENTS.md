# captain-codex

Claude Code plugin: Codex plans, Claude implements, Codex reviews.

## Layout

- `commands/` — skill markdown files (the command definitions)
- `hooks/` — shell scripts (Stop event hook)
- `scripts/` — shell utilities (config, planning, review prompt)
- `templates/` — prompt skeletons and default config

## Config resolution

`templates/default-config.json` ← `~/.claude-architect/config.json` ← `.claude-architect/config.json`
