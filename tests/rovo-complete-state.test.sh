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
exit 0
STUB
chmod +x "$WORK/bin/herdr"

payload='{"hook_event_name":"on_complete","session_id":"session-1","cwd":"/tmp","attributes":{}}'
printf '%s' "$payload" | env \
  PATH="$WORK/bin:$PATH" \
  HERDR_BIN_PATH="$WORK/bin/herdr" \
  HERDR_STUB_LOG="$LOG" \
  HERDR_ROVO_STATE_DIR="$WORK/state" \
  ROVO_SESSIONS_DIR="$WORK/sessions" \
  HERDR_PANE_ID="w1:p3" \
  HERDR_TAB_ID="w1:t3" \
  bash "$REPO_ROOT/bin/rovo-herdr-hook"

status=0
if ! grep -F "pane report-agent w1:p3" "$LOG" | grep -Fq -- "--state idle"; then
  echo "FAIL: on_complete should synchronously report idle" >&2
  status=1
fi
if ! grep -F "pane report-metadata w1:p3" "$LOG" | grep -Fq -- "--state-label idle=done"; then
  echo "FAIL: on_complete should synchronously label idle as done" >&2
  status=1
fi
complete_report="$(grep -F 'pane report-agent w1:p3' "$LOG" | tail -n1)"
if ! printf '%s' "$complete_report" | grep -Eq -- '--seq [0-9]{16,}([[:space:]]|$)'; then
  echo "FAIL: completion should use a high-resolution lifecycle sequence" >&2
  status=1
fi

exit "$status"
