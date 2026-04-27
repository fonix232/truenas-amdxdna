#!/usr/bin/env bash
set -euo pipefail

# Clones truenas/linux at KERNEL_SOURCE_REF, applies the exact three-overlay
# TrueNAS kernel config sequence, and runs make syncconfig + modules_prepare.
#
# Required env vars:
#   KERNEL_SOURCE_REF  - git tag on truenas/linux (e.g. TS-26.0.0-BETA.1)
#   BUILD_MODE         - "production" or "debug"
#
# Outputs: kernel-src/ directory in $PWD

: "${KERNEL_SOURCE_REF:?KERNEL_SOURCE_REF is required}"
: "${BUILD_MODE:?BUILD_MODE is required}"

git -c init.defaultBranch=main clone --depth 1 --branch "${KERNEL_SOURCE_REF}" \
  https://github.com/truenas/linux kernel-src

# Remove .git to strip the vermagic git hash suffix from the module.
# Without this, the built .ko has a "-dirty" or commit-hash suffix in its
# vermagic string that won't match the running kernel's vermagic.
rm -rf kernel-src/.git kernel-src/.gitattributes kernel-src/.gitignore

cd kernel-src

make ARCH=x86_64 defconfig
./scripts/kconfig/merge_config.sh .config scripts/package/truenas/debian_amd64.config
./scripts/kconfig/merge_config.sh .config scripts/package/truenas/truenas.config

# tn-debug.config may not exist in all tags; fall back to tn-production.config
if [[ "${BUILD_MODE}" == "debug" ]]; then
  ./scripts/kconfig/merge_config.sh .config \
    scripts/package/truenas/tn-debug.config 2>/dev/null || \
  ./scripts/kconfig/merge_config.sh .config \
    scripts/package/truenas/tn-production.config
else
  ./scripts/kconfig/merge_config.sh .config scripts/package/truenas/tn-production.config
fi

# Clear trusted keys — not needed for out-of-tree module builds
./scripts/config --set-str SYSTEM_TRUSTED_KEYS ""

# syncconfig re-solves dependencies; must run after all overlays so
# CONFIG_RUST=y and CONFIG_DEBUG_INFO_BTF=y survive (requires dwarves + rustc)
make syncconfig
make -j$(nproc) scripts prepare modules_prepare
