#!/usr/bin/env bash
set -euo pipefail

# Assemble the rocm-tools .run installer from the cached sysext .raw image.
# Must be called from the rocm-tools/ directory (working-directory: rocm-tools).
#
# Used in the package job where staging/ is not available — only the pre-built
# .raw (restored from cache) and version info from job outputs are present.
#
# Required env vars:
#   ROCM_VERSION   - ROCm major.minor version (from build-rocm-tools job output)
#   XRT_VERSION    - XRT package version      (from build-rocm-tools job output)
#   BUILD_RUN_ID   - github.run_id
#   BUILD_SHA      - github.sha
#
# Input:  out/rocm-tools-*.raw  (restored from cache into rocm-tools/out/)
# Output: out/rocm-tools-<ver>.run
#         (also copied to $GITHUB_WORKSPACE/out/ for the release step)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPT_DIR = rocm-tools/builder (absolute); repo root is two levels up
REPO_BUILDER="${SCRIPT_DIR}/../../builder"

: "${ROCM_VERSION:?ROCM_VERSION is required}"
: "${XRT_VERSION:?XRT_VERSION is required}"
: "${BUILD_RUN_ID:?BUILD_RUN_ID is required}"
: "${BUILD_SHA:?BUILD_SHA is required}"

mkdir -p out work/bundle

raw=$(ls out/rocm-tools-*.raw 2>/dev/null | head -1)
[[ -n "${raw}" ]] || { echo "ERROR: rocm-tools .raw not found in out/" >&2; exit 1; }
raw_file=$(basename "${raw}")
rocm_ver=$(echo "${raw_file}" | sed 's/^rocm-tools-//; s/\.raw$//')

cp "${raw}" work/bundle/

{
  printf 'ROCM_VERSION=%s\n'   "${ROCM_VERSION}"
  printf 'XRT_VERSION=%s\n'    "${XRT_VERSION}"
  printf 'BUILD_RUN_ID=%s\n'   "${BUILD_RUN_ID}"
  printf 'BUILD_SHA=%s\n'      "${BUILD_SHA}"
  printf 'BUILD_TIME_UTC=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > work/bundle/metadata.env

bash "${REPO_BUILDER}/make_run.sh" \
  work/bundle \
  "${SCRIPT_DIR}/installer-template.sh" \
  "out/rocm-tools-${rocm_ver}.run" \
  "s|__SYSEXT_NAME__|rocm-tools|g"

# Copy output to workspace root out/ so the release step can glob out/*.run
[[ -n "${GITHUB_WORKSPACE:-}" ]] && cp "out/rocm-tools-${rocm_ver}.run" "${GITHUB_WORKSPACE}/out/"
