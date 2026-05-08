# tmux-codex-chat

A Claude Code skill that sends a prompt to the [OpenAI Codex CLI](https://developers.openai.com/codex/cli) running in another **tmux pane**, then captures Codex's answer via Codex's `Stop` hook — no UI-string polling. Because completion detection is event-driven, the skill responds within ~0.3 s of Codex finishing, and survives Codex UI changes.

> The skill spans two CLIs: the *skill body* runs inside Claude Code, but the *completion signal* comes from a hook that lives on the Codex side. Plugin manifests can't reach across CLIs, so the Codex-side install is two manual steps: copy one shell script, and add one entry to `~/.codex/hooks.json`. See [Install](#install).

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

## Install

### 1. Install the Claude Code plugin

```text
/plugin marketplace add itouuuuuuuuu/claude-plugins
/plugin install tmux-codex-chat@itouuuuuuuuu-plugins
```

### 2. Copy the Stop hook script into `~/.codex/hooks/`

The plugin cache path is versioned, so resolve it dynamically:

```bash
HOOK_SRC=$(find ~/.claude/plugins/cache -path '*/tmux-codex-chat/*/codex-hook/tmux-codex-chat-stop.sh' -print -quit)
mkdir -p ~/.codex/hooks
cp "$HOOK_SRC" ~/.codex/hooks/tmux-codex-chat-stop.sh
chmod +x ~/.codex/hooks/tmux-codex-chat-stop.sh
```

### 3. Register the Stop hook in `~/.codex/hooks.json`

Add the following entry to the `Stop` array in `~/.codex/hooks.json`. If the file does not exist yet, create it with the full content shown:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/<you>/.codex/hooks/tmux-codex-chat-stop.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

> Replace `/Users/<you>` with your actual home directory — Codex does not expand `~` here.

If `hooks.json` already has `Stop` entries, append the inner `{ "hooks": [ … ] }` wrapper to the existing array; do not nest it inside another wrapper.

### 4. Enable hooks in `~/.codex/config.toml`

```toml
[features]
codex_hooks = true
```

### 5. Restart Codex CLI

Codex reads `hooks.json` only once at session start, so kill any running Codex sessions (`/exit` or `Ctrl-D`) and re-launch `codex`.

### 6. Verify

```bash
test -x ~/.codex/hooks/tmux-codex-chat-stop.sh && echo "hook script: OK"
jq '.hooks.Stop' ~/.codex/hooks.json
grep -E '^\s*codex_hooks\s*=\s*true' ~/.codex/config.toml && echo "codex_hooks: OK"
```

All three should report cleanly. If any do, fix the corresponding step above and restart Codex.

## Update

`/plugin update` only refreshes the Claude Code skill — the Codex-side hook script is a copy under `~/.codex/hooks/`, so re-copy it whenever the plugin's bundled version changes:

```text
/plugin update tmux-codex-chat@itouuuuuuuuu-plugins
```

```bash
HOOK_SRC=$(find ~/.claude/plugins/cache -path '*/tmux-codex-chat/*/codex-hook/tmux-codex-chat-stop.sh' -print -quit)
cp "$HOOK_SRC" ~/.codex/hooks/tmux-codex-chat-stop.sh
chmod +x ~/.codex/hooks/tmux-codex-chat-stop.sh
```

Then restart Codex.

## Uninstall

1. Edit `~/.codex/hooks.json` and remove the entry whose `command` ends in `tmux-codex-chat-stop.sh`.
2. Remove the hook script:

   ```bash
   rm ~/.codex/hooks/tmux-codex-chat-stop.sh
   ```

3. Restart Codex so it drops the now-missing hook from memory.
4. Optionally remove the Claude Code plugin:

   ```text
   /plugin uninstall tmux-codex-chat@itouuuuuuuuu-plugins
   ```

The runtime directory `/tmp/codex-chat-$UID` is left in place; remove it manually if desired.

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

### Skill silently times out, never sees Codex finish

Re-run the [Verify](#6-verify) commands. Most causes:

- `~/.codex/hooks.json` lacks the Stop entry (step 3 missed).
- `codex_hooks = true` not set in `~/.codex/config.toml` (step 4 missed).
- Codex CLI was started **before** you finished steps 3–4 (it reads `hooks.json` only at boot — restart it).

### Hook script differs from plugin source after `/plugin update`

Re-copy the script per the [Update](#update) section. The Stop hook executes the *installed* `~/.codex/hooks/tmux-codex-chat-stop.sh`, which doesn't auto-sync with the plugin cache.

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
mkdir -p ~/.codex/hooks
cp "$PWD/claude-plugins/plugins/tmux-codex-chat/codex-hook/tmux-codex-chat-stop.sh" \
   ~/.codex/hooks/tmux-codex-chat-stop.sh
chmod +x ~/.codex/hooks/tmux-codex-chat-stop.sh
```

Then continue from [step 3](#3-register-the-stop-hook-in-codexhooksjson) (register the Stop entry, set `codex_hooks = true`, restart Codex). To update, `git pull` and re-run the `cp` command.

## License

[MIT](../../LICENSE) © Masafumi Ito
