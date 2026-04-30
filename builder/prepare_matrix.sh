#!/usr/bin/env bash
set -euo pipefail

# Reads kernels.json and emits a build matrix as JSON to $GITHUB_OUTPUT
# (or stdout when running outside GitHub Actions).
#
# Required env vars:
#   EVENT_NAME       - github.event_name (push / pull_request / schedule / workflow_dispatch)
#   SINGLE_VERSION   - optional: filter to this truenas_tag only (leave empty for all)
#   INCLUDE_NIGHTLY  - 'true' to include nightly (branch-based) entries; default false

: "${EVENT_NAME:=push}"
: "${SINGLE_VERSION:=}"
: "${INCLUDE_NIGHTLY:=false}"

[[ -f kernels.json ]] || { echo "ERROR: kernels.json not found in $PWD" >&2; exit 1; }

expanded=$(jq -c '[.[] | {
  base_version: (.base_version // ""),
  truenas_tag,
  slug: (.truenas_tag | gsub("/"; "-")),
  xdna_ref: (.xdna_ref // "main"),
  nightly: (.nightly // false)
}]' kernels.json)

# Nightly entries are only included on scheduled runs or explicit request.
if [[ "${EVENT_NAME}" != "schedule" ]] && [[ "${INCLUDE_NIGHTLY}" != "true" ]]; then
  expanded=$(echo "${expanded}" | jq -c '[.[] | select(.nightly == false)]')
fi

if [[ -n "${SINGLE_VERSION}" ]]; then
  expanded=$(echo "${expanded}" | jq -c --arg v "${SINGLE_VERSION}" '[.[] | select(.truenas_tag == $v)]')
  [[ "$(echo "${expanded}" | jq 'length')" -gt 0 ]] \
    || { echo "ERROR: '${SINGLE_VERSION}' not found in kernels.json" >&2; exit 1; }
fi

# Resolve each truenas_tag to a git SHA (stable cache keys for tagged releases;
# advancing for branch refs used by nightly builds).
resolved="[]"
while IFS= read -r entry; do
  ref=$(echo "${entry}" | jq -r '.truenas_tag')
  sha=$(git ls-remote https://github.com/truenas/linux \
    "refs/tags/${ref}" "refs/heads/${ref}" 2>/dev/null | head -1 | cut -f1)
  sha="${sha:-${ref}}"
  entry=$(echo "${entry}" | jq -c --arg sha "${sha}" '. + {kernel_sha: $sha}')

  # Auto-detect base_version for nightly entries that omit it.
  if [[ "$(echo "${entry}" | jq -r '.base_version')" == "" ]]; then
    makefile=$(curl -fsSL \
      "https://raw.githubusercontent.com/truenas/linux/${sha}/Makefile" \
      2>/dev/null | head -10)
    ver=$(echo "${makefile}" | awk '/^VERSION[[:space:]]*=/{print $3}')
    pl=$(echo  "${makefile}" | awk '/^PATCHLEVEL[[:space:]]*=/{print $3}')
    sl=$(echo  "${makefile}" | awk '/^SUBLEVEL[[:space:]]*=/{print $3}')
    base_version="${ver}.${pl}.${sl}"
    echo "Auto-detected base_version=${base_version} for ${ref}" >&2
    entry=$(echo "${entry}" | jq -c --arg bv "${base_version}" '.base_version = $bv')
  fi

  resolved=$(echo "${resolved}" | jq -c --argjson e "${entry}" '. + [$e]')
done < <(echo "${expanded}" | jq -c '.[]')

output_line="matrix=${resolved}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "${output_line}" >> "${GITHUB_OUTPUT}"
else
  echo "${output_line}"
fi
