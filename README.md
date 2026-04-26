# truenas-amdxdna

Automated build pipeline that produces two [systemd-sysext](https://www.freedesktop.org/software/systemd/man/systemd-sysext.html) extension images (`.raw` SquashFS) containing:

- **`amdxdna-<base_krel>.raw`** — the `amdxdna.ko` kernel module, compiled from [amd/xdna-driver](https://github.com/amd/xdna-driver) DKMS source against the exact TrueNAS kernel (kernel-versioned)
- **`amdxdna-firmware.raw`** — AMD NPU firmware files from the Ubuntu `linux-firmware` apt package (`amdnpu/` subtree) (shared, not kernel-versioned)

TrueNAS SCALE 26+ ships `systemd-sysext` and already uses it for first-party extensions. Two extension images are placed in `/usr/share/truenas/sysext-extensions/` — one for the kernel module (kernel-versioned) and one for the firmware (shared) — and are merged over `/usr` on every boot without touching the read-only system image.

## How it works

```
kernels.json  →  GitHub Actions matrix
                       ↓
         truenas/linux  (kernel headers)
         amd/xdna-driver  (DKMS)
         linux-firmware apt package  (amdnpu/)
                       ↓
              amdxdna-<base_krel>.raw   (module, kernel-versioned)
              amdxdna-firmware.raw      (firmware, shared)
                + .run self-extracting installer
                       ↓
         /usr/share/truenas/sysext-extensions/
           amdxdna-6.18.13-production.raw
           amdxdna-firmware.raw
                       ↓
         systemd-sysext merge  →  /usr/lib/modules/<kver>/…/amdxdna.ko
                                   /usr/lib/firmware/amdnpu/…
```

The `.raw` images are split by concern so firmware can be updated independently of the kernel module:

```
# Module sysext  (kernel-versioned, one per kernel release+mode)
amdxdna-6.18.13-production/
  usr/
    lib/
      modules/6.18.13-production+truenas/kernel/drivers/accel/amdxdna/amdxdna.ko
      extension-release.d/extension-release.amdxdna-6.18.13-production

# Firmware sysext  (shared, not kernel-versioned)
amdxdna-firmware/
  usr/
    lib/
      firmware/amdnpu/
      extension-release.d/extension-release.amdxdna-firmware
```

Both images use `ID=_any` in their extension-release file, making them compatible with any TrueNAS release version.

The sysext name for the module image strips the `+truenas` local suffix for readability:
`6.18.13-production+truenas` → `amdxdna-6.18.13-production.raw`

## Repository layout

```
kernels.json                   Kernel build matrix
builder/
  build.sh                     Fetch → build → assemble pipeline
  installer-template.sh        Self-extracting installer template
.github/
  workflows/build.yml          GitHub Actions CI workflow
```

## kernels.json schema

Each entry defines a TrueNAS release to build for. The matrix expands one job per mode:

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

| Field | Required | Description |
|---|---|---|
| `base_version` | yes | Kernel version number (e.g. `6.18.13`) |
| `truenas_tag` | yes | Git tag on [truenas/linux](https://github.com/truenas/linux) (e.g. `TS-26.0.0-BETA.1`) |
| `modes` | no | `production` and/or `debug` — defaults to `["production"]` |
| `dkms_ref` | no | Branch/tag on amd/xdna-driver — defaults to `main` |

The full kernel release string `<base_version>-<mode>+truenas` (e.g. `6.18.13-production+truenas`) is computed automatically.

`production` and `debug` modules are built separately because the kernels have different configs (vermagic differs); a `production` `.ko` will not load on a `debug` kernel.

## CI builds (GitHub Actions)

Pushes to `main` and pull requests trigger a build for every entry × mode in `kernels.json`. Each job:

1. Clones [truenas/linux](https://github.com/truenas/linux) at `truenas_tag`, prepares headers
2. Runs `builder/build.sh` directly on the runner (Ubuntu 24.04, packages installed via apt)
3. Uploads `amdxdna-<base_krel>.raw`, `amdxdna-firmware.raw`, and `amdxdna-override-<kernel_version>.run` as artifacts (the full `out/` directory)

Kernel headers are cached per `truenas_tag` + `mode` to speed up subsequent runs.

To build a single release via `workflow_dispatch`, enter the `truenas_tag` value (e.g. `TS-26.0.0-BETA.1`) in the **single_version** input.

Artifacts are retained for 30 days and can be downloaded from the Actions run page.

## Surviving TrueNAS updates

Extensions placed in `/usr/share/truenas/sysext-extensions/` live inside the active boot environment's `/usr` dataset (`boot-pool/ROOT/<version>/usr`). When TrueNAS performs an update it activates a new boot environment — the new BE's `/usr` is a fresh dataset and does not contain the installed extensions.

**Re-run the installer after every TrueNAS update.** The process is fast: the firmware `.raw` is not kernel-versioned so it works immediately; the module `.raw` only needs a rebuild if the kernel version changed (which will produce a new `.run` artifact from CI).

## Installing on TrueNAS

Copy the `.run` to TrueNAS and execute as root:

```bash
scp out/amdxdna-override-6.18.13-production+truenas.run root@freya:
bash amdxdna-override-6.18.13-production+truenas.run
```

The installer:

1. Reads `bootfs` from `zpool get -H -o value bootfs boot-pool` to identify the active boot environment's `/usr` dataset (e.g. `boot-pool/ROOT/26.0.0-BETA.1/usr`)
2. Sets `readonly=off` on that dataset (`trap EXIT` guarantees it is always re-locked, even on error)
3. Unmerges any currently active sysext extensions
4. Installs `amdxdna-<base_krel>.raw` and `amdxdna-firmware.raw` into `/usr/share/truenas/sysext-extensions/`
5. Re-locks the dataset (`readonly=on`)
6. Runs `systemd-sysext merge`, `depmod`, and reloads the `amdxdna` module

Optional flags:

```
--zfs-boot-pool <pool>  Override ZFS pool name (default: boot-pool)
--sysext-dir <path>     Override extension directory
                        (default: /usr/share/truenas/sysext-extensions)
--no-reload             Skip module reload after merge
```

## Fixed sources

| Source | URL |
|---|---|
| Kernel | <https://github.com/truenas/linux> |
| DKMS driver | <https://github.com/amd/xdna-driver> |
| Firmware | Ubuntu `linux-firmware` apt package (Ubuntu 24.04 runner) |

