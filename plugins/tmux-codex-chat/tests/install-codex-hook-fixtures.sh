#!/usr/bin/env bash
#
# install-codex-hook-fixtures.sh — fixture-based black-box tests for the
# tmux-codex-chat plugin's install-codex-hook.sh.
#
# Strategy: each test creates a fresh fake $CODEX_HOME inside an mktemp dir,
# points the installer at it via the CODEX_HOME env var, and asserts on the
# resulting filesystem state. The host's real ~/.codex is never touched.
#
# Run: bash tests/install-codex-hook-fixtures.sh
#      (returns non-zero if any assertion fails)
#
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SELF_DIR/.." && pwd)"
INSTALLER="$PLUGIN_ROOT/scripts/install-codex-hook.sh"
SRC_HOOK="$PLUGIN_ROOT/codex-hook/tmux-codex-chat-stop.sh"

[ -x "$INSTALLER" ] || { echo "FATAL: installer not executable at $INSTALLER" >&2; exit 2; }
[ -f "$SRC_HOOK" ]  || { echo "FATAL: hook source missing at $SRC_HOOK" >&2; exit 2; }

PASS=0
FAIL=0

# Per-test workspace; each test_* function gets a clean fake CODEX_HOME.
mk_fake_codex() {
  local fake
  fake=$(mktemp -d)
  mkdir -p "$fake/.codex/hooks"
  mkdir -p "$fake/.codex/sessions/2026/05/08"
  printf '[features]\ncodex_hooks = true\n' > "$fake/.codex/config.toml"
  echo "$fake"
}

# Run installer with a fake CODEX_HOME. Quote-safe.
run_installer() {
  local fake_codex_home="$1"; shift
  CODEX_HOME="$fake_codex_home" NO_COLOR=1 bash "$INSTALLER" "$@"
}

assert() {
  local desc="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS+1))
    printf '  PASS: %s\n' "$desc"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL: %s\n' "$desc" >&2
  fi
}

# Count Stop wrappers whose hooks[] include our DEST_HOOK command.
count_stop_entries_for() {
  local hooks_json="$1" dest="$2"
  jq --arg cmd "$dest" '[.hooks.Stop[]?.hooks[]? | select(.command == $cmd)] | length' "$hooks_json" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# Test 1: --install on a fresh fake home creates Stop entry and copies hook
# ---------------------------------------------------------------------------
test_fresh_install() {
  echo "=== test_fresh_install ==="
  local home; home=$(mk_fake_codex)
  local hooks_json="$home/.codex/hooks.json"
  local dest_hook="$home/.codex/hooks/tmux-codex-chat-stop.sh"

  # No hooks.json exists yet — installer should create the skeleton.
  run_installer "$home/.codex" --install >/dev/null

  assert "hooks.json was created"      "[ -f '$hooks_json' ]"
  assert "hook script was copied"      "[ -x '$dest_hook' ]"
  assert "hook script SHA matches src" "[ \"\$(shasum -a 256 < '$dest_hook' | cut -d' ' -f1)\" = \"\$(shasum -a 256 < '$SRC_HOOK' | cut -d' ' -f1)\" ]"
  local n; n=$(count_stop_entries_for "$hooks_json" "$dest_hook")
  assert "exactly 1 Stop entry"        "[ '$n' = 1 ]"

  rm -rf "$home"
}

# ---------------------------------------------------------------------------
# Test 2: --install is idempotent (3 consecutive runs leave 1 entry)
# ---------------------------------------------------------------------------
test_idempotent() {
  echo "=== test_idempotent ==="
  local home; home=$(mk_fake_codex)
  local hooks_json="$home/.codex/hooks.json"
  local dest_hook="$home/.codex/hooks/tmux-codex-chat-stop.sh"

  run_installer "$home/.codex" --install >/dev/null
  run_installer "$home/.codex" --install >/dev/null
  run_installer "$home/.codex" --install >/dev/null

  local n; n=$(count_stop_entries_for "$hooks_json" "$dest_hook")
  assert "still exactly 1 Stop entry after 3 runs" "[ '$n' = 1 ]"

  # 3 backups should exist (one per run)
  local backup_count
  backup_count=$(ls -1 "$home/.codex/"hooks.json.bak.* 2>/dev/null | wc -l | tr -d ' ')
  assert "3 backup files accumulated" "[ '$backup_count' = 3 ]"

  rm -rf "$home"
}

# ---------------------------------------------------------------------------
# Test 3: existing PreToolUse / PostToolUse must survive untouched
# ---------------------------------------------------------------------------
test_preserve_other_hooks() {
  echo "=== test_preserve_other_hooks ==="
  local home; home=$(mk_fake_codex)
  local hooks_json="$home/.codex/hooks.json"

  # Seed hooks.json with PreToolUse and PostToolUse entries the user
  # might have configured for unrelated reasons.
  cat > "$hooks_json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": "/usr/bin/true", "matcher": "Bash"}]}
    ],
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": "/usr/bin/true", "matcher": "Edit"}]}
    ]
  }
}
JSON
  local before_pre before_post
  before_pre=$(jq '.hooks.PreToolUse'  "$hooks_json")
  before_post=$(jq '.hooks.PostToolUse' "$hooks_json")

  run_installer "$home/.codex" --install >/dev/null

  local after_pre after_post
  after_pre=$(jq '.hooks.PreToolUse'   "$hooks_json")
  after_post=$(jq '.hooks.PostToolUse' "$hooks_json")

  assert "PreToolUse unchanged"  "[ \"\$before_pre\"  = \"\$after_pre\"  ]"
  assert "PostToolUse unchanged" "[ \"\$before_post\" = \"\$after_post\" ]"

  rm -rf "$home"
}

