#!/usr/bin/env bash
set -euo pipefail

# Assembles the staging tree from 1_fetch_packages.sh into a single
# systemd-sysext image (rocm-tools.raw) and a self-extracting .run installer.
#
# Required env vars:
#   BUILD_RUN_ID  - GitHub Actions run ID (annotates metadata.env)
#   BUILD_SHA     - git SHA of the triggering commit (annotates metadata.env)
#
# Inputs (relative to $PWD):
#   staging/                    - tree produced by 1_fetch_packages.sh
#   builder/installer-template.sh
#
# Outputs:
#   out/rocm-tools-<rocm_ver>.run
#   out/version.txt

: "${BUILD_RUN_ID:?BUILD_RUN_ID is required}"
: "${BUILD_SHA:?BUILD_SHA is required}"

[[ -f staging/metadata.env ]] \
  || { echo "ERROR: staging/metadata.env not found — run 1_fetch_packages.sh first" >&2; exit 1; }

# shellcheck source=/dev/null
source staging/metadata.env

# Clean version for filenames: strip build/epoch suffix (e.g. 6.2.4.60204-1 → 6.2.4)
rocm_ver_clean="${ROCM_VERSION%%[.-]*}"
# If ROCM_VERSION is already short (e.g. "6.2"), keep as-is; else trim to major.minor.patch
if [[ "${ROCM_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  rocm_ver_clean=$(echo "${ROCM_VERSION}" | grep -oP '^[0-9]+\.[0-9]+\.[0-9]+')
fi

echo "Packaging rocm-tools ${rocm_ver_clean} (ROCm ${ROCM_VERSION}, XRT ${XRT_VERSION})"

mkdir -p out work/sysext

SYSEXT_NAME="rocm-tools"

# ── Assemble sysext tree ───────────────────────────────────────────────────

sysext_tree="work/sysext/${SYSEXT_NAME}"
mkdir -p "${sysext_tree}/usr/lib/extension-release.d"

# Copy staged trees at their native paths.
# staging/usr/  → sysext /usr/   (xrt-smi binary + libs, wrapper scripts)
# staging/opt/  → sysext /opt/   (rocm-smi, amd-smi and all ROCm libs)
cp -a staging/usr/. "${sysext_tree}/usr/"
[[ -d staging/opt ]] && cp -a staging/opt/. "${sysext_tree}/opt/"

# ── extension-release file ─────────────────────────────────────────────────
# ID=_any makes the sysext compatible with any OS.
# SYSEXT_SCOPE=system covers both /usr and /opt hierarchies.

printf 'ID=_any\nSYSEXT_SCOPE=system\nARCHITECTURE=x86-64\n' \
  > "${sysext_tree}/usr/lib/extension-release.d/extension-release.${SYSEXT_NAME}"

# ── Build squashfs .raw ────────────────────────────────────────────────────

raw_file="work/${SYSEXT_NAME}.raw"
mksquashfs "${sysext_tree}" "${raw_file}" -comp xz -noappend -quiet
echo "Sysext image: $(du -sh "${raw_file}" | cut -f1)  →  ${raw_file}"

# ── Append build metadata to metadata.env ─────────────────────────────────

{
  printf 'BUILD_RUN_ID=%s\n'  "${BUILD_RUN_ID}"
  printf 'BUILD_SHA=%s\n'     "${BUILD_SHA}"
  printf 'BUILD_TIME_UTC=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> staging/metadata.env

# ── Self-extracting .run installer ────────────────────────────────────────

mkdir -p work/bundle
cp "${raw_file}"          work/bundle/
cp staging/metadata.env   work/bundle/

tar -C work/bundle -czf work/bundle.tar.gz .

installer="builder/installer-template.sh"
run_file="out/rocm-tools-${rocm_ver_clean}.run"
payload_line="$(($(wc -l < "${installer}") + 1))"
sed -e "s|__PAYLOAD_LINE__|${payload_line}|g" \
    -e "s|__SYSEXT_NAME__|${SYSEXT_NAME}|g" \
    "${installer}" > "${run_file}"
cat work/bundle.tar.gz >> "${run_file}"
chmod +x "${run_file}"

echo "${rocm_ver_clean}" > out/version.txt

echo "--- output ---"
ls -lh out/
