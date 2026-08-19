# Changelog — herdr-pane-chat

## [1.1.0] — 2026-08-19

Rewritten against the herdr 0.8.0 CLI. The 1.0.0 instructions were verified against 0.7.4 and no longer work.

- `herdr agent send` + `herdr pane send-keys <pane> enter` replaced by `herdr agent prompt <target> <text> --wait --timeout <ms>`, which writes, submits, and waits for a settled state in one call. The guarded-Enter pattern and the manual poll loop are gone, and with them the composer/Enter race the old flow could only mitigate best-effort.
- `herdr agent wait --status` renamed to `--until` (repeatable).
- `herdr agent read` now returns plain text; the old `jq -r '.result.read.text'` extraction produced a parse error.
- Documented that **every herdr CLI command exits 0 even on failure**, returning `{"error":{...}}` on stdout. Results are now checked for `.error` instead of an exit code — the removed 0.7.x commands print their usage block and still exit 0, so a stale call looks like it succeeded.
- The pre-send readiness check is now mandatory rather than an optimization: `--wait` does not track turns, so prompting an already-`working` agent can settle on its previous turn and return the wrong answer.
- Resume after `blocked` / `timeout` / `agent_prompt_stalled` uses `herdr agent wait`; the prompt is still never re-sent.
- Added a note that user shells alias short command names to unrelated tools (`tr` → `eza` observed in the wild), so builtins, parameter expansion, or absolute paths are preferred.
- Requires herdr 0.8.0 or newer.

## [1.0.0] — 2026-07-22

Initial release.

- One-shot prompt → answer round-trips with an AI agent (Claude Code, Codex, or any agent herdr detects) in another herdr pane.
- Completion detection via herdr's native agent-status tracking (`working` → `done`/`idle`) — no hooks, no markers, no UI-string polling.
- Candidate discovery via `herdr agent list`, scoped to the current workspace (`$HERDR_WORKSPACE_ID`) with the invoking pane (`$HERDR_PANE_ID`) excluded; ≥2 candidates ask the user, 0 candidates report and stop — the skill never auto-starts an agent.
- Two send paths: direct single-line `herdr agent send` restricted to shell-safe text, or a prompt file in a fresh per-run `mktemp -d` directory (mode 700, symlink-proof), written via the Write tool so the body never passes through shell parsing.
- Every `enter` keystroke is guarded by a status re-check immediately beforehand; `blocked` (approval dialog) is surfaced to the user — the skill never knowingly presses keys on the target's dialogs (best-effort, documented as such).
- Completion is correlated with the request: the `working` transition is confirmed after submit, and the answer is extracted after an explicit boundary (the unique per-run prompt-file path). `unknown`/empty statuses and CLI failures fail closed.
- 5-minute default deadline, extendable for heavy tasks; resume after `blocked`/`timeout` re-enters the wait loop only and never re-sends the prompt.
- Command behavior verified live against herdr (send does not submit; the submit key name is lowercase `enter`; completion status is `done`; `agent wait --status idle` also resolves on `done`).
