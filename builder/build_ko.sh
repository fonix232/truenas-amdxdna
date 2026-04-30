#!/usr/bin/env bash
set -euo pipefail

# Patch xdna-driver sources and compile amdxdna.ko against prepared kernel headers.
#
# Required env vars:
#   KERNEL_VERSION  - full kernel version string (e.g. 6.18.13-production+truenas)
#   KERNEL_SRC      - absolute path to prepared kernel headers directory
#   DRIVER_SRC      - absolute path to the amdxdna driver source directory
#                     (e.g. <workspace>/src/amdxdna-dkms/drivers/accel/amdxdna)
#
# Assumes config_kernel.h has already been generated in DRIVER_SRC by
# configure_kernel.sh before this script is called.
#
# Output:
#   ${DRIVER_SRC}/amdxdna.ko
#   Writes AMDXDNA_VERSION to $GITHUB_ENV  (if set)
#   Writes xdna_version    to $GITHUB_OUTPUT (if set)

: "${KERNEL_VERSION:?KERNEL_VERSION is required}"
: "${KERNEL_SRC:?KERNEL_SRC is required}"
: "${DRIVER_SRC:?DRIVER_SRC is required}"

[[ -d "${KERNEL_SRC}" ]] || { echo "ERROR: KERNEL_SRC '${KERNEL_SRC}' not found" >&2; exit 1; }
[[ -d "${DRIVER_SRC}" ]] || { echo "ERROR: DRIVER_SRC '${DRIVER_SRC}' not found" >&2; exit 1; }

drv_c="${DRIVER_SRC}/amdxdna_pci_drv.c"
[[ -f "${drv_c}" ]] || { echo "ERROR: ${drv_c} not found" >&2; exit 1; }

# Remove hardcoded MODULE_VERSION() — version is already advertised via
# DRM drm_driver.major/minor at runtime; the hardcoded "0.1" would shadow it.
sed -i '/^MODULE_VERSION(/d' "${drv_c}"

# Extract MAJOR.MINOR version from source defines.
xdna_major=$(grep -m1 'define[[:space:]]\+AMDXDNA_DRIVER_MAJOR' "${drv_c}" | grep -oP '\d+$')
xdna_minor=$(grep -m1 'define[[:space:]]\+AMDXDNA_DRIVER_MINOR' "${drv_c}" | grep -oP '\d+$')
xdna_modver="${xdna_major}.${xdna_minor}"
echo "Driver version: ${xdna_modver} (kernel: ${KERNEL_VERSION})"

# Fix: amdxdna_sva_fini must be called before mmdrop(client->mm).
# When FLM terminates dirty (SIGKILL / container stop), mm_users has already
# reached zero by the time DRM close runs; mmdrop then drops mm_count to zero
# and frees mm_struct, so the subsequent iommu_sva_unbind_device call traverses
# freed mm IOMMU SVA list entries, triggering a general protection fault.
# Swapping the two calls keeps the mm alive across the SVA unbind.
awk '
  /^static void amdxdna_client_cleanup\(/ { in_fn = 1 }
  in_fn && /^\}/ { in_fn = 0 }
  in_fn && /^[[:space:]]+mmdrop\(client->mm\);/ {
    hold = $0; getline nxt
    if (nxt ~ /^[[:space:]]+amdxdna_sva_fini\(client\);/) {
      print nxt; print hold; next
    }
    print hold
    $0 = nxt
  }
  { print }
' "${drv_c}" > "${drv_c}.tmp" && mv "${drv_c}.tmp" "${drv_c}"
grep -q 'amdxdna_sva_fini(client)' "${drv_c}" \
  || { echo "ERROR: SVA ordering patch was not applied to ${drv_c}" >&2; exit 1; }
echo "Applied amdxdna_client_cleanup SVA-before-mmdrop fix"

# Build the out-of-tree kernel module.
KBUILD_MODPOST_WARN=1 make -C "${KERNEL_SRC}" \
  M="${DRIVER_SRC}" \
  CFLAGS_MODULE="-DAMDXDNA_DEVEL" \
  OFT_CONFIG_AMDXDNA_PCI=y \
  modules
[[ -f "${DRIVER_SRC}/amdxdna.ko" ]] || { echo "ERROR: amdxdna.ko not found after build" >&2; exit 1; }
echo "Built: ${DRIVER_SRC}/amdxdna.ko"

[[ -n "${GITHUB_ENV:-}" ]]    && echo "AMDXDNA_VERSION=${xdna_modver}" >> "${GITHUB_ENV}"
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "xdna_version=${xdna_modver}"    >> "${GITHUB_OUTPUT}"
