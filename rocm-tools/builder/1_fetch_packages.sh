#!/usr/bin/env bash
set -euo pipefail

# Fetches rocm-smi (from ROCm noble apt repo) and xrt-smi (from amd-team/xrt PPA),
# plus the amdsmi Python 3.12 wheel from PyPI.
#
# Why noble (Ubuntu 24.04)?  ROCm 7.x targets Ubuntu noble (glibc 2.39).
# TrueNAS SCALE 26.x is Debian trixie (glibc 2.41), satisfying the requirement.
#
# Required env vars:
#   ROCM_VERSION  - ROCm major.minor version to fetch (e.g. 7.2)
#
# Outputs:
#   staging/  - tree ready for sysext assembly by 2_package.sh
#   work/     - intermediate download/extract artefacts

: "${ROCM_VERSION:?ROCM_VERSION is required (e.g. 7.2)}"

PYTHON_VERSION="3.12"          # TrueNAS SCALE 26.x (Debian trixie) ships Python 3.12
ROCM_DIST="noble"              # Ubuntu 24.04 — glibc 2.39, satisfied by trixie 2.41

mkdir -p staging/usr/bin \
         staging/usr/lib/rocm-tools/bin \
         staging/usr/lib/rocm-tools/lib \
         staging/usr/lib/rocm-tools/lib/python${PYTHON_VERSION}/site-packages \
         staging/usr/lib/xrt/bin \
         staging/usr/lib/xrt/lib \
         staging/usr/lib/extension-release.d \
         work

# ── ROCm apt repository ────────────────────────────────────────────────────

sudo mkdir -p /etc/apt/keyrings
wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key \
  | gpg --dearmor \
  | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] \
https://repo.radeon.com/rocm/apt/${ROCM_VERSION} ${ROCM_DIST} main" \
  | sudo tee /etc/apt/sources.list.d/rocm.list

sudo apt-get update -qq

# ── rocm-smi and amd-smi-lib packages ─────────────────────────────────────

pushd work > /dev/null

apt-get download rocm-smi-lib amd-smi-lib

dpkg-deb --extract rocm-smi-lib_*.deb  rocm-smi-lib
dpkg-deb --extract amd-smi-lib_*.deb   amd-smi-lib

# The rocm-smi CLI moved to libexec/rocm_smi/rocm_smi.py in ROCm 7.x (was a standalone script).
# Copy the entire libexec/rocm_smi/ dir so helper modules (rsmiBindings*.py) are alongside it.
rocm_smi_dir=$(find rocm-smi-lib/opt -type d -name 'rocm_smi' -path '*/libexec/*' | head -1)
[[ -n "${rocm_smi_dir}" ]] \
  || { echo "ERROR: rocm_smi dir not found in rocm-smi-lib" >&2; exit 1; }
[[ -f "${rocm_smi_dir}/rocm_smi.py" ]] \
  || { echo "ERROR: rocm_smi.py not found in ${rocm_smi_dir}" >&2; exit 1; }
install -D -m 0755 "${rocm_smi_dir}/rocm_smi.py" ../staging/usr/lib/rocm-tools/bin/rocm-smi
find "${rocm_smi_dir}" -name '*.py' ! -name 'rocm_smi.py' | while read -r f; do
  install -D -m 0644 "${f}" "../staging/usr/lib/rocm-tools/bin/$(basename "${f}")"
done
echo "rocm-smi: ${rocm_smi_dir}"

# libamd_smi.so — required by the amdsmi Python extension at import time
find amd-smi-lib/opt -name 'libamd_smi.so*' | while read -r lib; do
  dest="../staging/usr/lib/rocm-tools/lib/$(basename "${lib}")"
  if [[ -L "${lib}" ]]; then
    cp -P "${lib}" "${dest}"
  else
    install -D -m 0755 "${lib}" "${dest}"
  fi
done

# librocm_smi64.so — legacy; some rocm-smi versions still dlopen it
find rocm-smi-lib/opt -name 'librocm_smi64.so*' | while read -r lib; do
  dest="../staging/usr/lib/rocm-tools/lib/$(basename "${lib}")"
  if [[ -L "${lib}" ]]; then
    cp -P "${lib}" "${dest}" 2>/dev/null || true
  else
    install -D -m 0755 "${lib}" "${dest}" 2>/dev/null || true
  fi
done

popd > /dev/null

# ── amdsmi Python package ─────────────────────────────────────────────────
#
# Since ROCm 7.x the amdsmi Python package is bundled inside amd-smi-lib at
# share/amd_smi/amdsmi/. Use that directly; fall back to pip only if absent.

