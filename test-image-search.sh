#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/omarchy-capture-image-search"
TEST_DIR=$(mktemp -d)
BIN_DIR="$TEST_DIR/bin"
LOG_FILE="$TEST_DIR/events.log"
STATE_FILE="$TEST_DIR/state"
RETURN_COUNT_FILE="$TEST_DIR/return-count"
mkdir -p "$BIN_DIR" "$TEST_DIR/runtime"
chmod 700 "$TEST_DIR/runtime"

cleanup() {
  [[ -n ${FREEZE_PROCESS:-} ]] && kill "$FREEZE_PROCESS" 2>/dev/null || true
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

write_stub() {
  local name=$1
  shift
  printf '%s\n' '#!/bin/bash' "$@" >"$BIN_DIR/$name"
  chmod +x "$BIN_DIR/$name"
}

write_stub pkill 'exit 1'
write_stub hyprctl \
  'printf "hyprctl %s\n" "$*" >>"$LOG_FILE"' \
  'if [[ $1 == getoption ]]; then echo '\''{"int":1}'\''; exit 0; fi' \
  'if [[ $1 == clients ]]; then' \
  '  state=$(<"$STATE_FILE")' \
  '  case $state in' \
  '    initial) echo '\''[]'\'' ;;' \
  '    browser) echo '\''[{"address":"0xBROWSER","class":"helium","title":"Google - Helium"}]'\'' ;;' \
  '    chooser) echo '\''[{"address":"0xBROWSER","class":"helium","title":"Google - Helium"},{"address":"0xCHOOSER","class":"xdg-desktop-portal-gtk","title":"Open File"}]'\'' ;;' \
  '    result) echo '\''[{"address":"0xBROWSER","class":"helium","title":"Google Search - Helium"}]'\'' ;;' \
  '  esac' \
  'fi'
write_stub omarchy-capture-region 'printf "%s\n10,20 300x200\n" "$FREEZE_PROCESS"'
write_stub grim \
  'printf "grim %s\n" "$*" >>"$LOG_FILE"' \
  'printf "%s\n" "${@: -1}" >"$CAPTURE_PATH_LOG"' \
  'printf "fake-png" >"${@: -1}"'
write_stub curl 'echo "curl must not be used" >&2; exit 99'
write_stub omarchy-launch-browser \
  'kill -0 "$FREEZE_PROCESS" 2>/dev/null && { echo "freeze still running when browser opened" >&2; exit 90; }' \
  'printf "browser %s\n" "$*" >>"$LOG_FILE"' \
  '[[ ${BROWSER_FAIL:-false} == true ]] && exit 1' \
  'printf "browser\n" >"$STATE_FILE"'
write_stub wtype \
  'printf "wtype %s\n" "$*" >>"$LOG_FILE"' \
  'if [[ " $* " == *" -k return "* ]]; then' \
  '  count=$(<"$RETURN_COUNT_FILE")' \
  '  count=$((count + 1))' \
  '  printf "%s\n" "$count" >"$RETURN_COUNT_FILE"' \
  '  [[ $count -ge 2 ]] && printf "chooser\n" >"$STATE_FILE"' \
  'fi'
write_stub gdbus \
  'args=" $* "' \
  'if [[ $args == *" org.a11y.Bus.GetAddress "* ]]; then echo "('\''unix:path=/tmp/a11y'\'',)"; exit 0; fi' \
  'if [[ $args == *" --dest org.a11y.atspi.Registry "* ]]; then echo "([('\'':1.1'\'', objectpath '\''/org/a11y/atspi/accessible/root'\'')],)"; exit 0; fi' \
  'if [[ $args == *" org.freedesktop.DBus.Properties.Get "* && $args == *" /org/a11y/atspi/accessible/root "* ]]; then echo "(<'\''xdg-desktop-portal-gtk'\''>,)"; exit 0; fi' \
  'if [[ $args == *" org.a11y.atspi.Accessible.GetRoleName "* && $args == *" /org/a11y/atspi/accessible/root "* ]]; then echo "('\''application'\'',)"; exit 0; fi' \
  'if [[ $args == *" org.a11y.atspi.Accessible.GetChildren "* && $args == *" /org/a11y/atspi/accessible/root "* ]]; then echo "([('\'':1.1'\'', objectpath '\''/org/a11y/atspi/accessible/1'\'')],)"; exit 0; fi' \
  'if [[ $args == *" org.freedesktop.DBus.Properties.Get "* && $args == *" /org/a11y/atspi/accessible/1 "* ]]; then echo "(<'\''Select'\''>,)"; exit 0; fi' \
  'if [[ $args == *" org.a11y.atspi.Accessible.GetRoleName "* && $args == *" /org/a11y/atspi/accessible/1 "* ]]; then echo "('\''button'\'',)"; exit 0; fi' \
  'if [[ $args == *" org.a11y.atspi.Action.DoAction "* ]]; then printf "result\n" >"$STATE_FILE"; echo "(true,)"; exit 0; fi' \
  'echo "([], )"'
write_stub omarchy-notification-send 'printf "notify %s\n" "$*" >>"$LOG_FILE"'

export PATH="$BIN_DIR:$PATH"
export LOG_FILE STATE_FILE RETURN_COUNT_FILE
export CAPTURE_PATH_LOG="$TEST_DIR/capture-path"
export XDG_RUNTIME_DIR="$TEST_DIR/runtime"

reset_state() {
  printf 'initial\n' >"$STATE_FILE"
  printf '0\n' >"$RETURN_COUNT_FILE"
  : >"$LOG_FILE"
  unset BROWSER_FAIL
}

reset_state
sleep 60 &
FREEZE_PROCESS=$!
export FREEZE_PROCESS

"$SCRIPT" --private smart

CAPTURE_PATH=$(<"$CAPTURE_PATH_LOG")
[[ ! -e $CAPTURE_PATH ]] || { echo "capture was not cleaned up" >&2; exit 1; }
grep -F "browser --private --new-window https://www.google.com/" "$LOG_FILE" >/dev/null
grep -F 'wtype javascript:document.querySelector('\''[jsname=R5mgy]'\'').click()' "$LOG_FILE" >/dev/null
grep -F 'wtype -M ctrl -k l -m ctrl' "$LOG_FILE" >/dev/null
grep -F "wtype $CAPTURE_PATH" "$LOG_FILE" >/dev/null
grep -F 'address:0xBROWSER' "$LOG_FILE" >/dev/null
grep -F 'address:0xCHOOSER' "$LOG_FILE" >/dev/null
! grep -F 'curl ' "$LOG_FILE" >/dev/null

reset_state
sleep 60 &
FREEZE_PROCESS=$!
export FREEZE_PROCESS
export BROWSER_FAIL=true

if "$SCRIPT" smart; then
  echo "browser failure unexpectedly succeeded" >&2
  exit 1
fi

CAPTURE_PATH=$(<"$CAPTURE_PATH_LOG")
[[ ! -e $CAPTURE_PATH ]] || { echo "failed capture was not cleaned up" >&2; exit 1; }
grep -F "notify -g  -u critical Visual search failed Could not open the default browser" "$LOG_FILE" >/dev/null

echo "image-search tests passed"
