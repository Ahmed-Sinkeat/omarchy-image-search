#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$ROOT/omarchy-capture-image-search"
TEST_DIR=$(mktemp -d)
BIN_DIR="$TEST_DIR/bin"
mkdir -p "$BIN_DIR" "$TEST_DIR/runtime"
chmod 700 "$TEST_DIR/runtime"

cleanup() {
  if [[ -n ${FREEZE_PROCESS:-} ]]; then
    kill "$FREEZE_PROCESS" 2>/dev/null || true
  fi
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

stub() {
  local name=$1
  shift
  printf '%s\n' '#!/bin/bash' "$@" >"$BIN_DIR/$name"
  chmod +x "$BIN_DIR/$name"
}

stub pkill 'exit 1'
stub hyprctl \
  'if [[ $1 == getoption ]]; then echo '\''{"int":1}'\''; exit 0; fi' \
  'exit 0'
stub omarchy-capture-region 'printf "%s\n10,20 300x200\n" "$FREEZE_PROCESS"'
stub grim \
  'printf "%s\n" "${@: -1}" >"$CAPTURE_PATH_LOG"' \
  'printf "fake-png" >"${@: -1}"'
stub omarchy-launch-browser \
  'kill -0 "$FREEZE_PROCESS" 2>/dev/null && { echo "freeze still alive at browser launch" >&2; exit 90; }' \
  'printf "browser %s\n" "$*" >>"$LOG_FILE"' \
  '[[ ${BROWSER_FAIL:-false} == true ]] && exit 1' \
  'page=${@: -1}; cp "${page#file://}" "$PAGE_COPY"' \
  'exit 0'
stub omarchy-notification-send 'printf "notify %s\n" "$*" >>"$LOG_FILE"'
for forbidden in wtype gdbus curl; do
  stub "$forbidden" 'echo "'"$forbidden"' must not be used" >&2; exit 99'
done

export PATH="$BIN_DIR:$PATH"
export XDG_RUNTIME_DIR="$TEST_DIR/runtime"
export LOG_FILE="$TEST_DIR/events.log"
export CAPTURE_PATH_LOG="$TEST_DIR/capture-path"
export PAGE_COPY="$TEST_DIR/page.html"
export LENS_PAGE_TTL=0

start_freeze() {
  : >"$LOG_FILE"
  rm -f "$PAGE_COPY"
  sleep 60 &
  FREEZE_PROCESS=$!
  export FREEZE_PROCESS
}

# --- happy path -------------------------------------------------------------
start_freeze
"$SCRIPT" --private smart

CAPTURE_PATH=$(<"$CAPTURE_PATH_LOG")
[[ ! -e $CAPTURE_PATH ]] || { echo "capture PNG was not removed" >&2; exit 1; }
grep -F -- '--private --new-window file://' "$LOG_FILE" >/dev/null
# base64 of the stub's "fake-png" payload must be embedded in the page
grep -F 'atob("ZmFrZS1wbmc=")' "$PAGE_COPY" >/dev/null
grep -F 'action="https://lens.google.com/v3/upload?ep=ccm&s=&st=' "$PAGE_COPY" >/dev/null
grep -F 'name=encoded_image' "$PAGE_COPY" >/dev/null
grep -F 'f.submit();' "$PAGE_COPY" >/dev/null

# --- browser failure --------------------------------------------------------
start_freeze
BROWSER_FAIL=true
export BROWSER_FAIL
if "$SCRIPT" smart; then
  echo "browser failure unexpectedly succeeded" >&2
  exit 1
fi
unset BROWSER_FAIL

CAPTURE_PATH=$(<"$CAPTURE_PATH_LOG")
[[ ! -e $CAPTURE_PATH ]] || { echo "failed capture PNG was not removed" >&2; exit 1; }
[[ -z $(find "$XDG_RUNTIME_DIR" -name 'omarchy-image-search.*') ]] ||
  { echo "upload page leaked after browser failure" >&2; exit 1; }
grep -F 'Could not open the default browser' "$LOG_FILE" >/dev/null

echo "image-search tests passed"
