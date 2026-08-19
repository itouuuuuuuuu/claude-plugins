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

- Success goes to **stdout** with exit 0. Failure goes to **stderr** with a non-zero exit: `1` for an API error (`agent_not_found`, `timeout`, …), carrying `{"error":{"code":…,"message":…}}`; `2` for an unknown subcommand or option, carrying a plain-text usage block or `unknown option: …`. Capture `2>&1` and check both the exit code and the payload — a call that only reads stdout sees nothing at all on failure.
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
| `herdr pane send-keys <pane> enter` as the submit step | no longer needed — `agent prompt` submits. `pane send-keys` and `agent send-keys` both still exist for raw keys |
| `herdr agent wait --status idle` | `herdr agent wait --until idle` |
| `herdr agent read … \| jq -r '.result.read.text'` | `herdr agent read …` prints the text directly |

`agent send` is gone outright and `agent wait --status` is rejected as an unknown option; both fail with exit 2 and a usage block on stderr. A caller that pipes into `jq` without redirecting stderr sees an empty stdout and a jq parse error rather than the actual message, which is how the 1.0.0 flow failed obscurely.

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
AGENTS=$(herdr agent list 2>&1) || { echo "$AGENTS"; exit 1; }
case "$AGENTS" in *'"error"'*) echo "$AGENTS"; exit 1 ;; esac

printf '%s' "$AGENTS" | jq -r --arg ws "$WS" --arg self "$SELF_PANE" '
  .result.agents[]
  | select(.workspace_id == $ws and .pane_id != $self)
  | [.pane_id, .agent, .agent_status, .cwd, .terminal_title_stripped]
  | @tsv'
```

**Check the call before reading its output.** A failed `agent list` writes to stderr and leaves stdout empty, so piping it straight into `jq` produces no rows — indistinguishable from a genuine "no agents here". Reporting *"no matching agent exists"* when the socket call actually failed sends the user hunting for the wrong problem. Empty output counts as zero candidates **only after** the call is known to have succeeded.

Keep only rows whose agent label matches what the user asked for (`codex`, `claude`, …). If the user said something generic like "the agent in the other pane", every row is a candidate.

Decision rule — **never guess**:

- Exactly 1 candidate → use its `pane_id` as `$TARGET` for every following command (labels like `codex` only resolve when unique; pane ids always work).
- ≥2 candidates → present the rows (pane id, agent, status, title, cwd) and ask the user which one to target.
- 0 candidates → report that no matching agent exists in this workspace and stop. Do not start one (`herdr agent start` exists but is out of scope by design — the user launches agents themselves).

### 2. Pre-send readiness check

Calls that answer with an agent object — `agent get`, `agent prompt --wait`, `agent wait` — go through one helper that reduces the response (success, API error, or usage block) to a single string. Define it once per Bash invocation; each tool call starts a fresh shell, so it does not carry over:

```bash
hq() {                                   # hq herdr agent get "$TARGET"
  local out rc
  out=$("$@" 2>&1); rc=$?                # errors land on stderr, so capture it
  case "$out" in
    '{'*) printf '%s' "$out" | jq -r 'if .error then "ERROR:\(.error.code):\(.error.message)"
                                      else "STATUS:\(.result.agent.agent_status)" end' ;;
    *)    printf 'ERROR:exit%s:%s\n' "$rc" "${out%%$'\n'*}" ;;   # usage block, unknown option
  esac
}