# ---------------------------------------------------------------------------
# Test 4: --uninstall removes only our entry and the hook script
# ---------------------------------------------------------------------------
test_uninstall() {
  echo "=== test_uninstall ==="
  local home; home=$(mk_fake_codex)
  local hooks_json="$home/.codex/hooks.json"
  local dest_hook="$home/.codex/hooks/tmux-codex-chat-stop.sh"

  # Seed with PostToolUse to verify it survives uninstall too.
  cat > "$hooks_json" <<'JSON'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": "/usr/bin/true", "matcher": "Edit"}]}
    ]
  }
}
JSON

  run_installer "$home/.codex" --install   >/dev/null
  run_installer "$home/.codex" --uninstall >/dev/null

  local n; n=$(count_stop_entries_for "$hooks_json" "$dest_hook")
  assert "Stop entry removed"             "[ '$n' = 0 ]"
  assert "hook script removed"            "[ ! -e '$dest_hook' ]"
  assert "PostToolUse still present"      "jq -e '.hooks.PostToolUse | length == 1' '$hooks_json' >/dev/null"

  rm -rf "$home"
}

# ---------------------------------------------------------------------------
# Test 5: --uninstall preserves a hand-edited hook script (SHA mismatch)
# ---------------------------------------------------------------------------
test_uninstall_preserves_modified_hook() {
  echo "=== test_uninstall_preserves_modified_hook ==="
  local home; home=$(mk_fake_codex)
  local dest_hook="$home/.codex/hooks/tmux-codex-chat-stop.sh"

  run_installer "$home/.codex" --install >/dev/null

  # User manually edits the hook script.
  echo "# user-added comment" >> "$dest_hook"

  run_installer "$home/.codex" --uninstall >/dev/null

  assert "modified hook script preserved" "[ -f '$dest_hook' ]"

  rm -rf "$home"
}

