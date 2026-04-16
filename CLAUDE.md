# CLAUDE.md

## Project Purpose

On-device LLM inference on Rockchip RK3588 NPU via the vendor RKNN-LLM stack. First target: Gemma 4 E2B. Measurable done state: prompt in → coherent tokens out at ≥10 tok/s, served via an Ollama-style HTTP endpoint on the board.

Depends on the sibling repo [antonioacg/rknpu-rk3588](https://github.com/antonioacg/rknpu-rk3588) being installed on the target board (driver, DT overlay, DKMS). That work is validated and you do NOT need to touch it.

## Two halves, different machines

- **`conversion/`** — runs on an x86 workstation. Uses [rkllm-toolkit](https://github.com/airockchip/rknn-llm/tree/main/rkllm-toolkit) (Python, may need CUDA) to convert HuggingFace weights to `.rkllm` format for RK3588.
- **`serving/`** — runs on the RK3588 board. Loads `.rkllm` via `librkllmrt.so`, exposes an HTTP API (likely via [rkllama](https://github.com/NotPunchnox/rkllama) or a minimal hand-rolled server against the rkllm C API).

Keep these separate: different dependencies, different hardware, different iteration speed.

## Scope boundary

This repo is **userspace only**. It assumes:

- The rknpu kernel driver is already installed on the target (see rknpu-rk3588).
- `/dev/dri/renderD129` exists and `cat /sys/module/rknpu/version` reports `0.9.8`.
- `librkllmrt.so` works against the driver — validated indirectly by the MobileNet smoke test in the driver repo (librknnrt and librkllmrt share the same ioctl path).

If you hit a kernel, DT, or DKMS problem, that's a bug to file on [rknpu-rk3588](https://github.com/antonioacg/rknpu-rk3588/issues), not a thing to fix here.

## What NOT to do

- Do NOT commit `.rkllm` files, HuggingFace `.safetensors` / `.bin` / `.pth`, or any multi-GB artifacts. The `.gitignore` catches these; don't fight it. Publish models as release artifacts or document the conversion step so users rebuild locally.
- Do NOT vendor `rkllm-toolkit` source into this repo — pin it via `requirements.txt` / `pyproject.toml`.
- Do NOT touch kernel / DT / DKMS work. Report the issue to rknpu-rk3588.
- Do NOT write to devfreq sysfs (`/sys/class/devfreq/fdab0000.npu/*`). Documented in rknpu-rk3588 as a board-freeze trigger.
- Do NOT try to fix the "NPU stuck at lowest OPP" performance ceiling here — that's a driver bug tracked in rknpu-rk3588. Expect ~1/3 of vendor-quoted tok/s until it's fixed upstream.

## Commit style

Conventional commits: `feat:`, `fix:`, `docs:`, `chore:`. When a change depends on a specific driver version, reference it by commit or tag from rknpu-rk3588.

## Target hardware

Same as rknpu-rk3588:

- Board: Orange Pi 5 Pro (RK3588S, 3-core NPU, 6 TOPS)
- OS: Armbian Trixie Minimal, kernel `6.18.22-current-rockchip64`
- Driver: rknpu 0.9.8 via DKMS, auto-loads on boot
- See `CLAUDE.local.md` (once created) for lab SSH credentials and workstation paths.

## Development discipline

- One workstream at a time. If you're in `conversion/`, don't start touching `serving/` until you have a working end-to-end conversion.
- Small surface first. A minimal "load TinyLlama, run one prompt" is more valuable than a half-built "full Gemma pipeline with options for everything."
- Document deviations. If upstream `rkllm-toolkit` breaks or changes API, note it; we're a consumer, not a fork.
