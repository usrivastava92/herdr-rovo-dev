# Herdr Rovo Dev Detector

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Platform: macOS | Linux](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue.svg)](#requirements)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-informational.svg)](https://www.conventionalcommits.org)

A [Herdr](https://herdr.dev) plugin that detects [Rovo Dev CLI](https://www.atlassian.com/software/rovo) sessions and reports them as Herdr agents, so a running `acli rovodev run` pane shows up in Herdr's sidebar `agents` list with a live status dot, just like Codex, Cursor Agent, and Claude Code.

## Why

Herdr can track terminal AI-agent sessions and show their live state (working, blocked, idle) in a single dashboard, but it has no built-in Rovo Dev integration, so Rovo panes are invisible to the `agents` list. This plugin closes that gap: it spots panes running Rovo Dev, infers what the session is doing, and reports it back to Herdr, entirely through Herdr's public plugin and CLI APIs.

## What it does

This plugin uses Herdr's `pane report-agent` API to surface Rovo Dev sessions.

On each scan it:

1. Lists panes and inspects the foreground process of each one.
2. Detects Rovo when the foreground command is `atlassian_cli_rovodev run` or `acli rovodev run`.
3. Reads recent pane output and classifies the session state.
4. Reports the pane as the `rovo-dev` agent with that state.
5. Resets any previously-detected pane to `idle` once Rovo is gone (e.g. it exited).

### State classification

State is inferred from Rovo's visible output (best-effort heuristics):

| State     | Trigger examples                                                        |
|-----------|------------------------------------------------------------------------|
| `working` | "Rovo Dev is thinking", an active tool-call line, "Esc to interrupt"   |
| `blocked` | `[y/n]` prompts, "Do you want to...", "Waiting for input", approvals   |
| `idle`    | interactive prompt present (`? for shortcuts`, `agent mode:`) and quiet |
| `unknown` | nothing recognizable                                                    |

The current Rovo `agent mode:` (e.g. `plan`) is reported as the agent's custom status.

## Install

Herdr has no package registry. Plugins are distributed as Git repos and
referenced either by local path or by `owner/repo`.

### From GitHub (shareable)

```sh
herdr plugin install usrivastava92/herdr-rovo-dev              # latest default branch
herdr plugin install usrivastava92/herdr-rovo-dev --ref v1.0.0 # pin a tag/branch/commit
herdr plugin uninstall rovo-dev.detector
```

On install Herdr clones the repo, validates `herdr-plugin.toml`, and runs the
`[[build]]` steps:

1. `bin/check-deps` - a preflight that verifies `bash`, `jq`, `grep`, and `sed`
   are on `PATH`. Herdr ships no bundled runtime and execs plugin commands
   directly on the host, so a missing tool fails the **install** with a clear
   message (and install hint) instead of failing mysteriously on the first scan.
2. `chmod +x` on the scripts, since Git does not always preserve the exec bit.

The scanner also re-checks for `jq` at runtime as a second line of defense.

### Local (development / private use)

```sh
herdr plugin link /path/to/herdr-rovo-dev
herdr plugin list --plugin rovo-dev.detector --json
herdr plugin unlink rovo-dev.detector
```

## Usage

The plugin rescans automatically on `pane.created`, `pane.focused`, `pane.moved`, `pane.exited`, and `tab.created`.
You can also trigger a scan manually:

```sh
herdr plugin action invoke scan --plugin rovo-dev.detector
```

Then confirm:

```sh
herdr agent list
```

## Development loop

```sh
herdr plugin link .
herdr plugin action list --plugin rovo-dev.detector
herdr plugin action invoke scan --plugin rovo-dev.detector
herdr plugin log list --plugin rovo-dev.detector
herdr plugin unlink rovo-dev.detector
```

You can also run the scanner directly from a Herdr pane:

```sh
./bin/scan-rovo-panes
```

## Requirements

- Herdr >= 0.7.0
- macOS or Linux (Windows via WSL/Git Bash - anything with a POSIX shell)
- `bash`, `jq`, `grep`, and `sed` on `PATH`

## Limitations and future work

- Detection is **event-driven**. State only refreshes when one of the subscribed
  lifecycle events fires (or on a manual scan), so a session that transitions
  from working to blocked without any pane event may show a stale state until the
  next event. For continuous updates, a long-running watcher using the Herdr
  socket `events.subscribe` API can be layered on top.
- State classification is heuristic and based on Rovo's current TUI output. If
  Rovo's interface text changes, the patterns in `bin/herdr-lib.sh`
  (`classify_state`) may need updating.
- No durable Rovo session id/path is reported yet; if Rovo exposes one, it can be
  passed via `--agent-session-id` / `--agent-session-path`.

## Files

```
herdr-rovo-dev/
  herdr-plugin.toml   manifest: actions + event hooks
  bin/
    scan-rovo-panes   main scanner
    herdr-lib.sh      shared helpers (detection, classification, reporting)
    check-deps        install-time dependency preflight
  LICENSE
  CONTRIBUTING.md
  README.md
```

## References

- Herdr plugins: https://herdr.dev/docs/plugins/
- Herdr CLI reference: https://herdr.dev/docs/cli-reference/
- Herdr socket API: https://herdr.dev/docs/socket-api/
- Rovo Dev CLI: https://www.atlassian.com/software/rovo

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](./CONTRIBUTING.md) for the dev
loop, testing steps, and commit conventions (this project uses
[Conventional Commits](https://www.conventionalcommits.org)).

## License

[MIT](./LICENSE) © Utkarsh Srivastava

This is an independent, community-built plugin. "Rovo Dev" and "Herdr" are
trademarks of their respective owners; this project is not affiliated with or
endorsed by them.
