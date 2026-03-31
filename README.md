# captain-codex

Claude Code plugin that puts Codex in charge. Codex plans, Claude implements, Codex reviews — looping until Codex is satisfied.

## What It Does

One command. You describe what you want. Codex reads the codebase, writes a detailed plan with acceptance criteria, Claude implements it, Codex reviews, Claude addresses feedback, loop repeats until Codex approves. You walk away after the initial command.

```
/captain-codex build a maximally principled refactor to unlock a separate iOS app with maximum code sharing
```

That's it.

## Dependencies

- [codex-plugin-cc](https://github.com/openai/codex-plugin-cc) — OpenAI's official plugin (provides the review gate hook infrastructure)
- [Codex CLI](https://github.com/openai/codex) installed and authenticated (`codex login`)
- Claude Code v2.1.34+
- `jq` (for JSON processing in hook scripts)

## Installation

```bash
claude plugin install <this-repo-url>
```

## Commands

| Command | Description |
|---------|-------------|
| `/captain-codex <task>` | Full pipeline: plan → implement → review loop |
| `/captain-codex:status` | Show current pipeline state and review history |
| `/captain-codex:instructions` | View or edit Codex review instructions |
| `/captain-codex:config` | View or edit plugin configuration |

## Flags

| Flag | Description |
|------|-------------|
| `--plan-only` | Stop after planning, output plan for human review |
| `--skip-plan <path>` | Skip planning, use existing plan file |
| `--no-team` | Forbid subagent teams during implementation |
| `--max-rounds <n>` | Cap review iterations (default: 10) |
| `--supervised` | Pause after planning for human approval |

## How It Works

### Phase 1: Planning (Codex)
Codex reads the full codebase and writes a detailed implementation plan with acceptance criteria. The plan is saved to `tasks/<slug>.md`.

### Phase 2: Implementation (Claude)
Claude receives the plan and implements autonomously, maintaining a worklog in the plan file.

### Phase 3: Review Loop (Codex)
When Claude finishes, a Stop hook fires Codex to review the implementation against the plan's acceptance criteria. If rejected, Claude receives specific feedback and continues. Loop repeats until approval or max rounds.

## Configuration

User-level config: `~/.claude-architect/config.json`
Project-level override: `.claude-architect/config.json`

```bash
/captain-codex:config                           # view all
/captain-codex:config codex.model gpt-5.4      # set a value
/captain-codex:config max_rounds 15             # set a value
```

See `templates/default-config.json` for all available options.

## License

MIT
