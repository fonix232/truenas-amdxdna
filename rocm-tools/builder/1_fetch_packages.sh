#!/usr/bin/env bash
set -euo pipefail

# Installs rocm-smi-lib, amd-smi-lib, and XRT tools (libxrt-utils/npu2/2) directly
# via apt into the (throwaway) GitHub Actions runner, then rsyncs all files from
# newly-installed packages into staging/ at their native paths.  This ensures every
# transitive shared-library dependency is captured automatically.
#
# Required env vars:
#   ROCM_VERSION  - ROCm major.minor version (e.g. 7.2)
#
# Outputs:
#   staging/  - tree ready for sysext assembly by 2_package.sh

: "${ROCM_VERSION:?ROCM_VERSION is required (e.g. 7.2)}"
export DEBIAN_FRONTEND=noninteractive

PYTHON_VERSION="3.12"
ROCM_DIST="noble"

mkdir -p staging work

# ── Set up repositories ────────────────────────────────────────────────────

sudo mkdir -p /etc/apt/keyrings

# ROCm
wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key \
  | gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] \
https://repo.radeon.com/rocm/apt/${ROCM_VERSION} ${ROCM_DIST} main" \
  | sudo tee /etc/apt/sources.list.d/rocm.list

# XRT PPA (key fingerprint from https://launchpad.net/~amd-team/+archive/ubuntu/xrt)
XRT_PPA_KEY="F83FE7BE8F1A44E83CDA3625D47169167A18444E"
wget -qO - "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${XRT_PPA_KEY}" \
  | gpg --dearmor | sudo tee /etc/apt/keyrings/xrt.gpg > /dev/null
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/xrt.gpg] \
https://ppa.launchpadcontent.net/amd-team/xrt/ubuntu ${ROCM_DIST} main" \
  | sudo tee /etc/apt/sources.list.d/xrt.list

sudo apt-get update -qq

# ── Install packages ──────────────────────────────────────────────────────
# Record what is installed before so we can identify newly added packages
# (including transitive deps) and capture exactly those files.

dpkg-query -f '\${Package}\n' -W | sort > work/before.txt

sudo apt-get install -y --no-install-recommends \
  rocm-smi-lib amd-smi-lib libxrt-utils libxrt-npu2 libxrt2 2>&1 \
  | grep -E '^(Setting up|E:)'

dpkg-query -f '\${Package}\n' -W | sort > work/after.txt
new_pkgs=$(comm -13 work/before.txt work/after.txt)
echo "New packages installed: $(echo "${new_pkgs}" | wc -l)"

# ── Capture installed files into staging/ ─────────────────────────────────
# List all files owned by newly installed packages, filtered to /usr and /opt.
# Excluding docs, headers, cmake, pkg-config, man pages, OpenCL ICD files.
echo "${new_pkgs}" | xargs dpkg -L 2>/dev/null | sort -u \
  | grep -E '^(/usr|/opt)' \
  | grep -vE '/share/(doc|man|lintian|bash-completion|cmake|pkgconfig)
             |/include/
             |\.gz$|NOTICE|changelog|copyright|TODO
             |\.h$|\.md$
             |example|OpenCL
             |amd_smi/(example|setup\.py|pyproject)' \
  > work/filelist.txt

# rsync -aR preserves symlinks and permissions and uses the full path as relative source
rsync -aR --files-from=work/filelist.txt / staging/

# /opt/rocm symlink: rocm-core manages this via update-alternatives
# (/opt/rocm -> /etc/alternatives/rocm -> /opt/rocm-X.Y.Z)
# Recreate as a direct relative symlink in staging so the sysext works standalone.
if [[ -L /opt/rocm ]]; then
  rocm_real=$(readlink -f /opt/rocm)
  rocm_dir=$(basename "${rocm_real}")
  mkdir -p staging/opt
  ln -sfn "${rocm_dir}" staging/opt/rocm
  echo "opt/rocm -> ${rocm_dir}"
fi

# Capture package versions for metadata
rocm_ver_full=$(dpkg-query -f '\${Version}' -W rocm-smi-lib 2>/dev/null || echo "${ROCM_VERSION}.unknown")
xrt_ver_full=$(dpkg-query  -f '\${Version}' -W libxrt-utils  2>/dev/null || echo "unknown")

# ── PATH wrapper scripts ───────────────────────────────────────────────────
# rocm-smi and amd-smi install to /opt/rocm/bin/, not /usr/bin/.
# Add thin wrappers so they are available on PATH after the sysext merges /usr.

mkdir -p staging/usr/bin
printf '#!/bin/bash\nexec /opt/rocm/bin/rocm-smi "$@"\n' > staging/usr/bin/rocm-smi
printf '#!/bin/bash\nexec /opt/rocm/bin/amd-smi "$@"\n'  > staging/usr/bin/amd-smi
chmod 0755 staging/usr/bin/rocm-smi staging/usr/bin/amd-smi

# ── Version metadata ───────────────────────────────────────────────────────

printf 'ROCM_VERSION=%s\nXRT_VERSION=%s\nPYTHON_VERSION=%s\nBUILD_TIME_UTC=%s\n' \
  "${rocm_ver_full}" \
  "${xrt_ver_full}" \
  "${PYTHON_VERSION}" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > staging/metadata.env

echo "--- staging tree (bin + lib) ---"
find staging/usr/bin staging/usr/lib staging/opt 2>/dev/null -not -type d | sort | \
  while read -r f; do
    if [[ -L "$f" ]]; then echo "  L $f  ->  $(readlink "$f")"; else echo "  F $f"; fi
  done
echo "--------------------"
echo "Metadata:"
cat staging/metadata.env
