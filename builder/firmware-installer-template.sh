#!/usr/bin/env bash
set -euo pipefail

PAYLOAD_LINE=__PAYLOAD_LINE__

# /var/lib/extensions is a standard systemd-sysext search directory
# and is writable on TrueNAS SCALE (/var is a separate writable dataset).
SYSEXT_DIR="${SYSEXT_DIR:-/var/lib/extensions}"

usage() {
  cat <<'EOF'
Usage:
  ./amdnpu-firmware.run [options]

Options:
  --sysext-dir <path>     Sysext extensions directory
                          (default: /var/lib/extensions)
  --help                  Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sysext-dir) SYSEXT_DIR="$2"; shift 2 ;;
    --help)       usage; exit 0 ;;
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

  local firmware_raw="amdxdna-firmware.raw"

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  _cleanup() {
    [[ -n "${tmp_dir:-}" ]] && rm -rf "${tmp_dir}"
  }
  trap '_cleanup' EXIT

  mkdir -p "${tmp_dir}/payload"
  tail -n +"${PAYLOAD_LINE}" "$0" | tar -xz -C "${tmp_dir}/payload"

  [[ -f "${tmp_dir}/payload/${firmware_raw}" ]] \
    || { echo "ERROR: ${firmware_raw} not found in payload" >&2; exit 1; }

  # If extensions are currently merged, unmerge first so we can replace the file.
  if systemd-sysext status 2>/dev/null | awk 'NR>1 && $2 != "none" {found=1} END {exit !found}' > /dev/null 2>&1; then
    systemd-sysext unmerge || true
  fi

  mkdir -p "${SYSEXT_DIR}"
  install -m 0644 "${tmp_dir}/payload/${firmware_raw}" "${SYSEXT_DIR}/${firmware_raw}"

  # Enable the service so extensions are auto-merged on every boot.
  systemctl enable systemd-sysext 2>/dev/null || true

  # Merge all extensions from /var/lib/extensions.
  systemd-sysext merge

  echo "Install complete"
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
