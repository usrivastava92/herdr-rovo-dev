#!/usr/bin/env bash
#
# Regression tests for classify_state (bin/herdr-lib.sh) and its use by
# scan-rovo-panes.
#
# Live symptom this locks in a fix for: an old Rovo pane that predates hook
# installation (no hook-active marker, so the scanner's screen-scrape
# fallback is the only source of truth) is genuinely idle on screen, but
# scan-rovo-panes reports it as "working". Cause: classify_state's
# `pane read --source recent-unwrapped --lines N` can return real scrollback,
# not just the current viewport - a stale "Rovo Dev is thinking" (or a stale
# tool-call line) from an earlier turn can still be present higher up in that
# window even though the pane is now sitting quietly at an idle prompt. The
# old classifier matched patterns against the WHOLE fetched window, so that
# stale text outvoted the current, genuinely-idle bottom-of-screen prompt.
#
# The fix restricts pattern matching to a small slice near the bottom of the
# fetched output (as close to "what's actually on screen right now" as a
# plain scrollback read gets), independent of how much is fetched.
#
# No real Herdr server (or the captain's session) is ever touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- tiny assertion helpers (mirrors the other tests/*.test.sh files) ------
TESTS_RUN=0
TESTS_FAILED=0

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  FAIL: $1" >&2
  [ -n "${2:-}" ] && echo "        $2" >&2
}

check() { # <condition-rc> <description> [detail]
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$1" -eq 0 ]; then
    echo "  ok: $2"
  else
    fail "$2" "${3:-}"
  fi
}

assert_eq() { # <actual> <expected> <description>
  if [ "$1" = "$2" ]; then check 0 "$3"; else
    check 1 "$3" "expected '$2', got '$1'"
  fi
}

assert_contains() { # <haystack-file> <needle> <description>
  if grep -Fq -- "$2" "$1" 2>/dev/null; then check 0 "$3"; else
    check 1 "$3" "expected to find: $2 in:\n$(cat "$1" 2>/dev/null)"
  fi
}

# --- fake herdr + fresh env -------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB="$WORK/bin/herdr"
mkdir -p "$WORK/bin"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
# Fake herdr: records every invocation and serves controllable fixtures for
# `pane list`, `pane process-info`, and `pane read` (the screen buffer),
# enough to drive both classify_state directly and scan-rovo-panes end to end
# with no real Herdr server.
printf '%s\n' "$*" >> "${HERDR_STUB_LOG:-/dev/null}"

if [ "${1:-}" = "pane" ] && [ "${2:-}" = "read" ]; then
  cat "${HERDR_STUB_SCREEN:-/dev/null}" 2>/dev/null
  exit 0
fi

if [ "${1:-}" = "pane" ] && [ "${2:-}" = "list" ]; then
  cat "${HERDR_STUB_PANE_LIST:-/dev/null}" 2>/dev/null
  exit 0
fi

if [ "${1:-}" = "pane" ] && [ "${2:-}" = "process-info" ]; then
  cat "${HERDR_STUB_PROCESS_INFO:-/dev/null}" 2>/dev/null
  exit 0
fi

exit 0
STUB_EOF
chmod +x "$STUB"

export HERDR_ROVO_STATE_DIR="$WORK/state"
export HERDR_BIN_PATH="$STUB"
export HERDR_STUB_SCREEN="$WORK/screen.txt"
export HERDR_STUB_PANE_LIST="$WORK/pane-list.json"
export HERDR_STUB_PROCESS_INFO="$WORK/process-info.json"

reset_stub() {
  HERDR_STUB_LOG="$WORK/calls.log"
  : > "$HERDR_STUB_LOG"
  export HERDR_STUB_LOG
}

# shellcheck source=../bin/herdr-lib.sh
source "$REPO_ROOT/bin/herdr-lib.sh"

# --- screen fixtures ---------------------------------------------------------
#
# Every fixture pads well past ROVO_STATE_SLICE_LINES worth of filler between
# any "stale" (earlier-turn) status text and the CURRENT bottom-of-screen
# footer, so a fix that only looks at the bottom slice provably ignores the
# stale text, and the unfixed whole-window matcher provably does not.
filler() { # <count>
  local i
  for i in $(seq 1 "$1"); do
    printf 'assistant response line %d from an earlier turn\n' "$i"
  done
}

idle_footer() { printf '> agent mode: default\n? for shortcuts\n'; }
working_footer_thinking() { printf 'Rovo is thinking..\nEnter to queue, Ctrl+Enter to steer\n'; }
working_footer_queue() { printf 'Enter to queue, Ctrl+Enter to steer\n'; }
blocked_footer() { printf 'Do you want to proceed? [y/n]\n'; }
unrecognized_footer() { printf 'a plain line of output with no recognizable status text\n'; }

write_screen() { # <top-lines-producer-output> written verbatim, then a blank separator
  cat > "$HERDR_STUB_SCREEN"
}

# =============================================================================
echo "test: classify_state - stale 'thinking' scrolled above a current idle prompt => idle"
{
  printf 'Rovo Dev is thinking..\nEsc to interrupt\n'
  filler 30
  idle_footer
} | write_screen
result="$(classify_state "wT:c1")"
assert_eq "$result" "idle" "stale working text above the bottom slice does not outvote the current idle footer"

