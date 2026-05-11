---
name: tmux-codex-chat
description: Send one prompt to the OpenAI Codex CLI running in another tmux pane, submit it, wait until Codex's answer is captured, and report it back. Use when the user wants to consult Codex, ask Codex, get Codex's opinion, have Codex review something, or route a question to a Codex CLI in a separate tmux pane — phrases like "codex に聞いて", "ask codex", "consult codex", "別 pane の codex にレビューさせて", "%138 の codex に <X>", "codex の意見が欲しい". Pane detection looks for `pane_current_command` in {codex, node} and confirms via Codex UI signals (`›` input prompt, status line with model name and "Context X% used", `─ Worked for ... ─` separator, or the `OpenAI Codex` startup banner). Only panes inside the current tmux session are considered — other sessions are never targeted, even if explicitly named. If multiple Codex panes are found or none can be confirmed, ask the user which pane id to target before sending. Prefer this over the general-purpose tmux-pane-send / tmux-pane-exec skills whenever the target is specifically a Codex CLI and the user expects a captured answer back.
allowed-tools: Bash
---

# tmux-codex-chat

One invocation = one prompt → one captured answer. Follow-ups require re-invocation. The skill never presses `y`/`n`/`Enter`/`Esc` on a Codex approval dialog — if one appears, the run is interrupted and surfaced.

## How completion is detected (no UI polling)

The skill injects a unique marker `[CODEX_CHAT_REQ:<full-uuid>]` into the visible prompt and creates a pending file. Codex's `Stop` hook (`~/.codex/hooks/tmux-codex-chat-stop.sh`) parses the **latest user message** of the transcript via `jq -rs`, and if the extracted UUID has a matching pending file it atomically writes `$RUNDIR/done-<uuid>.json`. The skill blocks on that file.

Approval dialogs do not end Codex's turn, so `Stop` never fires while paused on one — a parallel watcher subshell scans the pane every ~2 s (with a 0.5 s burst for the first 10 s) for dialog patterns and trips an approval sentinel file instead.

`$RUNDIR = /tmp/codex-chat-$UID` (mode 700, ownership-checked) holds: `pending-<uuid>`, `done-<uuid>.json`, `approval-<uuid>.txt`, `prompt-<ts>-<uuid>.md`, and `stop-hook.log`.

## Prerequisites

1. `~/.codex/config.toml` has `features.codex_hooks = true`.
2. `~/.codex/hooks.json` registers a `Stop` hook pointing at `~/.codex/hooks/tmux-codex-chat-stop.sh`.
3. The hook script is executable. `jq` is on PATH.
4. **Codex CLI was started AFTER the hook was installed.** Codex reads `hooks.json` once at session boot and does not reload it. If hook config changed since the target pane was started, the user must `Ctrl-D`/`/exit` and restart Codex in that pane — otherwise this skill silently times out.

Health-check:

```bash
hook_ok() {
  test -x ~/.codex/hooks/tmux-codex-chat-stop.sh || return 1
  jq -e '.hooks.Stop' ~/.codex/hooks.json >/dev/null 2>&1 || return 1
  grep -qE 'codex_hooks[[:space:]]*=[[:space:]]*true' ~/.codex/config.toml || return 1
  command -v jq >/dev/null
}
hook_ok && echo OK_HOOK_READY || echo MISSING
```

If `MISSING`, fall back to UI polling (final section) and tell the user once.

## Workflow

### 0. Session guard

```bash
[ -n "$TMUX" ] || { echo "Not inside tmux"; exit 1; }
SESSION=$(tmux display-message -p '#S')
```

All pane operations target `$SESSION`. Other tmux sessions are out of scope.

### 1. Discover & confirm Codex pane

```bash
tmux list-panes -s -t "$SESSION" -F "#{pane_id} #{pane_current_command} #{pane_current_path}"
```

A pane is a candidate when `pane_current_command` is `codex` (high) or `node` (medium — Codex runs as Node and often shows up that way). Capture each candidate (`tmux capture-pane -t %N -p -S -`) and require ≥1 of:

- Line matching `^[[:space:]]*›` (U+203A input prompt) — confirmed
- Status line `Context [0-9]+% used` — confirmed
- Completion separator `─ Worked for .* ─` — confirmed
- Startup banner `OpenAI Codex` near `model:` and `directory:` — confirmed (rescues fresh panes)
- `gpt-5` / `gpt-5\.[0-9]` near status — supporting only

Decision: 1 confirmed → use it; ≥2 → list as `session:window.pane` and ask; 0 → ask. Never guess.

### 2. Validate target pane

```bash
tmux display-message -p -t %N "#{pane_id} #{session_name} #{pane_current_command}"
```

If the pane is in a different session, refuse — do not silently retarget. Then check **busy state**: any of the following means not-ready, surface the capture and ask the user (wait / cancel / interrupt) — the skill never presses Esc/Ctrl-C itself.

