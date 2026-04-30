#!/usr/bin/env bash
set -euo pipefail

# Assemble the amdnpu-firmware .run installer from the cached firmware .raw.
# Must be called from the workspace root after the firmware .raw has been
# restored from cache.
#
# Required env vars:
#   BUILD_RUN_ID     - github.run_id
#   BUILD_SHA        - github.sha
#   FW_COMMIT_SHORT  - short SHA of linux-firmware HEAD
#
# Inputs in $PWD:
#   amdxdna-firmware-<fw_commit_short>.raw
#
# Output:
#   out/amdnpu-firmware-<fw_commit_short>.run

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${BUILD_RUN_ID:?BUILD_RUN_ID is required}"
: "${BUILD_SHA:?BUILD_SHA is required}"
: "${FW_COMMIT_SHORT:?FW_COMMIT_SHORT is required}"

mkdir -p out work/fw-bundle

# The cached .raw has the commit hash in its name; copy to canonical name.
fw_raw="amdxdna-firmware-${FW_COMMIT_SHORT}.raw"
[[ -f "${fw_raw}" ]] || { echo "ERROR: ${fw_raw} not found in $PWD" >&2; exit 1; }
cp "${fw_raw}" work/fw-bundle/amdxdna-firmware.raw
echo "Bundled: ${fw_raw} → amdxdna-firmware.raw"

# Write build metadata.
{
  printf 'FW_COMMIT_SHORT=%s\n' "${FW_COMMIT_SHORT}"
  printf 'BUILD_RUN_ID=%s\n'    "${BUILD_RUN_ID}"
  printf 'BUILD_SHA=%s\n'       "${BUILD_SHA}"
  printf 'BUILD_TIME_UTC=%s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > work/fw-bundle/metadata.env

bash "${SCRIPT_DIR}/make_run.sh" \
  work/fw-bundle \
  "${SCRIPT_DIR}/firmware-installer-template.sh" \
  "out/amdnpu-firmware-${FW_COMMIT_SHORT}.run"
