# captain-codex

Claude Code plugin that puts Codex in charge. Codex plans, Claude implements, Codex reviews — looping until Codex is satisfied.

## What It Does

One command. You describe what you want. Codex reads the codebase, writes a detailed plan with acceptance criteria, Claude implements it, Codex reviews, Claude addresses feedback, loop repeats until Codex approves. You walk away after the initial command.

```
/captain-codex refactor mac app to enable ios app with code sharing
```

That's it.

## Why Codex Plans and Reviews

Claude Code is a strong implementor — fast, creative, effective across large codebases and frontend work. But it reward-hacks. It takes shortcuts to appear done: skips edge cases, writes superficial tests that pass without verifying real behavior, silently deviates from a plan when compliance is hard, and declares victory prematurely. A human reviewer catches this. So does a separate model acting as verifier.

Codex (GPT-5.x family) is empirically better at architectural reasoning: it produces more principled plans with cleaner module boundaries and more coherent dependency graphs. It's weaker at frontend and implementation-level decisions, which is why this plugin scopes its review to structural concerns only — it reviews the architecture, not the code style.

The verifier should be a different model than the implementor. Same-model review has anchoring bias; the reviewer shares the implementor's blind spots. Cross-model review catches things neither model catches alone. This is the same principle behind adversarial review in multi-agent frameworks.

I've been doing this workflow manually for a long time — copying plans from Codex into Claude, copying Claude's output back to Codex for review, pasting the feedback back, repeating until Codex is satisfied. It produces noticeably better code than letting either model work alone. But it costs ~6 copy-paste steps per review round and requires babysitting the whole loop. This plugin automates it.

## Dependencies

- [codex-plugin-cc](https://github.com/openai/codex-plugin-cc) — OpenAI's official plugin (provides the review gate hook infrastructure)
- [Codex CLI](https://github.com/openai/codex) installed and authenticated (`codex login`)
- Claude Code v2.1.34+
- `jq` (for JSON processing in hook scripts)

## Installation

```bash
claude mcp add-plugin captain-codex https://github.com/jul-sh/captain-codex
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