# ---------------------------------------------------------------------------
# Test 6: malformed hooks.json is refused (.hooks not an object)
# ---------------------------------------------------------------------------
test_refuse_malformed_hooks_object() {
  echo "=== test_refuse_malformed_hooks_object ==="
  local home; home=$(mk_fake_codex)
  local hooks_json="$home/.codex/hooks.json"

  echo '{"hooks": "invalid"}' > "$hooks_json"
  local before_mt
  before_mt=$(stat -f '%m' "$hooks_json" 2>/dev/null || stat -c '%Y' "$hooks_json")
  local before_sha
  before_sha=$(shasum -a 256 < "$hooks_json" | cut -d' ' -f1)

  set +e
  run_installer "$home/.codex" --install >/dev/null 2>&1
  local rc=$?
  set -e

  local after_mt after_sha
  after_mt=$(stat -f '%m' "$hooks_json" 2>/dev/null || stat -c '%Y' "$hooks_json")
  after_sha=$(shasum -a 256 < "$hooks_json" | cut -d' ' -f1)

  assert "installer exited non-zero"       "[ '$rc' != 0 ]"
  assert "hooks.json mtime unchanged"      "[ '$before_mt' = '$after_mt' ]"
  assert "hooks.json content unchanged"    "[ '$before_sha' = '$after_sha' ]"

  rm -rf "$home"
}

# ---------------------------------------------------------------------------
# Test 7: malformed hooks.json is refused (.hooks.Stop not an array)
# ---------------------------------------------------------------------------
test_refuse_malformed_stop_array() {
  echo "=== test_refuse_malformed_stop_array ==="
  local home; home=$(mk_fake_codex)
  local hooks_json="$home/.codex/hooks.json"

  echo '{"hooks": {"Stop": "not-an-array"}}' > "$hooks_json"
  local before_sha
  before_sha=$(shasum -a 256 < "$hooks_json" | cut -d' ' -f1)

  set +e
  run_installer "$home/.codex" --install >/dev/null 2>&1
  local rc=$?
  set -e

  local after_sha
  after_sha=$(shasum -a 256 < "$hooks_json" | cut -d' ' -f1)

  assert "installer exited non-zero"   "[ '$rc' != 0 ]"
  assert "hooks.json content unchanged" "[ '$before_sha' = '$after_sha' ]"

  rm -rf "$home"
}

# ---------------------------------------------------------------------------
# Test 8: symlinked hooks.json is refused
# ---------------------------------------------------------------------------
test_refuse_symlinked_hooks_json() {
  echo "=== test_refuse_symlinked_hooks_json ==="
  local home; home=$(mk_fake_codex)
  local hooks_json="$home/.codex/hooks.json"
  local real_target="$home/.codex/hooks.json.real"

  echo '{"hooks":{}}' > "$real_target"
  ln -s "$real_target" "$hooks_json"

  local before_sha
  before_sha=$(shasum -a 256 < "$real_target" | cut -d' ' -f1)

  set +e
  run_installer "$home/.codex" --install >/dev/null 2>&1
  local rc=$?
  set -e

  local after_sha
  after_sha=$(shasum -a 256 < "$real_target" | cut -d' ' -f1)

  assert "installer exited non-zero"     "[ '$rc' != 0 ]"
  assert "symlink target unchanged"      "[ '$before_sha' = '$after_sha' ]"
  assert "symlink itself preserved"      "[ -L '$hooks_json' ]"

  rm -rf "$home"
}

# ---------------------------------------------------------------------------
# Test 9: --check produces all 6 health-report items
# ---------------------------------------------------------------------------
test_check_six_items() {
  echo "=== test_check_six_items ==="
  local home; home=$(mk_fake_codex)

  run_installer "$home/.codex" --install >/dev/null

  local out
  out=$(run_installer "$home/.codex" --check 2>&1)

  # Every line should start with one of the four prefixes; we just need to
  # count enough total lines to cover all 6 items.
  local total
  total=$(printf '%s\n' "$out" | grep -cE '^\[(OK|WARN|FAIL|INFO)\]')
  assert "6 prefixed report lines (got $total)" "[ '$total' -ge 6 ]"

  printf '%s\n' "$out" | grep -q '\[OK\].*jq'                      && PASS=$((PASS+1)) && echo "  PASS: jq line"        || { FAIL=$((FAIL+1)); echo "  FAIL: jq line missing"; }
  printf '%s\n' "$out" | grep -q '\[OK\].*Stop entry'              && PASS=$((PASS+1)) && echo "  PASS: Stop entry line" || { FAIL=$((FAIL+1)); echo "  FAIL: Stop entry line missing"; }
  printf '%s\n' "$out" | grep -q '\[OK\].*hook script executable'  && PASS=$((PASS+1)) && echo "  PASS: hook script line" || { FAIL=$((FAIL+1)); echo "  FAIL: hook script line missing"; }
  printf '%s\n' "$out" | grep -q '\[OK\].*matches plugin source'   && PASS=$((PASS+1)) && echo "  PASS: integrity line"   || { FAIL=$((FAIL+1)); echo "  FAIL: integrity line missing"; }
  printf '%s\n' "$out" | grep -q '\[OK\].*codex_hooks = true'      && PASS=$((PASS+1)) && echo "  PASS: config.toml line"  || { FAIL=$((FAIL+1)); echo "  FAIL: config.toml line missing"; }
  printf '%s\n' "$out" | grep -qE '\[INFO\].*hooks\.json|restart'  && PASS=$((PASS+1)) && echo "  PASS: restart-reminder line" || { FAIL=$((FAIL+1)); echo "  FAIL: restart-reminder line missing"; }

  rm -rf "$home"
}

