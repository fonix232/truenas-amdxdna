# FastFlowLM — NPU inference server

`ghcr.io/fonix232/fastflowlm`

Containerised [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM) inference server for AMD Ryzen AI NPUs (XDNA2: Strix, Strix Halo, Kraken, Gorgon Point).

Runs LLMs, VLMs, and ASR workloads directly on the NPU — no GPU required. Exposes an OpenAI-compatible REST API on port **52625**.

Built from source against [amd/xdna-driver](https://github.com/amd/xdna-driver) XRT. Image version tracks upstream [FastFlowLM releases](https://github.com/FastFlowLM/FastFlowLM/releases) and is rebuilt daily.

---

## Requirements

- AMD Ryzen AI NPU with XDNA2 (Strix / Strix Halo / Kraken / Gorgon Point)
- `amdxdna.ko` kernel module loaded and `/dev/accel/accel0` present
- Linux host with `systemd-sysext` or equivalent driver install

On TrueNAS SCALE, install the driver first:

```bash
bash amdxdna-override-<version>.run
```

---

## Quick start

```bash
docker run -d \
  --name fastflowlm \
  --device /dev/accel/accel0:/dev/accel/accel0 \
  --ulimit memlock=-1 \
  -p 52625:52625 \
  -v flm-models:/root/.config/flm \
  ghcr.io/fonix232/fastflowlm:latest
```

Then query the API:

```bash
curl http://localhost:52625/v1/models
```

---

## Docker Compose

```yaml
services:
  fastflowlm:
    image: ghcr.io/fonix232/fastflowlm:latest
    restart: unless-stopped
    devices:
      - /dev/accel/accel0:/dev/accel/accel0
    ulimits:
      memlock:
        soft: -1
        hard: -1
    ports:
      - "52625:52625"
    volumes:
      - flm-models:/root/.config/flm

volumes:
  flm-models:
```

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `FLM_ASR` | *(unset)* | Enable ASR; set to the number of ASR instances (e.g. `1`) |
| `FLM_MODEL_PATH` | `/root/.config/flm` | Path where downloaded models and NPU kernels are stored |
| `FLM_XCLBIN_PATH` | `/opt/fastflowlm/share/flm/xclbins` | Path to bundled NPU xclbin kernels |

---

## Tags

| Tag | Description |
|---|---|
| `latest` | Most recent upstream FastFlowLM release |
| `v0.9.39` | Pinned to a specific FastFlowLM release |

---

## Notes

- The container always runs `flm serve`. There is no way to override the command — use environment variables for configuration.
- Models are downloaded from HuggingFace on first use and cached in the mounted volume. Internet access is required on first pull.
- The NPU requires unlocked memory for DMA buffers (`--ulimit memlock=-1`).

---

## Source

Dockerfile and workflow: <https://github.com/fonix232/truenas-amdxdna/tree/main/fastflowlm>  
Upstream project: <https://github.com/FastFlowLM/FastFlowLM>  
Upstream docs: <https://fastflowlm.com/docs>
