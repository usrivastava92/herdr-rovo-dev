# Fix plan: Rovo pane reports a stale `exited` status while still running

## How to use this document

This is an implementation plan for an engineer or agent who will execute the fix.
Work top to bottom.
Do not skip the reproduction step: reproduce each bug end to end before changing code, then re-run the same reproduction after the change to prove it is fixed.
Every claim below was verified on the reporter's machine on 2026-07-14; the "Evidence" blocks give the exact commands to re-verify.

Priorities are tiered:

- **P0** must ship together; they are the two bugs that directly cause the wrong status.
- **P1** is required for the event-hook path to actually stay authoritative after P0; verify it empirically, then fix if confirmed.
- **P2** is defense-in-depth hardening that makes the scan fallback resilient; include it if time allows.

## Symptom

In the Herdr sidebar, a Rovo CLI pane shows `idle - rovo-dev - exited` even though the pane is visibly active: the footer reads "Rovo is thinking..", context is filling, and a subagent is running.
The status never self-corrects while the session keeps working.

## Environment where this was observed

- New Rovo CLI (state under `~/.rovo`), interactive TUI, model "Claude Opus 4.8".
- Plugin installed from the GitHub remote (`herdr plugin install usrivastava92/herdr-rovo-dev`), resolved commit `6c667da`, plugin version `1.2.0`.
- The plugin had previously been used via a local `herdr plugin link` of the working tree, then switched to the GitHub install on 2026-07-14 at 11:03.

## Root cause summary

Two independent bugs combine to produce the symptom.

1. **P0 - Bug 1: the event-hook path is 100% dead.**
   The hook command registered in Rovo's `config.yml` points to Herdr's ephemeral install temp directory, which is deleted seconds after install.
   Every hook invocation fails with "No such file or directory", so the reliable, event-driven status path never reports anything.
2. **P0 - Bug 2: the scan fallback cannot detect the new CLI's process.**
   With hooks dead, status depends entirely on `scan-rovo-panes`, whose `pane_is_rovo` regex does not match the new CLI's real foreground process name (`atlassian_cli_rovodev` with no `run` subcommand).
   So the scanner concludes the still-running pane is "no longer Rovo" and takes its reset branch, reporting `idle` + custom status `exited`.

Because scans only run on discrete pane lifecycle events and hooks are dead, nothing ever corrects the stale `exited` while Rovo keeps working.

A third issue (P1) will surface once Bug 1 is fixed: the hook and the scanner may not agree on where the "hook is active for this pane" marker lives, which would let the scanner clobber correct hook state.
A fourth issue (P2) is that the scanner's exit-reset is triggered by a single detection miss and also wipes the hook-active marker, which is fragile.

---

## Bug 1 (P0): dead hook command path from build-time directory capture

### What happens

`bin/install-rovo-hooks` records the hook command as `$SCRIPT_DIR/rovo-herdr-hook`, where `$SCRIPT_DIR` is "the directory this script is running from right now" (`bin/install-rovo-hooks:31`, using the standard `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` idiom).

Commit `0532f82` ("feat: auto-install Rovo hooks on plugin install", 2026-07-10) added a third `[[build]]` step that runs `install-rovo-hooks --auto` automatically on install.

Herdr installs a GitHub plugin in three phases:

1. Clone the repo into an ephemeral temp checkout, e.g. `~/.config/herdr/plugins/.tmp-install-66924-1784007202699/checkout/`.
2. Run the `[[build]]` steps there, including `install-rovo-hooks --auto`, which captures that temp path and writes it into `~/.rovo/config.yml`.
3. Relocate the finished plugin to its permanent content-hashed directory (`~/.config/herdr/plugins/github/rovo-dev.detector-3caf789eac5c/`) and delete the temp dir.

So the path written into Rovo's config is valid only between phase 2 and phase 3.
Measured window on this machine: 1.261 seconds.

Nothing ever rewrites the config to the final location, so every subsequent hook fire runs a path that no longer exists.

### Why the local install never hit this

When the plugin was used via `herdr plugin link` of the working tree, hooks were installed by running `install-rovo-hooks` manually (the action or by hand) from a persistent directory, so the captured path was stable and real.
The auto-install-on-fresh-install code path had never been exercised until the switch to the GitHub remote, which is why the move "caused" it: the move triggered a fresh install, which runs `[[build]]`, which runs the buggy `--auto` capture for the first time.

### Deeper problem this exposes

