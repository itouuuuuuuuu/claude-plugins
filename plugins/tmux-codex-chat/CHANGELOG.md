# Changelog — tmux-codex-chat

## [1.0.1] — 2026-05-11

Portability fixes from a symmetry review against the mirror skill `tmux-claude-chat` in `itouuuuuuuuu/codex-plugins`, plus an unrelated documentation refresh for the Codex-side install procedure. Behavior on macOS is unchanged.

### Skill (`SKILL.md`)

- UUID generation now falls back through `/usr/bin/uuidgen` → `uuidgen` → `/proc/sys/kernel/random/uuid` → `python3` so the skill runs on Linux out of the box. The previous absolute-path `/usr/bin/uuidgen` was macOS-only despite the README advertising "macOS or Linux".
- Prompt-file template (§4b) builds the header with `printf` and appends the body via a single-quoted heredoc, eliminating the BSD-only `sed -i ''` post-process (GNU `sed -i` rejects the empty backup argument).
- Approval-watcher polling cadence (0.5 s × 20, then 2 s) is now annotated as an intentional asymmetry with the Claude-side mirror skill (which uses a slower 1 s burst).
- `Common commands` table's `Generate REQ` row updated to reflect the fallback chain.

### Documentation

- Install / Update / Uninstall guidance now fetches `tmux-codex-chat-stop.sh` directly from the GitHub repository via `curl`, instead of copying out of the versioned `~/.claude/plugins/cache` path. Users can re-run the same `curl` command to update without resolving the cache location.
- `hooks.json` examples now use `$HOME/.codex/hooks/tmux-codex-chat-stop.sh` (expanded at command invocation time) in place of literal `/Users/<you>/…` paths.
- Uninstall section's "diff before remove" check now compares against the raw GitHub source rather than the plugin cache.

## [1.0.0] — 2026-05-08

Initial public release. Carries forward the local v3 design that was iterated on with multiple rounds of [Codex CLI](https://developers.openai.com/codex/cli) self-review.

### Skill (`SKILL.md`)

- Hook-driven completion detection — no UI-string polling.
- `[CODEX_CHAT_REQ:<uuid>]` injected into both direct-send (≤500-char ASCII) and file-send (heredoc) prompts.
- Pending-file gate at `/tmp/codex-chat-$UID/pending-<uuid>` ensures stale markers cannot overwrite an in-flight request.
- Approval-dialog watcher with burst polling (0.5 s × 20, then 2 s).
- Approval / timeout branches surface `REQ` and `DONE_FILE` paths so users can recover answers from late completions.
- Health-check guidance (`hook_ok` shell function) and explicit "restart Codex after hook install" prerequisite.

### Codex hook (`tmux-codex-chat-stop.sh`)

- `jq -rs` extracts the marker only from the **latest user message** (`response_item` with `role: "user"`), so assistant quotes / tool output / older requests are structurally ignored.
- Strict UUID regex (`{8}-{4}-{4}-{4}-{12}`) plus a defensive `case` re-validation.
- Per-user `$RUNDIR = /tmp/codex-chat-$UID` (mode 700, ownership-checked, **symlink-rejected**).
- Atomic write via `mktemp` + `mv`.
- `stop_hook_active=true` is a no-op (avoids spurious done-files when other Stop hooks continue the agentic loop).

### Codex-side install: manual `cp` + one `hooks.json` edit

The Codex side is installed by hand (documented in [README](README.md#install)):

1. `cp` the bundled `codex-hook/tmux-codex-chat-stop.sh` into `~/.codex/hooks/`.
2. Add a `Stop` entry pointing at it in `~/.codex/hooks.json`.
3. Ensure `hooks = true` under `[features]` in `~/.codex/config.toml` (the older `codex_hooks` key is deprecated).
4. Restart Codex (it reads `hooks.json` only at session start).

This was deliberately kept as a documented manual procedure rather than an installer script: editing user-owned `~/.codex/hooks.json` programmatically carries non-trivial risk (symlinked dotfiles, malformed pre-existing config, racing edits) and the maintenance cost of a defensive installer outweighs the convenience for a one-time, two-step setup.
