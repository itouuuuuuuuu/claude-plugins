---
name: herdr-pane-chat
description: Send one prompt to an AI coding agent (Claude Code, Codex, or any agent herdr detects) running in another herdr pane, wait for its answer via herdr's native agent-status tracking, and report the answer back. MUST auto-trigger (invoke the Skill tool immediately — do NOT only describe) whenever the session is inside herdr (HERDR_ENV=1) and the user wants to consult another agent or have it review/check anything in a separate pane. Hard trigger: any sentence naming an agent (codex, claude, 別の claude, 隣の pane の…) together with レビュー / 確認 / チェック / 見て / 意見 / 聞いて or English review / check / audit / consult / ask — fire even when no pane is specified; the skill discovers candidates itself. Japanese examples:「codex に確認して」「別のペインの claude に確認して」「codex にレビューしてもらって」「隣の claude に聞いて」「codex の意見が欲しい」. English examples: "ask codex", "consult the other claude", "have codex review this". Candidates come from `herdr agent list`, restricted to the current workspace ($HERDR_WORKSPACE_ID); the invoking pane ($HERDR_PANE_ID) is always excluded. Exactly one candidate → use it; multiple → ask the user; zero → report and stop (the skill never auto-starts an agent). No hooks, no markers, no UI polling — submission and completion are handled by `herdr agent prompt --wait`.
allowed-tools: Bash, Write
---

# herdr-pane-chat

One invocation = one prompt → one captured answer. Follow-ups require re-invocation (the target pane is already known then, so repeat rounds are fast). The skill never presses keys on the target agent's approval dialogs: the normal path submits through `herdr agent prompt`, which needs no keystroke at all. If the target ends up `blocked`, the dialog is surfaced to the user instead.

## Why this is simpler than the tmux-based variants

herdr tracks per-pane agent identity and status natively (`idle` / `working` / `blocked` / `done` / `unknown`), so there is no Stop hook, no UUID marker, no pending file, and no UI-string polling. Everything runs over the `herdr agent ...` CLI (socket API).

`herdr agent prompt --wait` submits **and** waits for a settled state in a single call, so there is no composer/Enter race to guard and no poll loop to write.

## Verified behavior (herdr 0.8.0, 2026-08)

- **Every `herdr` CLI command exits 0, including on failure.** Errors come back on stdout as `{"error":{"code":…,"message":…}}`. Never branch on `$?` — always inspect the JSON for `.error`.
- `agent list` / `agent get` / `agent prompt` / `agent wait` return JSON. **`agent read` returns plain text, not JSON** — do not pipe it through `jq`.
- `herdr agent prompt <target> <text>` writes the text into the composer **and submits it**. There is no separate submit step.
- `--wait` blocks until the agent reaches a settled state and returns the agent object; the settled state is `.result.agent.agent_status`. Default matches are `idle`, `done`, and `blocked`. `--until <STATUS>` (repeatable) narrows it.
- Starting from a non-working state, `--wait` first requires an observed state change within 5000 ms, otherwise it returns `agent_prompt_stalled`. A `--timeout` shorter than that returns `timeout` instead. Without `--timeout` the settled-state wait is **indefinite** — always pass one.
- `--wait` **does not track turns**: if the agent was already `working`, that in-flight turn's completion can satisfy the wait. This is why the readiness check in §2 is mandatory, not an optimization.
- `herdr agent wait <target> --until <STATUS> --timeout <MS>` waits **without sending anything**. This is the resume path.
- On completion the status is `done`; it may later settle back to `idle`.
- `agent read --source recent-unwrapped` returns unwrapped scrollback — no line-wrapping artifacts.

### Removed or renamed in 0.8.0

| Pre-0.8.0 | 0.8.0 |
| --- | --- |
| `herdr agent send <target> <text>` (wrote without submitting) | `herdr agent prompt <target> <text>` (writes **and** submits) |
| `herdr pane send-keys <pane> enter` | no `pane send-keys` subcommand; raw keys go through `herdr agent send-keys <target> <key>` |
| `herdr agent wait --status idle` | `herdr agent wait --until idle` |
| `herdr agent read … \| jq -r '.result.read.text'` | `herdr agent read …` prints the text directly |