Even a "correct" absolute path into the plugin's own `bin/` is not durable: Herdr re-hashes the plugin directory on every upgrade (`rovo-dev.detector-<hash>`), so a captured path also rots on the next version bump.
The fix must therefore record a path that survives both relocation and upgrades, not merely a non-temp path.

### Evidence

```sh
# The registered hook path points at a deleted temp dir:
grep -n "rovo-herdr-hook" ~/.rovo/config.yml
ls -la "/Users/usrivastava/.config/herdr/plugins/.tmp-install-66924-1784007202699/checkout/bin/rovo-herdr-hook"  # No such file or directory

# The real installed hook is elsewhere:
herdr plugin list --plugin rovo-dev.detector --json | jq -r '.result.plugins[0].plugin_root'
# -> /Users/usrivastava/.config/herdr/plugins/github/rovo-dev.detector-3caf789eac5c

# Every hook fire has failed:
tail -40 ~/.rovo/event_hooks.log   # repeated: "No such file or directory"

# Confirm the current install is the GitHub remote and read the two timestamps:
herdr plugin list --plugin rovo-dev.detector --json | jq '.result.plugins[0].source'
# source.installed_unix_ms = 1784007203960 (final registration)
# temp dir name embeds       1784007202699 (temp checkout), 1.261s earlier
```

---

## Bug 2 (P0): detection regex misses the new CLI's real process name

### What happens

With hooks dead, `bin/scan-rovo-panes` is the only thing setting status, and it gates everything on `pane_is_rovo` (`bin/herdr-lib.sh:131`).
The new Rovo CLI's interactive TUI runs as the bare binary:

```
/Users/usrivastava/.local/share/rovo/current/atlassian_cli_rovodev
```

with no `run` subcommand, and there is no `rovo` launcher anywhere in the process tree (the ancestry is `herdr server` -> `zsh` -> `atlassian_cli_rovodev`).

The positive match in `pane_is_rovo` (`bin/herdr-lib.sh:144-147`) is:

```
(^|/|[[:space:]])rovo([[:space:]]+run)?([[:space:]]|$) | (atlassian_cli_rovodev[[:space:]]+run) | (acli[[:space:]]+rovodev[[:space:]]+run)
```

Bare `atlassian_cli_rovodev` matches none of these:

- The first alternative needs `rovo` preceded by start, slash, or space; inside `atlassian_cli_rovodev` the substring `rovo` is preceded by `_`, so it does not match.
- The second alternative requires a literal `run` after `atlassian_cli_rovodev`; there is none.

So `pane_is_rovo` returns false for the actual running pane.

### How that yields `exited`

In `bin/scan-rovo-panes`, a pane that fails `pane_is_rovo` is not added to `current_rovo`.
The reset loop then sees it was previously tracked but is now "missing" and takes the reset branch (`bin/scan-rovo-panes:59-72`):

```sh
report_agent "$old_pane" "idle" "exited"   # line 67
clear_pane_hooked "$old_pane"              # line 69
```

That reset branch is the only reachable code that emits custom status `exited`.
The hook's own `on_session_end` "exited" (`bin/rovo-herdr-hook:73-77`) cannot run, because its binary does not exist (Bug 1).

### Evidence

```sh
# The live interactive process name (run outside the command sandbox):
ps -Ao pid,ppid,comm,args | grep atlassian_cli_rovodev
# 16501 22860 atlassian_cli_rovodev  /Users/.../rovo/current/atlassian_cli_rovodev   (no "run")

# The tracked-panes file was emptied right after the screenshot, i.e. the pane
# was reset and untracked:
ls -la ~/.local/state/herdr/plugins/rovo-dev.detector/tracked-panes   # 0 bytes, mtime 13:27
```

Regex check (reproduces the exact filter + match from `pane_is_rovo`):

```sh
test_match() {
  printf '%s\n' "$1" \
    | grep -Ev '(atlassian_cli_rovodev|acli[[:space:]]+rovodev|(^|/|[[:space:]])rovo)[[:space:]]+serve([[:space:]]|$)' \
    | grep -Eq '(^|/|[[:space:]])rovo([[:space:]]+run)?([[:space:]]|$)|(atlassian_cli_rovodev[[:space:]]+run)|(acli[[:space:]]+rovodev[[:space:]]+run)' \
    && echo "MATCH   : $1" || echo "NO MATCH: $1"
}
test_match "atlassian_cli_rovodev"                       # NO MATCH  (bug)
test_match "/Users/x/.local/bin/atlassian_cli_rovodev"   # NO MATCH  (bug)
test_match "atlassian_cli_rovodev --restore abc123"      # NO MATCH  (bug)
test_match "atlassian_cli_rovodev run"                   # MATCH
test_match "rovo"                                        # MATCH
```

