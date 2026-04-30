#!/usr/bin/env bash
set -euo pipefail

# Generic: assemble a squashfs systemd-sysext .raw image from a prepared staging tree.
#
# The staging tree must already contain usr/ (and optionally opt/) in the correct
# layout.  This script writes the required extension-release file and calls mksquashfs.
#
# Usage:
#   make_sysext.sh <staging_tree> <output_raw> <sysext_name>
#
#   staging_tree  - directory containing usr/ (and optionally opt/) to pack
#   output_raw    - destination path for the output .raw squashfs image
#   sysext_name   - name used in extension-release filename
#                   (should match the intended image name, e.g. "amdxdna-firmware")

[[ $# -ge 3 ]] || {
  echo "usage: make_sysext.sh <staging_tree> <output_raw> <sysext_name>" >&2
  exit 1
}

staging_tree="$1"
output_raw="$2"
sysext_name="$3"

[[ -d "${staging_tree}" ]] || {
  echo "ERROR: staging tree '${staging_tree}' does not exist" >&2
  exit 1
}

# Write the extension-release metadata file required by systemd-sysext.
ext_release_dir="${staging_tree}/usr/lib/extension-release.d"
mkdir -p "${ext_release_dir}"
printf 'ID=_any\nSYSEXT_SCOPE=system\nARCHITECTURE=x86-64\n' \
  > "${ext_release_dir}/extension-release.${sysext_name}"

mkdir -p "$(dirname "${output_raw}")"
mksquashfs "${staging_tree}" "${output_raw}" -comp xz -noappend -quiet
echo "Sysext image: $(du -sh "${output_raw}" | cut -f1)  →  ${output_raw}"
