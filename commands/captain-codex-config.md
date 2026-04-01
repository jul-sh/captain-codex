# /captain-codex:config

View or edit plugin configuration.

## Usage

```
/captain-codex:config                           # view all config
/captain-codex:config <key> <value>             # set a config value
```

## Examples

```
/captain-codex:config codex.model gpt-5.4
/captain-codex:config max_rounds 15
```

## Behavior

### View (no arguments)

1. Read config via `scripts/config.sh read`.
2. Display all configuration in a readable format, including codex settings, plan settings, max_rounds, and the three instruction sets.
3. Indicate which values come from project-level overrides vs user-level config.

### Set (key + value)

1. Parse the dot-notation key (e.g., `codex.model` → `{"codex": {"model": ...}}`).
2. Write via `scripts/config.sh write <key> <value>`.
3. Confirm the change.

**Supported keys:**
- `codex.model`, `codex.reasoning_effort`, `codex.plan_model`, `codex.review_model`
- `plans.directory`, `plans.filename_template`
- `max_rounds`
- For array values (plan_instructions, implementation_instructions, review_instructions), use `/captain-codex:instructions` or edit the config file directly.
