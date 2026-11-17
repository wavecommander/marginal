#!/usr/bin/env bash
# Runs package tests, then the app's unit and UI tests on the simulator.
# Usage: scripts/test.sh [--packages-only] [--skip-packages] [--screenshots] [--serial]
#                        [xcodebuild args, e.g. -only-testing:TactileTextsUITests/LibraryUITests]
# The full gate (no -only-testing) runs in two passes after one build:
#   1. the UI tests except the measuring ones, on TACTILE_WORKERS simulator clones in parallel;
#   2. the unit tests and the measuring UI tests (frame gaps, timings) on one simulator, so load
#      from the other clones cannot skew them (the unit tests fail under that load).
# Screenshot tests only write PNGs to build/shots, so the gate skips them; --screenshots runs
# just those. --serial runs the first pass on one simulator. With -only-testing the arguments
# go to a single serial xcodebuild run, as before.
# Env: TACTILE_SIM (device name or UDID, default iPad Pro 11-inch), TACTILE_WORKERS (default 3).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sim.sh"
cd "$REPO"

packages=1; app=1; screenshots=0; serial=0; extra=()

# Tests that assert on frame gaps or timings: run alone in the gate's second pass.
MEASURING=(
  TactileTextsUITests/PerformanceUITests
  TactileTextsUITests/PDFAccessibilityUITests
  TactileTextsUITests/SidebarUITests/testFastThumbnailScrollingStaysBounded
  TactileTextsUITests/SidebarUITests/testAutoScrollThroughTheWholeBook
  TactileTextsUITests/SearchUITests/testCommonTermSearchStaysResponsiveAndCancelStopsIt
)
# Tests that only save screenshots (no checks of their own).
SCREENSHOTS=(
  TactileTextsUITests/MockupScreenshotUITests
  TactileTextsUITests/SidebarScreenshotUITests
  TactileTextsUITests/ReaderScreenshotUITests
  TactileTextsUITests/HighlightsUITests/testScreenshotFourColours
  TactileTextsUITests/NotebookHandwritingUITests/testScreenshots
  TactileTextsUITests/NotebookHandwritingUITests/testScreenshotNarrow
  TactileTextsUITests/NotePageUITests/testScreenshotMarkupPageAndNoteTogether
  TactileTextsUITests/NotebookUITests/testScreenshotLandscape
  TactileTextsUITests/NotebookUITests/testScreenshotNarrow
  TactileTextsUITests/NotesPanelUITests/testScreenshots
  TactileTextsUITests/PageInkUITests/testScreenshots
  TactileTextsUITests/SearchUITests/testScreenshots
  TactileTextsUITests/SearchUITests/testScreenshotLargeText
)
for a in "$@"; do
  case "$a" in
    --packages-only) app=0 ;;
    --skip-packages) packages=0 ;;
    --screenshots) screenshots=1 ;;
    --serial) serial=1 ;;
    *) extra+=("$a") ;;
  esac
done

"$REPO/scripts/fixtures.sh"
mkdir -p build
failed=0

if [[ $packages -eq 1 ]]; then
  for p in ReaderCore ReaderStore ReaderBackup S3Kit ReaderSync GoogleSignInKit; do
    echo "== swift test: $p"
    if ! (cd "$REPO/Packages/$p" && swift test 2>&1 | tee "$REPO/build/swift-test-$p.log" | tail -n 15; exit "${PIPESTATUS[0]}"); then
      echo "FAILED: swift test $p" >&2
      grep -E "✘|error:|failed" "$REPO/build/swift-test-$p.log" | head -n 30 >&2 || true
      failed=1
    fi
  done
fi

# run_xcodebuild <name> <action> [args]: logs to build/<name>.log, prints the summary lines.
run_xcodebuild() {
  local name="$1" action="$2"; shift 2
  local log="$REPO/build/$name.log" status
  [[ "$name" == TactileTexts ]] && log="$REPO/build/xcodebuild-test.log"
  local result=()
  if [[ "$action" != build-for-testing ]]; then
    rm -rf "$REPO/build/$name.xcresult"
    result=(-resultBundlePath "$REPO/build/$name.xcresult")
  fi
  set +e
  xcodebuild "$action" \
    -project TactileTexts.xcodeproj -scheme TactileTexts \
    -destination "id=$SIM_UDID" \
    -derivedDataPath "$REPO/build/DerivedData" \
    ${result[@]+"${result[@]}"} "$@" >"$log" 2>&1
  status=$?
  set -e
  grep -iE "warning:|error:|Test Case .* (passed|failed)|Executed .* tests|✔ Test|✘ Test|Test run with|\*\* TEST" "$log" | tail -n 60
  if [[ $status -ne 0 ]]; then
    echo "FAILED xcodebuild $action (log: $log). Failing tests:" >&2
    grep -iE "Test Case .* failed|✘|error:" "$log" | sort -u | head -n 40 >&2 || true
    failed=1
  fi
  return $status
}

if [[ $app -eq 1 ]]; then
  xcodegen generate --quiet
  sim_boot
  targeted=0
  for a in ${extra[@]+"${extra[@]}"}; do [[ "$a" == -only-testing:* ]] && targeted=1; done
  if [[ $screenshots -eq 1 ]]; then
    echo "== xcodebuild test (screenshots)"
    run_xcodebuild TactileTexts test "${SCREENSHOTS[@]/#/-only-testing:}" ${extra[@]+"${extra[@]}"} || true
  elif [[ $targeted -eq 1 ]]; then
    echo "== xcodebuild test"
    run_xcodebuild TactileTexts test ${extra[@]+"${extra[@]}"} || true
  else
    echo "== xcodebuild build-for-testing"
    if run_xcodebuild build build-for-testing ${extra[@]+"${extra[@]}"}; then
      parallel=(-parallel-testing-enabled YES -parallel-testing-worker-count "${TACTILE_WORKERS:-3}")
      [[ $serial -eq 1 ]] && parallel=(-parallel-testing-enabled NO)
      echo "== xcodebuild test, pass 1 (${parallel[*]})"
      run_xcodebuild TactileTexts test-without-building "${parallel[@]}" -only-testing:TactileTextsUITests \
        "${MEASURING[@]/#/-skip-testing:}" "${SCREENSHOTS[@]/#/-skip-testing:}" ${extra[@]+"${extra[@]}"} || true
      echo "== xcodebuild test, pass 2 (unit tests and measuring tests, one simulator)"
      run_xcodebuild TactileTexts-measuring test-without-building -parallel-testing-enabled NO \
        -only-testing:TactileTextsTests "${MEASURING[@]/#/-only-testing:}" ${extra[@]+"${extra[@]}"} || true
    fi
  fi
fi

exit $failed
