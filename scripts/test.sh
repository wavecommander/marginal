#!/usr/bin/env bash
# Runs package tests, then the app's unit and UI tests on the simulator.
# Usage: scripts/test.sh [--packages-only] [--skip-packages] [xcodebuild args, e.g. -only-testing:MarginalUITests/LibraryUITests]
# Env: MARGINAL_SIM (device name or UDID, default iPad Pro 11-inch).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sim.sh"
cd "$REPO"

packages=1; app=1; extra=()
for a in "$@"; do
  case "$a" in
    --packages-only) app=0 ;;
    --skip-packages) packages=0 ;;
    *) extra+=("$a") ;;
  esac
done

"$REPO/scripts/fixtures.sh"
mkdir -p build
failed=0

if [[ $packages -eq 1 ]]; then
  for p in ReaderCore ReaderStore; do
    echo "== swift test: $p"
    if ! (cd "$REPO/Packages/$p" && swift test 2>&1 | tee "$REPO/build/swift-test-$p.log" | tail -n 15; exit "${PIPESTATUS[0]}"); then
      echo "FAILED: swift test $p" >&2
      grep -E "✘|error:|failed" "$REPO/build/swift-test-$p.log" | head -n 30 >&2 || true
      failed=1
    fi
  done
fi

if [[ $app -eq 1 ]]; then
  echo "== xcodebuild test"
  xcodegen generate --quiet
  sim_boot
  LOG="$REPO/build/xcodebuild-test.log"
  rm -rf "$REPO/build/Marginal.xcresult"
  set +e
  xcodebuild test \
    -project Marginal.xcodeproj -scheme Marginal \
    -destination "id=$SIM_UDID" \
    -derivedDataPath "$REPO/build/DerivedData" \
    -resultBundlePath "$REPO/build/Marginal.xcresult" \
    ${extra[@]+"${extra[@]}"} \
    >"$LOG" 2>&1
  status=$?
  set -e
  grep -E "warning:|error:|Test Case .* (passed|failed)|Executed .* tests|✔ Test|✘ Test|Test run with|\*\* TEST" "$LOG" | tail -n 60
  if [[ $status -ne 0 ]]; then
    echo "FAILED xcodebuild test (log: $LOG). Failing tests:" >&2
    grep -E "Test Case .* failed|✘|error:" "$LOG" | sort -u | head -n 40 >&2 || true
    failed=1
  fi
fi

exit $failed
