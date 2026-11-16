#!/usr/bin/env bash
# Usage: scripts/shot.sh <name> [launch args...]   -> build/shots/<name>.png
# Env: TACTILE_SIM (device name or UDID), SHOT_DELAY (seconds to wait after launch, default 4),
#      SHOT_NO_BUILD=1 to skip building.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sim.sh"
cd "$REPO"

if [[ $# -lt 1 ]]; then echo "usage: shot.sh <name> [launch args...]" >&2; exit 2; fi
NAME="$1"; shift

if [[ -z "${SHOT_NO_BUILD:-}" ]]; then "$REPO/scripts/build.sh" >/dev/null; fi
APP="$REPO/build/DerivedData/Build/Products/Debug-iphonesimulator/TactileTexts.app"
[[ -d "$APP" ]] || { echo "shot.sh: $APP not found" >&2; exit 1; }

sim_boot
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIM_UDID" "$APP"
xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" "$@" >/dev/null
sleep "${SHOT_DELAY:-4}"
mkdir -p "$REPO/build/shots"
xcrun simctl io "$SIM_UDID" screenshot "$REPO/build/shots/$NAME.png" 2>&1 | tail -n 1
echo "$REPO/build/shots/$NAME.png"
