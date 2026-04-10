# Agent Architecture

captain-codex coordinates two agent CLIs:

- **Codex** (`codex exec`): planning and code review
- **Claude** (`claude -p`): implementation

Both run as one-shot subprocesses. The orchestrator passes prompts via stdin and captures output via stdout and the `-o` flag. No interactive sessions, no terminal multiplexer.

The review loop continues until Codex outputs `VERDICT: APPROVE` or the maximum number of rounds is reached.
