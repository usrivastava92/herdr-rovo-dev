#!/usr/bin/env bash
# Real jq / Mike Farah yq integration; no running Herdr or Rovo is needed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }
command -v yq >/dev/null || { echo 'Mike Farah yq v4 is required' >&2; exit 1; }
case "$(yq --version)" in *mikefarah*'version v4.'*) ;; *) echo 'Mike Farah yq v4 is required' >&2; exit 1;; esac
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/herdr-desktop-install.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT
# Match the installer's physical absolute paths (macOS /var aliases /private/var).
sandbox="$(cd "$sandbox" && pwd -P)"
export HOME="$sandbox/home"
export XDG_CONFIG_HOME="$HOME/config space"
export HERDR_APP_HOME="$HOME/Desktop's app"
export ROVO_USER_DIR="$HOME/Rovo's config space"
unset ROVO_DEV_CONFIG_FILE HERDR_ROVO_TRANSPORT HERDR_ROVO_TTY
mkdir -p "$ROVO_USER_DIR" "$HERDR_APP_HOME" "$HOME/.rovodev"
config="$ROVO_USER_DIR/config.yml"
programs="$HERDR_APP_HOME/programs.json"
installed="$ROVO_USER_DIR/hooks/herdr-managed-desktop"
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() { if "$@" >"$sandbox/failure.log" 2>&1; then fail "unexpected success: $*"; fi; }
assert_config() { yq -o=json '.' "$config" | jq -e "$1" >/dev/null || fail "config assertion: $1"; }
mkdir -p "$sandbox/fixture-bin"
cat > "$sandbox/fixture-bin/rovo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${ROVO_DEV_CONFIG_FILE:-}" > "$ROVO_CONFIG_RECORD"
SH
chmod +x "$sandbox/fixture-bin/rovo"
assert_launcher_config() {
  local menu="$1" expected="$2" arg
  local -a argv=()
  while IFS= read -r arg; do argv+=("$arg"); done < <(jq -r '.programs["rovo-dev"].run[]' "$menu")
  [ "${#argv[@]}" -eq 1 ] || fail 'registered command is not a standalone wrapper'
  env -u ROVO_DEV_CONFIG_FILE -u ROVO_USER_DIR -u HERDR_APP_HOME -u XDG_CONFIG_HOME \
    PATH="$sandbox/fixture-bin:$PATH" ROVO_CONFIG_RECORD="$sandbox/launched-config" \
    "${argv[@]}" </dev/null >"$sandbox/launcher.stdout" 2>"$sandbox/launcher.stderr"
  [ "$(cat "$sandbox/launched-config")" = "$expected" ] || fail 'launcher lost selected config'
}
cat > "$config" <<'YAML'
model: keep-me
eventHooks:
  extra: preserved
  events:
    - name: on_session_start
      custom: keep
      commands:
        - command: /tui/rovo-herdr-hook
          timeout: 42
        - command: echo unrelated
    - name: private_event
      custom: private
      commands:
        - command: echo private
YAML
printf 'legacy: unchanged\n' > "$HOME/.rovodev/config.yml"
printf '%s\n' '{"theme":"dark","programs":{"other":{"run":["other"]},"rovo-dev":{"name":"Custom Rovo","match":["my-rovo"],"icon":"custom.svg","color":"blue"}}}' > "$programs"
bash "$ROOT/bin/install-desktop" --help >/dev/null
bash "$ROOT/bin/uninstall-desktop" --help >/dev/null
# Sidecar destinations obey the same safety rules as installed scripts.
mkdir -p "$installed"
printf 'unrelated\n' > "$sandbox/sidecar-target"
ln -s "$sandbox/sidecar-target" "$installed/rovo-desktop-config.json"
expect_failure bash "$ROOT/bin/install-desktop"
expect_failure bash "$ROOT/bin/uninstall-desktop"
[ "$(cat "$sandbox/sidecar-target")" = unrelated ] || fail 'changed sidecar symlink target'
rm "$installed/rovo-desktop-config.json"
mkdir "$installed/rovo-desktop-config.json"
expect_failure bash "$ROOT/bin/install-desktop"
expect_failure bash "$ROOT/bin/uninstall-desktop"
rmdir "$installed/rovo-desktop-config.json"
bash "$ROOT/bin/install-desktop" >/dev/null
for file in rovo-herdr-desktop rovo-herdr-desktop-hook rovo-event.sh; do
  [ -x "$installed/$file" ] || fail "missing executable: $file"
  cmp "$ROOT/bin/$file" "$installed/$file" || fail "not standalone: $file"
