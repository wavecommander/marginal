#!/usr/bin/env bash
# Builds a signed build and installs it on a physical iPad, then launches it, reporting each step.
# Usage: MARGINAL_TEAM=<team id> scripts/device.sh ["Device name or UDID"]
# Env:   MARGINAL_TEAM        Apple development team ID used for automatic signing. Optional when
#                             Config/Local.xcconfig exists (it then supplies the team).
#        MARGINAL_DEVICE      Device name or UDID (default: the first connected physical iPad).
#        MARGINAL_CONFIG      Build configuration (default: Release).
#        MARGINAL_NO_INSTALL  Set to 1 to stop after the build (nothing is sent to the device).
# The device must be paired, unlocked, and have Developer Mode on. With a free Personal Team the
# developer profile must be trusted once on the device (Settings > General > VPN & Device
# Management) and the app stops launching after 7 days until it is installed again.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

DEVICE="${1:-${MARGINAL_DEVICE:-}}"
CONFIG="${MARGINAL_CONFIG:-Release}"
BUNDLE_ID="software.tactile.marginal"
STARTED=$SECONDS

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
elapsed() { printf '%dm%02ds' $(( ($SECONDS - ${1:-$STARTED}) / 60 )) $(( ($SECONDS - ${1:-$STARTED}) % 60 )); }

if [[ -z "${MARGINAL_TEAM:-}" && ! -f "$REPO/Config/Local.xcconfig" ]]; then
  echo "device.sh: set MARGINAL_TEAM to your Apple development team ID, or create Config/Local.xcconfig" >&2
  exit 1
fi

step "Finding the iPad"
if [[ -z "$DEVICE" ]]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null \
    | awk '/physical/ && /iPad/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')"
fi
[[ -n "$DEVICE" ]] || { echo "device.sh: no paired iPad found; connect one or pass a device name or UDID" >&2; exit 1; }
DEVICE_LINE="$(xcrun devicectl list devices 2>/dev/null | grep -F "$DEVICE" | head -n 1 || true)"
info "${DEVICE_LINE:-$DEVICE}"

step "Generating the Xcode project"
xcodegen generate --quiet
info "Marginal.xcodeproj is up to date ($(git rev-parse --short HEAD 2>/dev/null || echo 'no git'), branch $(git branch --show-current 2>/dev/null || echo '?'))"
if [[ -n "$(git status --porcelain -- App Tests UITests Packages 2>/dev/null)" ]]; then
  info "Note: this folder has uncommitted changes under App/, Tests/, UITests/ or Packages/; they are part of this build."
fi

step "Building ($CONFIG, signed) — this takes a few minutes on a clean build"
LOG="$REPO/build/device-build.log"
mkdir -p "$REPO/build"
SIGNING=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Automatic)
[[ -n "${MARGINAL_TEAM:-}" ]] && SIGNING+=("DEVELOPMENT_TEAM=$MARGINAL_TEAM")
BUILD_STARTED=$SECONDS
xcodebuild build \
    -project Marginal.xcodeproj -scheme Marginal -configuration "$CONFIG" \
    -destination "id=$DEVICE" \
    -derivedDataPath "$REPO/build/DerivedData-device" \
    -allowProvisioningUpdates \
    "${SIGNING[@]}" >"$LOG" 2>&1 &
BUILD_PID=$!
trap 'kill "$BUILD_PID" 2>/dev/null || true' INT TERM

# Report what the build is doing every few seconds until it finishes.
LAST=""
while kill -0 "$BUILD_PID" 2>/dev/null; do
  sleep 5
  PHASE="$(grep -E '^(SwiftCompile|SwiftDriver|CompileSwiftSources|SwiftEmitModule|CompileAssetCatalog|Ld|CodeSign|ProcessProductPackaging|GenerateDSYMFile|Validate|ProcessInfoPlistFile|CompileC|RegisterExecutionPolicyException) ' "$LOG" 2>/dev/null | tail -n 1 || true)"
  KIND="${PHASE%% *}"
  TARGET="$(printf '%s' "$PHASE" | sed -nE "s/.*\(in target '([^']+)'.*/\1/p")"
  case "$KIND" in
    SwiftCompile|SwiftDriver|CompileSwiftSources|SwiftEmitModule|CompileC) WHAT="compiling" ;;
    CompileAssetCatalog|ProcessInfoPlistFile) WHAT="processing resources" ;;
    Ld) WHAT="linking" ;;
    CodeSign|ProcessProductPackaging|Validate|RegisterExecutionPolicyException) WHAT="signing" ;;
    GenerateDSYMFile) WHAT="writing debug symbols" ;;
    *) WHAT="resolving packages and planning" ;;
  esac
  NOW="$WHAT${TARGET:+ $TARGET}"
  COMPILED="$(grep -cE '^SwiftCompile ' "$LOG" 2>/dev/null || true)"
  if [[ "$NOW" != "$LAST" ]]; then
    info "$(elapsed $BUILD_STARTED)  $NOW"
    LAST="$NOW"
  elif (( ($SECONDS - BUILD_STARTED) % 30 < 5 )); then
    info "$(elapsed $BUILD_STARTED)  still $NOW (${COMPILED:-0} Swift compile steps so far)"
  fi
done
trap - INT TERM
if ! wait "$BUILD_PID"; then
  grep -E "error:|BUILD FAILED" "$LOG" | sort -u | head -n 20 >&2
  echo "device.sh: build failed after $(elapsed $BUILD_STARTED) (full log: $LOG)" >&2
  exit 1
fi
info "Build succeeded in $(elapsed $BUILD_STARTED)"
PROFILE="$(grep -m1 -E 'Provisioning Profile: ' "$LOG" | sed -E 's/^ +//' || true)"
[[ -n "$PROFILE" ]] && info "$PROFILE"

APP="$REPO/build/DerivedData-device/Build/Products/$CONFIG-iphoneos/Marginal.app"
[[ -d "$APP" ]] || { echo "device.sh: $APP not found" >&2; exit 1; }
if [[ "${MARGINAL_NO_INSTALL:-}" == "1" ]]; then
  step "Skipping install (MARGINAL_NO_INSTALL=1)"
  info "Built app: $APP"
  exit 0
fi

step "Installing on the iPad"
if ! xcrun devicectl device install app --device "$DEVICE" "$APP" >"$REPO/build/device-install.log" 2>&1; then
  tail -n 12 "$REPO/build/device-install.log" >&2
  echo "device.sh: install failed. Is the iPad connected, unlocked and trusted? (log: build/device-install.log)" >&2
  exit 1
fi
info "Installed $BUNDLE_ID"

step "Launching"
if ! xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" >"$REPO/build/device-launch.log" 2>&1; then
  if grep -qi "locked" "$REPO/build/device-launch.log"; then
    info "The app is installed, but the iPad is locked. Unlock it and open Marginal from the Home Screen."
  else
    info "The app is installed, but it could not be launched from here:"
    grep -E "NSLocalizedFailureReason|ERROR" "$REPO/build/device-launch.log" | head -n 2 | sed 's/^ */    /'
    info "With a Personal Team, trust the developer profile once in Settings > General > VPN & Device Management."
  fi
  exit 2
fi
info "Marginal is running on the iPad"
printf '\nDone in %s.\n' "$(elapsed)"
