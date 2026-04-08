# Plan: Create captain-claude Plugin

## Goal

Create a new Claude Code plugin `captain-claude` — a variant of `captain-codex` where Claude (via `claude -p`) handles **all three phases**: planning, implementation, and review. Same model throughout. No Codex dependency.

## Key Difference from captain-codex

- `captain-codex`: Codex plans → Claude implements → Codex reviews
- `captain-claude`: Claude plans → Claude implements → Claude reviews (all via `claude -p`)

The value proposition shifts from cross-model verification to automated self-review with a structured plan/implement/review loop — still useful because the planner and reviewer operate in separate sessions with different prompts and system instructions than the implementor.

## Step 1: Create the new repo

1. Create directory `/Users/julsh/git/captain-claude`
2. `git init`
3. Copy the directory structure from captain-codex: `commands/`, `hooks/`, `scripts/`, `templates/`, `.claude-plugin/`, `.github/`, `AGENTS.md`, `CLAUDE.md` (symlink), `LICENSE`, `README.md`

## Step 2: Update `.claude-plugin/plugin.json`

```json
{
  "name": "captain-claude",
  "version": "0.1.0",
  "description": "Claude plans, Claude implements, Claude reviews. One command."
}
```

## Step 3: Update `templates/default-config.json`

Replace the `codex` config block with a `claude` config block:

```json
{
  "claude": {
    "model": "sonnet",
    "plan_model": null,
    "review_model": null
  },
  "plans": {
    "directory": "tasks",
    "filename_template": "{{slug}}.md"
  },
  "max_rounds": 10,
  "plan_instructions": [...same...],
  "implementation_instructions": [...same...],
  "review_instructions": [...same...]
}
```

Remove `reasoning_effort` (Codex-specific). The `model` field takes Claude model names (e.g., `sonnet`, `opus`, `claude-sonnet-4-6`).

## Step 4: Update `scripts/config.sh`

- Rename config dir from `.claude-architect` to `.captain-claude` (to avoid conflicts if both plugins installed)
  - `USER_CONFIG="$HOME/.captain-claude/config.json"`
  - `PROJECT_CONFIG=".captain-claude/config.json"`
  - `STATE_FILE=".captain-claude/state.json"`
- Update `init_state` — same structure, no changes needed beyond paths

## Step 5: Update `scripts/plan.sh`

This is the biggest change. Replace `codex exec` calls with `claude -p` calls.

The `claude` CLI usage for non-interactive planning:
```bash
claude -p "prompt text" --model <model> --output-format json
```

Key changes:
1. Read `claude.plan_model // claude.model` instead of `codex.plan_model // codex.model`
2. Remove `reasoning_effort` references
3. Replace `codex exec -m ... --json` with `claude -p "..." --model ... --output-format stream-json`
4. For session resuming (call 2), claude CLI supports `--resume` or `--continue` flags. Use `claude -p "..." --model ... --continue` to resume the session. Check the actual claude CLI flags — the session continuation approach may differ from codex.
5. Parse output differently — claude CLI JSON output has different event structure than codex
6. Extract session ID from claude output (look for `session_id` in the JSON stream)
7. Output same format: `<plan_path>\t<session_id>`

**Important**: The `claude` CLI's `--continue` flag continues the most recent conversation in the current directory. For explicit session resuming, use `--session-id <id>`. Check `claude --help` for exact flags.

Actually, simpler approach: since `claude -p` with `--output-format stream-json` outputs JSON events, we can:
- Call 1: Plan the task, capture session ID from output
- Call 2: Resume with `--session-id <id>` to formalize and write the plan file

## Step 6: Update `scripts/review-prompt.sh`