# ---------------------------------------------------------------------------
# Test 10: --check warns when installed script differs from plugin source
# ---------------------------------------------------------------------------
test_check_integrity_warn() {
  echo "=== test_check_integrity_warn ==="
  local home; home=$(mk_fake_codex)
  local dest_hook="$home/.codex/hooks/tmux-codex-chat-stop.sh"

  run_installer "$home/.codex" --install >/dev/null
  echo "# drift" >> "$dest_hook"

  local out
  out=$(run_installer "$home/.codex" --check 2>&1)

  printf '%s\n' "$out" | grep -q '\[WARN\].*differs from plugin source' \
    && { PASS=$((PASS+1)); echo "  PASS: integrity WARN emitted"; } \
    || { FAIL=$((FAIL+1)); echo "  FAIL: integrity WARN missing"; }

  rm -rf "$home"
}

# ---------------------------------------------------------------------------
# Test 11: --check fails when codex_hooks = true is missing
# ---------------------------------------------------------------------------
test_check_codex_hooks_false() {
  echo "=== test_check_codex_hooks_false ==="
  local home; home=$(mk_fake_codex)

  printf '[features]\n# codex_hooks not set\n' > "$home/.codex/config.toml"
  run_installer "$home/.codex" --install >/dev/null 2>/dev/null  # warn but succeed

  set +e
  local out
  out=$(run_installer "$home/.codex" --check 2>&1)
  local rc=$?
  set -e

  printf '%s\n' "$out" | grep -q '\[FAIL\].*codex_hooks = true NOT found' \
    && { PASS=$((PASS+1)); echo "  PASS: codex_hooks FAIL emitted"; } \
    || { FAIL=$((FAIL+1)); echo "  FAIL: expected FAIL line missing"; }
  assert "exit code non-zero" "[ '$rc' != 0 ]"

  rm -rf "$home"
}

# ---------------------------------------------------------------------------
# Test 12: --check is read-only (hooks.json mtime unchanged)
# ---------------------------------------------------------------------------
test_check_readonly() {
  echo "=== test_check_readonly ==="
  local home; home=$(mk_fake_codex)
  local hooks_json="$home/.codex/hooks.json"

  run_installer "$home/.codex" --install >/dev/null
  local before_mt
  before_mt=$(stat -f '%m' "$hooks_json" 2>/dev/null || stat -c '%Y' "$hooks_json")

  sleep 1
  run_installer "$home/.codex" --check >/dev/null 2>&1 || true

  local after_mt
  after_mt=$(stat -f '%m' "$hooks_json" 2>/dev/null || stat -c '%Y' "$hooks_json")
  assert "hooks.json mtime unchanged after --check" "[ '$before_mt' = '$after_mt' ]"

  rm -rf "$home"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_fresh_install
test_idempotent
test_preserve_other_hooks
test_uninstall
test_uninstall_preserves_modified_hook
test_refuse_malformed_hooks_object
test_refuse_malformed_stop_array
test_refuse_symlinked_hooks_json
test_check_six_items
test_check_integrity_warn
test_check_codex_hooks_false
test_check_readonly

echo ""
echo "==============================================="
printf 'Summary: %d pass / %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
