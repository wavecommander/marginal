#!/usr/bin/env bash
# Builds a Debug build, installs it on a physical iPad and runs it with its console attached, so the
# app's stdout, stderr and os_log (Logger) messages stream here and into build/device-console.log.
# When the app exits or crashes, any new crash reports for it are copied from the iPad into
# build/crashes/ and summarised (exception, crashed thread, app frames symbolicated against the build).
# Usage: scripts/device-debug.sh ["Device name or UDID"] [-- launch args...]
# Env:   TACTILE_DEVICE    Device name or UDID (default: the first connected physical iPad).
#        TACTILE_NO_BUILD  Set to 1 to launch what is already installed (skips build and install).
#        TACTILE_TEAM      As for scripts/device.sh.
# Ctrl-C stops the app (devicectl forwards the signal) and still collects crash reports.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
BUNDLE_ID="software.tactile.texts"

DEVICE="${TACTILE_DEVICE:-}"
if [[ $# -gt 0 && "$1" != "--" ]]; then DEVICE="$1"; shift; fi
[[ "${1:-}" == "--" ]] && shift
LAUNCH_ARGS=("$@")

if [[ -z "$DEVICE" ]]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null \
    | awk '/physical/ && /iPad/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')"
fi
[[ -n "$DEVICE" ]] || { echo "device-debug.sh: no paired iPad found" >&2; exit 1; }

if [[ "${TACTILE_NO_BUILD:-}" != "1" ]]; then
  TACTILE_CONFIG=Debug TACTILE_NO_LAUNCH=1 "$REPO/scripts/device.sh" "$DEVICE"
fi
APP="$REPO/build/DerivedData-device/Build/Products/Debug-iphoneos/TactileTexts.app"

mkdir -p "$REPO/build/crashes"
CONSOLE="$REPO/build/device-console.log"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# Names of the app's crash reports on the iPad, one per line.
crash_names() {
  xcrun devicectl device info files --device "$DEVICE" --domain-type systemCrashLogs \
      -j "$SCRATCH/files.json" >/dev/null 2>&1 || return 0
  /usr/bin/python3 -c '
import json, sys
for f in json.load(open(sys.argv[1]))["result"]["files"]:
    n = f["relativePath"]
    if n.startswith("TactileTexts") and n.endswith(".ips"): print(n)
' "$SCRATCH/files.json" | sort
}

crash_names >"$SCRATCH/before.txt"

printf '\n==> Running Tactile Texts (Debug) with the console attached; log: %s\n' "$CONSOLE"
printf '    Ctrl-C stops the app. Crash reports go to build/crashes/.\n\n'
{
  echo "# device-debug.sh $(date '+%Y-%m-%d %H:%M:%S') device=$DEVICE commit=$(git rev-parse --short HEAD 2>/dev/null) args=${LAUNCH_ARGS[*]:-}"
} >"$CONSOLE"

# OS_ACTIVITY_DT_MODE mirrors os_log / Logger messages to stderr, as Xcode does when it runs an app.
set +e
DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=enable \
  xcrun devicectl device process launch --device "$DEVICE" --console --terminate-existing \
    "$BUNDLE_ID" ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"} 2>&1 \
  | while IFS= read -r line; do
      stamped="$(date '+%H:%M:%S') $line"
      printf '%s\n' "$stamped"
      printf '%s\n' "$stamped" >>"$CONSOLE"
    done
STATUS=${PIPESTATUS[0]}
set -e
printf '\n==> App exited (devicectl status %s) at %s\n' "$STATUS" "$(date '+%H:%M:%S')" | tee -a "$CONSOLE"

# The crash reporter writes the report a few seconds after the process dies.
NEW=()
for _ in 1 2 3 4 5 6; do
  crash_names >"$SCRATCH/after.txt"
  NEW=()
  while IFS= read -r n; do [[ -n "$n" ]] && NEW+=("$n"); done \
    < <(comm -13 "$SCRATCH/before.txt" "$SCRATCH/after.txt")
  [[ ${#NEW[@]} -gt 0 ]] && break
  sleep 3
done

if [[ ${#NEW[@]} -eq 0 ]]; then
  echo "==> No new crash report for the app on the iPad." | tee -a "$CONSOLE"
  exit 0
fi
for n in "${NEW[@]}"; do
  dest="$REPO/build/crashes/$n"
  xcrun devicectl device copy from --device "$DEVICE" --domain-type systemCrashLogs \
      --source "$n" --destination "$dest" >/dev/null 2>&1 || { echo "    could not copy $n"; continue; }
  printf '\n==> Crash report: %s\n' "$dest" | tee -a "$CONSOLE"
  /usr/bin/python3 "$REPO/scripts/crash-summary.py" "$dest" "$APP" | tee -a "$CONSOLE"
done