- Update `STATE_FILE` path to `.captain-claude/state.json`
- Everything else stays the same (it just builds a prompt string, doesn't call any CLI)

## Step 7: Update `hooks/review-gate.sh`

Replace `codex exec` / `codex exec resume` with `claude -p` / `claude -p --session-id`:

1. Change `STATE_FILE` to `.captain-claude/state.json`
2. Read `claude.review_model // claude.model` instead of codex equivalents
3. Remove `reasoning_effort` config reading
4. Replace `codex_cmd` construction:
   ```bash
   claude_cmd=(claude -p --model "$claude_model" --output-format text)
   if [[ -n "$session_id" ]]; then
     claude_cmd+=(--session-id "$session_id")
   fi
   ```
5. Execute: `echo "$review_prompt" | "${claude_cmd[@]}"`
6. Parse verdict same way (grep for VERDICT: APPROVE)

## Step 8: Update `hooks/hooks.json`

Same structure, just references the local hook path (uses `${CLAUDE_PLUGIN_ROOT}` so no change needed).

## Step 9: Update all command files

### `commands/captain-claude.md`
- Rename from captain-codex references
- Update description: "Claude plans, Claude implements, Claude reviews until satisfied."
- Replace all `captain-codex` references with `captain-claude`
- Replace `.claude-architect` references with `.captain-claude`
- Remove codex dependency mentions

### `commands/captain-claude-status.md`
- Same structure, rename references
- Remove `/codex:status` reference (replace with session info from state)

### `commands/captain-claude-config.md`
- Replace `codex.model` examples with `claude.model`
- Replace all naming references

### `commands/captain-claude-instructions.md`
- Replace naming references

## Step 10: Update `templates/plan-prompt.md`

No changes needed — it's model-agnostic.

## Step 11: Update `templates/implement-prompt.md`

No changes needed — it's model-agnostic.

## Step 12: Update `templates/review-prompt.md`

No changes needed — it's model-agnostic.

## Step 13: Update `AGENTS.md` / `CLAUDE.md`

```markdown
# captain-claude

Claude Code plugin: Claude plans, Claude implements, Claude reviews.

## Layout
... (same structure)

## Config resolution
`templates/default-config.json` ← `~/.captain-claude/config.json` ← `.captain-claude/config.json`
```

## Step 14: Update `README.md`

- Rebrand entirely for captain-claude
- Update the "Why" section: emphasize that structured plan/implement/review loops with separate sessions and prompts catch issues even with the same model
- Remove Codex CLI dependency
- Update installation instructions for captain-claude
- Update all command references

## Step 15: Update `.github/workflows/bump-version.yml`

Same workflow, no changes needed (it's generic).

## Step 16: Create GitHub repo and push

```bash
cd /Users/julsh/git/captain-claude
gh repo create jul-sh/captain-claude --public --source=. --push
```

## Step 17: Add to marketplace

Update `/Users/julsh/git/claude-plugins/.claude-plugin/marketplace.json`:
```json
{
  "name": "captain-claude",
  "source": {
    "source": "github",
    "repo": "jul-sh/captain-claude"
  }
}
```

Update `/Users/julsh/git/claude-plugins/README.md` to add the new plugin listing.

Commit and push marketplace changes.

## Acceptance Criteria

- [x] New repo at `/Users/julsh/git/captain-claude` with all files
- [x] All `codex exec` calls replaced with `claude -p` equivalents
- [x] Config uses `claude.*` keys instead of `codex.*`
- [x] State directory is `.captain-claude/` (not `.claude-architect/`)
- [x] All command names are `captain-claude`, `captain-claude-status`, etc.
- [x] Plugin published to GitHub as `jul-sh/captain-claude`
- [x] Marketplace updated with the new plugin entry
- [x] No remaining references to "codex" in the new repo (except README cross-reference)
- [x] README accurately describes the plugin's purpose and differences

## Worklog

### Implementation complete

All steps executed:
- Created `/Users/julsh/git/captain-claude` with git init
- Wrote all 19 files: plugin.json, 4 commands, 3 scripts, 2 hooks, 4 templates, AGENTS.md, CLAUDE.md (symlink), LICENSE, README.md, bump-version workflow
- Replaced all `codex exec` with `claude -p`, `--resume` for session continuation
- Config key renamed from `codex.*` to `claude.*`, removed `reasoning_effort`
- State dir changed from `.claude-architect/` to `.captain-claude/`
- Published to GitHub: https://github.com/jul-sh/captain-claude
- Added to marketplace in jul-sh/claude-plugins (marketplace.json + README.md)
