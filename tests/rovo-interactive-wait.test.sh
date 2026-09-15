#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/state" "$WORK/sessions/session-1"
LOG="$WORK/herdr.log"

cat > "$WORK/bin/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_STUB_LOG"
STUB
chmod +x "$WORK/bin/herdr"

run_hook() {
  local event="$1" tool="${2:-}"
  printf '{"hook_event_name":"%s","session_id":"session-1","cwd":"/tmp","attributes":{"tool_input":{"tool_name":"%s"}}}' "$event" "$tool" | env \
    HERDR_BIN_PATH="$WORK/bin/herdr" \
    HERDR_STUB_LOG="$LOG" \
    HERDR_ROVO_STATE_DIR="$WORK/state" \
    ROVO_SESSIONS_DIR="$WORK/sessions" \
    HERDR_PANE_ID="w1:p3" \
    bash "$REPO_ROOT/bin/rovo-herdr-hook"
}

last_state() {
  grep -F 'pane report-agent w1:p3' "$LOG" | tail -n1
}

assert_state() {
  if ! last_state | grep -Fq -- "--state $1"; then
    echo "FAIL: $2" >&2
    echo "last report: $(last_state)" >&2
    exit 1
  fi
}

run_hook on_tool_start ask_user_questions
assert_state blocked "interactive question start should report blocked"

run_hook on_session_start
assert_state blocked "subagent session events must not clear a pending question"

run_hook on_tool_start bash
assert_state blocked "unrelated tool events must not overwrite a pending question"

run_hook on_complete
assert_state blocked "completion must not mark a pending question done"

run_hook on_tool_end bash
assert_state blocked "unrelated tool completion must not clear a pending question"

run_hook on_user_prompt
assert_state working "answering the question should resume working"

run_hook on_complete
assert_state idle "completion after the answer should report idle"
