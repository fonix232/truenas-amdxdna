#!/usr/bin/env bash
set -euo pipefail

# Generic: assemble a self-extracting .run installer from a bundle directory.
#
# The bundle directory must contain all .raw sysext images and a metadata.env file.
# The installer template must contain a __PAYLOAD_LINE__ placeholder.
# Additional sed substitutions (e.g. for __SYSEXT_NAME__) can be supplied as
# extra arguments in the form "s|__FOO__|bar|g".
#
# Usage:
#   make_run.sh <bundle_dir> <installer_template> <output_run> [sed_expr...]
#
#   bundle_dir:          directory containing .raw files + metadata.env
#   installer_template:  path to an installer-template.sh
#   output_run:          destination path for the output .run file
#   sed_expr...:         optional additional sed -e expressions

[[ $# -ge 3 ]] || {
  echo "usage: make_run.sh <bundle_dir> <installer_template> <output_run> [sed_expr...]" >&2
  exit 1
}

bundle_dir="$1"
installer_template="$2"
output_run="$3"
shift 3

[[ -d "${bundle_dir}" ]]          || { echo "ERROR: bundle dir '${bundle_dir}' not found" >&2; exit 1; }
[[ -f "${installer_template}" ]]  || { echo "ERROR: template '${installer_template}' not found" >&2; exit 1; }

tmp_tar=$(mktemp /tmp/sysext-bundle.XXXXXX.tar.gz)
trap 'rm -f "${tmp_tar}"' EXIT

tar -C "${bundle_dir}" -czf "${tmp_tar}" .

# __PAYLOAD_LINE__ is always substituted; caller may add more expressions.
payload_line="$(($(wc -l < "${installer_template}") + 1))"
sed_args=(-e "s|__PAYLOAD_LINE__|${payload_line}|g")
for expr in "$@"; do
  sed_args+=(-e "${expr}")
done

mkdir -p "$(dirname "${output_run}")"
sed "${sed_args[@]}" "${installer_template}" > "${output_run}"
cat "${tmp_tar}" >> "${output_run}"
chmod +x "${output_run}"

echo "Installer: $(du -sh "${output_run}" | cut -f1)  →  ${output_run}"
