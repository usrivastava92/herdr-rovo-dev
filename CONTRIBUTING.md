# Contributing

Thanks for your interest in improving the Herdr Rovo Dev Detector.

## Development setup

Requirements:

- [Herdr](https://herdr.dev) >= 0.7.0
- macOS or Linux (Windows via WSL/Git Bash)
- `bash`, `jq`, `grep`, `sed` on `PATH`

Link the plugin from your working copy so edits take effect immediately:

```sh
herdr plugin link "$(pwd)"
herdr plugin list --plugin rovo-dev.detector --json
```

## Dev loop

```sh
# Trigger a scan manually
herdr plugin action invoke scan --plugin rovo-dev.detector

# Inspect results and logs
herdr agent list
herdr plugin log list --plugin rovo-dev.detector

# Reload after changes (link picks up edits in place; unlink to remove)
herdr plugin unlink rovo-dev.detector
```

You can also run the scanner directly inside a Herdr pane:

```sh
./bin/scan-rovo-panes
```

Before opening a PR, run a syntax check:

```sh
for script in bin/* tests/*.sh; do bash -n "$script"; done
```

The tests require `jq`, Mike Farah `yq` v4, and `python3`. They use isolated
config directories, a fake TUI backend, and real pseudo-terminals; no running
Herdr server, desktop app, Rovo login, or user config is touched:

```sh
bash tests/run.sh
```

## Desktop development

Desktop files are `bin/rovo-herdr-desktop` (opt-in launcher),
`bin/rovo-herdr-desktop-hook` (OSC 7501 output), `bin/rovo-event.sh` (shared
lifecycle parsing), and `bin/install-desktop` / `bin/uninstall-desktop`.
Keep the existing TUI state mapping and plugin install interface compatible.
Desktop uses `done` and `error` without changing the TUI's `idle` / `blocked`
mapping for those same events.

For manual verification, install into scratch `ROVO_USER_DIR` and
`HERDR_APP_HOME` directories first. In a real desktop terminal, launch through
the installed wrapper and exercise prompt, permission, resume, completion,
error, Ctrl+C, and exit-to-shell. Check `hc get TERMINAL` and the desktop
agents list. A passing pseudo-terminal test does not replace this UI check.

## Commit style

This project uses [Conventional Commits](https://www.conventionalcommits.org/).
Use a type prefix so history stays readable and releases can be derived from it:

- `feat:` a new feature
- `fix:` a bug fix
- `docs:` documentation only
- `refactor:`, `test:`, `chore:`, `ci:` as appropriate

Examples:

```
feat: classify blocked state from permission prompts
fix: avoid aborting scan when a pane read fails
docs: document install-from-GitHub flow
```

Breaking changes: add a `!` after the type (e.g. `feat!:`) or a `BREAKING CHANGE:`
footer.

## Releases

Releases happen directly from `main` with semantic-release.
Every push to `main` analyzes commits since the last `vX.Y.Z` tag, chooses the next SemVer version from Conventional Commits, updates `herdr-plugin.toml`, creates a GitHub release, and pushes the release tag.
There is no release PR.
The release workflow mints a one-repo contents-write GitHub App token from `APP_CLIENT_ID` and `APP_PRIVATE_KEY`.
Set `APP_CLIENT_ID` as a `production` environment variable and `APP_PRIVATE_KEY` as a `production` environment secret.
Releases run unattended and use only the minted token, so there is no PAT fallback.
Keep the `production` environment free of required reviewers and wait timers so releases do not pause.
Do not create release tags manually except when repairing a broken release.

For an explicitly requested major milestone, use a
`chore(major-release): ...` commit. This selects a major version without
claiming an incompatible API change. Normal `fix:`, `feat:`, and breaking-change
rules remain unchanged. Put curated notes in `docs/releases/X.Y.Z.md`; the
release workflow appends that version's notes to its generated release notes
when the file exists. Include compatibility, setup, fixes, and actual dependency
changes; do not describe CI-only tools as runtime upgrades.

## State classification

State heuristics live in `bin/herdr-lib.sh` (`classify_state`). They match Rovo
Dev's visible TUI output, so if Rovo's interface text changes, update the
patterns there. Please include a short note in the PR describing what output you
observed.

## Code of conduct

Be kind and constructive. Assume good intent.
