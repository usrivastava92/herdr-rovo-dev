#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/state" "$WORK/sessions/session-1" "$WORK/sessions/session-2"
LOG="$WORK/herdr.log"

cat > "$WORK/bin/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_STUB_LOG"
exit 0
STUB
chmod +x "$WORK/bin/herdr"

cat > "$WORK/sessions/session-1/metadata.json" <<'JSON'
{"title":"Agent Display Names","is_manual_title":false}
JSON

run_hook() {
  local payload="$1" pane_id="$2"
  printf '%s' "$payload" | env \
    PATH="$WORK/bin:$PATH" \
    HERDR_BIN_PATH="$WORK/bin/herdr" \
    HERDR_STUB_LOG="$LOG" \
    HERDR_ROVO_STATE_DIR="$WORK/state" \
    ROVO_SESSIONS_DIR="$WORK/sessions" \
    HERDR_PANE_ID="$pane_id" \
    bash "$REPO_ROOT/bin/rovo-herdr-hook"
}

status=0
run_hook '{"hook_event_name":"on_session_start","session_id":"session-1","cwd":"/tmp","attributes":{}}' "w1:p3"
if ! grep -F "pane report-metadata w1:p3" "$LOG" | grep -Fq -- "--source plugin:rovo-dev:title"; then
  echo "FAIL: title metadata should use a source separate from lifecycle state" >&2
  status=1
fi
if ! grep -F "pane report-metadata w1:p3" "$LOG" | grep -Fq -- "--display-agent Agent Display Names"; then
  echo "FAIL: restored session should replace the visible agent name" >&2
  status=1
fi
if grep -Fq "tab rename" "$LOG"; then
  echo "FAIL: semantic titles should not rename tabs" >&2
  status=1
fi

cat > "$WORK/sessions/session-1/metadata.json" <<'JSON'
{"title":"Renamed During Session","is_manual_title":true}
JSON
run_hook '{"hook_event_name":"on_user_prompt","session_id":"session-1","cwd":"/tmp","attributes":{}}' "w1:p3"
if ! grep -F "pane report-metadata w1:p3" "$LOG" | grep -Fq -- "--display-agent Renamed During Session"; then
  echo "FAIL: lifecycle events should refresh titles changed during a session" >&2
  status=1
fi

cat > "$WORK/sessions/session-1/metadata.json" <<'JSON'
{"title":"Updated Semantic Session Title","is_manual_title":false}
JSON
run_hook '{"hook_event_name":"on_complete","session_id":"session-1","cwd":"/tmp","attributes":{}}' "w1:p3"
if ! grep -F "pane report-metadata w1:p3" "$LOG" | grep -Fq -- "--display-agent Updated Semantic Session Title"; then
  echo "FAIL: completion should refresh the visible agent name" >&2
  status=1
fi
if grep -Fq "tab rename" "$LOG"; then
  echo "FAIL: completion should not rename tabs" >&2
  status=1
fi

run_hook '{"hook_event_name":"on_session_start","session_id":"session-2","cwd":"/tmp","attributes":{}}' "w1:p4"
if ! grep -F "pane report-metadata w1:p4" "$LOG" | grep -Fq -- "--display-agent Rovo Dev"; then
  echo "FAIL: sessions without a title should keep a visible fallback" >&2
  status=1
fi
if grep -Fq "tab rename" "$LOG"; then
  echo "FAIL: fallback titles should not rename tabs" >&2
  status=1
fi

exit "$status"