---

## Bug 3 (P1): hook and scanner may disagree on the hook-active state directory

### Why this matters only after Bug 1 is fixed

The design intends hooks to be authoritative: once a pane has fired at least one hook, the scanner should trust the hook layer and not re-derive state from screen text.
This coordination uses a filesystem marker written by `mark_pane_hooked` and read by `pane_hook_active` (`bin/herdr-lib.sh:51-83`), both routed through `state_dir()` (`bin/herdr-lib.sh:24-28`):

```sh
state_dir() {
  local dir="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-rovo-dev}"
  ...
}
```

The scanner runs as a Herdr-invoked plugin command, so Herdr injects `HERDR_PLUGIN_STATE_DIR` (observed: `~/.local/state/herdr/plugins/rovo-dev.detector`).
The hook runs as a child of the Rovo process, whose environment is inherited from the pane.
Pane environments carry pane-scoped variables like `HERDR_PANE_ID` and `HERDR_BIN_PATH`, but there is no reason to expect the plugin-scoped `HERDR_PLUGIN_STATE_DIR` to be present there.
If it is absent, the hook falls back to `${TMPDIR}/herdr-rovo-dev`, a different directory than the scanner reads.

Consequence: the scanner never sees the hook's "this pane is hooked" marker, so it keeps reclassifying and can still reset a live, hook-reporting pane to `exited` on any lifecycle event where classification misfires.
In other words, fixing Bugs 1 and 2 restores correct hook reports, but this bug lets the scanner overwrite them.

### Required verification before fixing

Confirm empirically whether the hook's environment contains `HERDR_PLUGIN_STATE_DIR`.
A minimal way: temporarily have the launcher (or the real hook) append `env | sort` to a debug file on first fire inside a linked dev build, trigger a Rovo event, and inspect it.
Alternatively, compare where markers actually land at runtime: after a real hook fires, check both `~/.local/state/herdr/plugins/rovo-dev.detector/hooked/` and `${TMPDIR}/herdr-rovo-dev/hooked/`.
If the marker lands somewhere the scanner does not read, this bug is confirmed.

### Fix if confirmed

Make the coordination markers resolve to the same deterministic path in both contexts, independent of `HERDR_PLUGIN_STATE_DIR`.
Recommended: change `state_dir()` to a fixed, well-known location, for example:

```sh
state_dir() {
  local dir="${HERDR_ROVO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-rovo-dev}"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s' "$dir"
}
```

This is computed identically whether the caller is the Herdr-invoked scanner or the Rovo-invoked hook, so both agree on `tracked-panes` and the `hooked/` markers.
Keep an env override (`HERDR_ROVO_STATE_DIR`) for tests.

---

## Bug 4 (P2, optional hardening): the scanner's exit-reset is too eager

The reset branch (`bin/scan-rovo-panes:59-72`) fires after a single scan where `pane_is_rovo` returns false, and it also clears the hook-active marker.
Foreground-process detection is inherently momentary; a single blip (a transient child process briefly owning the terminal foreground, or a one-off `process-info` read failure) should not be enough to declare a session dead and to discard hook trust.

Recommended hardening, in order of value:

1. Do not reset a pane that currently has an active hook marker unless there is stronger evidence the process is gone; hooks are the authoritative signal and a single scan miss should not override them.
2. Debounce: require N consecutive misses (for example 2) before resetting a previously-tracked pane, persisting a small miss counter in the state dir.

This is defense-in-depth; it is not required to fix the reported symptom once P0 and P1 are done, but it prevents a whole class of future flapping.

---

## The fix, file by file

The recommended shape for Bug 1 is a small, static "launcher" script that is copied to a stable location and resolves the current plugin at fire-time.
This is preferred over writing the plugin's own absolute `bin/` path, because it survives both relocation and upgrades, and it needs no rewrite of the config on upgrade.

### Design constraints (must hold)

These are hard requirements agreed with the maintainer; the implementation must not violate them.

- **No new external dependencies.**
  The fix may use only what the plugin already relies on: the `herdr` host CLI (used throughout via `herdr_bin()` for every `report-agent`, `pane read`, `pane list`, and `process-info` call) and the already-required host tools `bash`, `jq`, `grep`, `sed` (enforced at install by `bin/check-deps`).
  `yq` remains the optional, hook-install-only tool it already is.
  Do not add any new binary, package, language runtime, or service.
