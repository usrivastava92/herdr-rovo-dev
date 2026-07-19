#!/usr/bin/env bash
#
# Regression tests for report_agent / report_custom_status in bin/herdr-lib.sh.
#
# These lock in the fix for the bug where the plugin passed a `--custom-status`
# flag to `herdr pane report-agent`. That flag does not exist on the Herdr CLI,
# so Herdr rejected the whole invocation (non-zero exit) before it reached the
# server, the agent state was never recorded, and running Rovo panes silently
# never appeared in Herdr's agents list.
#
# The tests drive the real library functions against a fake `herdr` binary that
# records every invocation and can be told to fail a given subcommand, so no
# real Herdr server (or the captain's session) is ever touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- tiny assertion helpers ------------------------------------------------
TESTS_RUN=0
TESTS_FAILED=0

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  FAIL: $1" >&2
  [ -n "${2:-}" ] && echo "        $2" >&2
}

check() { # <description> <condition-rc> [detail]
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$1" -eq 0 ]; then
    echo "  ok: $2"
  else
    fail "$2" "${3:-}"
  fi
}

assert_contains() { # <haystack-file> <needle> <description>
  if grep -Fq -- "$2" "$1"; then check 0 "$3"; else
    check 1 "$3" "expected to find: $2 in:\n$(cat "$1")"
  fi
}

assert_absent() { # <haystack-file> <needle> <description>
  if grep -Fq -- "$2" "$1"; then
    check 1 "$3" "did NOT expect to find: $2 in:\n$(cat "$1")"
  else check 0 "$3"; fi
}

assert_count() { # <haystack-file> <pattern> <expected> <description>
  local n
  n="$(grep -Fc -- "$2" "$1" 2>/dev/null || true)"
  n="${n:-0}"
  if [ "$n" -eq "$3" ]; then check 0 "$4"; else
    check 1 "$4" "expected $3 occurrence(s) of '$2', found $n"
  fi
}

# --- fake herdr + fresh env per test ---------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB="$WORK/bin/herdr"
mkdir -p "$WORK/bin"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
# Fake herdr: record the full invocation (one line per call), and optionally
# fail a named subcommand exactly like the real CLI rejecting bad args.
printf '%s\n' "$*" >> "$HERDR_STUB_LOG"
# argv is: pane <subcommand> <pane_id> ...
if [ "${2:-}" = "${HERDR_STUB_FAIL_SUBCMD:-}" ]; then
  echo "fake-herdr: simulated failure for '$2'" >&2
  exit 2
fi
exit 0
STUB_EOF
chmod +x "$STUB"

# Isolate library state entirely inside the workdir.
export HERDR_ROVO_STATE_DIR="$WORK/state"
export HERDR_BIN_PATH="$STUB"

# shellcheck source=../bin/herdr-lib.sh
source "$REPO_ROOT/bin/herdr-lib.sh"

reset_stub() { # [fail-subcommand]
  HERDR_STUB_LOG="$WORK/calls.log"
  : > "$HERDR_STUB_LOG"
  export HERDR_STUB_LOG
  export HERDR_STUB_FAIL_SUBCMD="${1:-}"
}

# ---------------------------------------------------------------------------
echo "test: custom status never uses the nonexistent report-agent flag"
reset_stub
report_agent "wT:p1" "working" "mode:plan" >/dev/null 2>"$WORK/err.log"
rc=$?
check "$rc" "report_agent returns 0 on success (got $rc)"
# The core regression guard: --custom-status must never be passed to anything.
assert_absent "$HERDR_STUB_LOG" "--custom-status" "no --custom-status flag anywhere"
assert_contains "$HERDR_STUB_LOG" "pane report-agent wT:p1" "core state reported via report-agent"
assert_contains "$HERDR_STUB_LOG" "--state working" "state passed to report-agent"
assert_contains "$HERDR_STUB_LOG" "pane report-metadata wT:p1" "custom status reported via report-metadata"
assert_contains "$HERDR_STUB_LOG" "--state-label working=mode:plan" "custom status carried as a state label"

echo "test: no custom status -> no report-metadata call"
reset_stub
report_agent "wT:p2" "idle" "" >/dev/null 2>&1
assert_contains "$HERDR_STUB_LOG" "pane report-agent wT:p2" "core state still reported"
assert_absent "$HERDR_STUB_LOG" "report-metadata" "no metadata call when custom status is empty"

echo "test: optional flags forwarded to report-agent"
reset_stub
report_agent "wT:p3" "blocked" "" "sess-123" "waiting" >/dev/null 2>&1
assert_contains "$HERDR_STUB_LOG" "--agent-session-id sess-123" "agent-session-id forwarded"
assert_contains "$HERDR_STUB_LOG" "--message waiting" "message forwarded"

echo "test: a rejected report-agent surfaces the failure (does not fail silently)"
reset_stub "report-agent"
report_agent "wT:p4" "working" "mode:plan" >/dev/null 2>"$WORK/err.log"
rc=$?
check "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "report_agent returns non-zero when Herdr rejects it (got $rc)"
assert_contains "$WORK/err.log" "report-agent' failed" "failure is logged to stderr / plugin log"
# On a failed core report we must not pretend to attach a custom status.
assert_absent "$HERDR_STUB_LOG" "report-metadata" "no metadata call after a failed core report"

echo "test: custom-status is best-effort - a metadata failure does not fail the report"
reset_stub "report-metadata"
report_agent "wT:p5" "working" "mode:plan" >/dev/null 2>"$WORK/err.log"
rc=$?
check "$rc" "report_agent still returns 0 when only report-metadata fails (got $rc)"
assert_contains "$HERDR_STUB_LOG" "pane report-agent wT:p5" "core state reported despite metadata failure"
assert_contains "$WORK/err.log" "report-metadata' (custom status) failed" "metadata failure is logged"

# ---------------------------------------------------------------------------
echo
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "PASS: $TESTS_RUN checks passed"
  exit 0
else
  echo "FAIL: $TESTS_FAILED of $TESTS_RUN checks failed" >&2
  exit 1
fi