- `Working (XXs • esc to interrupt)` visible
- An approval dialog is on screen (patterns in §6)
- No `›` prompt at all (mid-stream)

The following are **NOT** busy signals — proceed without confirmation:

- The `Create a plan?  shift + tab use Plan mode   esc dismiss` hint.
- A non-empty `›` line is not busy only when it matches a known Codex ghost-text pattern:
  - starts with `/<slash-command>` such as `/review`, `/diff`, `/model`, `/statusline`
  - starts with `Run /<slash-command>`
  - matches a previously-sent prompt verbatim

  Otherwise treat it as residual user input: surface the capture and ask before overwriting. For near-matches to the slash-command patterns, prefer sending; do not apply that latitude to natural-language drafts.

### 3. Generate REQ + create pending file

```bash
RUNDIR="/tmp/codex-chat-${UID:-$(id -u)}"
mkdir -m 700 -p "$RUNDIR" && chmod 700 "$RUNDIR"
[ -O "$RUNDIR" ] || { echo "$RUNDIR not owned by us"; exit 1; }

REQ=$(/usr/bin/uuidgen)            # absolute path bypasses any user alias
PENDING="$RUNDIR/pending-$REQ"
DONE_FILE="$RUNDIR/done-$REQ.json"
APPROVAL_FILE="$RUNDIR/approval-$REQ.txt"
PANE="%14"   # the confirmed Codex pane id from §1

touch "$PENDING"                   # pending-file gate; hook only writes done if this exists
```

The pending file is the **load-bearing safety mechanism** — it must be created BEFORE submission and it ensures stale markers in older transcript turns cannot ever overwrite a current run.

### 4. Send the prompt safely

The marker must appear in the **visible user message**, not only inside a referenced file — if Codex never reads the file, the hook will see no marker and the run will time out (better than writing to the wrong done-file). Two send paths:

#### 4a. Direct send (≤500 chars, ASCII-safe, single-line, no fenced code/diff/multi-heading)

```bash
tmux send-keys -t "$PANE" -l "[CODEX_CHAT_REQ:$REQ] (internal routing tag — please ignore in your reply) <flattened safe text>"
tmux send-keys -t "$PANE" Enter
```

#### 4b. File path (everything else)

```bash
ts=$(date +%Y%m%d-%H%M%S)
PROMPT_FILE="$RUNDIR/prompt-$ts-$REQ.md"
umask 077
cat > "$PROMPT_FILE" <<'EOF'
[CODEX_CHAT_REQ:__REQ__]
(internal routing tag — please ignore in your reply)

<full prompt body — any characters, the heredoc terminator is single-quoted>
EOF
sed -i '' "s/__REQ__/$REQ/" "$PROMPT_FILE"

ref="[CODEX_CHAT_REQ:$REQ] Please read $PROMPT_FILE and respond to the request inside it. Do not echo or strip the [CODEX_CHAT_REQ:...] marker — it is internal."
printf '%s' "$ref" | tmux load-buffer -
tmux paste-buffer -t "$PANE"
tmux send-keys -t "$PANE" Enter
```

Notes:

- The reference text in 4b carries the marker too, so the marker is always in the visible user message regardless of whether Codex reads the file.
- `tmux load-buffer -` overwrites tmux clipboard buffer 0; mention to the user if they care about it.
- Prompt files are not auto-deleted (Codex may re-read mid-response). Clean periodically with `rm -f "$RUNDIR"/prompt-*.md`.

#### Hard rules

- Never embed a literal newline in one `send-keys -l` call. Each `\n` is its own keystroke and Codex mis-submits.
- `Enter` is its own `send-keys` call **without** `-l`. (`-l Enter` types the letters.)
- Keep marker + body on one line for direct-send (a separate Enter would split into two messages).

### 5. Confirm submission

Wait ~1 s, capture once. If the prompt body still sits visibly above the `›` line, send `Enter` once more as a standalone key. If it still hasn't submitted, stop, surface the capture, report. Do not try a third Enter / `C-j` / `C-m`.

### 6. Wait for completion

