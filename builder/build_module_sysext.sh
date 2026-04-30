#!/usr/bin/env bash
set -euo pipefail

# Assemble a per-kernel module sysext .raw image from a compiled amdxdna.ko.
#
# The output filename embeds kernel version, driver version, and XRT version
# so each unique combination gets a distinct cached artifact.
#
# Required env vars:
#   KERNEL_VERSION   - full version string (e.g. 6.18.13-production+truenas)
#   AMDXDNA_VERSION  - driver version extracted by build_ko.sh (e.g. 0.10)
#   XRT_VERSION      - XRT version extracted by get_xrt_version.sh (e.g. 2.16.0)
#
# Args:
#   $1 - path to the compiled amdxdna.ko
#
# Outputs in $PWD:
#   amdxdna-<base_krel>-<xdna_ver>-xrt<xrt_ver>.raw
#   module_version.txt  — xdna driver version (for use by assemble_amdxdna_run.sh)
#   xrt_version.txt     — XRT version         (for use by assemble_amdxdna_run.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${KERNEL_VERSION:?KERNEL_VERSION is required}"
: "${AMDXDNA_VERSION:?AMDXDNA_VERSION is required}"
: "${XRT_VERSION:?XRT_VERSION is required}"

[[ $# -ge 1 ]] || { echo "usage: build_module_sysext.sh <path/to/amdxdna.ko>" >&2; exit 1; }
ko_path="$1"
[[ -f "${ko_path}" ]] || { echo "ERROR: ko not found: ${ko_path}" >&2; exit 1; }

# base_krel strips the +truenas local-version suffix, e.g. 6.18.13-production
base_krel="${KERNEL_VERSION%%+*}"
module_name="amdxdna-${base_krel}-${AMDXDNA_VERSION}-xrt${XRT_VERSION}"
kver="${KERNEL_VERSION}"

mod_tree="work/sysext-module-${base_krel}"
mkdir -p "${mod_tree}/usr/lib/modules/${kver}/kernel/drivers/accel/amdxdna"
install -m 0644 "${ko_path}" \
  "${mod_tree}/usr/lib/modules/${kver}/kernel/drivers/accel/amdxdna/amdxdna.ko"

# The extension-release name uses the unversioned base identifier so the
# installer-template.sh can match the right .raw by kernel version alone.
bash "${SCRIPT_DIR}/make_sysext.sh" \
  "${mod_tree}" \
  "${module_name}.raw" \
  "amdxdna-${base_krel}"

# Sidecar version files read by assemble_amdxdna_run.sh.
echo "${AMDXDNA_VERSION}" > module_version.txt
echo "${XRT_VERSION}"     > xrt_version.txt
