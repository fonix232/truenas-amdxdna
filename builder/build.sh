#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:-}"
KERNEL_HEADERS_DIR="${KERNEL_HEADERS_DIR:-/inputs/kernel-headers}"
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

parse_dkms_var() {
  local var="$1"
  local file="$2"
  awk -F '=' -v name="${var}" '
    $1 ~ "^"name"(\[[0-9]+\])?$" {
      gsub(/^[ \t]+|[ \t]+$/, "", $2)
      gsub(/\"/, "", $2)
      print $2
      exit
    }
  ' "${file}"
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
  local pkg_name
  local pkg_ver
  local module_path=""

  log "cloning DKMS source: ${DKMS_REPO} (${AMDXDNA_REF})"
  git clone --depth 1 --branch "${AMDXDNA_REF}" "${DKMS_REPO}" "${src}" || \
    git clone --depth 1 "${DKMS_REPO}" "${src}"

  [[ -d "${KERNEL_HEADERS_DIR}" ]] || die "KERNEL_HEADERS_DIR not found: ${KERNEL_HEADERS_DIR}"
  [[ -f "${src}/dkms.conf" ]] || die "dkms.conf not found in DKMS repo"

  pkg_name="$(parse_dkms_var PACKAGE_NAME "${src}/dkms.conf")"
  pkg_ver="$(parse_dkms_var PACKAGE_VERSION "${src}/dkms.conf")"
  [[ -n "${pkg_name}" ]] || pkg_name="amdxdna"
  [[ -n "${pkg_ver}" ]] || pkg_ver="0.0.0+local"

  dkms add -m "${pkg_name}" -v "${pkg_ver}" --sourcetree "${src}" || true
  dkms build -m "${pkg_name}" -v "${pkg_ver}" -k "${KERNEL_VERSION}" --kernelsourcedir "${KERNEL_HEADERS_DIR}"

  module_path="$(find /var/lib/dkms/${pkg_name}/${pkg_ver} -type f -name amdxdna.ko | grep "/${KERNEL_VERSION}/" | head -n1 || true)"
  if [[ -z "${module_path}" ]]; then
    module_path="$(find /var/lib/dkms/${pkg_name}/${pkg_ver} -type f -name amdxdna.ko | head -n1 || true)"
  fi
  [[ -n "${module_path}" ]] || die "could not locate built amdxdna.ko"

  install -m 0644 "${module_path}" "${PAYLOAD_DIR}/module/amdxdna.ko"

  git -C "${src}" rev-parse HEAD > "${PAYLOAD_DIR}/dkms.commit"
  printf '%s\n' "${pkg_name}" > "${PAYLOAD_DIR}/dkms.package"
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

  # extension-release filename must match the image name (without .raw)
  printf 'ID=_any\n' > "${mod_tree}/usr/lib/extension-release.d/extension-release.${module_name}"

  local module_raw="${WORK_ROOT}/${module_name}.raw"
  mksquashfs "${mod_tree}" "${module_raw}" -comp xz -noappend -quiet

  # --- Firmware sysext: firmware files only, not kernel-versioned ---
  local fw_tree="${WORK_ROOT}/sysext-firmware"
  mkdir -p \
    "${fw_tree}/usr/lib/firmware/amdnpu" \
    "${fw_tree}/usr/lib/extension-release.d"

  rsync -a "${PAYLOAD_DIR}/firmware/" "${fw_tree}/usr/lib/firmware/amdnpu/"
  printf 'ID=_any\n' > "${fw_tree}/usr/lib/extension-release.d/extension-release.${firmware_name}"

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
  need_cmd dkms
  need_cmd dpkg-deb
  need_cmd mksquashfs
  need_cmd rsync
  need_cmd tar

  [[ -n "${KERNEL_VERSION}" ]] || die "KERNEL_VERSION is required"

  prepare
  fetch_linux_firmware
  build_dkms_module
  write_metadata
  assemble_sysext

  log "done"
}

main "$@"
