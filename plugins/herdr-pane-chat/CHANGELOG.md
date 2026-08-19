# Changelog — herdr-pane-chat

## [1.1.0] — 2026-08-19

Rewritten against the herdr 0.8.0 CLI. The 1.0.0 instructions were verified against 0.7.4 and no longer work.

- `herdr agent send` + `herdr pane send-keys <pane> enter` replaced by `herdr agent prompt <target> <text> --wait --timeout <ms>`, which writes, submits, and waits for a settled state in one call. The guarded-Enter pattern and the manual poll loop are gone, and with them the composer/Enter race the old flow could only mitigate best-effort.
- `herdr agent wait --status` renamed to `--until` (repeatable).
- `herdr agent read` now returns plain text; the old `jq -r '.result.read.text'` extraction produced a parse error.
- Documented herdr's error contract and gave every response shape an explicit check — `hq` for agent objects (`get` / `prompt --wait` / `wait`), `hrun` for acknowledgements (`send-keys`), an inline check for `agent list`, and plain-text reads for `agent read`. Failures go to **stderr** with a non-zero exit (`1` for API errors carrying `{"error":{...}}`, `2` for a removed subcommand or unknown option carrying a usage block). Piping a herdr call straight into `jq` without redirecting stderr shows an empty stdout and a parse error instead of the actual reason — the obscure way the 1.0.0 flow broke on 0.8.0.
- The pre-send readiness check is now mandatory rather than an optimization: `--wait` does not track turns, so prompting an already-`working` agent can settle on its previous turn and return the wrong answer.
- Resume after `blocked` / `timeout` / `agent_prompt_stalled` uses `herdr agent wait`; the prompt is still never re-sent.
- Added a note that user shells alias short command names to unrelated tools (`tr` → `eza` observed in the wild), so builtins, parameter expansion, or absolute paths are preferred.
- A failed `agent list` used to be indistinguishable from an empty one: stderr carried the reason, stdout was empty, and the `jq` filter produced no rows — reported to the user as "no matching agent in this workspace". The call is now checked before its output is read.
- Stall recovery verifies its `send-keys` landed before waiting on the result, instead of waiting on an agent that was never prompted and reporting the timeout as target slowness.
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
