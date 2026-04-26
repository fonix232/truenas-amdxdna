# Copilot Instructions — truenas-amdxdna

## What this repository does

Builds two `systemd-sysext` extension images (`.raw` SquashFS) that overlay the AMD XDNA kernel module and NPU firmware onto a TrueNAS SCALE 26+ system, without modifying the read-only system image.

TrueNAS SCALE 26+ ships `systemd-sysext` and already uses it for extensions (stored in `/usr/share/truenas/sysext-extensions/`). This repo produces `amdxdna-<base_krel>.raw` (kernel module, kernel-versioned) and `amdxdna-firmware.raw` (firmware, shared), which are placed there and automatically merged on boot.

## Key design decisions

- **No system file modification**: the extension overlays `/usr` via systemd-sysext; nothing is written to the base OS image
- **ZFS readonly**: TrueNAS mounts `/usr` from `boot-pool/ROOT/<version>/usr` as `readonly=on`; the installer temporarily unlocks it just long enough to place the `.raw` files, then re-locks it (enforced via `trap EXIT`)
- **Kernel-versioned module path**: the `.raw` contains `usr/lib/modules/<kernel_version>/kernel/drivers/accel/amdxdna/amdxdna.ko` — must match the running kernel exactly
- **Firmware source**: Ubuntu's `linux-firmware` apt package — downloaded with `apt-get download linux-firmware` (no install), extracted with `dpkg-deb -x`; the `amdnpu/` subtree is located dynamically under the extracted tree (`find … -type d -name amdnpu`). This is used instead of the kernel.org git repo because the Ubuntu package tracks the AMD staging branch and includes newer firmware files (e.g. `17f0_20` for npu6) that the kernel.org repo lags on.
- **`ID=_any`** in both `extension-release.amdxdna-<base_krel>` and `extension-release.amdxdna-firmware` — makes the extensions work with any TrueNAS OS version
- **production vs debug**: these are separate kernel builds with different configs (vermagic differs); a `.ko` compiled for one will not load on the other

## File roles

| File | Purpose |
|---|---|
| `kernels.json` | Declares which TrueNAS releases to build for |
| `builder/build.sh` | Core pipeline: fetch firmware, build DKMS, assemble `.raw`, create `.run` |
| `builder/installer-template.sh` | Self-extracting installer header (baked into `.run` at build time) |
| `.github/workflows/build.yml` | GitHub Actions CI — the only supported build mechanism |

## kernels.json schema

```json
[
  {
    "base_version": "6.18.13",
    "truenas_tag":  "TS-26.0.0-BETA.1",
    "modes":        ["production"],
    "dkms_ref":     "main"
  }
]
```

- `base_version`: the numeric kernel version string (no suffix)
- `truenas_tag`: git tag on `truenas/linux` used to clone kernel sources — format is `TS-<truenas-version>` (e.g. `TS-26.0.0-BETA.1`, `TS-25.10.3`)
- `modes`: array of `"production"` and/or `"debug"`; defaults to `["production"]` if omitted
- `dkms_ref`: optional branch/tag on `amd/xdna-driver`; defaults to `"main"`

The workflow's `prepare-matrix` step expands this into one job per entry×mode, computing `kernel_version` as `<base_version>-<mode>+truenas`.

## Environment variables in builder/build.sh

| Variable | Required | Default | Notes |
|---|---|---|---|
| `KERNEL_VERSION` | yes | — | Full kernel release string, e.g. `6.18.13-production+truenas` |
| `KERNEL_HEADERS_DIR` | yes | `/inputs/kernel-headers` | Prepared kernel headers tree |
| `AMDXDNA_REF` | no | `main` | DKMS repo branch/tag |
| `WORK_ROOT` | no | `/work` | Scratch space |
| `OUT_DIR` | no | `/output` | Where `.raw` and `.run` are written |
| `INSTALLER_TEMPLATE` | no | `/builder/installer-template.sh` | Path to installer template (override in CI) |
| `BUILD_RUN_ID` / `BUILD_SHA` | no | — | Annotate metadata.env with CI provenance |

