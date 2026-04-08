# captain-codex

Zellij-native orchestrator. Codex plans, Claude implements, Codex reviews — each agent in its own tab.

## Why

Coding agents reward-hack. They take shortcuts to look done: skip edge cases, drift from the plan, write shallow tests, and declare victory early. Review helps catch that.

Using a different model for review often helps more. Not because users already have a reviewer, and not because same-model review must share a session. It helps because different models have different blind spots. Cross-model review is one practical way to get less correlated mistakes.

This repo packages that loop into a small zellij-native orchestrator. It is not a platform. It is a shell script driving two interactive CLIs in separate tabs.

## What This Tool Actually Does

`captain-codex` creates a zellij session with three tabs:

- `Captain` tab: the orchestrator ([`scripts/orchestrate.sh`](scripts/orchestrate.sh)), shows status and progress
- `Codex` tab: one persistent interactive Codex session used for both planning and review
- `Claude` tab: one persistent interactive Claude session used for implementation

It always generates a temporary layout from [`templates/zellij-layout.kdl`](templates/zellij-layout.kdl) and hands that layout to zellij. Outside zellij, that starts a fresh session. Inside zellij, zellij adds the same Captain/Codex/Claude layout to the current session.

The orchestrator does four simple things:

1. Starts both agent CLIs in their own tabs.
2. Writes prompts into temporary files under `/tmp/captain-codex-$$/` and tells each agent to read them.
3. Polls each tab with `zellij action dump-screen` until the screen stops changing and the CLI prompt reappears.
4. Parses the reviewer verdict and either stops or sends rejection feedback back to the implementor.

This is terminal automation, not an API integration. That is both the hack and the point. It works with existing CLIs, keeps the full interaction visible, and does not require special support from model providers beyond "can run interactively in a terminal."

## Architecture

The system is intentionally simple.

### 1. Planning

Captain starts Codex in its own tab:

```bash
codex
```

It then builds a planning prompt from [`templates/plan-prompt.md`](templates/plan-prompt.md) plus merged config instructions. Codex drafts a plan, then is explicitly told to formalize it into a delegatable plan file, usually under `tasks/<slug>.md`.

The plan file is the contract between agents. That is important. Shared state should be explicit and inspectable, not implicit in one model's hidden conversation state.

### 2. Implementation

Captain starts Claude in its own tab with:

```bash
claude
```

Then it builds an implementation prompt from:

- the plan file contents
- implementation instructions from config
- optional ad-hoc implementation instructions

The template lives in [`templates/implement-prompt.md`](templates/implement-prompt.md).

Claude is told to execute autonomously and maintain a `## Worklog` section in the plan file. This gives the reviewer more than a final diff. It exposes what Claude thought it was doing, what it skipped, what it changed, and whether it pushed back on the plan.

### 3. Review Loop

Captain builds the review prompt with [`scripts/review-prompt.sh`](scripts/review-prompt.sh). That prompt includes:

- the full plan
- the extracted `## Worklog`
- review instructions from config
- optional ad-hoc review instructions from state

The review template is [`templates/review-prompt.md`](templates/review-prompt.md), and it requires an explicit output contract:

```text
VERDICT: APPROVE
```

or

```text
VERDICT: REJECT
```

If Codex rejects, Captain extracts the review text from the Codex tab's scrollback and sends it back to Claude as the next implementation prompt. This repeats until approval or `max_rounds` is exceeded.

### 4. Polling Instead of Guessing

The orchestration trick is in [`scripts/helpers.sh`](scripts/helpers.sh).

`wait_for_idle` does not try to read model internals. It does something much simpler:

- switch focus to the target tab
- `dump-screen` to a file
- hash the screen
- wait for the hash to stabilize across polls
- check that the tail of the screen matches the CLI's idle prompt regex

For Codex and Claude, the current idle patterns live in [`scripts/orchestrate.sh`](scripts/orchestrate.sh):

```bash
CODEX_IDLE_PATTERN='(^>|╰─>|❯)'
CLAUDE_IDLE_PATTERN='(^>|╰─|❯)'
```

This is crude, but it is also robust enough. The orchestrator is not pretending to have structured semantic access to agent state. It watches the terminal like a human would, just more consistently.

## Why Zellij

Because this kind of workflow wants three properties at once:

- isolation: each agent keeps its own context
- observability: you can watch both agents work in real time
- controllability: the orchestrator can drive both from the outside

A single terminal gives you none of that cleanly. Separate tabs do.

The zellij part matters for another reason: the Codex planning session stays alive into review. That means the reviewer still has the planning context when judging the implementation. This is why `codex.review_model` is currently ignored in zellij mode: there is one persistent Codex session for both phases.

## Installation

Dependencies:

- `zellij`
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

Per-phase ad-hoc instructions are supported, but they are not parsed out of the task string. Pass them explicitly as environment variables:

```bash
ADHOC_PLAN="optimize for backwards compatibility" \
ADHOC_IMPL="do not touch the database layer" \
ADHOC_REVIEW="be strict about integration tests" \
captain-codex "refactor auth module"
```

That point matters because the current code does exactly this and nothing more. There is no natural-language phase parser in the entrypoint.

## What a Run Produces

By default, a run creates:

- a plan file under `tasks/` using a slugified task description
- a state file at `.claude-architect/state.json`
- temporary prompt and screen files under `/tmp/captain-codex-<pid>/`

The state file tracks:

- current phase
- current review round
- max rounds
- plan file path
- zellij session name
- review history

This makes the run externally inspectable. Again, explicit state beats hidden state.

## Configuration

Config resolution is:

```text
templates/default-config.json
  <- ~/.claude-architect/config.json
  <- .claude-architect/config.json
```

So defaults are overridden by user config, then by project config.

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

One subtle point: `codex.review_model` exists in config, but the zellij orchestrator does not use it today because planning and review share one live Codex session for context retention.

## Prompt Surface

The prompts are deliberately small:

- [`templates/plan-prompt.md`](templates/plan-prompt.md)
- [`templates/implement-prompt.md`](templates/implement-prompt.md)
- [`templates/review-prompt.md`](templates/review-prompt.md)

This is intentional. The value here is not fancy prompt ornamentation. The value is the control loop:

- explicit plan
- separate implementor
- separate reviewer
- persistent contexts
- visible state
- iterative rejection until approval

## Operational Notes

- `--supervised` pauses after planning and after each review verdict so a human can gate the loop.
- The current timeout defaults live in [`scripts/helpers.sh`](scripts/helpers.sh): `POLL_INTERVAL=3` and `PHASE_TIMEOUT=2700`.
- Review verdict extraction depends on the reviewer emitting the exact `VERDICT: APPROVE` or `VERDICT: REJECT` strings.
- Idle detection depends on current CLI prompt shapes. If Codex or Claude changes its prompt format, update the regexes in [`scripts/orchestrate.sh`](scripts/orchestrate.sh).

## Limits

This is not trying to be elegant.

It is screen scraping plus prompt files plus shell glue. That means:

- it is more brittle than a true structured API
- it is more inspectable than a true structured API
- it composes with existing CLIs immediately

That tradeoff is fine here.

The thesis of this repo is not "Bash is beautiful." The thesis is that cross-model review is valuable enough that even a slightly ugly orchestration layer is worth building.

## License

MIT