done
jq -e --arg config "$config" '. == {config_file:$config}' "$installed/rovo-desktop-config.json" >/dev/null
assert_launcher_config "$programs" "$config"
assert_config '.model == "keep-me" and .eventHooks.extra == "preserved" and .eventHooks.events[0].custom == "keep" and .eventHooks.events[0].commands[0].timeout == 42'
assert_config '[.eventHooks.events[].commands[] | select(.command | contains("rovo-herdr-desktop-hook"))] | length == 8'
assert_config '[.eventHooks.events[].commands[] | select(.command == "/tui/rovo-herdr-hook")] | length == 1'
assert_config '.eventHooks.events[1] == {name:"private_event",custom:"private",commands:[{command:"echo private"}]}'
command_string="$(yq -r '.eventHooks.events[0].commands[-1].command' "$config")"
# Parse as a shell command without executing it: apostrophes/spaces stay one word.
EXPECTED="$installed/rovo-herdr-desktop-hook" bash -c "set -- $command_string; [ \"\$#\" -eq 1 ] && [ \"\$1\" = \"\$EXPECTED\" ]" || fail 'unsafe shell quoting'
jq -e --arg run "$installed/rovo-herdr-desktop" '.theme == "dark" and .programs.other.run == ["other"] and .programs["rovo-dev"] == {icon:"custom.svg",color:"blue",name:"Custom Rovo",run:[$run],match:["my-rovo"]}' "$programs" >/dev/null
cp "$config" "$sandbox/once.yml"
cp "$programs" "$sandbox/once.json"
cp "$installed/rovo-desktop-config.json" "$sandbox/once-sidecar.json"
bash "$ROOT/bin/install-desktop" >/dev/null
cmp "$config" "$sandbox/once.yml" || fail 'reinstall changed config'
cmp "$programs" "$sandbox/once.json" || fail 'reinstall changed programs'
cmp "$installed/rovo-desktop-config.json" "$sandbox/once-sidecar.json" || fail 'reinstall changed sidecar'
compgen -G "$config.before-herdr-desktop.*" >/dev/null || fail 'missing config backup'
compgen -G "$programs.before-herdr-desktop.*" >/dev/null || fail 'missing programs backup'
# TUI uninstall's marker must not match desktop commands, and vice versa.
assert_config '[.eventHooks.events[].commands[] | select(.command | contains("rovo-herdr-hook"))] | length == 1'
printf 'leave me\n' > "$installed/unowned"
bash "$ROOT/bin/uninstall-desktop" >/dev/null
assert_config '[.eventHooks.events[].commands[] | select(.command | contains("rovo-herdr-desktop-hook"))] | length == 0'
assert_config '.eventHooks.events[0].commands == [{command:"/tui/rovo-herdr-hook",timeout:42},{command:"echo unrelated"}]'
jq -e '.theme == "dark" and .programs.other.run == ["other"] and .programs["rovo-dev"] == {name:"Custom Rovo",match:["my-rovo"],icon:"custom.svg",color:"blue"}' "$programs" >/dev/null
[ -f "$installed/unowned" ] || fail 'removed unowned file'
[ ! -e "$installed/rovo-herdr-desktop" ] || fail 'left owned wrapper'
[ ! -e "$installed/rovo-desktop-config.json" ] || fail 'left owned config sidecar'
rm "$installed/unowned"
bash "$ROOT/bin/uninstall-desktop" >/dev/null
[ ! -d "$installed" ] || fail 'left empty owned directory'
# Default-valued display fields are not evidence of installer ownership.
printf '%s\n' '{"programs":{"rovo-dev":{"name":"Rovo","match":["rovo"],"icon":"custom.svg"}}}' > "$programs"
cp "$programs" "$sandbox/preexisting-display.json"
bash "$ROOT/bin/install-desktop" >/dev/null
bash "$ROOT/bin/uninstall-desktop" >/dev/null
jq -S . "$programs" > "$sandbox/display-after.json"
jq -S . "$sandbox/preexisting-display.json" > "$sandbox/display-before.json"
cmp "$sandbox/display-before.json" "$sandbox/display-after.json" || fail 'changed pre-existing default display fields'
# Existing run ownership conflicts are rejected before changing hooks/files.
printf '%s\n' '{"programs":{"rovo-dev":{"run":["someone-else"],"icon":"keep"}}}' > "$programs"
cp "$config" "$sandbox/before-conflict.yml"
cp "$programs" "$sandbox/before-conflict.json"
expect_failure bash "$ROOT/bin/install-desktop"
cmp "$config" "$sandbox/before-conflict.yml"
cmp "$programs" "$sandbox/before-conflict.json"
[ ! -d "$installed" ] || fail 'copied files before conflict validation'
# Malformed and multi-document files must never be replaced or trigger removal.
printf '{broken\n' > "$programs"
cp "$programs" "$sandbox/broken.json"
expect_failure bash "$ROOT/bin/install-desktop"
expect_failure bash "$ROOT/bin/uninstall-desktop"
cmp "$programs" "$sandbox/broken.json"
cmp "$config" "$sandbox/before-conflict.yml"
printf '{}\n{}\n' > "$programs"
expect_failure bash "$ROOT/bin/install-desktop"
printf '{}\n' > "$programs"
printf 'eventHooks: [broken\n' > "$config"
cp "$config" "$sandbox/broken.yml"
expect_failure bash "$ROOT/bin/install-desktop"
expect_failure bash "$ROOT/bin/uninstall-desktop"
cmp "$config" "$sandbox/broken.yml"
printf 'eventHooks: wrong-shape\n' > "$config"
expect_failure bash "$ROOT/bin/install-desktop"
printf '{}\n---\n{}\n' > "$config"
expect_failure bash "$ROOT/bin/install-desktop"
# Explicit config override wins; post-install edits to a run are not ours to undo.
mkdir -p "$HOME/Explicit Rovo's config"
selected_config="$HOME/Explicit Rovo's config/selected.yml"
export ROVO_DEV_CONFIG_FILE="$HOME/Explicit Rovo's config/../Explicit Rovo's config/selected.yml"
printf '{}\n' > "$ROVO_DEV_CONFIG_FILE"
bash "$ROOT/bin/install-desktop" >/dev/null
jq -e --arg run "$(dirname "$selected_config")/hooks/herdr-managed-desktop/rovo-herdr-desktop" '.programs["rovo-dev"].run == [$run]' "$programs" >/dev/null
assert_launcher_config "$programs" "$selected_config"
jq '.programs["rovo-dev"] += {run:["edited"],name:"My Rovo",match:["custom"],icon:"mine"}' "$programs" > "$sandbox/edited.json"
cp "$sandbox/edited.json" "$programs"
bash "$ROOT/bin/uninstall-desktop" >/dev/null
cmp "$programs" "$sandbox/edited.json" || fail 'changed customized program'
# With the owned run intact, remove it but preserve edited name/match/icon.
printf '{}\n' > "$programs"
bash "$ROOT/bin/install-desktop" >/dev/null
jq '.programs["rovo-dev"] += {name:"Custom name",match:["custom"],icon:"mine"}' "$programs" > "$sandbox/custom-fields.json"
cp "$sandbox/custom-fields.json" "$programs"
bash "$ROOT/bin/uninstall-desktop" >/dev/null
jq -e '.programs["rovo-dev"] == {name:"Custom name",match:["custom"],icon:"mine"}' "$programs" >/dev/null
# Missing current config never falls back to legacy, and uninstall remains safe.
unset ROVO_DEV_CONFIG_FILE ROVO_USER_DIR HERDR_APP_HOME
expect_failure bash "$ROOT/bin/install-desktop"
bash "$ROOT/bin/uninstall-desktop" >/dev/null
[ "$(cat "$HOME/.rovodev/config.yml")" = 'legacy: unchanged' ] || fail 'touched legacy config'
# Default current config and XDG programs location work without overrides.
mkdir -p "$HOME/.rovo"
printf '{}\n' > "$HOME/.rovo/config.yml"
bash "$ROOT/bin/install-desktop" >/dev/null
[ -f "$XDG_CONFIG_HOME/herdr-app/programs.json" ] || fail 'ignored XDG config home'
jq -e --arg config "$HOME/.rovo/config.yml" '. == {config_file:$config}' "$HOME/.rovo/hooks/herdr-managed-desktop/rovo-desktop-config.json" >/dev/null
assert_launcher_config "$XDG_CONFIG_HOME/herdr-app/programs.json" "$HOME/.rovo/config.yml"
bash "$ROOT/bin/uninstall-desktop" >/dev/null
printf 'desktop-install: passed\n'