The removed commands print their usage block and still exit 0, so a stale call looks like it worked. This is the failure mode that motivated the rewrite.

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
  if .error then "ERROR:\(.error.code):\(.error.message)"
  else .result.agents[]
    | select(.workspace_id == $ws and .pane_id != $self)
    | [.pane_id, .agent, .agent_status, .cwd, .terminal_title_stripped]
    | @tsv
  end'
```

Keep only rows whose agent label matches what the user asked for (`codex`, `claude`, …). If the user said something generic like "the agent in the other pane", every row is a candidate.

Decision rule — **never guess**:

- Exactly 1 candidate → use its `pane_id` as `$TARGET` for every following command (labels like `codex` only resolve when unique; pane ids always work).
- ≥2 candidates → present the rows (pane id, agent, status, title, cwd) and ask the user which one to target.
- 0 candidates → report that no matching agent exists in this workspace and stop. Do not start one (`herdr agent start` exists but is out of scope by design — the user launches agents themselves).

### 2. Pre-send readiness check

```bash
STATUS=$(herdr agent get "$TARGET" | jq -r 'if .error then "error" else .result.agent.agent_status end')
```

- `idle` / `done` → proceed.
- `working` → wait: `herdr agent wait "$TARGET" --until idle --until done --timeout 60000`. If that returns a timeout error, show the user the current status plus the tail of `herdr agent read "$TARGET" --source visible --lines 20` and ask whether to keep waiting or abort. Do not interrupt the target.
- `blocked` → the pane is paused on an approval dialog. Surface the visible pane content and ask the user to resolve it in that pane. Never act on its behalf.
- **Anything else** (`unknown`, empty string, `.error` present) → fail closed: send nothing, surface the raw `herdr agent get` output, stop.

**Do not skip this step.** `agent prompt --wait` does not correlate its wait with your submission, so prompting an agent that is already `working` can return the instant its *previous* turn ends — and you would then read someone else's answer as if it were yours.

### 3. Send the prompt

Every run gets a fresh private directory — `mktemp -d` creates it mode 700 and cannot be pre-seeded with a symlink:

```bash
RUNDIR=$(mktemp -d "${TMPDIR:-/tmp}/herdr-pane-chat.XXXXXXXX") || exit 1
PROMPT_FILE="$RUNDIR/prompt.md"
```

Two send paths:

#### 3a. Direct send — only for trivially safe one-liners

Allowed only when the prompt is a single line, ≤200 chars, and contains **none** of `'`, `"`, `` ` ``, `$`, `\` (so it can be single-quoted into the Bash call verbatim). Anything else — and any prompt where you may later need to correlate the answer (busy pane, likely resume) — goes through 3b.

#### 3b. File reference (default for anything long, multi-line, or containing code/quotes)

Write the prompt body to `$PROMPT_FILE` **with the Write tool, not a shell heredoc** — the body must never pass through shell parsing, so no quoting/heredoc-terminator collision is possible and the body truly may contain any characters.

The `$RUNDIR` path is unique per run, which makes the reference line a natural request boundary in the scrollback (see §5).

#### Submit and wait

```bash
RESPONSE=$(herdr agent prompt "$TARGET" "Please read $PROMPT_FILE and respond to the request inside it." \
  --wait --timeout 900000)
```

Deadline: 300000 (5 min) by default; 600000–900000 (10–15 min) when the request is explicitly heavy — multi-file review, deep audit. Never omit `--timeout`; without it the wait is indefinite.

**Hard rule: never embed a literal newline in the prompt text.** TUI composers may submit on newline, splitting one prompt into several partial messages. That is exactly what the file-reference path exists for.

### 4. Interpret the result

```bash
echo "$RESPONSE" | jq -r 'if .error then "ERROR:\(.error.code):\(.error.message)"
                          else "STATUS:\(.result.agent.agent_status)" end'
```

