#!/usr/bin/env bash
set -euo pipefail

# Fetches amdnpu firmware from the upstream linux-firmware git repository
# and creates npu.sbin symlinks pointing to the latest versioned firmware
# in each subdirectory.
#
# No env vars required.
# Outputs: amdnpu-firmware/ directory in $PWD

mkdir -p amdnpu-firmware
git clone --depth 1 \
  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git \
  fw-git
[[ -d fw-git/amdnpu ]] \
  || { echo "ERROR: amdnpu not found in linux-firmware git" >&2; exit 1; }

rsync -a fw-git/amdnpu/ amdnpu-firmware/
git -C fw-git log -1 --format='%H %ai' > amdnpu-firmware/.pkg-version
echo "linux-firmware commit: $(cat amdnpu-firmware/.pkg-version)"

# Symlink npu.sbin -> latest npu.sbin.<ver> in each subdir.
# The kernel module requests firmware by the unversioned name.
find amdnpu-firmware -mindepth 1 -maxdepth 1 -type d | while read -r dir; do
  mapfile -t candidates < <(find "${dir}" -maxdepth 1 -name 'npu.sbin.*' | sort -V)
  if [[ ${#candidates[@]} -eq 0 ]]; then
    echo "WARNING: no versioned npu.sbin.* found in ${dir}" >&2; continue
  fi
  echo "  ${dir}: candidates (sorted): ${candidates[*]##*/}"
  latest="${candidates[-1]}"
  ln -sf "$(basename "${latest}")" "${dir}/npu.sbin"
  echo "  ${dir}: npu.sbin -> $(readlink "${dir}/npu.sbin")"
done

echo "--- amdnpu firmware files ---"
find amdnpu-firmware -not -name '.pkg-version' | sort | \
  xargs -I{} sh -c 'if [ -L "{}" ]; then echo "  L {}  ->  $(readlink {})"; else echo "  F {}"; fi'
echo "-----------------------------"
