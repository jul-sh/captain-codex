# Agent Architecture

captain-codex coordinates two agent CLIs:

- **Codex** (`codex exec`): planning and code review
- **Claude** (`claude -p`): implementation

Each runs as a one-shot subprocess. By default the orchestrator dispatches them into named zellij panes via per-pane fifos so the user can watch both agents live and Ctrl-C either of them. With `--no-zellij`, the agents run as direct subprocesses inheriting the orchestrator's TTY.

Either way: the orchestrator builds a prompt file, hands it to the agent on stdin, captures the agent's output, and parses the verdict. The review loop continues until Codex outputs `VERDICT: APPROVE` (matched anchored to a line start) or `MAX_ROUNDS` is exceeded.
