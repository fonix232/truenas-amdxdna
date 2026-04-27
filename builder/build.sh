#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:-}"
KERNEL_HEADERS_DIR="${KERNEL_HEADERS_DIR:-/inputs/kernel-headers}"
# If FIRMWARE_DIR is set and non-empty, skip the apt fetch and use it directly.
FIRMWARE_DIR="${FIRMWARE_DIR:-}"
AMDXDNA_REF="${AMDXDNA_REF:-main}"
BUILD_RUN_ID="${BUILD_RUN_ID:-}"
BUILD_SHA="${BUILD_SHA:-}"

# Configurable so the script can run on any Ubuntu 24.04 host (e.g. GitHub Actions runner)
WORK_ROOT="${WORK_ROOT:-/work}"
OUT_DIR="${OUT_DIR:-/output}"
INSTALLER_TEMPLATE="${INSTALLER_TEMPLATE:-/builder/installer-template.sh}"

readonly DKMS_REPO="https://github.com/amd/xdna-driver"
readonly KERNEL_SOURCE_REPO="https://github.com/truenas/linux"

SRC_DIR="${WORK_ROOT}/src"
PAYLOAD_DIR="${WORK_ROOT}/payload"

log() {
  printf '[builder] %s\n' "$*"
}

die() {
  printf '[builder] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "missing command: ${cmd}"
}

prepare() {
  rm -rf "${WORK_ROOT}"
  mkdir -p "${SRC_DIR}" "${PAYLOAD_DIR}/module" "${PAYLOAD_DIR}/firmware" "${OUT_DIR}"
}

fetch_linux_firmware() {
  local deb_dir="${SRC_DIR}/fw-deb"
  local extract_dir="${SRC_DIR}/fw-extract"
  local deb_file
  local fw_path

  log "downloading linux-firmware package via apt"
  mkdir -p "${deb_dir}" "${extract_dir}"

  # Download the .deb without installing it; run in deb_dir so the file lands there
  ( cd "${deb_dir}" && apt-get download linux-firmware )

  deb_file="$(find "${deb_dir}" -maxdepth 1 -name 'linux-firmware_*.deb' | head -n1)"
  [[ -n "${deb_file}" ]] || die "linux-firmware .deb not found after apt-get download"

  # Extract full filesystem layout; path may be ./lib/firmware or ./usr/lib/firmware
  dpkg-deb -x "${deb_file}" "${extract_dir}"

  fw_path="$(find "${extract_dir}" -type d -name amdnpu | head -n1)"
  [[ -n "${fw_path}" ]] || die "amdnpu directory not found in linux-firmware package"

  rsync -a --delete "${fw_path}/" "${PAYLOAD_DIR}/firmware/"

  # Record package version in place of a git commit hash
  dpkg-deb -f "${deb_file}" Version > "${PAYLOAD_DIR}/firmware.commit"
  log "linux-firmware package version: $(cat "${PAYLOAD_DIR}/firmware.commit")"
}