| Result | Meaning | Action |
| --- | --- | --- |
| `STATUS:done` / `STATUS:idle` | the agent finished its turn | go to §5 |
| `STATUS:blocked` | approval dialog | surface the visible pane, the user resolves it in that pane, then **resume** |
| `ERROR:agent_prompt_stalled:…` | the submission never moved the agent | see below |
| `ERROR:timeout:…` | still working at the deadline | show the tail of the pane, report, offer to **resume** with a longer wait |
| any other `ERROR:` | fail closed | surface the raw JSON and stop |

**Resume path — never re-run §3.** Re-prompting duplicates the request. Resume waits only:

```bash
herdr agent wait "$TARGET" --until idle --until done --until blocked --timeout 900000
```

Then go to §5. Keep `$RUNDIR` and `$PROMPT_FILE` until the answer is captured, so the §5 boundary still works.

**On `agent_prompt_stalled`**, read the visible pane (`herdr agent read "$TARGET" --source visible`):

- The prompt is sitting unsubmitted on the composer (`›`) line → re-check that the status is still `idle`/`done`, send one `herdr agent send-keys "$TARGET" enter`, then resume with `agent wait`.
- The pane shows the prompt already submitted with output below it → the turn completed faster than the state machine observed; go to §5 (the boundary check still applies).
- Anything else → stop, surface the pane content, report. Do not keep hammering.

### 5. Read the answer

```bash
herdr agent read "$TARGET" --source recent-unwrapped --lines 200
```

Plain text — no `jq`. Identify the answer with an explicit request boundary, never just "the text at the bottom":

- **3b sends**: locate the **last occurrence** of the `Please read $PROMPT_FILE …` line. The `$RUNDIR` path is unique per run, so everything after that line is this request's exchange; the target's output within it is the answer.
- **3a sends**: locate the last occurrence of the exact prompt text. If the same text appears as an earlier request in the scrollback, or you cannot find it, say so and show the tail instead of guessing — and prefer 3b next time.

If the top of the answer is cut off, re-read with a larger `--lines`.

### 6. Report back

Include: the target pane id + agent label, the prompt (or the `$PROMPT_FILE` path when 3b was used), and the answer — verbatim when short, faithfully summarized with key passages quoted when long. Flag explicitly when the run timed out, failed closed, or was interrupted by an approval dialog. Do not claim the target "approved", "agreed", or "completed" anything unless its captured text literally supports it.

### 7. Cleanup

After the answer is captured and reported:

```bash
/bin/rm -rf "$RUNDIR"
```

On `blocked`/`timeout`/`agent_prompt_stalled`, keep `$RUNDIR` for the resume path and tell the user its location. Stale run directories can always be removed with `/bin/rm -rf "${TMPDIR:-/tmp}"/herdr-pane-chat.*` — always the absolute `/bin/rm`, so cleanup is idempotent regardless of how the invoking shell aliases `rm`.

Shell aliases are a live hazard here in general: user shells alias short names to unrelated tools (`tr` → `eza` has been observed). Prefer shell builtins and parameter expansion, or absolute paths, over bare short commands.

## Command reference

| Need | Command |
| --- | --- |
| List agents (JSON) | `herdr agent list` |
| One agent's status | `herdr agent get <target> \| jq -r '.result.agent.agent_status'` |
| Send + submit + wait | `herdr agent prompt <target> "<text>" --wait --timeout <ms>` |
| Wait without sending (resume) | `herdr agent wait <target> --until idle --until done --until blocked --timeout <ms>` |
| Raw keystroke (stall recovery only) | `herdr agent send-keys <target> enter` |
| Read scrollback (**plain text**) | `herdr agent read <target> --source recent-unwrapped --lines N` |

Targets accept pane ids (`w4:pP`), terminal ids, and unique agent labels — prefer the pane id resolved in §1.

Every one of these exits 0 on failure. Check the JSON for `.error` before trusting a result.
