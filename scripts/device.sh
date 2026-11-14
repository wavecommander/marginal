#!/usr/bin/env bash
# Builds a signed Release build and installs it on a physical iPad, then tries to launch it.
# Usage: MARGINAL_TEAM=<team id> scripts/device.sh ["Device name or UDID"]
# Env:   MARGINAL_TEAM    Apple development team ID used for automatic signing (required).
#        MARGINAL_DEVICE  Device name or UDID (default: the first connected physical iPad).
#        MARGINAL_CONFIG  Build configuration (default: Release).
# The device must be paired, unlocked, and have Developer Mode on. With a free Personal Team the
# developer profile must be trusted once on the device (Settings > General > VPN & Device
# Management) and the app stops launching after 7 days until it is installed again.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

: "${MARGINAL_TEAM:?Set MARGINAL_TEAM to your Apple development team ID}"
DEVICE="${1:-${MARGINAL_DEVICE:-}}"
CONFIG="${MARGINAL_CONFIG:-Release}"
BUNDLE_ID="software.tactile.marginal"

if [[ -z "$DEVICE" ]]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null \
    | awk '/physical/ && /iPad/ && /connected/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')"
fi
[[ -n "$DEVICE" ]] || { echo "device.sh: no connected iPad found; pass a device name or UDID" >&2; exit 1; }

xcodegen generate --quiet
LOG="$REPO/build/device-build.log"
mkdir -p "$REPO/build"
if ! xcodebuild build \
    -project Marginal.xcodeproj -scheme Marginal -configuration "$CONFIG" \
    -destination "id=$DEVICE" \
    -derivedDataPath "$REPO/build/DerivedData-device" \
    -allowProvisioningUpdates \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$MARGINAL_TEAM" >"$LOG" 2>&1; then
  grep -E "error:|BUILD FAILED" "$LOG" | sort -u | head -n 20 >&2
  echo "device.sh: build failed (full log: $LOG)" >&2
  exit 1
fi

APP="$REPO/build/DerivedData-device/Build/Products/$CONFIG-iphoneos/Marginal.app"
xcrun devicectl device install app --device "$DEVICE" "$APP" | tail -n 3
if ! xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1; then
  echo "device.sh: installed, but could not launch. Unlock the iPad and, with a Personal Team," >&2
  echo "trust the developer profile once in Settings > General > VPN & Device Management." >&2
  exit 2
fi
echo "Launched $BUNDLE_ID on $DEVICE"
