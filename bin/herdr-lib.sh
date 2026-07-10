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
        | if ((.cmdline // "") != "") then
            .cmdline
          elif (((.argv // []) | length) > 0) then
            (.argv | join(" "))
          else
            (.argv0 // empty)
          end
      '
}

# Return 0 if the pane is running a Rovo CLI or Rovo Dev CLI session in the
# foreground. Supports both the legacy Rovo Dev CLI and the new Rovo CLI:
#
#   Rovo Dev CLI (legacy): `acli rovodev run`, `atlassian_cli_rovodev run`
#   Rovo CLI (new):        `rovo` (bare TUI launch; the `rovo` launcher execs a
#                          binary that may itself be named `rovo` or
#                          `atlassian_cli_rovodev`), also `rovo run`.
#
# Non-interactive `serve` sessions (e.g. the IDE-embedded
# `atlassian_cli_rovodev serve ...`) are deliberately NOT matched - they are not
# interactive TUI panes and should not be reported as agents.
pane_is_rovo() {
  local pane_id="$1"
  local cmds
  cmds="$(pane_foreground_cmdlines "$pane_id")" || return 1

  # Exclude non-interactive serve mode outright, then match either CLI.
  printf '%s\n' "$cmds" \
    | grep -Ev '(atlassian_cli_rovodev|acli[[:space:]]+rovodev|rovo)[[:space:]]+serve' \
    | grep -Eq \
      '(^|/|[[:space:]])rovo([[:space:]]+run)?[[:space:]]*$|(atlassian_cli_rovodev[[:space:]]+run)|(acli[[:space:]]+rovodev[[:space:]]+run)'
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
  local agent_session_id="${4:-}"
  local message="${5:-}"
  local seq
  seq="$(date +%s 2>/dev/null || true)"
  local args=(pane report-agent "$pane_id"
    --source "$ROVO_SOURCE"
    --agent "$ROVO_AGENT"
    --state "$state")
  [ -n "$custom_status" ] && args+=(--custom-status "$custom_status")
  [ -n "$agent_session_id" ] && args+=(--agent-session-id "$agent_session_id")
  [ -n "$message" ] && args+=(--message "$message")
  [ -n "$seq" ] && args+=(--seq "$seq")
  "$(herdr_bin)" "${args[@]}" >/dev/null 2>&1
}

# Resolve the pane associated with a Rovo hook invocation. Rovo inherits the
# Herdr pane environment when started inside Herdr, which is the reliable path.
# The cwd fallback is only for manual tests or unusual launchers.
resolve_rovo_hook_pane() {
  local cwd="${1:-}"

  if [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s' "$HERDR_PANE_ID"
    return 0
  fi

  if [ -z "$cwd" ]; then
    return 1
  fi

  local pane_id pane_json pane_cwd
  while IFS= read -r pane_id; do
    [ -n "$pane_id" ] || continue
    pane_json="$("$(herdr_bin)" pane get "$pane_id" 2>/dev/null)" || continue
    pane_cwd="$(printf '%s' "$pane_json" \
      | jq -r '.result.pane.foreground_cwd // .result.pane.cwd // empty' 2>/dev/null)" || continue
    if [ "$pane_cwd" = "$cwd" ] && pane_is_rovo "$pane_id"; then
      printf '%s' "$pane_id"
      return 0
    fi
  done < <(list_pane_ids)

  return 1
}

short_status() {
  printf '%s' "$1" | tr '\n' ' ' | cut -c 1-80
}

# Resolve the Rovo config.yml to operate on, supporting both CLIs:
#
#   Rovo CLI (new):        ~/.rovo/config.yml
#   Rovo Dev CLI (legacy): ~/.rovodev/config.yml
#
# Resolution order:
#   1. ROVO_DEV_CONFIG_FILE - explicit full path (either CLI).
#   2. ROVODEV_USER_DIR / ROVO_USER_DIR - explicit state dir; its config.yml.
#   3. ~/.rovo/config.yml if it exists (prefer the new CLI).
#   4. ~/.rovodev/config.yml if it exists (legacy fallback).
#   5. ~/.rovo/config.yml as the default target when neither exists yet
#      (so a first-time install lands on the new CLI).
rovo_config_file() {
  if [ -n "${ROVO_DEV_CONFIG_FILE:-}" ]; then
    printf '%s' "$ROVO_DEV_CONFIG_FILE"
    return 0
  fi
  if [ -n "${ROVO_USER_DIR:-}" ]; then
    printf '%s/config.yml' "${ROVO_USER_DIR%/}"
    return 0
  fi
  if [ -n "${ROVODEV_USER_DIR:-}" ]; then
    printf '%s/config.yml' "${ROVODEV_USER_DIR%/}"
    return 0
  fi

  local new_config="$HOME/.rovo/config.yml"
  local legacy_config="$HOME/.rovodev/config.yml"
  if [ -f "$new_config" ]; then
    printf '%s' "$new_config"
  elif [ -f "$legacy_config" ]; then
    printf '%s' "$legacy_config"
  else
    printf '%s' "$new_config"
  fi
}
