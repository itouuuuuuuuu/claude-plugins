---
name: herdr-pane-chat
description: Send one prompt to an AI coding agent (Claude Code, Codex, or any agent herdr detects) running in another herdr pane, wait for its answer via herdr's native agent-status tracking, and report the answer back. MUST auto-trigger (invoke the Skill tool immediately — do NOT only describe) whenever the session is inside herdr (HERDR_ENV=1) and the user wants to consult another agent or have it review/check anything in a separate pane. Hard trigger: any sentence naming an agent (codex, claude, 別の claude, 隣の pane の…) together with レビュー / 確認 / チェック / 見て / 意見 / 聞いて or English review / check / audit / consult / ask — fire even when no pane is specified; the skill discovers candidates itself. Japanese examples:「codex に確認して」「別のペインの claude に確認して」「codex にレビューしてもらって」「隣の claude に聞いて」「codex の意見が欲しい」. English examples: "ask codex", "consult the other claude", "have codex review this". Candidates come from `herdr agent list`, restricted to the current workspace ($HERDR_WORKSPACE_ID); the invoking pane ($HERDR_PANE_ID) is always excluded. Exactly one candidate → use it; multiple → ask the user; zero → report and stop (the skill never auto-starts an agent). No hooks, no markers, no UI polling — completion is detected by the agent status transitioning working → done/idle.
allowed-tools: Bash, Write
---

# herdr-pane-chat

One invocation = one prompt → one captured answer. Follow-ups require re-invocation (the target pane is already known then, so repeat rounds are fast). The skill never *knowingly* presses keys on the target agent's approval dialogs: the status is re-checked immediately before every `enter` keystroke and the submit is aborted if the target is not `idle`/`done`. This is **best-effort** — herdr has no atomic "submit only if still idle" API, so a small race window between the check and the keystroke is unavoidable. If the target becomes `blocked`, the dialog is surfaced to the user instead.

## Why this is simpler than the tmux-based variants

herdr tracks per-pane agent identity and status natively (`idle` / `working` / `blocked` / `done` / `unknown`), so there is no Stop hook, no UUID marker, no pending file, and no UI-string polling. Everything runs over the `herdr agent ...` / `herdr pane ...` CLI (socket API), which returns JSON.

Verified behavior (herdr 0.7.4, 2026-07):

- `herdr agent send <target> <text>` writes literal text into the composer; it does **not** submit.
- `herdr pane send-keys <pane_id> enter` submits (the key name is lowercase `enter`).
- After submission the status flips to `working` within ~1 s.
- On completion the status becomes `done` (it may later settle back to `idle`). `herdr agent wait <target> --status idle` also resolves on `done`.
- `herdr agent read <target> --source recent-unwrapped` returns unwrapped scrollback in the JSON field `.result.read.text` — no line-wrapping artifacts.

## Workflow

### 0. Session guard

```bash
[ "$HERDR_ENV" = 1 ] || { echo "Not inside a herdr session"; exit 1; }
SELF_PANE="$HERDR_PANE_ID"        # e.g. w4:p1 — always excluded
WS="$HERDR_WORKSPACE_ID"          # e.g. w4 — candidates limited to this workspace
```

If the guard fails, tell the user this skill only works inside herdr and stop.

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
- **Anything else** (`unknown`, empty string, jq/CLI failure) → fail closed: do not send anything; surface the raw `herdr agent get` output to the user and stop.

### 3. Send the prompt

Every run gets a fresh private directory — `mktemp -d` creates it mode 700 and cannot be pre-seeded with a symlink:

```bash
RUNDIR=$(mktemp -d "${TMPDIR:-/tmp}/herdr-pane-chat.XXXXXXXX") || exit 1
PROMPT_FILE="$RUNDIR/prompt.md"
```

Two send paths:

#### 3a. Direct send — only for trivially safe one-liners

Allowed only when the prompt is a single line, ≤200 chars, and contains **none** of `'`, `"`, `` ` ``, `$`, `\` (so it can be single-quoted into the Bash call verbatim). Anything else — and any prompt where you may later need to correlate the answer (busy pane, likely resume) — goes through 3b.

```bash
herdr agent send "$TARGET" '<single-line prompt text>'
```

#### 3b. File reference (default for anything long, multi-line, or containing code/quotes)

Write the prompt body to `$PROMPT_FILE` **with the Write tool, not a shell heredoc** — the body must never pass through shell parsing, so no quoting/heredoc-terminator collision is possible and the body truly may contain any characters. Then:

```bash
herdr agent send "$TARGET" "Please read $PROMPT_FILE and respond to the request inside it."
```

The `$RUNDIR` path is unique per run, which also makes this line a natural request boundary in the scrollback (see §6).

#### Submit — guarded Enter

`agent send` never submits; the composer does not change the agent status. Re-check the status immediately before the keystroke and abort unless it is still `idle`/`done`:

```bash
STATUS=$(herdr agent get "$TARGET" | jq -r '.result.agent.agent_status')
case "$STATUS" in
  idle|done) herdr pane send-keys "$TARGET" enter ;;
  *) echo "abort: target status changed to '$STATUS' before submit"; exit 1 ;;
