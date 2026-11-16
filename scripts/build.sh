#!/usr/bin/env bash
# Generates the Xcode project and builds the app for the simulator.
# Env: TACTILE_SIM (device name or UDID, default iPad Pro 11-inch).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sim.sh"
cd "$REPO"

xcodegen generate --quiet

LOG="$REPO/build/build.log"
mkdir -p "$REPO/build"
set +e
xcodebuild build \
  -project TactileTexts.xcodeproj -scheme TactileTexts \
  -destination "id=$SIM_UDID" \
  -derivedDataPath "$REPO/build/DerivedData" \
  -skipPackagePluginValidation \
  2>&1 | tee "$LOG" | grep -E "warning:|error:|BUILD (SUCCEEDED|FAILED)|\*\* BUILD"
status=${PIPESTATUS[0]}
set -e
if [[ $status -ne 0 ]]; then
  echo "build.sh: build failed (full log: $LOG)" >&2
  exit "$status"
fi