READY=$(hq herdr agent get "$TARGET")
```

The `case` arm matters: a removed subcommand answers with a usage block, not JSON, and piping that straight into `jq` yields a parse error instead of the reason.

Calls that do **not** answer with an agent object — `agent send-keys` in the stall recovery — need their own check, since there is no `agent_status` to read:

```bash
hrun() {                                 # hrun herdr agent send-keys "$TARGET" enter
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then printf 'ERROR:exit%s:%s\n' "$rc" "${out%%$'\n'*}"
  elif [ "${out#*'"error"'}" != "$out" ]; then printf 'ERROR:%s\n' "${out%%$'\n'*}"
  else printf 'OK\n'; fi
}
```

`agent list` (§1) is the third shape — its payload is a list, not a status — and is checked inline there.

- `STATUS:idle` / `STATUS:done` → proceed to §3.
- `STATUS:working` → wait, and **check the wait's own result the same way**:

  ```bash
  READY=$(hq herdr agent wait "$TARGET" --until idle --until done --timeout 60000)
  ```

  Only `STATUS:idle` / `STATUS:done` may proceed. On `ERROR:timeout:…` show the user the current status plus the tail of `herdr agent read "$TARGET" --source visible --lines 20` and ask whether to keep waiting or abort. On any other `ERROR:` fail closed. Do not interrupt the target.
- `STATUS:blocked` → the pane is paused on an approval dialog. Surface the visible pane content and ask the user to resolve it in that pane. Never act on its behalf.
- **Anything else** (`STATUS:unknown`, empty string, any `ERROR:`) → fail closed: send nothing, surface the raw response, stop.

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

```bash
RESPONSE=$(hq herdr agent prompt "$TARGET" '<single-line prompt text>' --wait --timeout 900000)
```

#### 3b. File reference (default for anything long, multi-line, or containing code/quotes)

Write the prompt body to `$PROMPT_FILE` **with the Write tool, not a shell heredoc** — the body must never pass through shell parsing, so no quoting/heredoc-terminator collision is possible and the body truly may contain any characters.

The `$RUNDIR` path is unique per run, which makes the reference line a natural request boundary in the scrollback (see §5).

```bash
RESPONSE=$(hq herdr agent prompt "$TARGET" "Please read $PROMPT_FILE and respond to the request inside it." \
  --wait --timeout 900000)
```

#### Deadline and hard rules

Both paths produce `$RESPONSE`, which §4 interprets.

Deadline: 300000 (5 min) by default; 600000–900000 (10–15 min) when the request is explicitly heavy — multi-file review, deep audit. Never omit `--timeout`; without it the wait is indefinite.

**Hard rule: never embed a literal newline in the prompt text.** TUI composers may submit on newline, splitting one prompt into several partial messages. That is exactly what the file-reference path exists for.

### 4. Interpret the result

`$RESPONSE` already holds a `STATUS:…` or `ERROR:…` string — `hq` did the reduction.

| Result | Meaning | Action |
| --- | --- | --- |
| `STATUS:done` / `STATUS:idle` | the agent finished its turn | go to §5 |
| `STATUS:blocked` | approval dialog | surface the visible pane, the user resolves it in that pane, then **resume** |
| `ERROR:agent_prompt_stalled:…` | the submission never moved the agent | see below |
| `ERROR:timeout:…` | still working at the deadline | show the tail of the pane, report, offer to **resume** with a longer wait |
| any other `ERROR:` | fail closed | surface the raw JSON and stop |

**Resume path — never re-run §3.** Re-prompting duplicates the request. Resume waits only:

```bash
RESPONSE=$(hq herdr agent wait "$TARGET" --until idle --until done --until blocked --timeout 900000)
```

`agent wait` returns the same JSON shape as `agent prompt --wait`, so **feed `$RESPONSE` back through the §4 table** — it can time out again, come back `blocked`, or carry an `.error`. Only `STATUS:done` / `STATUS:idle` may proceed to §5; anything else loops back here or stops. Never read the scrollback on an unresolved status: the turn is still in flight and the output is partial.

Keep `$RUNDIR` and `$PROMPT_FILE` until the answer is captured, so the §5 boundary still works.

**On `agent_prompt_stalled`**, read the visible pane (`herdr agent read "$TARGET" --source visible`):

- The prompt is sitting unsubmitted on the composer (`›`) line → re-check that the status is still `idle`/`done`, then send exactly one Enter and **verify it landed** before waiting on it:

  ```bash
  [ "$(hrun herdr agent send-keys "$TARGET" enter)" = OK ] || { echo "keystroke failed"; exit 1; }
  RESPONSE=$(hq herdr agent wait "$TARGET" --until idle --until done --until blocked --timeout 900000)
  ```

  Without that check a rejected keystroke is followed by a wait on an agent that was never prompted, which then times out — or worse, settles on unrelated activity — and the failure is reported as the target being slow. Interpret `$RESPONSE` through the §4 table as usual.
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

All of these report failure on **stderr** with a non-zero exit, so none of them is ever called bare or piped straight into `jq`:

| Response shape | Checked by |
| --- | --- |
| agent object (`get`, `prompt --wait`, `wait`) | `hq` (§2) |
| acknowledgement (`send-keys`) | `hrun` (§2) |
| list payload (`list`) | inline exit + `"error"` check (§1) |
| plain text (`read`) | read directly — not JSON, no `jq` |
