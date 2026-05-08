#!/usr/bin/env bash
#
# install-codex-hook.sh — Codex CLI side installer for the tmux-codex-chat
# Claude Code plugin.
#
# This script lives at  <plugin-root>/scripts/install-codex-hook.sh
# and acts on the user's Codex CLI configuration:
#
#   ~/.codex/hooks/tmux-codex-chat-stop.sh   ← copied from <plugin-root>/codex-hook/
#   ~/.codex/hooks.json                       ← Stop entry merged via jq
#
# Subcommands:
#   --install     (default) atomically install/refresh the hook
#   --check       6-item health report; never writes
#   --uninstall   remove the Stop entry and (if SHA matches) the hook script
#
# Design notes (see also: plan / SKILL.md / hook script):
#   - Refuses if ~/.codex/hooks.json is a symlink (don't silently break dotfiles).
#   - Refuses if existing hooks.json is malformed (refuse-and-leave-alone semantic).
#   - Stages BOTH the merged hooks.json and the new hook script before any
#     production rename(2), so disk-full / perm-denied / RO-fs failures
#     surface during staging and the user's existing files stay intact.
#   - Falls back between `shasum -a 256` (macOS) and `sha256sum` (Linux).
#   - All filesystem mutations use absolute paths (/bin/rm, /bin/cp, …) to
#     avoid alias surprises in user shells.
set -u

# ---------------------------------------------------------------------------
# Constants and paths
# ---------------------------------------------------------------------------

# Plugin root = parent of the directory containing this script.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_HOOK="$PLUGIN_ROOT/codex-hook/tmux-codex-chat-stop.sh"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOKS_DIR="$CODEX_HOME/hooks"
HOOKS_JSON="$CODEX_HOME/hooks.json"
CONFIG_TOML="$CODEX_HOME/config.toml"
DEST_HOOK="$HOOKS_DIR/tmux-codex-chat-stop.sh"

# Match ANSI-free output even when stdout is not a tty.
COLOR_OK="${COLOR_OK:-}"
COLOR_WARN="${COLOR_WARN:-}"
COLOR_FAIL="${COLOR_FAIL:-}"
COLOR_INFO="${COLOR_INFO:-}"
COLOR_END="${COLOR_END:-}"
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  COLOR_OK=$'\033[32m'
  COLOR_WARN=$'\033[33m'
  COLOR_FAIL=$'\033[31m'
  COLOR_INFO=$'\033[36m'
  COLOR_END=$'\033[0m'
fi

# stat(1) flag dialect differs between GNU coreutils and BSD/macOS. Detect
# once and stash the formats so we don't have to "try one then the other"
# (which is racy: GNU stat with `-f` doesn't error cleanly on BSD-style
# format strings — it interprets `-f` as `--file-system` and produces
# fs metadata, which silently breaks our mtime/mode reads).
if stat --version 2>/dev/null | grep -q "GNU coreutils"; then
  STAT_MTIME_FMT='-c %Y'
  STAT_MODE_FMT='-c %a'
else
  STAT_MTIME_FMT='-f %m'
  STAT_MODE_FMT='-f %Lp'
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

ok()    { printf '%s[OK]%s   %s\n'   "$COLOR_OK"   "$COLOR_END" "$*"; }
warn()  { printf '%s[WARN]%s %s\n'   "$COLOR_WARN" "$COLOR_END" "$*" >&2; }
fail()  { printf '%s[FAIL]%s %s\n'   "$COLOR_FAIL" "$COLOR_END" "$*" >&2; }
info()  { printf '%s[INFO]%s %s\n'   "$COLOR_INFO" "$COLOR_END" "$*"; }
die()   { fail "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# hash_file <path>  → SHA-256 hex on stdout (or "no-hash-tool")
hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | cut -d' ' -f1
  else
    echo "no-hash-tool"
  fi
}

# stat_mtime <path>  → unix epoch seconds (uses pre-detected stat flavor)
stat_mtime() {
  # shellcheck disable=SC2086
  stat $STAT_MTIME_FMT "$1"
}

# stat_mode <path>  → octal mode digits, e.g. "755"
stat_mode() {
  # shellcheck disable=SC2086
  stat $STAT_MODE_FMT "$1"
}