build_dkms_module() {
  local src="${SRC_DIR}/amdxdna-dkms"
  local drv_src="${src}/drivers/accel/amdxdna"
  local configure_script="${src}/drivers/accel/tools/configure_kernel.sh"
  local config_hdr="${drv_src}/config_kernel.h"

  log "cloning driver source: ${DKMS_REPO} (${AMDXDNA_REF})"
  git clone --depth 1 --branch "${AMDXDNA_REF}" "${DKMS_REPO}" "${src}" || \
    git clone --depth 1 "${DKMS_REPO}" "${src}"

  [[ -d "${KERNEL_HEADERS_DIR}" ]] || die "KERNEL_HEADERS_DIR not found: ${KERNEL_HEADERS_DIR}"
  [[ -d "${drv_src}" ]]            || die "driver source not found: ${drv_src}"
  [[ -f "${configure_script}" ]]   || die "configure_kernel.sh not found: ${configure_script}"

  # Generate config_kernel.h by feature-testing the target kernel headers.
  # The script uses KERNEL_SRC (headers tree), KERNEL_VER (for cache key),
  # and OUT (absolute path to write the header).
  log "generating config_kernel.h against ${KERNEL_HEADERS_DIR}"
  # KBUILD_MODPOST_WARN=1: the headers tree has no Module.symvers (we only ran
  # modules_prepare, not a full build). Without this, modpost exits non-zero
  # for any probe that references an exported symbol (e.g. drm_fdinfo_print_size),
  # causing configure_kernel.sh to falsely report the feature absent and emit a
  # compat macro that then conflicts with the kernel's own definition.
  KERNEL_SRC="${KERNEL_HEADERS_DIR}" \
    KERNEL_VER="${KERNEL_VERSION}" \
    KBUILD_MODPOST_WARN=1 \
    KCFLAGS="-Wno-unused-variable" \
    OUT="${config_hdr}" \
    bash "${configure_script}"
  [[ -f "${config_hdr}" ]] || die "config_kernel.h was not generated"

  # Build the out-of-tree module directly using the kernel build system.
  # OFT_CONFIG_AMDXDNA_PCI=y selects the PCIe driver objects (Kbuild flag).
  log "building amdxdna.ko against kernel ${KERNEL_VERSION}"
  # KBUILD_MODPOST_WARN=1: same reason as above — no Module.symvers in the
  # headers-only tree; treat undefined DRM symbol references as warnings.
  KBUILD_MODPOST_WARN=1 make -C "${KERNEL_HEADERS_DIR}" \
    M="${drv_src}" \
    CFLAGS_MODULE="-DAMDXDNA_DEVEL" \
    OFT_CONFIG_AMDXDNA_PCI=y \
    modules

  local ko="${drv_src}/amdxdna.ko"
  [[ -f "${ko}" ]] || die "could not locate built amdxdna.ko under ${drv_src}"

  install -m 0644 "${ko}" "${PAYLOAD_DIR}/module/amdxdna.ko"

  git -C "${src}" rev-parse HEAD > "${PAYLOAD_DIR}/dkms.commit"
  # Parse version from the Makefile XDNA_DRIVER_VERSION variable
  local pkg_ver
  pkg_ver="$(grep -m1 'XDNA_DRIVER_VERSION' "${drv_src}/Makefile" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo '0.0.0')"
  printf 'amdxdna\n'      > "${PAYLOAD_DIR}/dkms.package"
  printf '%s\n' "${pkg_ver}" > "${PAYLOAD_DIR}/dkms.version"
}

write_metadata() {
  {
    echo "KERNEL_VERSION=${KERNEL_VERSION}"
    echo "KERNEL_SOURCE_REPO=${KERNEL_SOURCE_REPO}"
    echo "FIRMWARE_PKG_VERSION=$(cat "${PAYLOAD_DIR}/firmware.commit")"
    echo "DKMS_REPO=${DKMS_REPO}"
    echo "DKMS_REF=${AMDXDNA_REF}"
    echo "DKMS_COMMIT=$(cat "${PAYLOAD_DIR}/dkms.commit")"
    echo "DKMS_VERSION=$(cat "${PAYLOAD_DIR}/dkms.version")"
    echo "BUILD_TIME_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -n "${BUILD_RUN_ID}" ]] && echo "BUILD_RUN_ID=${BUILD_RUN_ID}" || true
    [[ -n "${BUILD_SHA}" ]]    && echo "BUILD_SHA=${BUILD_SHA}"       || true
  } > "${PAYLOAD_DIR}/metadata.env"
}

