# gemma-rk3588

On-device LLM inference on Rockchip RK3588/RK3588S NPU. First target: Gemma 4 E2B.

## Status

- **`serving/`** — first end-to-end spike done (2026-04-16): rkllama 0.0.66 on the Orange Pi 5 Pro serves `Qwen2.5-0.5B-Instruct` (w8a8) at ~9 tok/s over Ollama-compatible HTTP, behind a hardened systemd unit. See [`serving/README.md`](serving/README.md).
- **`conversion/`** — TODO.

The kernel driver + DKMS + device tree work is done (see sibling repo); this repo is the userspace half. See [AGENT_PROMPT.md](AGENT_PROMPT.md) for the kickoff brief.

## What this repo is

- **Conversion**: HuggingFace weights → `.rkllm` via [rkllm-toolkit](https://github.com/airockchip/rknn-llm/tree/main/rkllm-toolkit). Runs on an x86 workstation (Python, possibly CUDA).
- **Serving**: loads `.rkllm` via `librkllmrt.so` and exposes an HTTP API (Ollama-compatible, either via [rkllama](https://github.com/NotPunchnox/rkllama) or a minimal hand-rolled server). Runs on the RK3588 board.
- **Tests**: end-to-end prompt→response regression checks.

## What this repo is not

Kernel driver, device tree, DKMS, hardware bring-up — all in the sibling repo [antonioacg/rknpu-rk3588](https://github.com/antonioacg/rknpu-rk3588). This repo assumes the driver is installed (`/dev/dri/renderD129` present, `rknpu 0.9.8` loaded). See the rknpu-rk3588 Quick Start to set that up first.

## Layout

```
gemma-rk3588/
├── conversion/   # rkllm-toolkit pipeline (x86 workstation) — TODO
└── serving/      # on-board deployment (rkllama + systemd)
    ├── install.sh
    ├── systemd/rkllama.service
    └── tests/e2e.sh
```

Each subdirectory grows its own README as it materializes.

## Hardware target

Same as rknpu-rk3588: Orange Pi 5 Pro (RK3588S, 3-core NPU, 6 TOPS), Armbian 6.18.22, driver auto-loaded on boot via DKMS.

## License

Apache-2.0 — matches the [airockchip/rknn-llm](https://github.com/airockchip/rknn-llm) runtime this repo depends on.
