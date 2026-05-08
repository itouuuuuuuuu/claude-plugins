# Changelog — tmux-codex-chat

## [1.0.0] — 2026-05-08

Initial public release. Carries forward the local v3 design that was iterated on with multiple rounds of [Codex CLI](https://developers.openai.com/codex/cli) self-review.

### Skill (`SKILL.md`)

- Hook-driven completion detection — no UI-string polling.
- `[CODEX_CHAT_REQ:<uuid>]` injected into both direct-send (≤500-char ASCII) and file-send (heredoc) prompts.
- Pending-file gate at `/tmp/codex-chat-$UID/pending-<uuid>` ensures stale markers cannot overwrite an in-flight request.
- Approval-dialog watcher with burst polling (0.5 s × 20, then 2 s).
- Approval / timeout branches surface `REQ` and `DONE_FILE` paths so users can recover answers from late completions.
- 6-item health-check guidance and explicit "restart Codex after hook install" prerequisite.

### Codex hook (`tmux-codex-chat-stop.sh`)

- `jq -rs` extracts the marker only from the **latest user message** (`response_item` with `role: "user"`), so assistant quotes / tool output / older requests are structurally ignored.
- Strict UUID regex (`{8}-{4}-{4}-{4}-{12}`) plus a defensive `case` re-validation.
- Per-user `$RUNDIR = /tmp/codex-chat-$UID` (mode 700, ownership-checked, **symlink-rejected**).
- Atomic write via `mktemp` + `mv`.
- `stop_hook_active=true` is a no-op (avoids spurious done-files when other Stop hooks continue the agentic loop).

### Installer (`scripts/install-codex-hook.sh`)

- Single file with `--install` / `--check` / `--uninstall` subcommands.
- Idempotent: re-running re-syncs the hook script and the Stop entry without duplicating wrappers.
- Refuses if `~/.codex/hooks.json` is a symlink (don't break dotfiles managers).
- Refuses if the existing `hooks.json` is structurally malformed (`.hooks` not object, `.hooks.Stop` not array).
- Stages both replacement files (merged JSON + hook script) before any production rename — disk-full / perm-denied / RO-fs failures surface during staging.
- Rolls hooks.json back from backup if the second rename fails.
- `--check` emits 6 prefixed lines (`[OK] / [WARN] / [FAIL] / [INFO]`) covering jq, Stop entry, hook script, integrity, `codex_hooks=true`, and a Codex restart reminder. Exit non-zero if any `[FAIL]`.
- `--uninstall` removes the hook script only when its SHA-256 matches the shipped source (preserves user overrides).
- `hash_file()` falls back between `shasum -a 256` (macOS) and `sha256sum` (Linux).
- All filesystem mutations use absolute paths (`/bin/cp`, `/bin/mv`, `/bin/rm`) to avoid alias surprises.
- Backup names include `$$-$RANDOM` to avoid timestamp collisions on back-to-back runs.

### Tests (`tests/install-codex-hook-fixtures.sh`)

12 black-box scenarios, all isolated to throwaway `mktemp` HOMEs:

- Fresh install creates skeleton, copies hook, registers Stop entry.
- Three consecutive installs are idempotent and produce three distinct backups.
- Existing `PreToolUse` / `PostToolUse` survive both `--install` and `--uninstall`.
- `--uninstall` removes Stop entry + hook script (when SHA matches), preserves a hand-edited script otherwise.
- Malformed `hooks.json` (object value not object; Stop value not array) is refused.
- Symlinked `hooks.json` is refused (target untouched, symlink itself preserved).
- `--check` produces all 6 health-report lines, warns on integrity drift, fails on `codex_hooks` not set, and is read-only (no mtime change).