assemble_sysext() {
  # Strip +truenas local suffix for human-friendly sysext image names.
  # The full KERNEL_VERSION is still used for the module path inside the image.
  # e.g. 6.18.13-production+truenas → amdxdna-6.18.13-production
  local base_krel="${KERNEL_VERSION%%+*}"
  local module_name="amdxdna-${base_krel}"
  local firmware_name="amdxdna-firmware"

  # --- Module sysext: kernel module only, kernel-version scoped ---
  local mod_tree="${WORK_ROOT}/sysext-module"
  mkdir -p \
    "${mod_tree}/usr/lib/modules/${KERNEL_VERSION}/kernel/drivers/accel/amdxdna" \
    "${mod_tree}/usr/lib/extension-release.d"

  install -m 0644 \
    "${PAYLOAD_DIR}/module/amdxdna.ko" \
    "${mod_tree}/usr/lib/modules/${KERNEL_VERSION}/kernel/drivers/accel/amdxdna/amdxdna.ko"

  # extension-release filename must match the image name (without .raw).
  # SYSEXT_SCOPE=system: this extension targets the running system (not portable containers).
  # ARCHITECTURE=x86-64: reject gracefully on wrong-arch hosts.
  printf 'ID=_any\nSYSEXT_SCOPE=system\nARCHITECTURE=x86-64\n' \
    > "${mod_tree}/usr/lib/extension-release.d/extension-release.${module_name}"

  local module_raw="${WORK_ROOT}/${module_name}.raw"
  mksquashfs "${mod_tree}" "${module_raw}" -comp xz -noappend -quiet

  # --- Firmware sysext: firmware files only, not kernel-versioned ---
  local fw_tree="${WORK_ROOT}/sysext-firmware"
  mkdir -p \
    "${fw_tree}/usr/lib/firmware/amdnpu" \
    "${fw_tree}/usr/lib/extension-release.d"

  rsync -a "${PAYLOAD_DIR}/firmware/" "${fw_tree}/usr/lib/firmware/amdnpu/"
  printf 'ID=_any\nSYSEXT_SCOPE=system\nARCHITECTURE=x86-64\n' \
    > "${fw_tree}/usr/lib/extension-release.d/extension-release.${firmware_name}"

  local firmware_raw="${WORK_ROOT}/${firmware_name}.raw"
  mksquashfs "${fw_tree}" "${firmware_raw}" -comp xz -noappend -quiet

  # Bundle both raws + metadata into the .run self-extractor
  local bundle_dir="${WORK_ROOT}/bundle"
  mkdir -p "${bundle_dir}"
  cp "${module_raw}"  "${bundle_dir}/${module_name}.raw"
  cp "${firmware_raw}" "${bundle_dir}/${firmware_name}.raw"
  cp "${PAYLOAD_DIR}/metadata.env" "${bundle_dir}/metadata.env"

  local bundle_tar="${WORK_ROOT}/bundle.tar.gz"
  tar -C "${bundle_dir}" -czf "${bundle_tar}" .

  local run_file="${OUT_DIR}/amdxdna-override-${KERNEL_VERSION}.run"
  local payload_line
  payload_line="$(($(wc -l < "${INSTALLER_TEMPLATE}") + 1))"

  sed \
    -e "s|__PAYLOAD_LINE__|${payload_line}|g" \
    -e "s|__TARGET_KREL__|${KERNEL_VERSION}|g" \
    "${INSTALLER_TEMPLATE}" > "${run_file}"
  cat "${bundle_tar}" >> "${run_file}"
  chmod +x "${run_file}"

  # Also emit standalone .raw files as direct-use artifacts
  cp "${module_raw}"  "${OUT_DIR}/${module_name}.raw"
  cp "${firmware_raw}" "${OUT_DIR}/${firmware_name}.raw"

  log "created ${OUT_DIR}/${module_name}.raw"
  log "created ${OUT_DIR}/${firmware_name}.raw"
  log "created ${run_file}"
}

main() {
  need_cmd git
  need_cmd make
  need_cmd mksquashfs
  need_cmd rsync
  need_cmd tar

  [[ -n "${KERNEL_VERSION}" ]] || die "KERNEL_VERSION is required"

  prepare

  if [[ -n "${FIRMWARE_DIR}" ]]; then
    [[ -d "${FIRMWARE_DIR}" ]] || die "FIRMWARE_DIR not found: ${FIRMWARE_DIR}"
    log "using pre-fetched firmware from ${FIRMWARE_DIR}"
    rsync -a --delete "${FIRMWARE_DIR}/" "${PAYLOAD_DIR}/firmware/"
    echo "pre-fetched" > "${PAYLOAD_DIR}/firmware.commit"
  else
    need_cmd dpkg-deb
    fetch_linux_firmware
  fi

  build_dkms_module
  write_metadata
  assemble_sysext

  log "done"
}

main "$@"
