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
bash -n bin/scan-rovo-panes bin/herdr-lib.sh bin/check-deps
```

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

## State classification

State heuristics live in `bin/herdr-lib.sh` (`classify_state`). They match Rovo
Dev's visible TUI output, so if Rovo's interface text changes, update the
patterns there. Please include a short note in the PR describing what output you
observed.

## Code of conduct

Be kind and constructive. Assume good intent.
