#!/usr/bin/env bash
set -euo pipefail

# Assembles all module sysext images (.raw), the shared firmware sysext,
# and a single self-extracting .run bundle containing all variants.
#
# Required env vars:
#   MATRIX        - JSON array from prepare-matrix (kernels.json expanded)
#   BUILD_RUN_ID  - GitHub Actions run ID (annotates metadata.env)
#   BUILD_SHA     - git SHA of the triggering commit (annotates metadata.env)
#   AMDXDNA_VERSION - xdna driver version (MAJOR.MINOR, e.g. 0.10); passed from
#                     the build job output. Falls back to reading module_version.txt
#                     from artifact directories when running locally.
#
# Inputs (relative to $PWD):
#   amdnpu-firmware/              - restored from cache by build-firmware job
#   amdxdna-ko-<slug>-<mode>/     - restored from cache by package job
#   builder/installer-template.sh - self-extracting installer header
#
# Outputs:
#   out/amdxdna-override-<xdna_ver>.run  - single .run for all kernel/mode variants
#   out/version.txt                      - xdna driver version string (e.g. 0.10)

: "${MATRIX:?MATRIX is required}"
: "${BUILD_RUN_ID:?BUILD_RUN_ID is required}"
: "${BUILD_SHA:?BUILD_SHA is required}"

mkdir -p out work

# Use AMDXDNA_VERSION if provided by CI (set as $GITHUB_ENV / job output by the
# build job). Fall back to scanning module_version.txt in artifact dirs so that
# local test runs (without the env var) still work.
xdna_ver="${AMDXDNA_VERSION:-}"
if [[ -z "${xdna_ver}" ]]; then
  for _d in amdxdna-ko-*/; do
    if [[ -f "${_d}module_version.txt" ]]; then
      xdna_ver=$(cat "${_d}module_version.txt")
      break
    fi
  done
fi
xdna_ver="${xdna_ver:-0.0.0}"
echo "${xdna_ver}" > out/version.txt
echo "xdna driver version: ${xdna_ver}"

firmware_name="amdxdna-firmware"
fw_ver="$(cat amdnpu-firmware/.pkg-version 2>/dev/null || echo unknown)"

# --- Firmware sysext: shared across all kernel variants ---
fw_tree="work/sysext-firmware"
mkdir -p "${fw_tree}/usr/lib/firmware/amdnpu" \
         "${fw_tree}/usr/lib/extension-release.d"
rsync -a amdnpu-firmware/ "${fw_tree}/usr/lib/firmware/amdnpu/"
printf 'ID=_any\nSYSEXT_SCOPE=system\nARCHITECTURE=x86-64\n' \
  > "${fw_tree}/usr/lib/extension-release.d/extension-release.${firmware_name}"
mksquashfs "${fw_tree}" "work/${firmware_name}.raw" -comp xz -noappend -quiet

# --- Module sysext: one per kernel×mode ---
bundle_dir="work/bundle"
mkdir -p "${bundle_dir}"
cp "work/${firmware_name}.raw" "${bundle_dir}/"

echo "${MATRIX}" | jq -r '.[] | [(.truenas_tag | gsub("/"; "-")), .base_version] | @tsv' | \
while IFS=$'\t' read -r slug base_version; do
  for mode in production debug; do
    kver="${base_version}-${mode}+truenas"
    base_krel="${kver%%+*}"
    module_name="amdxdna-${base_krel}"
    ko_dir="amdxdna-ko-${slug}-${mode}"

    [[ -f "${ko_dir}/amdxdna.ko" ]] \
      || { echo "ERROR: ${ko_dir}/amdxdna.ko not found" >&2; exit 1; }

    mod_tree="work/sysext-module-${base_krel}"
    mkdir -p \
      "${mod_tree}/usr/lib/modules/${kver}/kernel/drivers/accel/amdxdna" \
      "${mod_tree}/usr/lib/extension-release.d"
    install -m 0644 "${ko_dir}/amdxdna.ko" \
      "${mod_tree}/usr/lib/modules/${kver}/kernel/drivers/accel/amdxdna/amdxdna.ko"
    printf 'ID=_any\nSYSEXT_SCOPE=system\nARCHITECTURE=x86-64\n' \
      > "${mod_tree}/usr/lib/extension-release.d/extension-release.${module_name}"
    mksquashfs "${mod_tree}" "${bundle_dir}/${module_name}.raw" -comp xz -noappend -quiet

pkg_ver="${AMDXDNA_VERSION:-$(cat "${ko_dir}/module_version.txt" 2>/dev/null || echo '0.0.0')}"

    {
      printf 'KERNEL_VERSION=%s\n'        "${kver}"
      printf 'XDNA_VERSION=%s\n'          "${pkg_ver}"
      printf 'FIRMWARE_PKG_VERSION=%s\n'  "${fw_ver}"
      printf 'BUILD_RUN_ID=%s\n'          "${BUILD_RUN_ID}"
      printf 'BUILD_SHA=%s\n'             "${BUILD_SHA}"
      printf 'BUILD_TIME_UTC=%s\n'        "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >> "${bundle_dir}/metadata.env"
  done
done

# --- Self-extracting .run: one file for all variants ---
tar -C "${bundle_dir}" -czf work/bundle.tar.gz .

installer="builder/installer-template.sh"
run_file="out/amdxdna-override-${xdna_ver}.run"
payload_line="$(($(wc -l < "${installer}") + 1))"
sed -e "s|__PAYLOAD_LINE__|${payload_line}|g" "${installer}" > "${run_file}"
cat work/bundle.tar.gz >> "${run_file}"
chmod +x "${run_file}"

echo "--- output ---"
ls -lh out/
