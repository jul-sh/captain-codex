# captain-codex

Zellij-native orchestrator. Codex plans, Claude implements, Codex reviews — each agent in its own tab.

## What It Does

One command. You describe what you want; include ad-hoc instructions for any phase in natural language.

```
captain-codex refactor mac app to enable ios app with code sharing
```

```
captain-codex "refactor auth module. for planning, focus on backwards compat. when implementing, don't touch the database layer. reviewer should be strict about test coverage."
```

This creates a zellij session with three tabs:
- **Captain** — orchestrator showing status and progress
- **Codex** — interactive Codex session for planning and reviewing
- **Claude** — interactive Claude session for implementing

You can switch between tabs to watch each agent work in real-time.

## Why

Claude is a strong implementor; fast, creative, good across large codebases. But it reward-hacks. It takes shortcuts to look done: skips edge cases, writes tests that pass without verifying behavior, deviates from plans when compliance is hard, declares victory early. You need a separate verifier.

Codex is better at architectural reasoning; cleaner module boundaries, more principled dependency graphs. The verifier should be a different model than the implementor. Same-model review has anchoring bias; the reviewer shares the implementor's blind spots. Cross-model review catches things neither catches alone.

The previous version automated this loop but ran everything in a single terminal. This version gives each agent its own zellij tab so you can watch both agents work simultaneously.

## Dependencies

- [Zellij](https://zellij.dev/) terminal multiplexer (v0.40+)
- [Codex CLI](https://github.com/openai/codex) installed and authenticated (`codex login`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- `jq`

## Installation

Clone this repo and add the `captain-codex` script to your PATH:

```bash
git clone https://github.com/jul-sh/captain-codex.git
ln -s "$(pwd)/captain-codex/captain-codex" ~/.local/bin/captain-codex
```

The slash commands (`/captain-codex:status`, etc.) are still available as a Claude Code plugin:

```
/plugin install captain-codex@jul-sh
```

## Usage

```
captain-codex <task description> [--skip-plan <path>] [--max-rounds <n>] [--supervised]
```

| Flag | Description |
|------|-------------|
| `--skip-plan <path>` | Skip planning, use an existing plan file |
| `--max-rounds <n>` | Cap review iterations (default: from config) |
| `--supervised` | Pause after planning and each review for human approval |

### Slash commands (inside Claude Code)

| Command | Description |
|---------|-------------|
| `/captain-codex` | Info about the standalone CLI |
| `/captain-codex:status` | Current phase, round, review history |
| `/captain-codex:instructions` | View/edit plan, implementation, and review instructions |
| `/captain-codex:config` | View/edit plugin config |

## How It Works

**Planning.** The orchestrator starts Codex in its tab and sends the planning prompt. Codex reads the codebase and writes an implementation plan to `tasks/<slug>.md`. The Codex session stays alive for reviews, retaining full context.

**Implementation.** The orchestrator switches to the Claude tab and sends the plan. Claude implements autonomously, maintaining a worklog in the plan file.

**Review loop.** When the orchestrator detects Claude has finished (via screen polling), it switches to the Codex tab and sends the review prompt. Rejected: feedback goes back to Claude. Approved: done. Max rounds exceeded: run reports failure.

**Supervised mode.** `--supervised` pauses in the Captain tab after planning and after each review round for human confirmation.

## Configuration

Three instruction sets control what each phase does:

| Config key | Controls |
|---|---|
| `plan_instructions` | What Codex should focus on when planning |
| `implementation_instructions` | How Claude should implement |
| `review_instructions` | What Codex should check during review |

Edit via `/captain-codex:instructions` or directly in config files.

User-level: `~/.claude-architect/config.json`
Project-level override: `.claude-architect/config.json`

```
/captain-codex:config                           # view all
/captain-codex:config codex.model gpt-5.4      # set a value
/captain-codex:config max_rounds 15             # set a value
```

See `templates/default-config.json` for all options.

## License

MIT
