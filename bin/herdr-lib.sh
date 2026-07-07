#!/usr/bin/env bash
# Shared helpers for the Rovo Dev Herdr detector plugin.
#
# This file is meant to be sourced, not executed directly. It centralizes the
# Herdr CLI invocation, Rovo process detection, output-based state
# classification, and the small amount of persisted state the scanner needs.

# Stable identifiers used when reporting agents to Herdr.
readonly ROVO_SOURCE="plugin:rovo-dev"
readonly ROVO_AGENT="rovo-dev"

# Number of trailing output lines to inspect when classifying pane state.
readonly ROVO_READ_LINES="${ROVO_READ_LINES:-60}"

# Resolve the Herdr binary. Inside a plugin/pane, HERDR_BIN_PATH is injected;
# fall back to `herdr` on PATH for manual runs.
herdr_bin() {
  printf '%s' "${HERDR_BIN_PATH:-herdr}"
}

# Directory used to remember which panes we have marked as Rovo agents, so we
# can reset them to idle once Rovo is no longer the foreground process. Falls
# back to a temp dir when the plugin state dir is not provided (manual runs).
state_dir() {
  local dir="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-rovo-dev}"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s' "$dir"
}

# Path to the file tracking panes we currently consider Rovo agents.
tracked_file() {
  printf '%s/tracked-panes' "$(state_dir)"
}

# jq must be available for JSON parsing.
require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "herdr-rovo-dev: jq is required but was not found on PATH" >&2
    return 1
  fi
}

# List all pane ids, one per line.
# Herdr's `pane list` already emits JSON on stdout (no --json flag).
list_pane_ids() {
  "$(herdr_bin)" pane list 2>/dev/null \
    | jq -r '.result.panes[]?.pane_id // .panes[]?.pane_id // empty'
}

# Emit the foreground command line(s) for a pane, one argv0/cmdline per line.
# `pane process-info` also emits JSON on stdout by default.
pane_foreground_cmdlines() {
  local pane_id="$1"
  "$(herdr_bin)" pane process-info --pane "$pane_id" 2>/dev/null \
    | jq -r '
        (.result.process_info // .process_info) as $pi
        | $pi.foreground_processes[]?
        | (.cmdline // (.argv | join(" ")) // .argv0 // empty)
      '
}

# Return 0 if the pane is running a Rovo Dev CLI session in the foreground.
# Matches the acli launcher and the underlying binary, in run mode.
pane_is_rovo() {
  local pane_id="$1"
  local cmds
  cmds="$(pane_foreground_cmdlines "$pane_id")" || return 1
  printf '%s\n' "$cmds" | grep -Eq \
    '(atlassian_cli_rovodev[[:space:]]+run)|(acli[[:space:]]+rovodev[[:space:]]+run)'
}

# Classify the semantic state of a Rovo pane from its recent visible output.
# Prints one of: working | blocked | idle | unknown
classify_state() {
  local pane_id="$1"
  local out
  out="$("$(herdr_bin)" pane read "$pane_id" --source recent-unwrapped \
    --lines "$ROVO_READ_LINES" 2>/dev/null)" || {
    printf 'unknown'
    return 0
  }

  # Working: Rovo is actively thinking or executing a tool call.
  if printf '%s' "$out" | grep -Eq \
    'Rovo Dev is (thinking|working|running)|(Esc to interrupt)|(▶[^|]+\|[[:space:]]*[a-z_]+[[:space:]]*$)'; then
    printf 'working'
    return 0
  fi

  # Blocked: Rovo is waiting on the user for a decision or input.
  if printf '%s' "$out" | grep -Eq \
    '\[y/n\]|\(y/n\)|Do you want to|Waiting for (your )?(input|confirmation)|Approve|Allow this|Choose an option|Select an option|Press Enter to'; then
    printf 'blocked'
    return 0
  fi

  # Idle: an interactive prompt is present and nothing is in flight.
  if printf '%s' "$out" | grep -Eq '\? for shortcuts|agent mode:'; then
    printf 'idle'
    return 0
  fi

  printf 'unknown'
}

# Derive a short custom-status from the Rovo status line (e.g. the agent mode),
# printed on stdout. Empty output means "no custom status".
derive_custom_status() {
  local pane_id="$1"
  local out mode
  out="$("$(herdr_bin)" pane read "$pane_id" --source recent-unwrapped \
    --lines "$ROVO_READ_LINES" 2>/dev/null)" || return 0
  mode="$(printf '%s' "$out" \
    | grep -oE 'agent mode:[[:space:]]*[a-zA-Z-]+' \
    | tail -1 \
    | sed -E 's/agent mode:[[:space:]]*//' || true)"
  if [ -n "$mode" ]; then
    printf 'mode:%s' "$mode"
  fi
  return 0
}

# Report a pane as a Rovo agent with the given state and optional custom status.
report_agent() {
  local pane_id="$1" state="$2" custom_status="$3"
  local args=(pane report-agent "$pane_id"
    --source "$ROVO_SOURCE"
    --agent "$ROVO_AGENT"
    --state "$state")
  [ -n "$custom_status" ] && args+=(--custom-status "$custom_status")
  "$(herdr_bin)" "${args[@]}" >/dev/null 2>&1
}
