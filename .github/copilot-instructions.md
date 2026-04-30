# Copilot Instructions — truenas-amdxdna

## What this repository does

Builds a single `amdxdna-override.run` self-extracting installer that contains
`systemd-sysext` images for the AMD XDNA kernel module and NPU firmware. When
run as root on TrueNAS SCALE, it auto-detects the running kernel, selects the
matching module image, installs both images into `/var/lib/extensions/`, and
loads the module via `systemd-sysext merge` + `depmod` + `modprobe`.

## Key design decisions

- **Single `.run` for all variants**: the bundle contains module raws for every
  kernel×mode combination + the shared firmware raw. The installer uses `uname -r`
  to select the right one at install time; if no match is found, it lists
  available raws and exits with a clear error.
- **No system file modification**: extensions overlay `/usr` via systemd-sysext;
  the base OS image is never written to. `/var/lib/extensions/` is a standard
  sysext search directory on a writable dataset.
- **Kernel-versioned module path**: the module raw contains
  `usr/lib/modules/<kernel_version>/kernel/drivers/accel/amdxdna/amdxdna.ko` —
  must match the running kernel's vermagic exactly.
- **production vs debug**: separate kernel builds with different configs;
  a `.ko` compiled for one will not load on the other. Both are always built.
- **Firmware from kernel.org git**: `builder/1_fetch_firmware.sh` clones
  `git.kernel.org/…/linux-firmware.git` with `--depth 1`, which is newer than
  any Ubuntu package and has no distro dependency. `npu.sbin` symlinks are
  created by the script (pointing to the latest versioned file in each subdir)
  and preserved through the cache via `actions/cache` (which uses tar and keeps
  symlinks, unlike artifact upload/download which resolves them).
- **Firmware cached by git SHA**: `build-firmware` first resolves HEAD via
  `git ls-remote` (no clone), then restores/saves cache keyed to that SHA.
  Firmware is only re-fetched when the upstream repo has new commits.
- **`ID=_any`** in all extension-release files — compatible with any TrueNAS
  OS version without needing to know the host OS ID.
- **Rust 1.91.1 + bindgen 0.72.1 + dwarves required** for header prep
  (`prepare-headers` job, ubuntu-22.04): TrueNAS kernels have `CONFIG_RUST=y`
  and `CONFIG_DEBUG_INFO_BTF=y`; without the correct Rust toolchain and pahole,
  `make syncconfig` silently disables those options, changing struct layouts and
  causing the module to fail with "Invalid relocation target" or "Exec format
  error" at load time.
- **`.git` removed after kernel clone**: prevents a git hash suffix in the
  vermagic string that would cause the `.ko` to fail the kernel's version check.

## File roles

| File | Purpose |
|---|---|
| `kernels.json` | Declares which TrueNAS releases to build for |
| `builder/1_fetch_firmware.sh` | Clone linux-firmware git, rsync amdnpu/, create npu.sbin symlinks |
| `builder/2_prepare_headers.sh` | Clone truenas/linux, apply 3-overlay config, run syncconfig + modules_prepare |
| `builder/3_package.sh` | Assemble all .raw sysext images + single .run self-extractor |
| `builder/installer-template.sh` | Self-extracting installer header (baked into `.run` at package time) |
| `.github/workflows/build.yml` | GitHub Actions CI — the only supported build mechanism |

## kernels.json schema

```json
[
  {
    "base_version": "6.18.13",
    "truenas_tag":  "TS-26.0.0-BETA.1",
    "xdna_ref":     "main"
  }
]
```

- `base_version`: the numeric kernel version string (no suffix)
- `truenas_tag`: git tag on `truenas/linux` — format is `TS-<truenas-version>`
- `xdna_ref`: optional branch/tag on `amd/xdna-driver`; defaults to `"main"`

Mode (`production`/`debug`) is a fixed matrix axis in the workflow — both are
always built. `kernel_version` is computed as `<base_version>-<mode>+truenas`.

## CI workflow structure (build.yml)

Five jobs, all independently re-runnable:

| Job | Runner | Script called | Cached? |
|---|---|---|---|
| `prepare-matrix` | ubuntu-24.04 | inline jq | — |
| `build-firmware` | ubuntu-24.04 | `builder/1_fetch_firmware.sh` | yes — by linux-firmware HEAD SHA |
| `prepare-headers` | ubuntu-22.04 | `builder/2_prepare_headers.sh` | yes — by truenas_tag + mode |
| `build` | ubuntu-22.04 | inline (short steps) | uses headers cache |
| `package` | ubuntu-24.04 | `builder/3_package.sh` | restores firmware cache |

Simple steps (apt installs, a few commands) stay inline in the workflow.
Complex logic lives in numbered scripts in `builder/`.

## Sysext image layout

```
# Module sysext (kernel-versioned, one per kernel+mode)
usr/lib/modules/<kver>/kernel/drivers/accel/amdxdna/amdxdna.ko
usr/lib/extension-release.d/extension-release.amdxdna-<base_krel>

# Firmware sysext (shared, not kernel-versioned)
usr/lib/firmware/amdnpu/<subdir>/npu.sbin        ← symlink → latest versioned
usr/lib/firmware/amdnpu/<subdir>/npu.sbin.<ver>  ← actual firmware binary
usr/lib/extension-release.d/extension-release.amdxdna-firmware
```

## installer-template.sh behaviour

The template is prepended to the bundle tarball to make a self-extracting `.run`.
At install time it:
1. Calls `uname -r` to get the running kernel release
2. Strips `+truenas` suffix to derive `base_krel`
3. Looks for `amdxdna-${base_krel}.raw` in the extracted payload
4. If not found: lists all `amdxdna-*.raw` files in the bundle and exits 1
5. Installs module + firmware raws to `SYSEXT_DIR` (default `/var/lib/extensions/`)
6. Runs `systemd-sysext merge`, `depmod -a`, `modprobe amdxdna`

`PAYLOAD_LINE` is substituted at package time (line number where the binary
payload begins in the `.run` file).