- **Self-contained in the plugin architecture.**
  All shipped code lives in the plugin repo (the launcher is a repo file under `bin/`).
  The launcher must resolve the plugin only through Herdr's public CLI (`herdr plugin list --plugin rovo-dev.detector --json` -> `.result.plugins[].plugin_root`), not by hardcoding install paths, globbing Herdr's internal directories, or parsing Herdr-private files.
- **The one out-of-plugin artifact is unavoidable and bounded.**
  Rovo reads its hooks from `~/.rovo/config.yml`, so the config must reference some absolute path; the stable launcher copy under `~/.rovo/hooks/herdr-managed/` (or the legacy `~/.rovodev/...` equivalent) is that path.
  This is consistent with the plugin already editing `~/.rovo/config.yml` and mirrors the existing `~/.rovo/hooks/aloc-managed/` precedent.
  `uninstall-rovo-hooks` must remove this copy so uninstall leaves no residue.

### How the launcher indirection works (context for the implementer)

Instead of registering the real hook's path in Rovo's config (a moving target: the plugin dir is an ephemeral temp dir at build time, and gets a new content-hash on every upgrade), register a tiny stable middleman.
Rovo calls the launcher at a fixed path; the launcher asks Herdr where the plugin lives right now and execs the real hook there.

```
~/.rovo/config.yml  ──►  ~/.rovo/hooks/herdr-managed/rovo-herdr-hook   (launcher; fixed, never moves)
                                 │  on each event, resolve at fire-time:
                                 ▼
                          herdr plugin list --plugin rovo-dev.detector --json
                                 │  →  plugin_root = /…/github/rovo-dev.detector-<current-hash>/
                                 ▼
                          exec  <plugin_root>/bin/rovo-herdr-hook   (real hook, wherever it is today)
```

The config only ever holds the one address guaranteed to be stable (the launcher); the launcher absorbs all relocation and upgrade churn behind it, using nothing but the host CLI the plugin already depends on.

### 1. New file: `bin/rovo-herdr-hook-launcher` (P0, Bug 1)

A static, reviewable, lintable script shipped in the repo.
`install-rovo-hooks` copies it to a stable location and registers that copy in Rovo's config.
It resolves the plugin's current root through the Herdr API at fire-time and execs the real hook.

```sh
#!/usr/bin/env bash
#
# rovo-herdr-hook-launcher - stable indirection to the real Herdr Rovo hook.
#
# install-rovo-hooks copies this file to a stable, Rovo-owned location
# (e.g. ~/.rovo/hooks/herdr-managed/rovo-herdr-hook) and registers THAT path in
# Rovo's config.yml. Rovo invokes it on every lifecycle event.
#
# Why the indirection: Herdr builds a plugin in an ephemeral temp checkout, then
# relocates it to a content-hashed directory and re-hashes on every upgrade. Any
# absolute path into the plugin's own bin/ captured at install time therefore
# goes stale (immediately for the temp dir, or on the next upgrade). This
# launcher resolves the plugin's CURRENT root at fire-time, so the path recorded
# in Rovo's config never rots.
set -u

HB="${HERDR_BIN_PATH:-herdr}"

root="$("$HB" plugin list --plugin rovo-dev.detector --json 2>/dev/null \
  | jq -r '.result.plugins[]? | select(.plugin_id == "rovo-dev.detector") | .plugin_root' 2>/dev/null \
  | head -n1)"

# A failed hook must never disrupt the Rovo session, and a missed event just
# leaves that transition to the next scan. So if we cannot resolve the current
# install (Herdr server down, plugin removed, jq missing), do nothing.
[ -n "${root:-}" ] || exit 0
[ -x "$root/bin/rovo-herdr-hook" ] || exit 0

# stdin (the JSON payload) and the environment are inherited across exec.
exec "$root/bin/rovo-herdr-hook" "$@"
```

### 2. `bin/install-rovo-hooks` (P0, Bug 1)

Replace the build-time `$SCRIPT_DIR` capture with: copy the launcher to a stable per-CLI directory next to the resolved config, and register that copy.

- Remove `HOOK_CMD="$SCRIPT_DIR/rovo-herdr-hook"` (line 31).
- Compute a stable launcher directory from the resolved config path so it tracks the CLI in use:
  - new CLI -> `~/.rovo/hooks/herdr-managed/`
  - legacy CLI -> `~/.rovodev/hooks/herdr-managed/`
  - i.e. `LAUNCHER_DIR="$(dirname "$(config_file)")/hooks/herdr-managed"`.
