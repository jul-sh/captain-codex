# captain-codex

Claude Code plugin: Codex plans, Claude implements, Codex reviews — all on GitHub.

## Flow

1. Codex creates a plan → posted as a GitHub issue
2. Claude implements on a branch → opens a PR linking the issue
3. Codex reviews the PR diff → posts PR reviews (request changes / approve)
4. Loop until LGTM or max rounds

## Layout

- `commands/` — skill markdown files (the command definitions)
- `hooks/` — hook config (currently empty — review loop is explicit)
- `scripts/` — shell utilities:
  - `config.sh` — config resolution and state management
  - `plan.sh` — Codex planning orchestrator
  - `gh-adapter.sh` — GitHub API adapter (issues, PRs, reviews via `gh` CLI)
  - `review-loop.sh` — single review iteration (Codex review → PR review post)
  - `review-prompt.sh` — builds the review prompt from templates
- `templates/` — prompt skeletons and default config

## Config resolution

`templates/default-config.json` ← `~/.claude-architect/config.json` ← `.claude-architect/config.json`

## Architecture principle

The planner and implementor are shielded from GitHub and git-transport complexity. `gh-adapter.sh` is the only component that touches the `gh` CLI and the `git` commands needed to support it (fetch, checkout, push). The orchestrator (`commands/captain-codex.md`) calls the adapter between phases.
