#!/usr/bin/env bash
# Writes the git branch, commit, uncommitted-changes flag and build time into the built app's
# Info.plist under `TactileTextsBuild`, which Settings ▸ About shows (`BuildInfo` in the app).
#
# Run by the TactileTexts target's "Stamp Build Info" phase (project.yml) on every build, after the
# Info.plist is processed and before signing. Only the built copy is changed; the committed
# App/Info.plist never carries these values. Never fails the build: without git, or outside a
# repository, the git values are written empty and the app shows "Unknown".
#
# Env (set by Xcode): SRCROOT, TARGET_BUILD_DIR, INFOPLIST_PATH.
set -uo pipefail

PLIST="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
if [[ ! -f "$PLIST" ]]; then
  echo "warning: stamp-build-info: no Info.plist at $PLIST; build info not stamped"
  exit 0
fi

BRANCH=""
COMMIT=""
DIRTY=false
if command -v git >/dev/null 2>&1 && git -C "$SRCROOT" rev-parse --git-dir >/dev/null 2>&1; then
  # Empty on a detached HEAD; the app then shows the commit instead.
  BRANCH="$(git -C "$SRCROOT" branch --show-current 2>/dev/null || true)"
  COMMIT="$(git -C "$SRCROOT" rev-parse --short HEAD 2>/dev/null || true)"
  # Untracked files count too: a new source file is part of the build.
  if [[ -n "$(git -C "$SRCROOT" status --porcelain 2>/dev/null | head -n 1)" ]]; then
    DIRTY=true
  fi
fi
TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# JSON-escape the branch (names may hold any character git allows, including quotes and backslashes).
json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

JSON="{\"Branch\":$(json_string "$BRANCH"),\"Commit\":$(json_string "$COMMIT"),\"Dirty\":$DIRTY,\"Time\":$(json_string "$TIME")}"
if ! plutil -replace TactileTextsBuild -json "$JSON" "$PLIST"; then
  echo "warning: stamp-build-info: could not write TactileTextsBuild to $PLIST"
fi
exit 0