amdsmi_bundled=$(find work/amd-smi-lib/opt -type d -name 'amdsmi' -path '*/share/*' | head -1)
if [[ -n "${amdsmi_bundled}" ]]; then
  cp -a "${amdsmi_bundled}" \
    "staging/usr/lib/rocm-tools/lib/python${PYTHON_VERSION}/site-packages/amdsmi"
  echo "amdsmi Python package: bundled from amd-smi-lib (${amdsmi_bundled})"
else
  echo "amdsmi not bundled in amd-smi-lib; falling back to pip download"
  pip3 install --quiet --upgrade pip
  pip3 download "amdsmi~=${ROCM_VERSION}.0" \
    --python-version "${PYTHON_VERSION}" \
    --platform linux_x86_64 \
    --only-binary=:all: \
    --no-deps \
    -d work/amdsmi-wheel

  amdsmi_whl=$(find work/amdsmi-wheel -name "amdsmi-*.whl" | head -1)
  [[ -n "${amdsmi_whl}" ]] \
    || { echo "ERROR: amdsmi wheel not found on PyPI for ~=${ROCM_VERSION}.0" >&2; exit 1; }
  echo "amdsmi wheel: $(basename "${amdsmi_whl}")"

  mkdir -p work/amdsmi-extract
  python3 -m zipfile -e "${amdsmi_whl}" work/amdsmi-extract

  amdsmi_pkg=$(find work/amdsmi-extract -maxdepth 1 -type d -name 'amdsmi' | head -1)
  [[ -n "${amdsmi_pkg}" ]] \
    || { echo "ERROR: amdsmi package directory not found in wheel" >&2; exit 1; }

  cp -a "${amdsmi_pkg}" \
    "../staging/usr/lib/rocm-tools/lib/python${PYTHON_VERSION}/site-packages/amdsmi"

  # dist-info (optional; allows pip list / importlib.metadata to see it)
  find work/amdsmi-extract -maxdepth 1 -type d -name 'amdsmi-*.dist-info' \
    -exec cp -a {} "../staging/usr/lib/rocm-tools/lib/python${PYTHON_VERSION}/site-packages/" \; \
    2>/dev/null || true
fi

# ── XRT (xrt-smi) ──────────────────────────────────────────────────────────

sudo add-apt-repository -y ppa:amd-team/xrt
sudo apt-get update -qq

pushd work > /dev/null

apt-get download xrt

dpkg-deb --extract xrt_*.deb xrt

xrt_smi=$(find xrt/opt -name 'xrt-smi' -type f | head -1)
[[ -n "${xrt_smi}" ]] \
  || { echo "ERROR: xrt-smi binary not found in xrt package" >&2; exit 1; }
install -D -m 0755 "${xrt_smi}" ../staging/usr/lib/xrt/bin/xrt-smi
echo "xrt-smi binary: ${xrt_smi}"

# XRT runtime shared libraries (everything in the xrt lib directory)
xrt_lib_dir=$(find xrt/opt -mindepth 2 -maxdepth 2 -type d -name 'lib' | head -1)
if [[ -n "${xrt_lib_dir}" ]]; then
  find "${xrt_lib_dir}" -maxdepth 1 \( -name '*.so' -o -name '*.so.*' \) | while read -r lib; do
    dest="../staging/usr/lib/xrt/lib/$(basename "${lib}")"
    if [[ -L "${lib}" ]]; then
      cp -P "${lib}" "${dest}"
    else
      install -D -m 0755 "${lib}" "${dest}"
    fi
  done
fi

# Capture package versions for metadata
rocm_ver_full=$(dpkg-deb -f rocm-smi-lib_*.deb Version 2>/dev/null || echo "${ROCM_VERSION}.unknown")
xrt_ver_full=$(dpkg-deb  -f xrt_*.deb         Version 2>/dev/null || echo "unknown")

popd > /dev/null

# ── Version metadata ───────────────────────────────────────────────────────

printf 'ROCM_VERSION=%s\nXRT_VERSION=%s\nPYTHON_VERSION=%s\nBUILD_TIME_UTC=%s\n' \
  "${rocm_ver_full}" \
  "${xrt_ver_full}" \
  "${PYTHON_VERSION}" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > staging/metadata.env

echo "--- staging tree ---"
find staging -not -name 'metadata.env' -not -type d | sort | \
  xargs -I{} sh -c 'if [ -L "{}" ]; then echo "  L {}  ->  $(readlink {})"; else echo "  F {}"; fi'
echo "--------------------"
echo "Metadata:"
cat staging/metadata.env