- Copy `$SCRIPT_DIR/rovo-herdr-hook-launcher` to `$LAUNCHER_DIR/rovo-herdr-hook`, then `chmod +x` it.
  Note: at `--auto` build time `$SCRIPT_DIR` is the temp checkout, but the launcher source file exists there (it is a repo file), and the destination copy persists after the temp dir is deleted.
- Set `HOOK_CMD="$LAUNCHER_DIR/rovo-herdr-hook"`.
- Add a defensive guard: refuse to record a `HOOK_CMD` whose path contains `/.tmp-install-` (or is not under the resolved config's directory).
  If the guard trips, `skip_or_fail` with a clear message.
  This guarantees we can never persist an ephemeral path again, even if the launcher approach is later changed.
- If `$SCRIPT_DIR/rovo-herdr-hook-launcher` is missing, `skip_or_fail` with a clear message.

The existing marker-based rewrite (which strips any command containing `rovo-herdr-hook` before re-adding) already tolerates the new path, because the launcher filename still contains `rovo-herdr-hook`.

### 3. `bin/herdr-lib.sh` (P0, Bug 2 and P1, Bug 3)

Bug 2: broaden the `atlassian_cli_rovodev` branch of the positive match in `pane_is_rovo` (`:144-147`) so it matches the binary regardless of trailing subcommand, while still excluding `serve`.
Change the alternative `atlassian_cli_rovodev[[:space:]]+run` to `atlassian_cli_rovodev([[:space:]]|$)`.

Full replacement match expression:

```
(^|/|[[:space:]])rovo([[:space:]]+run)?([[:space:]]|$)|atlassian_cli_rovodev([[:space:]]|$)|(acli[[:space:]]+rovodev[[:space:]]+run)
```

The preceding `grep -Ev '... serve ...'` filter already removes serve lines before this match, so broadening the positive branch does not start matching `atlassian_cli_rovodev serve`.
Verify with the `test_match` harness above that all "expected to match" cases pass, all serve cases are excluded, and unrelated commands (`git status`, `node`, a bare `/bin/sh ...`) still do not match.

Bug 3 (only if verification confirms it): change `state_dir()` (`:24-28`) to a deterministic path as shown in the Bug 3 section, so the hook and the scanner agree.

### 4. `bin/uninstall-rovo-hooks` (P0 follow-through)

After stripping the hook entries from `config.yml`, also best-effort remove the stable launcher copy so uninstall is symmetric:

```sh
rm -f "$(dirname "$config")/hooks/herdr-managed/rovo-herdr-hook" 2>/dev/null || true
# also remove the herdr-managed dir if now empty
rmdir "$(dirname "$config")/hooks/herdr-managed" 2>/dev/null || true
```

### 5. `herdr-plugin.toml` (P0 follow-through)

Add `bin/rovo-herdr-hook-launcher` to the `chmod +x` `[[build]]` step list so the shipped launcher is executable (Git may not preserve the exec bit, mirroring the existing `check-deps` handling and commit `6c667da`).

### 6. `.github/workflows/ci.yml` and `.github/workflows/release.yml` (P0 follow-through)

Add `bin/rovo-herdr-hook-launcher` to the `bash -n` file lists in both workflows so the new script is syntax-checked in CI.

### 7. `README.md` (docs)

Update the "What it does" and reporting-paths sections to describe the launcher indirection and the fact that the config records a stable path, not the plugin's build-time directory.
Keep the one-sentence-per-line style used in this repo's longer prose where applicable.

---

## Remediate the reporter's currently-broken machine

The reporter's live state is already broken and will not self-heal from a code change alone, because the bad path is persisted in `~/.rovo/config.yml`.
After the fix is built and the plugin is reinstalled or relinked, do the following (back up first; the installer also makes its own timestamped backup):

1. Re-run the fixed hook install so `config.yml` gets the stable launcher path:
   `herdr plugin action invoke install-hooks --plugin rovo-dev.detector`
   or run the installed plugin's `bin/install-rovo-hooks` directly.
2. Confirm the new path is stable and the launcher exists:
   `grep rovo-herdr-hook ~/.rovo/config.yml` should show `~/.rovo/hooks/herdr-managed/rovo-herdr-hook`, and that file should exist and be executable.
3. Clear stale coordination state so nothing carries over:
   remove the old `hooked/` markers and empty `tracked-panes` under whichever state dir is now in use.
4. Restart the running Rovo session so it reloads `eventHooks` from `config.yml` (hooks are read at session start).
5. Also fix the legacy config if the legacy CLI is still used: `~/.rovodev/config.yml` currently points at the local working-tree path `/Users/usrivastava/workspace/github/herdr-rovo-dev/bin/rovo-herdr-hook`, which is stale relative to the GitHub install; re-running install-hooks against the legacy CLI updates it to a launcher too.

---

## Reproduction (do this first, and again after the fix)

Bug 2 is reproducible without a full Herdr session using the `test_match` harness above; it must flip from NO MATCH to MATCH for the bare `atlassian_cli_rovodev` cases.

End-to-end, matching how the user experiences it:

1. Install the plugin from a clean state via the GitHub remote (or `herdr plugin link` a fresh checkout, then run the auto build) so the `[[build]]` auto-install path runs.
2. Inspect `~/.rovo/config.yml`: before the fix the hook path is under `.tmp-install-*` and does not exist; after the fix it is the stable launcher path and exists.
3. Start a Rovo CLI session in a Herdr pane and give it a task that keeps it "thinking" and spawns a subagent.
4. Observe the sidebar: before the fix it reads `idle - rovo-dev - exited` while the pane works; after the fix it tracks the live state (`working` while thinking, `blocked` on a permission prompt, `idle` when done).
5. Tail `~/.rovo/event_hooks.log`: before the fix every entry is "No such file or directory"; after the fix the launcher resolves and the real hook runs cleanly.

---

## Acceptance criteria

- The `test_match` harness matches bare `atlassian_cli_rovodev`, `atlassian_cli_rovodev --restore <id>`, `/abs/path/atlassian_cli_rovodev`, and continues to match all prior `rovo` / `acli rovodev run` cases, while still excluding every `serve` variant and unrelated commands.
- A fresh GitHub install writes a hook command into `~/.rovo/config.yml` that exists on disk and is not under any `.tmp-install-*` directory.
- After an upgrade that changes the plugin's content hash, the previously-registered hook path still resolves and fires (the launcher finds the new root); no manual reinstall is required.
- While a Rovo session is actively working, the sidebar never shows `exited`; it shows `working`, `blocked`, or `idle` matching the session, and it converges to `idle`/`exited` only when the session truly ends.
- `event_hooks.log` shows the hook running without "No such file or directory".
- If Bug 3 is confirmed and fixed: the hook and scanner read and write the same `hooked/` marker directory, and a scan during active work does not reset a hook-reporting pane.
- `bash -n` passes for all scripts including the new launcher; CI's syntax-check job lists it.

---

## Non-goals

- Do not switch the plugin away from shell scripts or add new hard runtime dependencies beyond the existing `bash`, `jq`, `grep`, `sed` (`yq` remains the optional hook-install-only dependency).
- Do not attempt to make the scanner poll continuously; it stays event-driven, and hooks remain the primary path.
- Do not change Herdr itself; the fix lives entirely in this plugin and uses only public Herdr CLI APIs.

---

## Reviewer checklist (for the person reviewing the executing agent's changes)

- Design constraints hold: no new external dependency was introduced (only `herdr` plus the already-required `bash`/`jq`/`grep`/`sed`); `bin/check-deps` is unchanged except possibly for comments; all shipped code lives in the plugin repo; the launcher resolves the plugin only through the public `herdr plugin list` API, not by hardcoding or globbing Herdr-internal paths.
- New `bin/rovo-herdr-hook-launcher` is static, resolves `plugin_root` via `herdr plugin list --plugin rovo-dev.detector --json`, exits 0 (never errors) when it cannot resolve, and `exec`s the real hook so stdin passes through.
- `install-rovo-hooks` no longer records `$SCRIPT_DIR/...`; it copies the launcher to a stable per-CLI `hooks/herdr-managed/` directory and registers that path, with a guard rejecting any `.tmp-install-*` path.
- The Bug 2 regex change matches bare `atlassian_cli_rovodev` and still excludes `serve`; confirm against the `test_match` cases.
- Bug 3: confirm the empirical check was actually run and documented in the PR; if confirmed, `state_dir()` is deterministic across both invocation contexts.
- `uninstall-rovo-hooks` removes the launcher copy; `herdr-plugin.toml` chmod list and both CI workflows include the new file.
- Commits follow Conventional Commits (`fix:` for the bugs, `feat:`/`refactor:`/`docs:`/`ci:` as appropriate); no `CHANGELOG.md` hand-edits; no co-author trailer added.
- The E2E reproduction and its post-fix result are described in the PR body.