esac
```

Hard rules:

- Never embed a literal newline in the `agent send` text — TUI composers may submit on newline, splitting one prompt into several partial messages.
- Every `enter` keystroke, including the retry in §4, goes through the guarded pattern above.

### 4. Confirm submission

Require the `working` transition — it is what correlates the later `done`/`idle` with *this* request:

```bash
SUBMITTED=""
for _ in 1 2 3 4 5; do
  sleep 1
  STATUS=$(herdr agent get "$TARGET" | jq -r '.result.agent.agent_status')
  if [ "$STATUS" = working ]; then SUBMITTED=1; break; fi
done
```

If `working` was never observed:

- Read the visible pane (`herdr agent read "$TARGET" --source visible`). If the prompt text still sits in the composer (on the `›` line), send one more **guarded** Enter (§3 pattern) and repeat the loop once.
- If the status is `done`/`idle`, the composer is empty, and the pane shows your prompt as a submitted message with output below it, the answer arrived faster than the poll — treat it as submitted and proceed to §6 (the §6 boundary check still applies).
- Otherwise stop, surface the pane content, and report — do not keep hammering Enter.

### 5. Wait for completion

Default deadline 5 minutes; use 10–15 minutes when the request is explicitly heavy (multi-file review, deep audit). Poll `agent get` every 2 s so `blocked` is caught too — a bare `agent wait --status idle` would sit through an approval dialog until timeout. Unknown/empty statuses and CLI failures are tolerated only transiently (3 consecutive polls), then fail closed:

```bash
DEADLINE=$(( $(date +%s) + 300 ))
RESULT=timeout
FAILS=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  STATUS=$(herdr agent get "$TARGET" 2>/dev/null | jq -r '.result.agent.agent_status' 2>/dev/null)
  case "$STATUS" in
    done|idle) RESULT=answered; break ;;
    blocked)   RESULT=blocked;  break ;;
    working)   FAILS=0 ;;
    *)         FAILS=$((FAILS+1)); if [ "$FAILS" -ge 3 ]; then RESULT=error; break; fi ;;
  esac
  sleep 2
done
echo "RESULT=$RESULT"
```

- `answered` → go to §6.
- `blocked` → read the visible pane and show the dialog to the user; they resolve it in the target pane themselves. Then **resume** (below).
- `timeout` → show the tail of the pane and report. Offer to resume with a longer deadline.
- `error` → surface the last raw `herdr agent get` output and stop.

**Resume path (after `blocked` or `timeout`): never re-run §3–§4 — re-sending the prompt would duplicate the request.** Resume means re-running only this §5 wait loop and then §6. Keep `$RUNDIR` and `$PROMPT_FILE` until the answer is captured so the §6 boundary still works.

### 6. Read the answer

```bash
herdr agent read "$TARGET" --source recent-unwrapped --lines 200 | jq -r '.result.read.text'
```

Identify the answer with an explicit request boundary — never just "the text at the bottom":

- **3b sends**: locate the **last occurrence** of the `Please read $PROMPT_FILE …` line. The `$RUNDIR` path is unique per run, so everything after that line is this request's exchange; the target's output within it is the answer.
- **3a sends**: locate the last occurrence of the exact prompt text. If the same text appears as an earlier request in the scrollback, or you cannot find it, say so and show the tail instead of guessing — and prefer 3b next time.

If the top of the answer is cut off, re-read with a larger `--lines`.

### 7. Report back

Include: the target pane id + agent label, the prompt (or the `$PROMPT_FILE` path when 3b was used), and the answer — verbatim when short, faithfully summarized with key passages quoted when long. Flag explicitly when the run timed out, failed closed, or was interrupted by an approval dialog. Do not claim the target "approved", "agreed", or "completed" anything unless its captured text literally supports it.

### 8. Cleanup

After the answer is captured and reported:

```bash
/bin/rm -rf "$RUNDIR"
```

On `blocked`/`timeout`, keep `$RUNDIR` for the resume path and tell the user its location. Stale run directories can always be removed with `/bin/rm -rf "${TMPDIR:-/tmp}"/herdr-pane-chat.*` — always the absolute `/bin/rm`, so cleanup is idempotent regardless of how the invoking shell aliases `rm`.

## Command reference

| Need | Command |
| --- | --- |
| List agents (JSON) | `herdr agent list` |
| One agent's status | `herdr agent get <target> \| jq -r '.result.agent.agent_status'` |
| Send text (no submit) | `herdr agent send <target> "<text>"` |
| Submit | `herdr pane send-keys <pane_id> enter` (guarded, §3) |
| Block until idle/done | `herdr agent wait <target> --status idle --timeout <ms>` |
| Read scrollback | `herdr agent read <target> --source recent-unwrapped --lines N` |

Targets accept pane ids (`w4:pP`), terminal ids, and unique agent labels — prefer the pane id resolved in §1.
