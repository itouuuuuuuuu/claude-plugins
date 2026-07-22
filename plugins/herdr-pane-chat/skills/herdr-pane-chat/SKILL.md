---
name: herdr-pane-chat
description: Send one prompt to an AI coding agent (Claude Code, Codex, or any agent herdr detects) running in another herdr pane, wait for its answer via herdr's native agent-status tracking, and report the answer back. MUST auto-trigger (invoke the Skill tool immediately — do NOT only describe) whenever the session is inside herdr (HERDR_ENV=1) and the user wants to consult another agent or have it review/check anything in a separate pane. Hard trigger: any sentence naming an agent (codex, claude, 別の claude, 隣の pane の…) together with レビュー / 確認 / チェック / 見て / 意見 / 聞いて or English review / check / audit / consult / ask — fire even when no pane is specified; the skill discovers candidates itself. Japanese examples:「codex に確認して」「別のペインの claude に確認して」「codex にレビューしてもらって」「隣の claude に聞いて」「codex の意見が欲しい」. English examples: "ask codex", "consult the other claude", "have codex review this". Candidates come from `herdr agent list`, restricted to the current workspace ($HERDR_WORKSPACE_ID); the invoking pane ($HERDR_PANE_ID) is always excluded. Exactly one candidate → use it; multiple or zero → ask the user (zero never auto-starts an agent). No hooks, no markers, no UI polling — completion is detected by the agent status transitioning working → done/idle.
allowed-tools: Bash
---

# herdr-pane-chat

One invocation = one prompt → one captured answer. Follow-ups require re-invocation (the target pane is already known then, so repeat rounds are fast). The skill never presses `y`/`n`/`Enter`/`Esc` on the target agent's approval dialogs — if the target becomes `blocked`, the dialog is surfaced to the user instead.

## Why this is simpler than the tmux-based variants

herdr tracks per-pane agent identity and status natively (`idle` / `working` / `blocked` / `done`), so there is no Stop hook, no UUID marker, no pending file, and no UI-string polling. Everything runs over the `herdr agent ...` / `herdr pane ...` CLI (socket API), which returns JSON.

Verified behavior (herdr 2026-07):

- `herdr agent send <target> <text>` writes literal text into the composer; it does **not** submit.
- `herdr pane send-keys <pane_id> enter` submits (the key name is lowercase `enter`).
- After submission the status flips to `working` within ~1 s.
- On completion the status becomes `done` (it may later settle back to `idle`). `herdr agent wait <target> --status idle` also resolves on `done`.
- `herdr agent read <target> --source recent-unwrapped` returns unwrapped scrollback in the JSON field `.result.read.text` — no line-wrapping artifacts.

## Workflow

### 0. Session guard

```bash
[ -n "$HERDR_ENV" ] || { echo "Not inside a herdr session"; exit 1; }
SELF_PANE="$HERDR_PANE_ID"        # e.g. w4:p1 — always excluded
WS="$HERDR_WORKSPACE_ID"          # e.g. w4 — candidates limited to this workspace
```

If `$HERDR_ENV` is unset, tell the user this skill only works inside herdr and stop.

### 1. Discover the target agent

```bash
herdr agent list | jq -r --arg ws "$WS" --arg self "$SELF_PANE" '
  .result.agents[]
  | select(.workspace_id == $ws and .pane_id != $self)
  | [.pane_id, .agent, .agent_status, .cwd, .terminal_title_stripped]
  | @tsv'
```

Keep only rows whose agent label matches what the user asked for (`codex`, `claude`, …). If the user said something generic like "the agent in the other pane", every row is a candidate.

Decision rule — **never guess**:

- Exactly 1 candidate → use its `pane_id` as `$TARGET` for every following command (labels like `codex` only resolve when unique; pane ids always work).
- ≥2 candidates → present the rows (pane id, agent, status, title, cwd) and ask the user which one to target.
- 0 candidates → report that no matching agent exists in this workspace and stop. Do not start one (`herdr agent start` exists but is out of scope by design — the user launches agents themselves).

### 2. Pre-send readiness check

```bash
STATUS=$(herdr agent get "$TARGET" | jq -r '.result.agent.agent_status')
```

- `idle` / `done` → proceed.
- `working` → wait briefly: `herdr agent wait "$TARGET" --status idle --timeout 60000`. If that times out, show the user the current status plus the tail of `herdr agent read "$TARGET" --source visible --lines 20` and ask whether to keep waiting or abort. Do not interrupt the target.
- `blocked` → the pane is paused on an approval dialog. Surface the visible pane content and ask the user to resolve it in that pane. Never press keys on its behalf.

