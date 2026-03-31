# captain-codex

Claude Code plugin that puts Codex in charge. Codex plans, Claude implements, Codex reviews; loop until Codex is satisfied.

## What It Does

One command. You describe what you want. Codex writes a plan, Claude implements it, Codex reviews, Claude fixes, repeat until approved.

```
/captain-codex refactor mac app to enable ios app with code sharing
```

## Why

Claude is a strong implementor; fast, creative, good across large codebases. But it reward-hacks. It takes shortcuts to look done: skips edge cases, writes tests that pass without verifying behavior, deviates from plans when compliance is hard, declares victory early. You need a separate verifier.

Codex is better at architectural reasoning; cleaner module boundaries, more principled dependency graphs. It's weaker at frontend and implementation details, so the plugin scopes its review to structure only.

The verifier should be a different model. Same-model review has anchoring bias; the reviewer shares the implementor's blind spots. Cross-model review catches things neither catches alone.

I've been doing this manually for a long time; copying plans from Codex to Claude, pasting output back for review, feeding feedback in, repeating. It produces noticeably better code than either model alone. But it's ~6 copy-paste steps per round and you have to babysit the whole loop. This plugin automates it.

## Dependencies

- [codex-plugin-cc](https://github.com/openai/codex-plugin-cc); OpenAI's official plugin (provides the review gate hook infrastructure)
- [Codex CLI](https://github.com/openai/codex) installed and authenticated (`codex login`)
- Claude Code v2.1.34+
- `jq`

## Installation

Inside Claude Code:

```
/plugin marketplace add jul-sh/captain-codex
/plugin install captain-codex@jul-sh-captain-codex
```

## Commands

| Command | Description |
|---------|-------------|
| `/captain-codex <task>` | Full pipeline: plan, implement, review loop |
| `/captain-codex:status` | Current phase, round, review history |
| `/captain-codex:instructions` | View/edit Codex review instructions |
| `/captain-codex:config` | View/edit plugin config |

## Flags

| Flag | Description |
|------|-------------|
| `--plan-only` | Stop after planning; output plan for review |
| `--skip-plan <path>` | Use existing plan file; skip planning |
| `--no-team` | No subagent teams during implementation |
| `--max-rounds <n>` | Cap review iterations (default: 10) |
| `--supervised` | Pause after planning for human approval |

## How It Works

**Planning.** Codex reads the codebase and writes an implementation plan with acceptance criteria. Saved to `tasks/<slug>.md`.

**Implementation.** Claude receives the plan and implements autonomously, maintaining a worklog in the plan file.

**Review loop.** When Claude finishes, a Stop hook fires Codex to review against the acceptance criteria. Rejected; Claude gets feedback and continues. Approved; done. Max rounds exceeded; you decide.

## Configuration

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
