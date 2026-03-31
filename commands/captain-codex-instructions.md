# /captain-codex:instructions

View or edit the review instructions that get injected into Codex's review context.

## Usage

```
/captain-codex:instructions                     # view current
/captain-codex:instructions --edit              # open in editor
/captain-codex:instructions --reset             # restore defaults
```

## Behavior

### View (no flags)

1. Read config via `scripts/config.sh read`.
2. Display the current `review_instructions` array:

   ```
   ## Codex Review Instructions

   These instructions are injected into Codex's context when reviewing implementations.

   1. Maximally principled architecture; no expedient shortcuts
   2. All acceptance criteria in the plan must be met with evidence in the worklog
   3. ...
   ```

3. Also show the source (user-level or project-level config).

### Edit (`--edit`)

1. Read the current review instructions from config.
2. Write them to a temporary file, one instruction per line.
3. Tell the user to edit the instructions:
   ```
   Edit the review instructions below. One instruction per line.
   Delete a line to remove an instruction. Add new lines to add instructions.
   ```
4. Present the instructions for inline editing.
5. After the user confirms, write back via `scripts/config.sh write review_instructions '<json array>'`.

### Reset (`--reset`)

1. Read the default review instructions from `templates/default-config.json`.
2. Write them to config via `scripts/config.sh write review_instructions '<default json array>'`.
3. Confirm:
   ```
   Review instructions reset to defaults.
   ```
