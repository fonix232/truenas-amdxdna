#!/usr/bin/env bash
set -euo pipefail

# Assemble the amdxdna-override .run installer from cached sysext .raw images.
# Must be called from the workspace root after all module and firmware .raw files
# have been restored from cache.
#
# Required env vars:
#   BUILD_RUN_ID     - github.run_id
#   BUILD_SHA        - github.sha
#   AMDXDNA_VERSION  - driver version (optional; falls back to module_version.txt)
#
# Inputs in $PWD:
#   amdxdna-firmware-*.raw         - firmware sysext (built by build_firmware_sysext.sh)
#   amdxdna-<krel>-*-xrt*.raw      - per-kernel module sysexts (built by build_module_sysext.sh)
#   module_version.txt             - fallback source for AMDXDNA_VERSION
#   xrt_version.txt                - XRT version used in module filenames
#
# Outputs:
#   out/amdxdna-override-<xdna_ver>.run
#   out/version.txt

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${BUILD_RUN_ID:?BUILD_RUN_ID is required}"
: "${BUILD_SHA:?BUILD_SHA is required}"

mkdir -p out work/bundle

# Resolve driver version.
xdna_ver="${AMDXDNA_VERSION:-}"
if [[ -z "${xdna_ver}" ]] && [[ -f module_version.txt ]]; then
  xdna_ver=$(cat module_version.txt)
fi
xdna_ver="${xdna_ver:-0.0.0}"
echo "${xdna_ver}" > out/version.txt

# Resolve XRT version (needed to strip the version suffix from module filenames).
xrt_ver="${XRT_VERSION:-}"
if [[ -z "${xrt_ver}" ]] && [[ -f xrt_version.txt ]]; then
  xrt_ver=$(cat xrt_version.txt)
fi
xrt_ver="${xrt_ver:-unknown}"

# Copy firmware .raw into bundle under the canonical name the installer expects.
fw_raw=$(ls amdxdna-firmware-*.raw 2>/dev/null | head -1)
[[ -n "${fw_raw}" ]] || { echo "ERROR: firmware .raw not found in $PWD" >&2; exit 1; }
cp "${fw_raw}" work/bundle/amdxdna-firmware.raw
echo "Bundled firmware: ${fw_raw} → amdxdna-firmware.raw"

# Copy module .raws into bundle, stripping the version suffix so the
# installer-template.sh can find them by kernel version (amdxdna-<base_krel>.raw).
ver_suffix="-${xdna_ver}-xrt${xrt_ver}"
found_modules=0
for raw in amdxdna-*.raw; do
  [[ "${raw}" =~ ^amdxdna-firmware ]] && continue
  canonical="${raw/${ver_suffix}.raw/.raw}"
  cp "${raw}" "work/bundle/${canonical}"
  echo "Bundled module:   ${raw} → ${canonical}"
  found_modules=$((found_modules + 1))
done
[[ ${found_modules} -gt 0 ]] || { echo "ERROR: no module .raw files found in $PWD" >&2; exit 1; }

# Write build metadata.
{
  printf 'XDNA_VERSION=%s\n'   "${xdna_ver}"
  printf 'BUILD_RUN_ID=%s\n'   "${BUILD_RUN_ID}"
  printf 'BUILD_SHA=%s\n'      "${BUILD_SHA}"
  printf 'BUILD_TIME_UTC=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > work/bundle/metadata.env

bash "${SCRIPT_DIR}/make_run.sh" \
  work/bundle \
  "${SCRIPT_DIR}/installer-template.sh" \
  "out/amdxdna-override-${xdna_ver}.run"
