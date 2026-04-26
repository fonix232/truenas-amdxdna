#!/usr/bin/env bash
set -euo pipefail

PAYLOAD_LINE=__PAYLOAD_LINE__
EMBEDDED_KREL="__TARGET_KREL__"

# /var/lib/extensions is a standard systemd-sysext search directory
# and is writable on TrueNAS SCALE (/var is a separate writable dataset).
SYSEXT_DIR="${SYSEXT_DIR:-/var/lib/extensions}"
RELOAD_MODULE="${RELOAD_MODULE:-1}"

usage() {
  cat <<'EOF'
Usage:
  ./amdxdna-override-<krel>.run [options]

Options:
  --sysext-dir <path>     Sysext extensions directory
                          (default: /var/lib/extensions)
  --no-reload             Do not reload amdxdna module after merge
  --help                  Show this help

Notes:
  Extensions are placed in /var/lib/extensions (or --sysext-dir), which is
  a standard systemd-sysext search directory. After a TrueNAS system update
  (new boot environment), re-run this installer to restore the extensions.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sysext-dir)    SYSEXT_DIR="$2";    shift 2 ;;
    --no-reload)     RELOAD_MODULE=0;    shift   ;;
    --help)          usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }
}

main() {
  require_root
  need_cmd tar
  need_cmd systemd-sysext

  # Derive sysext image names from the embedded kernel release.
  # Strip +truenas local suffix for human-friendly names:
  #   6.18.13-production+truenas  →  amdxdna-6.18.13-production.raw
  local base_krel="${EMBEDDED_KREL%%+*}"
  local module_raw="amdxdna-${base_krel}.raw"
  local firmware_raw="amdxdna-firmware.raw"

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  _cleanup() {
    [[ -n "${tmp_dir:-}" ]] && rm -rf "${tmp_dir}"
  }
  trap '_cleanup' EXIT

  # Extract the bundle embedded in this self-extracting file
  mkdir -p "${tmp_dir}/payload"
  tail -n +"${PAYLOAD_LINE}" "$0" | tar -xz -C "${tmp_dir}/payload"
  [[ -f "${tmp_dir}/payload/${module_raw}" ]] \
    || { echo "ERROR: ${module_raw} not found in payload" >&2; exit 1; }
  [[ -f "${tmp_dir}/payload/${firmware_raw}" ]] \
    || { echo "ERROR: ${firmware_raw} not found in payload" >&2; exit 1; }

  # If extensions are currently merged, unmerge first so we can replace the files.
  if systemd-sysext status 2>/dev/null | awk 'NR>1 && $2 != "none" {found=1} END {exit !found}' > /dev/null 2>&1; then
    systemd-sysext unmerge || true
  fi

  mkdir -p "${SYSEXT_DIR}"
  install -m 0644 "${tmp_dir}/payload/${module_raw}"   "${SYSEXT_DIR}/${module_raw}"
  install -m 0644 "${tmp_dir}/payload/${firmware_raw}" "${SYSEXT_DIR}/${firmware_raw}"

  # Merge all extensions from /var/lib/extensions (a standard sysext search path).
  systemd-sysext merge

  if [[ "${RELOAD_MODULE}" == "1" ]]; then
    depmod -a "${EMBEDDED_KREL}" 2>/dev/null || true
    if lsmod | awk '{print $1}' | grep -qx amdxdna; then
      modprobe -r amdxdna || true
    fi
    modprobe amdxdna || true
  fi

  echo "Install complete"
  echo "  Module sysext:   ${SYSEXT_DIR}/${module_raw}"
  echo "  Firmware sysext: ${SYSEXT_DIR}/${firmware_raw}"
  echo
  echo "NOTE: after a TrueNAS system update, re-run this installer to restore"
  echo "      extensions in the new boot environment."
  echo
  systemd-sysext status

  if [[ -f "${tmp_dir}/payload/metadata.env" ]]; then
    echo
    echo "Build metadata:"
    cat "${tmp_dir}/payload/metadata.env"
  fi
}

main "$@"
# Exit explicitly so bash does not attempt to read/execute the binary payload
# that is appended after this line by the build script.
exit 0
