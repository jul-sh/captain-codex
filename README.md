# captain-codex

Use different models for planning, implementation, and review to catch reward hacking and blind spots.

## What It Does

One command. You describe what you want; include ad-hoc instructions for any phase in natural language.

```
captain-codex refactor mac app to enable ios app with code sharing
```

```
captain-codex "refactor auth module. for planning, focus on backwards compat. when implementing, don't touch the database layer. reviewer should be strict about test coverage."
```

The orchestrator runs three phases sequentially in your terminal:

1. **Plan** — Codex reads your codebase and writes a plan file
2. **Implement** — Claude executes the plan autonomously
3. **Review** — Codex reviews the implementation against the plan; if rejected, Claude fixes and Codex re-reviews

You see everything happening live — agent output streams directly to your terminal with full colors and error reporting.

## Why

Coding agents reward-hack. They take shortcuts to look done: skip edge cases, write shallow tests, drift from the plan, and declare victory early. You need review to catch that.

Using a different model for review often helps because different models have different blind spots. Cross-model review catches things a single model is more likely to miss.

This repo packages that loop into a small orchestrator. It is not a platform. It is a shell script calling two CLIs.

The orchestrator does three simple things:

1. Builds prompts from templates and config, writes them to temp files
2. Calls `codex exec` and `claude -p` as subprocesses, piping prompts via stdin
3. Parses the reviewer verdict and either stops or sends rejection feedback back to the implementor

## Architecture

The system is intentionally simple.

### 1. Planning

The orchestrator calls:

```bash
codex exec -o plan-output.md --full-auto - < plan-prompt.md
```

It builds the planning prompt from [`templates/plan-prompt.md`](templates/plan-prompt.md) plus merged config instructions. Codex drafts a plan and saves it to a file, usually under `tasks/<slug>.md`.

The plan file is the contract between agents. Shared state should be explicit and inspectable, not implicit in one model's hidden conversation state.

### 2. Implementation

The orchestrator calls:

```bash
claude -p --output-format text --dangerously-skip-permissions < impl-prompt.md | tee impl-output.md
```

The implementation prompt includes the plan contents, implementation instructions from config, and optional ad-hoc instructions. The template lives in [`templates/implement-prompt.md`](templates/implement-prompt.md).

Claude is told to execute autonomously and maintain a `## Worklog` section in the plan file. This gives the reviewer more than a final diff — it exposes what Claude thought it was doing, what it skipped, and whether it pushed back on the plan.

### 3. Review Loop

The orchestrator calls `codex exec` with a review prompt built by [`scripts/review-prompt.sh`](scripts/review-prompt.sh). That prompt includes:

- the full plan
- the extracted `## Worklog`
- review instructions from config

The review template is [`templates/review-prompt.md`](templates/review-prompt.md), and it requires an explicit output contract:

```text
VERDICT: APPROVE
```

or

```text
VERDICT: REJECT
```

If Codex rejects, the orchestrator extracts the feedback from the review output and sends it back to Claude. This repeats until approval or `max_rounds` is exceeded.

## Installation

Dependencies:

- `codex`
- `claude`
- `jq`

Clone this repo somewhere stable and put the entrypoint on your `PATH`:

```bash
git clone https://github.com/jul-sh/captain-codex.git
cd captain-codex
ln -sf "$PWD/captain-codex" ~/.local/bin/captain-codex
```

Then run `captain-codex` from the repository you actually want to modify, not from this repo. The working directory is where plan files, project config, and run state are created.

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
- temporary prompt files under `/tmp/captain-codex-<pid>/` (cleaned up on exit)

The state file tracks:

- current phase
- current review round
- max rounds
- plan file path
- review history

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

- `--supervised` pauses after planning and after each review verdict so a human can gate the loop.
- The current timeout default lives in [`scripts/helpers.sh`](scripts/helpers.sh): `PHASE_TIMEOUT=2700` (45 minutes).
- Review verdict extraction depends on the reviewer emitting the exact `VERDICT: APPROVE` or `VERDICT: REJECT` strings.

## License

MIT
