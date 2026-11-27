#!/usr/bin/env bash
# Shared lifecycle parsing. Transport-specific states are mapped by the caller.
# Sets event_name, session_id, cwd, tool_name, state, custom_status and message.
rovo_parse_event() {
  local payload="$1"
  printf '%s' "$payload" | jq -e '
    type == "object" and (.hook_event_name | type == "string" and length > 0)
  ' >/dev/null 2>&1 || return 1

  event_name="$(printf '%s' "$payload" | jq -r '.hook_event_name')"
  session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
  cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
  tool_name="$(printf '%s' "$payload" | jq -r '
    .attributes.tool_input.tool_name
    // .attributes.tool_calls[0].tool_name
    // .attributes.tool_results[0].tool_name
    // empty
  ' 2>/dev/null)" || return 1

  state="unknown"
  custom_status=""
  message=""
  case "$event_name" in
    on_session_start)
      state="idle"
      custom_status="session"
      message="Rovo Dev session started"
      ;;
    on_user_prompt)
      state="working"
      custom_status="prompt"
      message="Rovo Dev received a prompt"
      ;;
    on_tool_start)
      state="working"
      custom_status="tool:${tool_name:-running}"
      message="Rovo Dev started ${tool_name:-a tool}"
      ;;
    on_tool_permission)
      state="blocked"
      custom_status="permission:${tool_name:-tool}"
      message="Rovo Dev is waiting for permission"
      ;;
    on_tool_end)
      state="working"
      custom_status="tool-done:${tool_name:-tool}"
      message="Rovo Dev finished ${tool_name:-a tool}"
      ;;
    on_complete)
      state="idle"
      custom_status="done"
      message="Rovo Dev completed"
      ;;
    on_error)
      state="blocked"
      custom_status="error"
      message="Rovo Dev hit an error"
      ;;
    on_session_end)
      state="idle"
      custom_status="exited"
      message="Rovo Dev session ended"
      ;;
    *)
      custom_status="$event_name"
      message="Rovo Dev event: $event_name"
      ;;
  esac
  custom_status="$(printf '%s' "$custom_status" | tr '\n' ' ' | cut -c 1-80)"
}
