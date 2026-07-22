# Changelog — herdr-pane-chat

## [1.0.0] — 2026-07-22

Initial release.

- One-shot prompt → answer round-trips with an AI agent (Claude Code, Codex, or any agent herdr detects) in another herdr pane.
- Completion detection via herdr's native agent-status tracking (`working` → `done`/`idle`) — no hooks, no markers, no UI-string polling.
- Candidate discovery via `herdr agent list`, scoped to the current workspace (`$HERDR_WORKSPACE_ID`) with the invoking pane (`$HERDR_PANE_ID`) excluded; ambiguity (≥2 or 0 candidates) always asks the user, zero candidates never auto-starts an agent.
- Two send paths: direct single-line `herdr agent send` + `pane send-keys enter`, or a private prompt file under `/tmp/herdr-pane-chat-$UID/` (mode 700) for long/multi-line/code prompts.
- `blocked` (approval dialog) is surfaced to the user; the skill never presses keys on the target's dialogs.
- 5-minute default deadline, extendable for heavy tasks; timeouts and interrupted runs resume safely because no per-request state exists.
- Command behavior verified live against herdr (send does not submit; the submit key name is lowercase `enter`; completion status is `done`; `agent wait --status idle` also resolves on `done`).