# =============================================================================
echo
echo "test: classify_state - stale tool-call line scrolled above a current idle prompt => idle"
{
  printf '▶ running tool | bash_command\n'
  filler 30
  idle_footer
} | write_screen
result="$(classify_state "wT:c2")"
assert_eq "$result" "idle" "a stale tool-call indicator above the bottom slice does not outvote the current idle footer"

# =============================================================================
echo
echo "test: classify_state - assistant message QUOTING 'Rovo Dev is thinking' exactly 14 lines from the bottom, current idle footer at the very bottom => idle (live false positive: w1:p3)"
# Live audit found a visibly-idle pane misclassified as working because its
# own assistant message happened to mention the phrase "Rovo Dev is
# thinking" - not a status line at all, just prose - 14 lines from the
# bottom. That was inside the old ROVO_STATE_SLICE_LINES=15 default (so it
# still misclassified), but is outside the new default of 8. Position from
# the bottom, inclusive of the stale line itself: 1 (the stale line) + 11
# filler lines after it + 2 idle-footer lines = 14.
{
  filler 3
  printf 'I mentioned earlier that "Rovo Dev is thinking" was the status shown.\n'
  filler 11
  idle_footer
} | write_screen
# ROVO_STATE_SLICE_LINES is `readonly` once bin/herdr-lib.sh has been
# sourced, so overriding it for one call means sourcing it fresh in a brand
# new bash PROCESS (a subshell of *this* shell would just inherit the
# already-readonly binding, and a plain `VAR=val bash -c ...` prefix is
# itself an assignment in *this* shell and gets rejected the same way) -
# `env` sets it in the child's environment without ever assigning it here.
# This is exactly what happens for real whenever classify_state runs, since
# it's always invoked from a fresh process (scan-rovo-panes, or the hook).
result="$(env ROVO_STATE_SLICE_LINES=15 bash -c '
  source "$1/bin/herdr-lib.sh"
  classify_state "$2"
' _ "$REPO_ROOT" "wT:c2b")"
assert_eq "$result" "working" \
  "sanity: this fixture DOES reproduce the live false positive under the old slice=15 default"
result="$(classify_state "wT:c2b")"
assert_eq "$result" "idle" \
  "under the current slice=8 default, prose merely quoting a status phrase 14 lines up no longer outvotes the current idle footer"

# =============================================================================
echo
echo "test: classify_state - live 'thinking' footer at the bottom => working"
{
  filler 5
  working_footer_thinking
} | write_screen
result="$(classify_state "wT:c3")"
assert_eq "$result" "working" "a genuinely current thinking footer is still detected as working"

# =============================================================================
echo
echo "test: classify_state - live 'Enter to queue, Ctrl+Enter to steer' at the bottom => working"
{
  filler 5
  working_footer_queue
} | write_screen
result="$(classify_state "wT:c4")"
assert_eq "$result" "working" "a genuinely current queue-hint footer is still detected as working"

# =============================================================================
echo
echo "test: classify_state - permission prompt at the bottom => blocked"
{
  filler 5
  blocked_footer
} | write_screen
result="$(classify_state "wT:c5")"
assert_eq "$result" "blocked" "a genuinely current permission prompt is still detected as blocked"

# =============================================================================
echo
echo "test: classify_state - unrecognized bottom content => unknown"
{
  filler 5
  unrecognized_footer
} | write_screen
result="$(classify_state "wT:c6")"
assert_eq "$result" "unknown" "content matching none of the patterns falls through to unknown"

# =============================================================================
echo
echo "test: scan-rovo-panes - an old, non-hooked pane with stale scrollback 'thinking' text and a current idle prompt is reported idle, not working"
reset_stub
PANE="wT:old1"
cat > "$HERDR_STUB_PANE_LIST" <<EOF
{"panes":[{"pane_id":"$PANE"}]}
EOF
cat > "$HERDR_STUB_PROCESS_INFO" <<'EOF'
{"process_info":{"foreground_processes":[{"cmdline":"rovo"}]}}
EOF
{
  printf 'Rovo Dev is thinking..\nEsc to interrupt\n'
  filler 30
  idle_footer
} | write_screen

# No hook-active marker exists for this pane (it predates hooks), so the
# scanner must fall back to classify_state - this is the exact scenario from
# the live bug report.
pane_hook_active "$PANE" && fail "test setup: pane must NOT have an active hook marker" || true

(cd "$REPO_ROOT" && "$REPO_ROOT/bin/scan-rovo-panes") > "$WORK/scan-output.log" 2>&1
scan_rc=$?
check "$([ "$scan_rc" -eq 0 ] && echo 0 || echo 1)" "scan-rovo-panes exits 0" "scan output:\n$(cat "$WORK/scan-output.log")"

assert_contains "$HERDR_STUB_LOG" "pane report-agent $PANE" "the pane was reported"
last_report="$(grep -F "pane report-agent $PANE" "$HERDR_STUB_LOG" | tail -1)"
printf '%s' "$last_report" | grep -Fq -- "--state idle" \
  && check 0 "scanner reports idle for the old, non-hooked pane (not working)" \
  || check 1 "scanner reports idle for the old, non-hooked pane (not working)" "last report line: $last_report"

# ---------------------------------------------------------------------------
echo
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "PASS: $TESTS_RUN checks passed"
  exit 0
else
  echo "FAIL: $TESTS_FAILED of $TESTS_RUN checks failed" >&2
  exit 1
fi
