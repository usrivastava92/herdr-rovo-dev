#!/usr/bin/env bash
# The shared event parser must preserve the existing TUI hook contract.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HERDR_BIN_PATH="$WORK/herdr"
export HERDR_PANE_ID="wT:p1"
export HERDR_ROVO_STATE_DIR="$WORK/state"
export HOOK_LOG="$WORK/calls"
unset HERDR_ROVO_TRANSPORT
cat > "$HERDR_BIN_PATH" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOOK_LOG"
STUB
chmod +x "$HERDR_BIN_PATH"

while read -r event state label; do
  : > "$HOOK_LOG"
  jq -nc --arg event "$event" '{hook_event_name:$event,session_id:"session-1",attributes:{tool_input:{tool_name:"read"}}}' \
    | bash "$ROOT/bin/rovo-herdr-hook"
  grep -Fq -- "pane report-agent wT:p1 --source plugin:rovo-dev --agent rovo-dev --state $state --agent-session-id session-1" "$HOOK_LOG"
  grep -Fq -- "--state-label $state=$label" "$HOOK_LOG"
done <<'EVENTS'
on_session_start idle session
on_user_prompt working prompt
on_tool_start working tool:read
on_tool_permission blocked permission:read
on_tool_end working tool-done:read
on_complete idle done
on_error blocked error
on_session_end idle exited
future_event unknown future_event
EVENTS

# Desktop opt-in must suppress both TUI dispatch paths, even with stale pane env.
: > "$HOOK_LOG"
printf '%s' '{"hook_event_name":"on_user_prompt"}' \
  | HERDR_ROVO_TRANSPORT=osc bash "$ROOT/bin/rovo-herdr-hook"
HERDR_ROVO_TRANSPORT=osc bash "$ROOT/bin/rovo-herdr-hook-launcher" </dev/null
[ ! -s "$HOOK_LOG" ]

# A malformed event must never overwrite a valid agent's status.
printf '%s' '{"hook_event_name":[]}' | bash "$ROOT/bin/rovo-herdr-hook"
[ ! -s "$HOOK_LOG" ]
printf '%s\n' 'TUI hook lifecycle and desktop isolation passed.'
