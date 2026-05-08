# tmux-codex-chat

A Claude Code skill that sends a prompt to the [OpenAI Codex CLI](https://developers.openai.com/codex/cli) running in another **tmux pane**, then captures Codex's answer via Codex's `Stop` hook — no UI-string polling. Because completion detection is event-driven, the skill responds within ~0.3 s of Codex finishing, and survives Codex UI changes.

> The skill spans two CLIs: the *skill body* runs inside Claude Code, but the *completion signal* comes from a hook that lives on the Codex side. Plugin manifests can't reach across CLIs, so the Codex-side install is handled by [`scripts/install-codex-hook.sh`](scripts/install-codex-hook.sh).

## How it works

1. Claude Code generates a fresh `REQ=<uuid>` and creates a pending sentinel at `/tmp/codex-chat-$UID/pending-<REQ>`.
2. The skill injects `[CODEX_CHAT_REQ:<uuid>]` into the prompt and sends it to the target tmux pane.
3. When Codex ends the turn, its `Stop` hook (`tmux-codex-chat-stop.sh`) reads the latest user message from the transcript, finds the marker, and — only if the matching pending file exists — atomically writes `/tmp/codex-chat-$UID/done-<REQ>.json` with the assistant's reply.
4. Claude Code blocks on the existence of that file (cheap `stat` poll at 0.3 s) and reads `last_assistant_message`.
5. Approval dialogs are watched in parallel via a low-frequency capture-pane loop, since Codex doesn't fire `Stop` while paused on one.

Design guarantees (encoded in the hook + skill):

- **Pending-file gate**: stale markers in older transcript turns can never overwrite a fresh request.
- **Latest-user-message-only extraction**: `jq -rs` filters by `role: "user"` in `response_item` so assistant quotes / tool output / earlier requests are ignored.
- **Strict UUID regex**: `[0-9a-fA-F]{8}-{4}-{4}-{4}-{12}` only.
- **Per-user `$RUNDIR` (mode 700, ownership-checked, symlink-rejected)**: prompts and answers stay private to the running user.
- **`stop_hook_active=true` no-op**: blocking Stop hooks don't trigger spurious done-files.

## Prerequisites

- macOS or Linux with `tmux`
- [Claude Code](https://www.claude.com/product/claude-code) CLI
- [OpenAI Codex CLI](https://developers.openai.com/codex/cli) **v0.128 or newer** (Stop hook support)
- `jq` on `PATH`
- `codex_hooks = true` set under `[features]` in `~/.codex/config.toml`

## Install

### 1. Install the Claude Code plugin

```text
/plugin marketplace add itouuuuuuuuu/claude-plugins
/plugin install tmux-codex-chat@claude-plugins
```

### 2. Install the Codex side (hook script + `hooks.json` entry)

The plugin cache path is versioned, so locate the installer first:

```bash
INSTALLER=$(find ~/.claude/plugins/cache -path '*/tmux-codex-chat/*/scripts/install-codex-hook.sh' -print -quit)
echo "$INSTALLER"
bash "$INSTALLER"
```

The installer is **idempotent** and **non-destructive**: it backs up `~/.codex/hooks.json` before merging, refuses if the file is a symlink or malformed, and stages both replacement files before any production rename.

### 3. Restart Codex CLI

Codex reads `hooks.json` only once at session start, so kill any running Codex sessions (`/exit` or `Ctrl-D`) and re-launch `codex`.

### 4. Verify

```bash
bash "$INSTALLER" --check   # 6-item health report; never writes
```

A healthy install shows `[OK]` for all items and an `[INFO]` line about the Codex restart timing.

## Update

When the plugin publishes a new version, `/plugin update` only refreshes the Claude Code skill. The Codex-side hook script needs an explicit re-install:

```text
/plugin update tmux-codex-chat@claude-plugins
```

then

```bash
INSTALLER=$(find ~/.claude/plugins/cache -path '*/tmux-codex-chat/*/scripts/install-codex-hook.sh' -print -quit)
bash "$INSTALLER" --install   # idempotent; re-syncs hook script + hooks.json entry
```

then restart Codex.

## Uninstall

Run **before** removing the plugin (otherwise `--uninstall` can't find the source script for SHA verification):

```bash
INSTALLER=$(find ~/.claude/plugins/cache -path '*/tmux-codex-chat/*/scripts/install-codex-hook.sh' -print -quit)
bash "$INSTALLER" --uninstall
```

```text
/plugin uninstall tmux-codex-chat@claude-plugins
```

Restart Codex to pick up the cleaned `hooks.json`.

`--uninstall` removes the hook script only when its SHA-256 matches the version shipped with the plugin — a hand-edited override is preserved with a `[WARN]` so you can decide whether to keep it.

## Usage

In Claude Code, invoke the skill with a request to "ask codex" / "have codex review X":

```text
/tmux-codex-chat                 ← model-invoked when phrasing matches
```

or just say things like:

- 「別 pane の codex に <X> をレビューさせて」
- "ask codex about this design"
- "%14 の codex に意見を聞いて"

The skill auto-discovers Codex panes inside the **current tmux session** (other sessions are intentionally ignored), validates idle state, sends the prompt, and returns the captured answer.

## Troubleshooting

### `--check` reports `[FAIL] Stop entry NOT present`

You either skipped the Codex-side install or didn't restart Codex after running it. Re-run the installer and restart Codex.

### `--check` reports `[WARN] hook script differs from plugin source`

You ran `/plugin update` but didn't re-run `bash "$INSTALLER" --install`. The Stop hook executes the *installed* `~/.codex/hooks/tmux-codex-chat-stop.sh`, which is no longer in sync with the plugin's bundled version.

### Skill returns "TIMEOUT after 5 min"

For long reviews (multi-file audits, etc.), increase the deadline in the skill or in your invocation. **Important**: once the timeout fires, the skill removes the pending sentinel to prevent stale-marker replay — meaning Codex finishing later will *not* produce a done-file. Recover the answer from the pane scrollback, or re-invoke with a longer budget.

### Skill returns "APPROVAL DIALOG"

Codex paused on an approval dialog. The skill never presses keys; resolve the dialog yourself in the Codex pane. The skill prints the exact `REQ` and `DONE_FILE` path so you can pick up the answer once Codex finishes (the pending file is intentionally left in place).

### Hook fires but the answer file never appears

Tail `/tmp/codex-chat-$UID/stop-hook.log` — every Stop event is logged with a one-line outcome (`wrote …`, `skip REQ=… (no pending file)`, etc.).

## Manual install (no plugin system)

For users who'd rather not use Claude Code's plugin system:

```bash
git clone https://github.com/itouuuuuuuuu/claude-plugins.git
ln -sf "$PWD/claude-plugins/plugins/tmux-codex-chat/skills/tmux-codex-chat" \
       "$HOME/.claude/skills/tmux-codex-chat"
bash "$PWD/claude-plugins/plugins/tmux-codex-chat/scripts/install-codex-hook.sh"
# then restart Codex
```

`/plugin update` semantics don't apply; pull the repo and re-run the install script when you want to update.

## License

[MIT](../../LICENSE) © Masafumi Ito
