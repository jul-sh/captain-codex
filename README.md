# captain-codex

Claude Code plugin that puts Codex in charge. Codex plans, Claude implements, Codex reviews; loop until Codex is satisfied.

## What It Does

One command. You describe what you want; include ad-hoc instructions for any phase in natural language.

```
/captain-codex refactor mac app to enable ios app with code sharing
```

```
/captain-codex refactor auth module. for planning, focus on backwards compat. when implementing, don't touch the database layer. reviewer should be strict about test coverage.
```

Ad-hoc instructions are merged with your configured defaults for each phase.

## Why

Claude is a strong implementor; fast, creative, good across large codebases. But it reward-hacks. It takes shortcuts to look done: skips edge cases, writes tests that pass without verifying behavior, deviates from plans when compliance is hard, declares victory early. You need a separate verifier.

Codex is better at architectural reasoning; cleaner module boundaries, more principled dependency graphs. The verifier should be a different model than the implementor. Same-model review has anchoring bias; the reviewer shares the implementor's blind spots. Cross-model review catches things neither catches alone.

I've been doing this manually for a long time; copying plans from Codex to Claude, pasting output back for review, feeding feedback in, repeating. It produces noticeably better code than either model alone. But you have to babysit the whole loop. This plugin automates it.

## Dependencies

- [Codex CLI](https://github.com/openai/codex) installed and authenticated (`codex login`)
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated (`gh auth login`)
- Claude Code v2.1.34+
- `jq`

## Installation

This plugin is available through the [jul-sh Claude Code plugin marketplace](https://github.com/jul-sh/claude-plugins).

### Add the marketplace:
```
/plugin marketplace add jul-sh/claude-plugins
```

### Install the plugin:
```
/plugin install captain-codex@jul-sh
```

## Commands

| Command | Description |
|---------|-------------|
| `/captain-codex <task>` | Full pipeline: plan, implement, review loop |
| `/captain-codex:status` | Current phase, round, review history |
| `/captain-codex:instructions` | View/edit plan, implementation, and review instructions |
| `/captain-codex:config` | View/edit plugin config |

Flags: `--skip-plan <path>`, `--max-rounds <n>`, `--supervised`.

## How It Works

**Planning.** Codex reads the codebase and writes an implementation plan. Saved to `tasks/<slug>.md` and posted as a GitHub issue. Reviews happen in the same Codex session, so Codex retains full context of the plan it wrote.

**Implementation.** Claude receives the plan and implements autonomously on a dedicated branch, maintaining a worklog in the plan file. Once done, a PR is created linking the issue.

**Review loop.** Codex reviews the PR diff and posts its verdict as a GitHub PR review. Rejected with changes requested; Claude gets the feedback, pushes fixes, and the review repeats. Approved; done. Max rounds exceeded; you decide.

**Supervised mode.** `--supervised` pauses after planning and after each review round for human approval.

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
