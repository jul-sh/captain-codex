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
/captain-codex:config codex.reasoning_effort xhigh
/captain-codex:config max_rounds 15
/captain-codex:config defaults.supervised true
```

## Behavior

### View (no arguments)

1. Read config via `scripts/config.sh read`.
2. Display all configuration in a readable format:

   ```
   ## captain-codex Configuration

   ### Codex Settings
   - **model:** gpt-5.4
   - **reasoning_effort:** xhigh
   - **plan_model:** (default)
   - **review_model:** (default)

   ### Plans
   - **directory:** tasks
   - **filename_template:** {{slug}}.md

   ### Defaults
   - **max_rounds:** 10
   - **supervised:** false
   - **allow_teams:** true

   ### Acceptance Criteria
   1. Production ready
   2. Integration tests passing and covering new code paths
   3. ...

   ### Implementation Instructions
   1. Work autonomously until fully complete
   2. ...

   ### Review Instructions
   1. Maximally principled architecture; no expedient shortcuts
   2. ...

   **Config source:** ~/.claude-architect/config.json
   **Project override:** .claude-architect/config.json (not found)
   ```

3. Indicate which values come from project-level overrides vs user-level config.

### Set (key + value)

1. Parse the dot-notation key (e.g., `codex.model` → `{"codex": {"model": ...}}`).
2. Write via `scripts/config.sh write <key> <value>`.
3. Confirm the change:
   ```
   Set codex.model = "gpt-5.4"
   ```

**Supported keys:**
- `codex.model`, `codex.reasoning_effort`, `codex.plan_model`, `codex.review_model`
- `plans.directory`, `plans.filename_template`
- `max_rounds`
- `defaults.supervised`, `defaults.allow_teams`
- For array values (acceptance_criteria, implementation_instructions, review_instructions), use the dedicated `/captain-codex:instructions` command or edit the config file directly.
