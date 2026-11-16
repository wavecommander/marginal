#!/usr/bin/env bash
# Source this file:  source scripts/sim.sh
# Exports REPO, SIM_11_NAME, SIM_13_NAME, SIM_UDID, BUNDLE_ID.
# Set TACTILE_SIM (device name or UDID) to use a specific simulator; default is the 11-inch.
# Nothing here boots a device on its own; call `sim_boot`.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO
export SIM_11_NAME="iPad Pro 11-inch (M5)"
export SIM_13_NAME="iPad Pro 13-inch (M5)"
export BUNDLE_ID="software.tactile.texts"

_sim_resolve() {
  local want="${TACTILE_SIM:-$SIM_11_NAME}"
  # A UDID is used as is; a name is looked up among available devices.
  if [[ "$want" =~ ^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$ ]]; then
    printf '%s\n' "$want"
    return
  fi
  xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
name = sys.argv[1]
devs = [d for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"] == name]
devs.sort(key=lambda d: d["state"] != "Booted")
print(devs[0]["udid"] if devs else "")
' "$want"
}

SIM_UDID="$(_sim_resolve)"
if [[ -z "$SIM_UDID" ]]; then
  echo "sim.sh: no simulator matches '${TACTILE_SIM:-$SIM_11_NAME}'" >&2
  return 1 2>/dev/null || exit 1
fi
export SIM_UDID

# Boots the device if needed and waits until it is fully booted.
sim_boot() {
  local state
  state="$(xcrun simctl list devices -j | /usr/bin/python3 -c '
import json, sys
u = sys.argv[1]
for ds in json.load(sys.stdin)["devices"].values():
    for d in ds:
        if d["udid"] == u: print(d["state"])
' "$SIM_UDID")"
  if [[ "$state" != "Booted" ]]; then
    xcrun simctl boot "$SIM_UDID"
  fi
  xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null
}
