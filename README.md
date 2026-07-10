# Herdr Rovo Dev Detector

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Platform: macOS | Linux](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue.svg)](#requirements)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-informational.svg)](https://www.conventionalcommits.org)

A [Herdr](https://herdr.dev) plugin that detects [Rovo CLI and Rovo Dev CLI](https://www.atlassian.com/software/rovo) sessions and reports them as Herdr agents, so a running `rovo` (or legacy `acli rovodev run`) pane shows up in Herdr's sidebar `agents` list with a live status dot, just like Codex, Cursor Agent, and Claude Code.

Both CLIs are supported: the new **Rovo CLI** (`rovo`, state in `~/.rovo`) and the legacy **Rovo Dev CLI** (`acli rovodev run`, state in `~/.rovodev`).

## Why

Herdr can track terminal AI-agent sessions and show their live state (working, blocked, idle) in a single dashboard, but it has no built-in Rovo integration, so Rovo panes are invisible to the `agents` list. This plugin closes that gap: it spots panes running the Rovo CLI or Rovo Dev CLI, infers what the session is doing, and reports it back to Herdr, entirely through Herdr's public plugin and CLI APIs.

## What it does

This plugin uses Herdr's `pane report-agent` API to surface Rovo CLI and Rovo Dev CLI sessions.

It has two reporting paths, and **hooks always take priority** over scanning
once they are active for a pane:

1. **Rovo event hooks** for lifecycle state changes such as prompt submitted,
   tool permission requested, tool started, run completed, and session ended.
   These carry structured, semantic event names straight from Rovo's own
   lifecycle, so they are immune to any future wording/UI changes in the CLI.
2. **Pane scanning** as a fallback that only applies to panes with **no active
   hook pipeline yet** - e.g. already-running panes from before hooks were
   installed, or sessions where hooks are not (yet) firing for some other
   reason. It never re-derives or overwrites the state of a pane that hooks
   are already reporting for, so the two paths cannot fight over the same
   pane's status.

On each scan it:

1. Lists panes and inspects the foreground process of each one.
2. Detects Rovo when the foreground command is `rovo` (new Rovo CLI) or `acli rovodev run` / `atlassian_cli_rovodev run` (legacy Rovo Dev CLI). Non-interactive `serve` sessions (e.g. the IDE-embedded `atlassian_cli_rovodev serve`) are ignored.
3. If the pane already has an active hook pipeline (it has received at least
   one hook event and has not since had a clean `on_session_end`), skips
   straight to step 5 without touching its state - hooks are trusted as-is.
4. Otherwise, reads recent pane output and classifies the session state.
5. Reports/keeps the pane as the `rovo-dev` agent with that state.
6. Resets any previously-detected pane to `idle` once Rovo is gone (e.g. it
   exited), and forgets its hook-active marker so a later, unrelated session
   reusing the same pane id has to re-earn hook trust from its own first
   event.

### State classification

State is inferred from Rovo's visible output (best-effort heuristics):

| State     | Trigger examples                                                                                  |
|-----------|----------------------------------------------------------------------------------------------------|
| `working` | "Rovo is thinking" / "Rovo Dev is thinking", an active tool-call line, "Enter to queue, Ctrl+Enter to steer", "Esc to interrupt" |
| `blocked` | `[y/n]` prompts, "Do you want to...", "Waiting for input", approvals                               |
| `idle`    | interactive prompt present (`? for shortcuts`, `agent mode:`) and quiet                             |
| `unknown` | nothing recognizable                                                                                |

Note: the footer `? for shortcuts.` is shown by the Rovo CLI at all times, whether
or not a run is in flight, so the `working`/`blocked` checks are evaluated first
and take priority over the `idle` check.

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
3. `bin/install-rovo-hooks --auto` - best-effort automatic hook install, so
   status updates are instant and event-driven out of the box without a
   separate manual step. This step is **not** allowed to fail the install:
   `yq` is an optional dependency (unlike `bash`/`jq`/`grep`/`sed` above) and
   the Rovo config may not exist yet if Rovo hasn't been run once on this
   machine, so if either prerequisite is missing it skips quietly instead of
   erroring. Run the `install-hooks` action manually any time afterwards
   (e.g. once `yq` is installed, or after running Rovo for the first time) to
   pick up hooks retroactively - see [Usage](#usage).

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

Rovo event hooks are installed automatically at plugin-install time (see
[Install](#install)) whenever `yq` and an existing Rovo config are already
present, so most users get instant, event-driven status updates with no extra
step. Any running Rovo sessions from *before* install still need a restart to
pick up the new hooks (Rovo reads its hook config once at startup), and
sessions started afterwards get them automatically.

If the automatic install was skipped (missing `yq`, or Rovo hadn't been run
yet), or you want to re-sync hooks after a config reset, (re)install them
manually any time:

```sh
herdr plugin action invoke install-hooks --plugin rovo-dev.detector
```

This updates the Rovo config and creates a timestamped backup next to it. It
preserves existing hook commands and only removes/replaces previous commands
that contain `rovo-herdr-hook`, so it is safe to run repeatedly.

The config is resolved in this order:

1. `ROVO_DEV_CONFIG_FILE` - an explicit full path to a `config.yml`.
2. `ROVO_USER_DIR` / `ROVODEV_USER_DIR` - an explicit state dir; uses its `config.yml`.
3. `~/.rovo/config.yml` (new Rovo CLI) if it exists.
4. `~/.rovodev/config.yml` (legacy Rovo Dev CLI) if it exists.
5. `~/.rovo/config.yml` as the default target when neither exists yet.

If you run both CLIs and want hooks in both, install once per config, e.g.:

```sh
ROVO_DEV_CONFIG_FILE=~/.rovo/config.yml    herdr plugin action invoke install-hooks --plugin rovo-dev.detector
ROVO_DEV_CONFIG_FILE=~/.rovodev/config.yml herdr plugin action invoke install-hooks --plugin rovo-dev.detector
```

To remove the bridge hooks:

```sh
herdr plugin action invoke uninstall-hooks --plugin rovo-dev.detector
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

- Detection is **event-driven** for panes without active hooks. Their state
  only refreshes when one of the subscribed lifecycle events fires (or on a
  manual scan), so a session that transitions from working to blocked without
  any pane event may show a stale state until the next event. Once a pane has
  an active hook pipeline, this does not apply - hooks push state changes
  immediately and scanning stops touching that pane's state entirely.
- Rovo hook changes are loaded when the CLI reads its config. Restart existing
  Rovo CLI / Rovo Dev CLI sessions after installing hooks so they pick up the
  new commands. Until restarted, such a session has no active hook pipeline
  yet and is covered by the scan fallback above.
- State classification is heuristic and based on Rovo's current TUI output.
  This only affects the scan fallback for panes without active hooks - it is
  never used to override an already-hooked pane's state. If Rovo's interface
  text changes, the patterns in `bin/herdr-lib.sh` (`classify_state`) may need
  updating for that fallback path.
- No durable Rovo session id/path is reported yet; if Rovo exposes one, it can be
  passed via `--agent-session-id` / `--agent-session-path`.

## Files

```
herdr-rovo-dev/
  herdr-plugin.toml   manifest: actions + event hooks
  bin/
    scan-rovo-panes   main scanner
    rovo-herdr-hook    Rovo event hook bridge
    install-rovo-hooks installs bridge commands into Rovo config
    uninstall-rovo-hooks removes bridge commands from Rovo config
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
- Rovo CLI / Rovo Dev CLI: https://www.atlassian.com/software/rovo

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](./CONTRIBUTING.md) for the dev
loop, testing steps, and commit conventions (this project uses
[Conventional Commits](https://www.conventionalcommits.org)).

## License

[MIT](./LICENSE) © Utkarsh Srivastava

This is an independent, community-built plugin. "Rovo Dev" and "Herdr" are
trademarks of their respective owners; this project is not affiliated with or
endorsed by them.
