#!/usr/bin/env bash
set -euo pipefail

PAYLOAD_LINE=__PAYLOAD_LINE__
SYSEXT_NAME=__SYSEXT_NAME__

SYSEXT_DIR="${SYSEXT_DIR:-/var/lib/extensions}"

usage() {
  cat <<EOF
Usage:
  ./rocm-tools-<version>.run [options]

Installs the rocm-tools systemd-sysext image onto TrueNAS SCALE (or any
systemd-sysext-capable host).  The sysext overlays /usr and provides:
  /usr/bin/rocm-smi   — AMD GPU monitoring (ROCm SMI + amdsmi Python 3.11)
  /usr/bin/xrt-smi    — AMD NPU/XDNA monitoring (XRT)

Options:
  --sysext-dir <path>   Sysext extensions directory (default: /var/lib/extensions)
  --no-merge            Install the .raw but do not run systemd-sysext merge
  --help                Show this help

Notes:
  After a TrueNAS system update the base OS is refreshed; re-run this
  installer to restore the extension in the new boot environment.
  The extension uses ID=_any, so it is compatible with any OS release.
EOF
}

MERGE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sysext-dir) SYSEXT_DIR="$2"; shift 2 ;;
    --no-merge)   MERGE=0;         shift   ;;
    --help)       usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }
}

main() {
  [[ "${EUID}" -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }
  need_cmd tar
  need_cmd systemd-sysext

  local raw_file="${SYSEXT_NAME}.raw"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT

  # Extract the bundle embedded in this self-extracting file
  mkdir -p "${tmp_dir}/payload"
  tail -n +"${PAYLOAD_LINE}" "$0" | tar -xz -C "${tmp_dir}/payload"

  [[ -f "${tmp_dir}/payload/${raw_file}" ]] \
    || { echo "ERROR: ${raw_file} not found in payload" >&2; exit 1; }

  # If extensions are currently merged, unmerge first so files can be replaced
  if systemd-sysext status 2>/dev/null \
      | awk 'NR>1 && $2 != "none" {found=1} END {exit !found}' > /dev/null 2>&1; then
    systemd-sysext unmerge || true
  fi

  mkdir -p "${SYSEXT_DIR}"
  install -m 0644 "${tmp_dir}/payload/${raw_file}" "${SYSEXT_DIR}/${raw_file}"
  echo "Installed: ${SYSEXT_DIR}/${raw_file}"

  if [[ "${MERGE}" == "1" ]]; then
    systemd-sysext merge
    echo ""
    systemd-sysext status
  else
    echo "(skipped systemd-sysext merge — run 'systemd-sysext merge' when ready)"
  fi

  echo ""
  echo "Install complete."
  echo "  rocm-smi:  $(command -v rocm-smi 2>/dev/null || echo 'will be available after merge')"
  echo "  xrt-smi:   $(command -v xrt-smi  2>/dev/null || echo 'will be available after merge')"

  if [[ -f "${tmp_dir}/payload/metadata.env" ]]; then
    echo ""
    echo "Build metadata:"
    cat "${tmp_dir}/payload/metadata.env"
  fi
}

main "$@"
exit 0