### 3. Send the prompt

Two paths:

#### 3a. Direct send (single line, ≤500 chars, no code fences)

```bash
herdr agent send "$TARGET" "<single-line prompt text>"
herdr pane send-keys "$TARGET" enter
```

#### 3b. File reference (anything long, multi-line, or containing code/diffs)

```bash
RUNDIR="/tmp/herdr-pane-chat-${UID:-$(id -u)}"
mkdir -m 700 -p "$RUNDIR" && chmod 700 "$RUNDIR"
[ -O "$RUNDIR" ] || { echo "$RUNDIR not owned by us"; exit 1; }
umask 077
PROMPT_FILE="$RUNDIR/prompt-$(date +%Y%m%d-%H%M%S)-$$.md"
cat > "$PROMPT_FILE" <<'EOF'
<full prompt body — any characters; the heredoc terminator is single-quoted>
EOF
herdr agent send "$TARGET" "Please read $PROMPT_FILE and respond to the request inside it."
herdr pane send-keys "$TARGET" enter
```

Hard rules:

- Never embed a literal newline in the `agent send` text — TUI composers may submit on newline, splitting one prompt into several partial messages. Anything multi-line goes through 3b.
- Submission is always the separate `pane send-keys <pane> enter` call; `agent send` alone never submits.

### 4. Confirm submission

```bash
sleep 1
STATUS=$(herdr agent get "$TARGET" | jq -r '.result.agent.agent_status')
```

`working` (or already `done` for instant answers) means submitted. If still `idle`, read the visible pane; if the prompt text still sits in the composer, send `enter` once more. If it *still* has not submitted, stop, surface the pane content, and report — do not keep hammering Enter.

### 5. Wait for completion

Default deadline 5 minutes; use 10–15 minutes when the request is explicitly heavy (multi-file review, deep audit). Poll `agent get` every 2 s so `blocked` is caught too — a bare `agent wait --status idle` would sit through an approval dialog until timeout:

```bash
DEADLINE=$(( $(date +%s) + 300 ))
RESULT=timeout
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  STATUS=$(herdr agent get "$TARGET" | jq -r '.result.agent.agent_status')
  case "$STATUS" in
    done|idle) RESULT=answered; break ;;
    blocked)   RESULT=blocked;  break ;;
  esac
  sleep 2
done
```

- `answered` → go to §6.
- `blocked` → read the visible pane and show the dialog to the user; they resolve it in the target pane themselves. herdr keeps no per-request state, so after they resolve it, simply re-running this wait loop (or re-invoking the skill) picks the answer up — nothing can replay or go stale.
- `timeout` → show the tail of the pane and report. Resuming is safe: re-run the wait loop or re-invoke with a longer deadline.

### 6. Read the answer

```bash
herdr agent read "$TARGET" --source recent-unwrapped --lines 200 | jq -r '.result.read.text'
```

Read the output yourself and identify the answer: it is the text the target agent produced after your prompt (the prompt line is visible above it). If the top of the answer is cut off, re-read with a larger `--lines`.

### 7. Report back

Include: the target pane id + agent label, the prompt (or the `$PROMPT_FILE` path when 3b was used), and the answer — verbatim when short, faithfully summarized with key passages quoted when long. Flag explicitly when the run timed out or was interrupted by an approval dialog. Do not claim the target "approved", "agreed", or "completed" anything unless its captured text literally supports it.

### 8. Cleanup

Prompt files are not auto-deleted (the target may re-read them mid-answer). Clean up periodically:

```bash
/bin/rm -f "$RUNDIR"/prompt-*.md
```

Always use the absolute `/bin/rm` for this cleanup — it must be idempotent regardless of how the invoking shell aliases `rm`.

## Command reference

| Need | Command |
| --- | --- |
| List agents (JSON) | `herdr agent list` |
| One agent's status | `herdr agent get <target> \| jq -r '.result.agent.agent_status'` |
| Send text (no submit) | `herdr agent send <target> "<text>"` |
| Submit | `herdr pane send-keys <pane_id> enter` |
| Block until idle/done | `herdr agent wait <target> --status idle --timeout <ms>` |
| Read scrollback | `herdr agent read <target> --source recent-unwrapped --lines N` |

Targets accept pane ids (`w4:pP`), terminal ids, and unique agent labels — prefer the pane id resolved in §1.
