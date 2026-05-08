#!/usr/bin/env bash
# Codex Stop hook for the tmux-codex-chat skill (Claude Code side).
#
# Goal
#   When Codex CLI ends a turn whose latest user message contains a
#   `CODEX_CHAT_REQ:<full-uuid>` marker AND the corresponding pending
#   file exists, atomically write the answer to
#   $RUNDIR/done-<uuid>.json so the waiting Claude session wakes up.
#
# Per-user runtime directory: $RUNDIR = /tmp/codex-chat-$UID, mode 700,
# created on demand and ownership-verified to refuse hijacked dirs.
#
# Stdin JSON (subset used)
#   .transcript_path        path to current Codex session JSONL
#   .last_assistant_message latest assistant text (may be null)
#   .session_id, .turn_id   Codex identifiers (echoed for debugging)
#   .stop_hook_active       true if this Stop is a continuation; we no-op
#                           those, since they are not real turn ends.
#
# Behavior
#   - Any failure path: silent no-op (exit 0). Diagnostics go to
#     $RUNDIR/stop-hook.log.
#   - Marker extraction reads ONLY the most-recent user message via jq
#     slurp, so stale markers in older turns / assistant quotes / tool
#     output are ignored.
#   - Pending-file gate: a done file is written only if
#     $RUNDIR/pending-<uuid> exists. Claude removes it on success, so
#     replays of the same marker in later turns cannot overwrite it.
set -u

UID_REAL=${UID:-$(id -u)}
RUNDIR="/tmp/codex-chat-${UID_REAL}"
LOG="${RUNDIR}/stop-hook.log"
UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

ensure_rundir() {
  # `-d` follows symlinks, so an attacker-controlled symlink at $RUNDIR
  # would otherwise pass. Reject any symlink (broken or live) outright.
  if [ -L "$RUNDIR" ]; then
    log "$RUNDIR is a symlink, refusing"
    return 1
  fi
  if [ ! -d "$RUNDIR" ]; then
    mkdir -m 700 "$RUNDIR" 2>/dev/null || return 1
  fi
  # Refuse if not owned by us (-O) — covers same-user dir hijack only.
  [ -O "$RUNDIR" ] || return 1
  chmod 700 "$RUNDIR" 2>/dev/null || true
  return 0
}

log() {
  [ -d "$RUNDIR" ] || return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG" 2>/dev/null || true
}

# ----- read stdin once -----
INPUT=$(cat)

# Tolerate missing jq — skill falls back to UI polling.
command -v jq >/dev/null 2>&1 || exit 0

ensure_rundir || exit 0

STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
[ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || exit 0

LAST_MSG=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null || echo "")
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
TURN=$(printf '%s' "$INPUT" | jq -r '.turn_id // ""' 2>/dev/null || echo "")

# ----- extract marker from THE LAST user message only -----
# Codex transcript JSONL line shape (observed):
#   {"type":"response_item","payload":{"type":"message","role":"user",
#    "content":[{"type":"input_text","text":"..."}, ...]}}
# Slurp the entire transcript, take the last entry where role == user,
# concatenate every text-bearing field, then grep for a *full* UUID.
LAST_USER_TEXT=$(jq -rs '
  [
    .[]
    | select(type == "object")
    | select((.type? == "response_item") and (.payload?.role? == "user") and (.payload?.type? == "message"))
    | .payload.content // []
    | map(.text // "" )
    | join("\n")
  ]
  | last // ""
' "$TRANSCRIPT" 2>/dev/null || echo "")

if [ -z "$LAST_USER_TEXT" ]; then
  exit 0
fi

REQ=$(printf '%s\n' "$LAST_USER_TEXT" \
  | grep -oE "CODEX_CHAT_REQ:${UUID_RE}" \
  | tail -n1 \
  | sed -E 's/^CODEX_CHAT_REQ://')

if [ -z "$REQ" ]; then
  # Common path — last user prompt was not from this skill. Silent.
  exit 0
fi

# Defense in depth: re-validate REQ against full UUID before file ops.
case "$REQ" in
  [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
  *) log "rejected non-UUID REQ='$REQ'"; exit 0 ;;
esac

PENDING="${RUNDIR}/pending-${REQ}"
OUT="${RUNDIR}/done-${REQ}.json"

# Pending-file gate: only write done if Claude is actually waiting on
# this REQ. Stops stale-marker replays from clobbering anything.
if [ ! -e "$PENDING" ]; then
  log "skip REQ=$REQ (no pending file)"
  exit 0
fi

# Atomic write via mktemp.
TMP=$(mktemp "${OUT}.XXXXXX") || { log "mktemp failed for REQ=$REQ"; exit 0; }
chmod 600 "$TMP" 2>/dev/null || true

if ! jq -n \
  --arg msg "$LAST_MSG" \
  --arg sid "$SESSION" \
  --arg tid "$TURN" \
  --arg req "$REQ" \
  '{req_id: $req, last_assistant_message: $msg, session_id: $sid, turn_id: $tid, finished_at: now}' \
  >"$TMP" 2>>"$LOG"; then
  log "jq compose failed for REQ=$REQ"
  rm -f "$TMP"
  exit 0
fi

if ! mv -f "$TMP" "$OUT" 2>>"$LOG"; then
  log "rename failed for REQ=$REQ"
  rm -f "$TMP"
  exit 0
fi

# Consume pending so replays of the same marker do nothing.
rm -f "$PENDING" 2>/dev/null

log "wrote $OUT (session=$SESSION turn=$TURN bytes=$(wc -c <"$OUT" | tr -d ' '))"
exit 0
