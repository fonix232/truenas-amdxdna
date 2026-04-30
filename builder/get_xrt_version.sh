#!/usr/bin/env bash
set -euo pipefail

# Extract the XRT version from the submodule pointer committed in a cloned
# xdna-driver repository, by fetching CMakeLists.txt from the Xilinx/XRT repo
# at the pinned SHA — no submodule init/update required.
#
# Usage:
#   get_xrt_version.sh <xdna_driver_dir>
#
#   xdna_driver_dir - path to a cloned amd/xdna-driver repo
#
# Outputs:
#   - Prints "XRT version: X.Y.Z" to stderr for logging
#   - Writes "xrt_version=X.Y.Z" to $GITHUB_OUTPUT (if set)
#   - Writes "XRT_VERSION=X.Y.Z" to $GITHUB_ENV    (if set)

[[ $# -ge 1 ]] || { echo "usage: get_xrt_version.sh <xdna_driver_dir>" >&2; exit 1; }
driver_dir="$1"

[[ -d "${driver_dir}" ]] || { echo "ERROR: '${driver_dir}' is not a directory" >&2; exit 1; }

# Resolve the pinned XRT submodule SHA via git ls-tree (no checkout needed).
# Try the two known submodule paths used across xdna-driver versions.
xrt_sha=$(git -C "${driver_dir}" ls-tree HEAD -- xrt 2>/dev/null \
  | awk '{print $3}' | head -1)
if [[ -z "${xrt_sha}" ]]; then
  xrt_sha=$(git -C "${driver_dir}" ls-tree HEAD -- src/xrt 2>/dev/null \
    | awk '{print $3}' | head -1)
fi

if [[ -n "${xrt_sha}" ]]; then
  xrt_cmake=$(curl -fsSL \
    "https://raw.githubusercontent.com/Xilinx/XRT/${xrt_sha}/CMakeLists.txt" \
    2>/dev/null | head -30)

  # Primary: grep for quoted value  →  set(XRT_VERSION_MAJOR "2")
  xrt_major=$(echo "${xrt_cmake}" | grep 'XRT_VERSION_MAJOR' \
    | grep -oP '"[0-9]+"' | tr -d '"' | head -1 || true)
  xrt_minor=$(echo "${xrt_cmake}" | grep 'XRT_VERSION_MINOR' \
    | grep -oP '"[0-9]+"' | tr -d '"' | head -1 || true)
  xrt_patch=$(echo "${xrt_cmake}" | grep 'XRT_VERSION_PATCH' \
    | grep -oP '"[0-9]+"' | tr -d '"' | head -1 || true)

  # Fallback: awk extracts the first small integer on the matching line
  if [[ -z "${xrt_major}" ]]; then
    xrt_major=$(echo "${xrt_cmake}" | awk '/XRT_VERSION_MAJOR/ \
      {for(i=1;i<=NF;i++) if($i~/^[0-9]+$/ && $i+0<10000){print $i; exit}}' | head -1)
    xrt_minor=$(echo "${xrt_cmake}" | awk '/XRT_VERSION_MINOR/ \
      {for(i=1;i<=NF;i++) if($i~/^[0-9]+$/ && $i+0<10000){print $i; exit}}' | head -1)
    xrt_patch=$(echo "${xrt_cmake}" | awk '/XRT_VERSION_PATCH/ \
      {for(i=1;i<=NF;i++) if($i~/^[0-9]+$/ && $i+0<10000){print $i; exit}}' | head -1)
  fi

  xrt_version="${xrt_major:-0}.${xrt_minor:-0}.${xrt_patch:-0}"
else
  echo "WARNING: XRT submodule SHA not found in ${driver_dir}" >&2
  xrt_version="unknown"
fi

echo "XRT version: ${xrt_version}"

[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "xrt_version=${xrt_version}" >> "${GITHUB_OUTPUT}"
[[ -n "${GITHUB_ENV:-}" ]]    && echo "XRT_VERSION=${xrt_version}"  >> "${GITHUB_ENV}"