# Common preflight shared by all subcommands.
# - jq required
# - $CODEX_HOME must exist (user has run `codex` at least once)
# - hooks.json must NOT be a symlink (dotfiles guard)
# - existing hooks.json must be structurally valid
preflight_strict() {
  command -v jq >/dev/null 2>&1 || die "jq is required but not found on PATH"
  [ -d "$CODEX_HOME" ] || die "$CODEX_HOME not found — run \`codex\` once first"

  if [ -L "$HOOKS_JSON" ]; then
    die "$HOOKS_JSON is a symlink. Resolve it manually (cp -L) or update the link target before running this script."
  fi

  if [ -f "$HOOKS_JSON" ]; then
    if ! jq -e '
      (type == "object")
      and ((.hooks // {}) | type == "object")
      and ((.hooks.Stop // []) | type == "array")
      and ((.hooks.PreToolUse // []) | type == "array")
      and ((.hooks.PostToolUse // []) | type == "array")
    ' "$HOOKS_JSON" >/dev/null 2>&1; then
      die "$HOOKS_JSON is malformed or has unexpected structure. Refusing to touch it. (Move it aside manually if you want me to overwrite.)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: --install
# ---------------------------------------------------------------------------

cmd_install() {
  preflight_strict
  [ -f "$SRC_HOOK" ] || die "hook source not found: $SRC_HOOK"

  # 1. ensure ~/.codex/hooks/ exists
  mkdir -p "$HOOKS_DIR"

  # 2. ensure hooks.json exists (create empty skeleton if missing)
  [ -f "$HOOKS_JSON" ] || echo '{"hooks":{}}' > "$HOOKS_JSON"

  # 3. backup current hooks.json (preserve mode/mtime for git-diff readability).
  #    Suffix combines timestamp + PID + $RANDOM so back-to-back invocations
  #    inside the same second produce distinct backup files.
  local backup="$HOOKS_JSON.bak.$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
  /bin/cp -p "$HOOKS_JSON" "$backup"

  # 4. STAGE both replacement files. Until both stagings succeed we have
  #    not touched any production file. Disk-full / perm-denied / RO-fs
  #    failures surface here, before any commit.
  local tmp_hooks tmp_hook
  tmp_hooks=$(mktemp -t codex-hooks.XXXXXX) || die "mktemp failed"
  tmp_hook="$DEST_HOOK.tmp.$$"
  trap '/bin/rm -f "$tmp_hooks" "$tmp_hook"' EXIT

  # 4a. compute merged hooks.json
  if ! jq --arg cmd "$DEST_HOOK" '
    .hooks.Stop = (
      (.hooks.Stop // [])
      | map(.hooks |= map(select(.command != $cmd)))
      | map(select((.hooks // []) | length > 0))
    ) + [{
      "hooks": [
        { "type": "command", "command": $cmd, "timeout": 10 }
      ]
    }]
  ' "$HOOKS_JSON" > "$tmp_hooks"; then
    die "jq merge failed — production file left untouched"
  fi

  # 4b. validate merged result before going further
  if ! jq -e 'type == "object" and (.hooks.Stop | type == "array")' "$tmp_hooks" >/dev/null; then
    die "merged hooks.json failed validation — production file left untouched"
  fi

  # 4c. stage hook script *next to* DEST_HOOK so the final mv is rename(2)
  #     on the same filesystem (atomic on POSIX).
  install -m 755 "$SRC_HOOK" "$tmp_hook" || die "failed to stage hook script at $tmp_hook"

  # 5. COMMIT in two consecutive renames. Both rename(2) on the same fs are
  #    atomic. If the second mv fails (vanishingly unlikely after a
  #    successful staging), restore hooks.json from the backup.
  /bin/mv "$tmp_hooks" "$HOOKS_JSON" || die "rename of merged hooks.json failed"
  if ! /bin/mv "$tmp_hook" "$DEST_HOOK"; then
    warn "hook script rename failed — rolling hooks.json back from $backup"
    /bin/cp -p "$backup" "$HOOKS_JSON" || die "rollback also failed; investigate manually"
    die "hook script rename failed; system restored from backup"
  fi
  trap - EXIT

  # 6. config.toml advisory (do not auto-edit user-owned config)
  if ! grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$CONFIG_TOML" 2>/dev/null; then
    warn "Add \`codex_hooks = true\` under [features] in $CONFIG_TOML so Codex actually executes hooks"
  fi

  cat <<EOF

Installed:
  hook script  → $DEST_HOOK
  hooks.json   ← Stop entry merged (backup at $backup)

NEXT: restart your Codex CLI — Codex reads hooks.json once at startup.
Verify with:  bash $0 --check

EOF
}

# ---------------------------------------------------------------------------
# Subcommand: --uninstall
# ---------------------------------------------------------------------------

cmd_uninstall() {
  preflight_strict

  # Backup before any modification (timestamp + PID + RANDOM avoids
  # collisions on back-to-back invocations).
  if [ -f "$HOOKS_JSON" ]; then
    /bin/cp -p "$HOOKS_JSON" "$HOOKS_JSON.bak.$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"

    # Drop our entry (and any wrapper that becomes empty as a result).
    local tmp
    tmp=$(mktemp -t codex-hooks.XXXXXX) || die "mktemp failed"
    trap '/bin/rm -f "$tmp"' EXIT
    if ! jq --arg cmd "$DEST_HOOK" '
      .hooks.Stop = (
        (.hooks.Stop // [])
        | map(.hooks |= map(select(.command != $cmd)))
        | map(select((.hooks // []) | length > 0))
      )
    ' "$HOOKS_JSON" > "$tmp"; then
      die "jq merge failed during uninstall"
    fi
    jq -e . "$tmp" >/dev/null || die "uninstall produced invalid JSON"
    /bin/mv "$tmp" "$HOOKS_JSON"
    trap - EXIT
  fi

  # Remove hook script only if it matches the plugin's shipped source —
  # don't nuke a user's hand-edited override.
  if [ -f "$DEST_HOOK" ]; then
    if [ -f "$SRC_HOOK" ] && [ "$(hash_file "$DEST_HOOK")" = "$(hash_file "$SRC_HOOK")" ]; then
      /bin/rm -f "$DEST_HOOK"
      ok "Removed $DEST_HOOK"
    else
      warn "$DEST_HOOK differs from plugin source — left in place (manually rm if needed)"
    fi
  fi

  cat <<EOF

Uninstalled. Restart Codex to reload hooks.json.
Backup of previous hooks.json: $HOOKS_JSON.bak.*
The runtime dir /tmp/codex-chat-\$UID is left in place; remove manually if desired.

EOF
}

# ---------------------------------------------------------------------------
# Subcommand: --check (health report; no writes)
# ---------------------------------------------------------------------------

cmd_check() {
  local exit_code=0

  # 0. jq presence
  if command -v jq >/dev/null 2>&1; then
    ok "jq $(jq --version 2>/dev/null) on PATH"
  else
    fail "jq not found on PATH — install jq before continuing"
    exit_code=1
  fi

  # 1. Stop entry registered for our hook command
  if [ -f "$HOOKS_JSON" ] && command -v jq >/dev/null 2>&1; then
    local count
    count=$(jq --arg cmd "$DEST_HOOK" '
      [.hooks.Stop[]?.hooks[]? | select(.command == $cmd)] | length
    ' "$HOOKS_JSON" 2>/dev/null || echo 0)
    if [ "${count:-0}" -ge 1 ]; then
      ok "Stop entry present (command=$DEST_HOOK, count=$count)"
    else
      fail "Stop entry NOT present in $HOOKS_JSON — run: bash $0 --install"
      exit_code=1
    fi
  else
    fail "$HOOKS_JSON missing or unreadable"
    exit_code=1
  fi

  # 2. Hook script existence + executable
  if [ -x "$DEST_HOOK" ]; then
    local size mode
    size=$(wc -c < "$DEST_HOOK" | tr -d ' ')
    mode=$(stat_mode "$DEST_HOOK")
    ok "hook script executable ($size bytes, mode $mode)"
  else
    fail "hook script not executable at $DEST_HOOK"
    exit_code=1
  fi

  # 3. Script integrity vs plugin source
  if [ -f "$DEST_HOOK" ] && [ -f "$SRC_HOOK" ]; then
    local dest_h src_h
    dest_h=$(hash_file "$DEST_HOOK")
    src_h=$(hash_file "$SRC_HOOK")
    if [ "$dest_h" = "$src_h" ]; then
      ok "hook script matches plugin source (sha256=${dest_h:0:12}…)"
    else
      warn "hook script differs from plugin source — re-run --install to update"
      warn "  installed: ${dest_h:0:12}…"
      warn "  plugin:    ${src_h:0:12}…"
    fi
  fi

  # 4. config.toml has codex_hooks = true
  if grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$CONFIG_TOML" 2>/dev/null; then
    ok "codex_hooks = true in $CONFIG_TOML"
  else
    fail "codex_hooks = true NOT found in $CONFIG_TOML — Codex will skip hook execution"
    exit_code=1
  fi

  # 5. Codex restart reminder (compare hooks.json mtime to latest session file mtime)
  if [ -f "$HOOKS_JSON" ]; then
    local hooks_mt session_mt latest_session
    hooks_mt=$(stat_mtime "$HOOKS_JSON" 2>/dev/null || echo 0)
    latest_session=$(/usr/bin/find "$CODEX_HOME/sessions" -type f -name 'rollout-*.jsonl' -print 2>/dev/null \
      | sort | tail -n1)
    if [ -n "$latest_session" ]; then
      session_mt=$(stat_mtime "$latest_session" 2>/dev/null || echo 0)
      if [ "$hooks_mt" -gt "$session_mt" ]; then
        info "hooks.json modified after the latest Codex session was active — restart Codex to pick up the new hook"
      else
        info "hooks.json older than the latest Codex session — no restart needed for the current hook config"
      fi
    else
      info "no Codex session history found — restart Codex if you have a session running from before --install"
    fi
  fi

  exit $exit_code
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $0 [--install | --check | --uninstall]

Options (all subcommands except --check write to disk):
  --install    (default) Install / refresh the Codex Stop hook for tmux-codex-chat.
               Idempotent: re-running re-syncs the hook script and the Stop entry.
  --check      Health report (6 items). Never writes.
  --uninstall  Remove the Stop entry and (if SHA matches) the hook script.

Environment:
  CODEX_HOME   Override ~/.codex location (used by tests)
  NO_COLOR     Disable ANSI color output

EOF
}

case "${1:-}" in
  ""|--install) cmd_install ;;
  --check)      cmd_check   ;;
  --uninstall)  cmd_uninstall ;;
  -h|--help)    usage ;;
  *)            usage; exit 2 ;;
esac
