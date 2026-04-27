# truenas-amdxdna

Automated CI pipeline that produces a single self-extracting `.run` installer
containing [systemd-sysext](https://www.freedesktop.org/software/systemd/man/systemd-sysext.html)
images for the AMD XDNA kernel module and NPU firmware.

The `.run` auto-detects the running kernel and installs the matching variant.

## What's inside the bundle

| Image | Content | Kernel-versioned? |
|---|---|---|
| `amdxdna-<base_krel>.raw` | `amdxdna.ko` compiled from [amd/xdna-driver](https://github.com/amd/xdna-driver) | Yes — one per kernel + mode |
| `amdxdna-firmware.raw` | `amdnpu/` firmware from [linux-firmware git](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git) | No — shared |

Both images use `ID=_any` in their extension-release files, making them
compatible with any TrueNAS OS version. Extensions are placed in
`/var/lib/extensions/` and merged over `/usr` by `systemd-sysext`.

## Repository layout

```
kernels.json                     Kernel build matrix
builder/
  1_fetch_firmware.sh            Fetch amdnpu firmware from kernel.org git, create npu.sbin symlinks
  2_prepare_headers.sh           Clone truenas/linux, apply config overlays, run modules_prepare
  3_package.sh                   Assemble sysext .raw images and single .run self-extractor
  installer-template.sh          Self-extracting installer (baked into .run at package time)
.github/
  workflows/build.yml            GitHub Actions CI workflow (5 jobs)
  copilot-instructions.md        AI assistant context for this repo
```

## kernels.json

Each entry defines a TrueNAS release to build for. Both production and debug
modes are built automatically.

```json
[
  {
    "base_version": "6.18.13",
    "truenas_tag":  "TS-26.0.0-BETA.1",
    "dkms_ref":     "main"
  }
]
```

| Field | Required | Description |
|---|---|---|
| `base_version` | yes | Kernel version number (e.g. `6.18.13`) |
| `truenas_tag` | yes | Git tag on [truenas/linux](https://github.com/truenas/linux) |
| `dkms_ref` | no | Branch/tag on amd/xdna-driver — defaults to `main` |

The full kernel release string `<base_version>-<mode>+truenas` is computed
automatically. Both `production` and `debug` are always built (their vermagic
strings differ, so each needs its own `.ko`).

## CI pipeline (GitHub Actions)

Five jobs, all re-runnable independently:

| Job | Runner | Purpose |
|---|---|---|
| `prepare-matrix` | ubuntu-24.04 | Read kernels.json, emit matrix JSON |
| `build-firmware` | ubuntu-24.04 | Fetch amdnpu firmware from kernel.org; cached by git commit |
| `prepare-headers` | ubuntu-22.04 | Clone truenas/linux, apply 3-overlay config, run modules_prepare; cached per tag+mode |
| `build` | ubuntu-22.04 | Restore headers cache, build amdxdna.ko, upload artifact |
| `package` | ubuntu-24.04 | Assemble all .raw images + single .run; re-run alone after installer changes |

Caches are keyed to avoid redundant work:
- Kernel headers: `truenas-kernel-headers-{tag}-{mode}-v11`
- Firmware: `amdxdna-firmware-{linux-firmware HEAD SHA}`

To build a single release via `workflow_dispatch`, enter the `truenas_tag`
value (e.g. `TS-26.0.0-BETA.1`) in the **single_version** input.

## Installing on TrueNAS SCALE

Download `amdxdna-override.run` from the Actions run artifacts, copy to
TrueNAS, and run as root:

```bash
scp amdxdna-override.run root@freya:
bash amdxdna-override.run
```

The installer:
1. Auto-detects the running kernel via `uname -r`
2. Selects the matching `amdxdna-<base_krel>.raw` from the bundle
3. Lists available variants and exits cleanly if no match is found
4. Installs both `.raw` images into `/var/lib/extensions/`
5. Runs `systemd-sysext merge`, `depmod`, and `modprobe amdxdna`

Optional flags:
```
--sysext-dir <path>   Override install directory (default: /var/lib/extensions)
--no-reload           Skip module reload after merge
```

## After a TrueNAS system update

TrueNAS updates activate a new boot environment. `/var/lib/extensions/` is
on a writable dataset and persists across BEs, so the extensions survive
unless TrueNAS wipes that dataset. Re-run the installer if the module fails
to load after an update (a new kernel version will need a new CI build).

