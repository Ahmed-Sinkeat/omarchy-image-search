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
  'if [[ -n ${FREEZE_PROCESS:-} ]] && kill -0 "$FREEZE_PROCESS" 2>/dev/null; then' \
  '  echo "freeze still alive at browser launch" >&2; exit 90' \
  'fi' \
  'printf "browser %s\n" "$*" >>"$LOG_FILE"' \
  '[[ ${BROWSER_FAIL:-false} == true ]] && exit 1' \
  'page=${@: -1}; [[ $page == file://* ]] && cp "${page#file://}" "$PAGE_COPY"' \
  'exit 0'
stub omarchy-notification-send 'printf "notify %s\n" "$*" >>"$LOG_FILE"'
stub magick 'printf "magick %s\n" "$*" >>"$LOG_FILE"' 'cp "$1" "${@: -1}"'
stub wl-paste 'printf "%s" "${CLIP_PAYLOAD:-}"'
stub curl \
  'printf "curl %s\n" "$*" >>"$LOG_FILE"' \
  '[[ ${BING_EMPTY:-false} == true ]] && exit 0' \
  'printf "https://www.bing.com/images/search?view=detailV2\n"'
for forbidden in wtype gdbus; do
  stub "$forbidden" 'echo "'"$forbidden"' must not be used" >&2; exit 99'
done

# A bare `! grep` is a no-op under set -e, so negative assertions go through here.
refute() {
  if grep -F -e "$1" "$LOG_FILE" >/dev/null; then
    echo "$2" >&2
    exit 1
  fi
}

export PATH="$BIN_DIR:$PATH"
export XDG_RUNTIME_DIR="$TEST_DIR/runtime"
export LOG_FILE="$TEST_DIR/events.log"
export CAPTURE_PATH_LOG="$TEST_DIR/capture-path"
export PAGE_COPY="$TEST_DIR/page.html"
export LENS_PAGE_TTL=0

reset_logs() {
  : >"$LOG_FILE"
  rm -f "$PAGE_COPY"
}

start_freeze() {
  reset_logs
  sleep 60 &
  FREEZE_PROCESS=$!
  export FREEZE_PROCESS
}

# Sources other than a screen capture never freeze the desktop.
no_freeze() {
  reset_logs
  if [[ -n ${FREEZE_PROCESS:-} ]]; then
    kill "$FREEZE_PROCESS" 2>/dev/null || true
  fi
  FREEZE_PROCESS=""
  export FREEZE_PROCESS
}

# --- happy path -------------------------------------------------------------
start_freeze
"$SCRIPT" --private smart

CAPTURE_PATH=$(<"$CAPTURE_PATH_LOG")
[[ ! -e $CAPTURE_PATH ]] || { echo "capture PNG was not removed" >&2; exit 1; }
grep -E -- 'browser --private file:///' "$LOG_FILE" >/dev/null
# A tab in the running browser, not another window.
refute '--new-window' "browser was asked for a new window"
# Only ever shrinks, never enlarges.
grep -F -- '-resize 2000x2000>' "$LOG_FILE" >/dev/null
refute 'curl ' "the google path must not shell out to curl"
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

# --- stale page sweep ------------------------------------------------------
start_freeze
STALE="$XDG_RUNTIME_DIR/omarchy-image-search.STALE.html"
: >"$STALE"
touch -d '10 minutes ago' "$STALE"
FRESH="$XDG_RUNTIME_DIR/keep-me.html"
: >"$FRESH"
touch -d '10 minutes ago' "$FRESH"
"$SCRIPT" smart
[[ ! -e $STALE ]] || { echo "stale page was not swept" >&2; exit 1; }
[[ -e $FRESH ]] || { echo "sweep removed an unrelated file" >&2; exit 1; }
# Without --private the browser gets the page and nothing else.
grep -E -- 'browser file:///' "$LOG_FILE" >/dev/null
refute '--private' "private flag leaked into a normal search"