```bash
# Parallel approval watcher: 0.5s for first 10s, then 2s. Exits when either
# sentinel appears, so we don't strictly need to kill it.
(
  i=0
  while :; do
    [ -f "$DONE_FILE" ] && exit 0
    cap=$(tmux capture-pane -t "$PANE" -p 2>/dev/null) || exit 0
    if printf '%s' "$cap" | grep -qE \
      '(\(y/n\)|\[[yY]/[nN]\]|Apply this patch\?|Allow command:|Run command\?|Allow this command\?|Always allow|Approve and run|Proceed\?|Continue\?|\(esc to cancel\)|\(esc to dismiss\)|^[[:space:]]*[❯>][[:space:]]+(Yes|No|Allow|Deny|Approve|Run|Apply|Proceed|Continue))'; then
      printf '%s' "$cap" > "$APPROVAL_FILE"
      exit 0
    fi
    i=$((i+1))
    if [ "$i" -lt 20 ]; then sleep 0.5; else sleep 2; fi
  done
) &
WATCHER_PID=$!

# Default deadline is 5 min; use 600/900 for long reviews.
DEADLINE=$(( $(date +%s) + 300 ))
RESULT=timeout
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if [ -f "$DONE_FILE" ];     then RESULT=done; break; fi
  if [ -f "$APPROVAL_FILE" ]; then RESULT=approval; break; fi
  sleep 0.3
done
kill "$WATCHER_PID" 2>/dev/null
wait "$WATCHER_PID" 2>/dev/null || true

case "$RESULT" in
  done)
    ANSWER=$(jq -r '.last_assistant_message // ""' "$DONE_FILE")
    rm -f "$DONE_FILE" "$PENDING"   # pending should already be gone, idempotent
    ;;
  approval)
    DIALOG=$(cat "$APPROVAL_FILE")
    rm -f "$APPROVAL_FILE"
    # Pending file is left in place. Once the user resolves the dialog
    # in the Codex pane, Codex will finish the turn and the Stop hook
    # will write $DONE_FILE. The skill MUST surface the exact REQ and
    # DONE_FILE path so the user can recover the answer without losing
    # the routing context — either by re-invoking this skill with the
    # same $REQ to wait again, or by reading $DONE_FILE manually.
    cat <<EOF
APPROVAL DIALOG — Codex is paused waiting for your decision.
   REQ:       $REQ
   DONE_FILE: $DONE_FILE
   Resolve the dialog in the Codex pane (do not press keys from here).
   Once Codex finishes, the answer will appear at \$DONE_FILE.
Dialog text follows:
$DIALOG
EOF
    ;;
  timeout)
    LATEST=$(tmux capture-pane -t "$PANE" -p)
    rm -f "$PENDING"   # drop pending so a late completion cannot replay into a future run
    cat <<EOF
TIMEOUT — Codex did not finish within the 5-minute window.
   The pending file has been removed to prevent stale replay, so the
   Stop hook will NOT write $DONE_FILE even if Codex finishes later.
   Recover the answer manually from the pane scrollback, or re-invoke
   the skill with a longer DEADLINE (e.g. 600 or 900 seconds).
   Latest pane content follows:
$LATEST
EOF
    ;;
esac
```

Approval dialog patterns (used by the watcher above):
classic `(y/n)`, `[y/N]`, `Apply this patch?`, `Allow command:`; Codex-style `Run command?`, `Allow this command?`, `Always allow`, `Approve and run`, `Proceed?`, `Continue?`, `(esc to cancel/dismiss)`; selector lines starting with `❯ ` or `> ` followed by `Yes/No/Allow/Deny/Approve/Run/Apply/Proceed/Continue`.

### 7. Report

Return: pane id, REQ, the prompt (summarized if long; include `$PROMPT_FILE` if file path was used), and `last_assistant_message` from the done file (preferred over re-capturing the pane — no terminal wrapping artifacts). Flag uncertainty: timed out, approval interrupted, fallback path used.

Do not claim Codex "approved", "completed", or "agreed" unless its captured text literally supports it.

### 8. Cleanup

The `done`/`approval` files of the current run are removed in §6. `$PROMPT_FILE` is intentionally retained. Periodically `rm -f "$RUNDIR"/prompt-*.md "$RUNDIR"/stop-hook.log`.

## Fallback: UI polling (best-effort, hook-missing only)

If the health-check failed, fall through to a UI-string poll: baseline `$(tmux capture-pane -t "$PANE" -p -S - | grep -c "Worked for")` before sending, then poll every ~3 s and complete when the bottom shows an empty `›` AND no `Working`/spinner/approval AND either `Worked for` count exceeds baseline OR two consecutive captures are byte-identical. Apply the same approval short-circuit. 5-min soft timeout.

**This path is best-effort only.** It can mis-detect when output wraps mid-line, when prior `›` text is stale, when Codex changes its UI strings, or when the answer arrives faster than 3 s. Do not treat it as equivalent to the hook path. Tell the user the prerequisites failed (`MISSING`) so they fix it once and never come back here.

## Common commands

| Need | Command |
| --- | --- |
| Session name | `tmux display-message -p '#S'` |
| Panes (current session) | `tmux list-panes -s -t "$SESSION" -F "#{pane_id} #{pane_current_command}"` |
| Capture screen / scrollback | `tmux capture-pane -t %N -p` / `tmux capture-pane -t %N -p -S -` |
| Generate REQ | `/usr/bin/uuidgen` (absolute path — alias-proof) |
| Submit | `tmux send-keys -t %N Enter` (separate from `-l` text) |
| Wait for done | `until [ -f "$DONE_FILE" ]; do sleep 0.3; done` |
| Inspect last hook activity | `tail "$RUNDIR/stop-hook.log"` |
