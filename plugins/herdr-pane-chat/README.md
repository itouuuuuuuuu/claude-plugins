# herdr-pane-chat

A Claude Code skill that sends a prompt to an AI coding agent — Claude Code, [OpenAI Codex CLI](https://developers.openai.com/codex/cli), or anything else [herdr](https://herdr.dev) detects — running in **another herdr pane**, waits for the answer, and reports it back.

Unlike the tmux-based sibling ([`tmux-codex-chat`](../tmux-codex-chat/)), this skill needs **no hooks, no markers, and no UI-string polling**: herdr tracks each pane's agent identity and status (`idle` / `working` / `blocked` / `done`) natively, so completion is detected by a plain status transition over herdr's socket API.

## How it works

1. Guard: the skill only runs inside a herdr session (`HERDR_ENV=1`).
2. Discover: `herdr agent list` is filtered to the **current workspace** (`$HERDR_WORKSPACE_ID`); the invoking pane (`$HERDR_PANE_ID`) is excluded. One candidate → used directly; multiple → the user is asked; zero → reported and stopped. The skill never starts an agent on its own.
3. Send: `herdr agent send` writes the prompt into the target's composer, then `herdr pane send-keys <pane> enter` submits (with a status re-check immediately before the keystroke). Anything long, multi-line, or containing code/quotes is written — without passing through the shell — to a fresh private `mktemp -d` directory (mode 700) and referenced by path instead.
4. Wait: the skill first confirms the `working` transition (correlating completion with *this* request), then polls `herdr agent get` until the status becomes `done`/`idle` (answered) or `blocked` (approval dialog — surfaced to the user; the skill never knowingly presses keys on the target's dialogs, best-effort since no atomic submit API exists). Unknown statuses and CLI failures fail closed. Default deadline is 5 minutes.
5. Read: `herdr agent read --source recent-unwrapped` returns clean, unwrapped scrollback; the answer is extracted after an explicit request boundary (the unique per-run prompt-file path) and reported.

One invocation = one prompt → one answer. Follow-up questions are new invocations. Timeouts and interrupted runs resume by re-entering the wait loop only — the prompt is never re-sent.

## Prerequisites

- [herdr](https://herdr.dev) — the session must run inside it
- [Claude Code](https://www.claude.com/product/claude-code) CLI
- `jq` on `PATH`
- A target agent already running in another pane of the same workspace

## Install

```text
/plugin marketplace add itouuuuuuuuu/claude-plugins
/plugin install herdr-pane-chat@itouuuuuuuuu-plugins
```

Then restart Claude Code or run `/reload-plugins`. No target-side setup is required.

## Usage

Just ask, in a herdr session with the target agent visible in the same workspace:

- 「codex に確認して」
- 「別のペインの claude に確認して」
- 「codex にレビューしてもらって」
- "ask codex about this design"
- "have the other claude review this diff"

The skill discovers the target pane, sends the prompt, waits for completion, and reports the answer.

## Troubleshooting

### "Not inside a herdr session"

The skill requires `HERDR_ENV=1` in the environment — run Claude Code inside a herdr pane.

### No candidates found

Only agents in the **same workspace** are eligible, and the invoking pane never counts. Open or move the target agent into the current workspace, or switch to its workspace and re-ask.

### The run reports `blocked`

The target agent paused on an approval dialog. Resolve it in that pane yourself (the skill intentionally never presses keys there), then ask Claude to check the answer again — it resumes cleanly.

### Timeout on long tasks

The default deadline is 5 minutes. For heavy reviews, ask again with a longer budget (e.g. "wait up to 15 minutes") — resuming is safe because it only re-enters the wait loop; the prompt is never re-sent.

## Manual install (no plugin system)

```bash
git clone https://github.com/itouuuuuuuuu/claude-plugins.git
ln -sf "$PWD/claude-plugins/plugins/herdr-pane-chat/skills/herdr-pane-chat" \
       "$HOME/.claude/skills/herdr-pane-chat"
```

## License

[MIT](../../LICENSE) © Masafumi Ito