# --- bing engine -----------------------------------------------------------
start_freeze
"$SCRIPT" --bing smart
grep -F -- 'imageBin=<' "$LOG_FILE" >/dev/null
# Bing gets a size-capped JPEG, not the full PNG.
grep -F -- '-resize 1600x1600>' "$LOG_FILE" >/dev/null
grep -E -- 'magick .*\.scaled\.jpg' "$LOG_FILE" >/dev/null
grep -F -- 'browser https://www.bing.com/' "$LOG_FILE" >/dev/null
[[ -z $(find "$XDG_RUNTIME_DIR" -name 'omarchy-image-search.*') ]] ||
  { echo "bing run left files behind" >&2; exit 1; }

# --- bing returning nothing ------------------------------------------------
start_freeze
BING_EMPTY=true
export BING_EMPTY
if "$SCRIPT" --bing smart; then
  echo "empty bing result unexpectedly succeeded" >&2
  exit 1
fi
unset BING_EMPTY
grep -F 'Bing did not return a result' "$LOG_FILE" >/dev/null
[[ -z $(find "$XDG_RUNTIME_DIR" -name 'omarchy-image-search.*') ]] ||
  { echo "failed bing run leaked files" >&2; exit 1; }

# --- resize failure must not destroy the capture ---------------------------
start_freeze
stub magick 'exit 1'
"$SCRIPT" smart
grep -F 'Could not resize the capture' "$LOG_FILE" >/dev/null
grep -E -- 'browser file:///' "$LOG_FILE" >/dev/null
grep -F 'atob("ZmFrZS1wbmc=")' "$PAGE_COPY" >/dev/null
stub magick 'printf "magick %s\n" "$*" >>"$LOG_FILE"' 'cp "$1" "${@: -1}"'

# --- --file must not consume the caller's file -----------------------------
no_freeze
SOURCE_IMAGE="$TEST_DIR/source.png"
printf 'from-file' >"$SOURCE_IMAGE"
"$SCRIPT" --file "$SOURCE_IMAGE"
[[ -f $SOURCE_IMAGE ]] || { echo "--file deleted the caller's image" >&2; exit 1; }
[[ $(<"$SOURCE_IMAGE") == from-file ]] || { echo "--file modified the caller's image" >&2; exit 1; }
grep -F "atob(\"$(printf 'from-file' | base64 -w0)\")" "$PAGE_COPY" >/dev/null
refute 'omarchy-capture-region' "--file must not open the region selector"
[[ -z $(find "$XDG_RUNTIME_DIR" -name 'omarchy-image-search.*.png') ]] ||
  { echo "--file left a copy behind" >&2; exit 1; }

# --- --file on a missing path ----------------------------------------------
no_freeze
if "$SCRIPT" --file "$TEST_DIR/not-here.png"; then
  echo "missing --file path unexpectedly succeeded" >&2
  exit 1
fi
grep -F 'Could not read' "$LOG_FILE" >/dev/null

# --- --file with no argument -----------------------------------------------
no_freeze
if "$SCRIPT" --file; then
  echo "--file without a path unexpectedly succeeded" >&2
  exit 1
fi

# --- --clipboard ------------------------------------------------------------
no_freeze
CLIP_PAYLOAD=from-clip
export CLIP_PAYLOAD
"$SCRIPT" --clipboard
grep -F "atob(\"$(printf 'from-clip' | base64 -w0)\")" "$PAGE_COPY" >/dev/null
refute 'omarchy-capture-region' "--clipboard must not open the region selector"

# --- --clipboard with an empty clipboard ------------------------------------
no_freeze
CLIP_PAYLOAD=""
if "$SCRIPT" --clipboard; then
  echo "empty clipboard unexpectedly succeeded" >&2
  exit 1
fi
unset CLIP_PAYLOAD
grep -F 'No image in the clipboard' "$LOG_FILE" >/dev/null

echo "image-search tests passed"
