# captain-codex

Use different models for planning, implementation, and review to catch reward hacking and blind spots — and watch them work side-by-side.

## What It Does

One command. You describe what you want; ad-hoc instructions for any phase go in natural language.

```
captain-codex refactor mac app to enable ios app with code sharing
```

```
captain-codex "refactor auth module. for planning, focus on backwards compat. when implementing, don't touch the database layer. reviewer should be strict about test coverage."
```

You get attached to a zellij session with three panes:

```
┌─────────────────────┬─────────────────────┐
│                     │                     │
│       Codex         │       Claude        │
│   (planner /        │   (implementer)     │
│    reviewer)        │                     │
│                     │                     │
├─────────────────────┴─────────────────────┤
│                                           │
│   Captain                                 │
│   > task: refactor auth                   │
│   Phase: review (round 2)                 │
│                                           │
└───────────────────────────────────────────┘
```

The orchestrator runs three phases:

1. **Plan** — Codex reads your codebase and writes a plan file (in the codex pane)
2. **Implement** — Claude executes the plan autonomously (in the claude pane)
3. **Review** — Codex reviews against the plan; if rejected, Claude fixes and Codex re-reviews

You see both agents live in their own panes, with full TTY colors and progress. You can Ctrl-C either of them. The captain pane streams orchestrator status and is where supervised-mode prompts appear.

If you don't want a multiplexer, pass `--no-zellij` and everything streams sequentially to your existing terminal.

## Why

Coding agents reward-hack. They take shortcuts to look done: skip edge cases, write shallow tests, drift from the plan, and declare victory early. You need review to catch that.

Using a different model for review often helps because different models have different blind spots. Cross-model review catches things a single model is more likely to miss.

This repo packages that loop into a small orchestrator. It is not a platform. It is shell scripts coordinating two CLIs.

## Architecture

The system has three parts that you can read end-to-end in under 500 lines of bash.

### 1. Entry point

[`captain-codex`](captain-codex) parses flags, validates dependencies, creates a per-run temp directory and named fifos for each agent pane, then spawns a zellij session with the [3-pane layout](templates/zellij-layout.kdl). The session inherits the entry script's environment, so the orchestrator and the per-pane runners all see the same `CAPTAIN_TMP`, task, and flags without any KDL templating.

### 2. Per-pane runner

Each agent pane runs [`scripts/agent-runner.sh`](scripts/agent-runner.sh), which blocks on a named fifo waiting for the orchestrator to dispatch a job. When a TSV line arrives (`prompt-file`, `output-file`, `sentinel-file`), it runs the agent — `codex exec -o ...` or `claude -p ...` — with the prompt as stdin and the output captured to a file. After the agent exits, the runner writes the exit code to the sentinel and goes back to waiting.

Why a fifo and not `zellij action write-chars`? Because typing into a pane that the user might also be typing into produces interleaved garbage. With the fifo model, the pane *is* the runner; user keystrokes during a run go to the foreground agent (Ctrl-C interrupts it) and are harmlessly discarded between runs. The orchestrator never injects characters into the pane.

### 3. Orchestrator

[`scripts/orchestrate.sh`](scripts/orchestrate.sh) runs in the captain pane. It builds prompts from [templates](templates/), writes them to temp files, dispatches each agent invocation through [`scripts/pane.sh`](scripts/pane.sh)'s `pane_dispatch`, polls the sentinel for completion, and parses the verdict. Rejected reviews loop back to Claude with the feedback inlined.

The verdict matcher requires `^VERDICT: APPROVE$` anchored to a line start, so a phrase like *"criteria for VERDICT: APPROVE would be …"* inside a REJECT body doesn't flip the verdict.

## Installation

Dependencies:

- `codex`
- `claude`
- `jq`
- `zellij` (skip if you only ever use `--no-zellij`)

Clone this repo somewhere stable and put the entry point on your `PATH`:

```bash
git clone https://github.com/jul-sh/captain-codex.git
cd captain-codex
ln -sf "$PWD/captain-codex" ~/.local/bin/captain-codex
```

Run `captain-codex` from the repository you want to modify, not from this repo. The working directory is where plan files, project config, and run state are created.

## Usage

Basic:

```bash
captain-codex "refactor auth module for multi-tenant support"
```

With supervision:

```bash
captain-codex "extract the sync engine into a reusable library" --supervised
```

Resume from an existing plan:

```bash
captain-codex --skip-plan tasks/extract-sync-engine.md
```

Limit review rounds:

```bash
captain-codex "add offline queueing" --max-rounds 3
```

Without a multiplexer:

```bash
captain-codex "fix the login bug" --no-zellij
```

Per-phase ad-hoc instructions via environment variables:

```bash
ADHOC_PLAN="optimize for backwards compatibility" \
ADHOC_IMPL="do not touch the database layer" \
ADHOC_REVIEW="be strict about integration tests" \
captain-codex "refactor auth module"
```

## What a Run Produces

By default, a run creates:

- a plan file under `tasks/` using a slugified task description
- a state file at `.claude-architect/state.json`
- temporary prompts, fifos, and sentinels under `$TMPDIR/captain-codex.XXXXXX/` (cleaned up on exit)

The state file tracks current phase, current review round, max rounds, plan file path, and review history.

## Configuration

Config resolution is:

```text
templates/default-config.json
  <- ~/.claude-architect/config.json
  <- .claude-architect/config.json
```

Defaults are overridden by user config, then by project config.

See [`templates/default-config.json`](templates/default-config.json) for the full shape. The main knobs are:

- `codex.model`
- `codex.plan_model`
- `codex.reasoning_effort`
- `plans.directory`
- `plans.filename_template`
- `max_rounds`
- `plan_instructions`
- `implementation_instructions`
- `review_instructions`

## Prompt Surface

The prompts are deliberately small:

- [`templates/plan-prompt.md`](templates/plan-prompt.md)
- [`templates/implement-prompt.md`](templates/implement-prompt.md)
- [`templates/review-prompt.md`](templates/review-prompt.md)

The value is not fancy prompt ornamentation. The value is the control loop:

- explicit plan
- separate implementor
- separate reviewer
- visible state
- iterative rejection until approval

## Operational Notes

- `--supervised` pauses after planning and after each review verdict so you can gate the loop from the captain pane.
- `--no-zellij` runs everything inline in the existing terminal; useful for CI and headless boxes.
- Review verdict extraction requires the reviewer emit `VERDICT: APPROVE` or `VERDICT: REJECT` on a line by itself.
- Don't run `captain-codex` from inside an existing zellij session — pane addressing collides. Detach (Ctrl-q) or pass `--no-zellij`.

## Tests

```bash
./tests/run-tests.sh          # unit tests
./tests/run-tests.sh --all    # + integration tests (mock agents, inline + zellij modes)
```

The zellij integration test drives a real session under a pseudo-tty via [`tests/with-pty.py`](tests/with-pty.py), so it requires `zellij` and `python3` on PATH; it skips automatically if either is missing.

## License

MIT
