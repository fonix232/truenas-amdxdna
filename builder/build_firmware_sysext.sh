#!/usr/bin/env bash
set -euo pipefail

# Build the amdxdna-firmware sysext .raw image from the amdnpu firmware tree.
# Must be called from the workspace root after 1_fetch_firmware.sh has run.
#
# Usage:
#   build_firmware_sysext.sh <fw_commit_short>
#
#   fw_commit_short - first 12 hex chars of the linux-firmware HEAD commit SHA,
#                     embedded in the output filename for cache-key traceability
#
# Input:  amdnpu-firmware/ in $PWD (produced by 1_fetch_firmware.sh)
# Output: amdxdna-firmware-<fw_commit_short>.raw in $PWD

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $# -ge 1 ]] || { echo "usage: build_firmware_sysext.sh <fw_commit_short>" >&2; exit 1; }
fw_commit_short="$1"

[[ -d amdnpu-firmware ]] || {
  echo "ERROR: amdnpu-firmware/ not found — run 1_fetch_firmware.sh first" >&2
  exit 1
}

fw_tree="work/sysext-firmware"
mkdir -p "${fw_tree}/usr/lib/firmware/amdnpu"
rsync -a amdnpu-firmware/ "${fw_tree}/usr/lib/firmware/amdnpu/"

bash "${SCRIPT_DIR}/make_sysext.sh" \
  "${fw_tree}" \
  "amdxdna-firmware-${fw_commit_short}.raw" \
  "amdxdna-firmware"
