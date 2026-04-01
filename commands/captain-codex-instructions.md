---
description: "View or edit plan, implementation, and review instructions."
---

# /captain-codex:instructions

View or edit the instructions injected into each phase's prompt.

## Usage

```
/captain-codex:instructions                          # view all
/captain-codex:instructions plan                     # view plan instructions
/captain-codex:instructions plan --edit              # edit plan instructions
/captain-codex:instructions implementation --edit    # edit implementation instructions
/captain-codex:instructions review --edit            # edit review instructions
/captain-codex:instructions <phase> --reset          # restore defaults for a phase
```

## Behavior

The three instruction sets map to the three prompt templates:
- `plan_instructions` → `templates/plan-prompt.md`
- `implementation_instructions` → `templates/implement-prompt.md`
- `review_instructions` → `templates/review-prompt.md`

### View (no flags, or phase without flags)

1. Read config via `scripts/config.sh read`.
2. If no phase specified, display all three instruction sets.
3. If a phase is specified, display just that one.
4. Also show the source (user-level or project-level config).

### Edit (`--edit`)

1. Read the current instructions for the specified phase from config.
2. Present the instructions for inline editing, one instruction per line.
3. After the user confirms, write back via `scripts/config.sh write <key> '<json array>'`.

### Reset (`--reset`)

1. Read the default instructions for the specified phase from `templates/default-config.json`.
2. Write them to config via `scripts/config.sh write <key> '<default json array>'`.
3. Confirm the reset.
