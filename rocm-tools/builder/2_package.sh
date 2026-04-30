#!/usr/bin/env bash
set -euo pipefail

# Assembles the staging tree from 1_fetch_packages.sh into a rocm-tools
# systemd-sysext .raw image.  The .run installer is assembled separately by
# assemble_run.sh (in the package job, after cache restore).
#
# Must be called from the rocm-tools/ directory (working-directory: rocm-tools).
#
# Inputs (relative to $PWD):
#   staging/   - staging tree produced by 1_fetch_packages.sh
#
# Outputs:
#   out/rocm-tools-<rocm_ver>.raw

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_BUILDER="${SCRIPT_DIR}/../../builder"

[[ -f staging/metadata.env ]] \
  || { echo "ERROR: staging/metadata.env not found — run 1_fetch_packages.sh first" >&2; exit 1; }

# shellcheck source=/dev/null
source staging/metadata.env

# Clean version for filenames: trim to major.minor.patch if fully qualified,
# otherwise strip any build/epoch suffix.
if [[ "${ROCM_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  rocm_ver_clean=$(echo "${ROCM_VERSION}" | grep -oP '^[0-9]+\.[0-9]+\.[0-9]+')
else
  rocm_ver_clean="${ROCM_VERSION%%[.-]*}"
fi

echo "Packaging rocm-tools ${rocm_ver_clean} (ROCm ${ROCM_VERSION}, XRT ${XRT_VERSION})"

SYSEXT_NAME="rocm-tools"
sysext_tree="work/sysext/${SYSEXT_NAME}"
mkdir -p "${sysext_tree}"

# Copy staged trees at their native paths.
# staging/usr/  → sysext /usr/   (xrt-smi binary + libs, wrapper scripts)
# staging/opt/  → sysext /opt/   (rocm-smi, amd-smi and all ROCm libs)
cp -a staging/usr/. "${sysext_tree}/usr/"
[[ -d staging/opt ]] && cp -a staging/opt/. "${sysext_tree}/opt/"

mkdir -p out
bash "${REPO_BUILDER}/make_sysext.sh" \
  "${sysext_tree}" \
  "out/rocm-tools-${rocm_ver_clean}.raw" \
  "${SYSEXT_NAME}"