## Sysext image layout

Two images are produced per build, split so firmware can be updated independently:

```
# Module image  (kernel-versioned)
amdxdna-<base_krel>/                          e.g. amdxdna-6.18.13-production
  usr/lib/modules/<kernel_version>/kernel/drivers/accel/amdxdna/amdxdna.ko
  usr/lib/extension-release.d/extension-release.amdxdna-<base_krel>

# Firmware image  (shared, not kernel-versioned)
amdxdna-firmware/
  usr/lib/firmware/amdnpu/
  usr/lib/extension-release.d/extension-release.amdxdna-firmware
```

- `base_krel` = `${KERNEL_VERSION%%+*}` — strips the `+truenas` local suffix (e.g. `6.18.13-production+truenas` → `6.18.13-production`)
- The **full** `KERNEL_VERSION` string (with `+truenas`) is used for the module path inside the image and for `depmod`
- `extension-release` filename must match the image name exactly (without `.raw`) — required by systemd-sysext

## Persistence across TrueNAS updates

Extensions are placed in `/usr/share/truenas/sysext-extensions/` inside the active boot environment's `/usr` dataset (`boot-pool/ROOT/<version>/usr`, `readonly=on`). This dataset is specific to each boot environment.

When TrueNAS performs a system update it activates a new BE with a fresh `/usr` — the extensions are gone and the installer must be re-run. This is the same recovery model used by TrueNAS's own nvidia extension.

- The firmware image (`amdxdna-firmware.raw`) can be re-installed as-is (not kernel-versioned)
- The module image only needs a rebuild if the new BE ships a different kernel version

Do **not** attempt to use a separate ZFS dataset at `/var/lib/extensions` — the required path is `/usr/share/truenas/sysext-extensions/`.

## Installer behaviour

The `.run` file is a bash script with a `tar.gz` payload appended after the last line (`PAYLOAD_LINE` substituted at build time). On execution:

1. Reads `bootfs` via `zpool get -H -o value bootfs boot-pool`, computes `/usr` dataset as `<bootfs>/usr`
2. Sets `readonly=off` on that dataset; a `trap EXIT` ensures it is always re-locked even on error
3. Unmerges active sysext extensions if any (required before writing to `/usr`)
4. Installs `amdxdna-<base_krel>.raw` and `amdxdna-firmware.raw` into `/usr/share/truenas/sysext-extensions/`
5. Re-locks the dataset (`readonly=on`)
6. Runs `systemd-sysext merge`, `depmod`, module reload

## What NOT to do

- Do not use ZFS dataset mounts as module/firmware overrides — the sysext approach is the only supported method
- **Extensions MUST be placed in `/usr/share/truenas/sysext-extensions/`** — this is the path TrueNAS scans; do not use `/var/lib/extensions/` or any other path
- Do not write to `/usr/share/truenas/sysext-extensions/` without first setting `readonly=off` on the `/usr` ZFS dataset — it is `readonly=on` by default
- Do not merge the module and firmware into a single `.raw` — they are intentionally separate so firmware can be updated without rebuilding the kernel module
- Do not make `DKMS_REPO`, `KERNEL_SOURCE_REPO` user-configurable — they are hardcoded constants in `builder/build.sh`
- Do not add `FIRMWARE_SUBDIR` logic — firmware always comes from and goes to `amdnpu/`
- Do not reference `TARGET_KREL`, `AMDXDNA_DKMS_REPO`, `FIRMWARE_SUBDIR`, `krel`, `SYSEXT_NAME`, `SYSEXT_DATASET` — these are old names that have been removed
- Do not add Docker, `Dockerfile`, or `build-bundle.sh` — builds are GHA-only; `builder/build.sh` runs directly on the runner

