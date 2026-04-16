# Kickoff brief for the first agent session

Paste this into a new Claude (or other coding-agent) session when you're ready to start work. Then point the agent at this repo.

---

You're starting work in a fresh repo called `gemma-rk3588`. Read `README.md` and `CLAUDE.md` first — the scope boundaries there are load-bearing, not decorative.

## Mission

Get **Gemma 4 E2B** running on the Rockchip RK3588 NPU (Orange Pi 5 Pro) via the Rockchip vendor RKNN-LLM stack.

**Done** = prompt in → coherent tokens out at ≥10 tok/s, served via an Ollama-compatible HTTP endpoint on the board, reachable from another machine on the same network.

## What's already done (don't redo)

- Kernel driver + device tree overlay + DKMS install — all in sibling repo [antonioacg/rknpu-rk3588](https://github.com/antonioacg/rknpu-rk3588).
- Validated end to end: `/dev/dri/renderD129` present on boot, vendor RKNN SDK 2.3.2 drives MobileNet v1 at 123 inf/s single-core / 271 inf/s all-3-cores. The library and ioctl paths that `librkllmrt.so` uses are the same ones that smoke test exercises — so the runtime path is proven; what remains is the LLM-specific userspace.
- This repo: bare scaffold (README, CLAUDE.md, LICENSE, .gitignore). No code yet.

## Two workstreams

### 1. `conversion/` — x86 workstation

- Download Gemma 4 E2B from HuggingFace (verify the exact model ID — Google's naming drifts).
- Use [rkllm-toolkit](https://github.com/airockchip/rknn-llm/tree/main/rkllm-toolkit) to convert to `.rkllm` for RK3588.
- Quantization target: something that fits in ~4 GB on the NPU. Start with w4a16 symmetric.
- Deliverables: `conversion/` with a README, a reproducible pipeline script, pinned `requirements.txt`, and a sample `.rkllm` output path.

### 2. `serving/` — RK3588 board

- Evaluate serving options:
  - [rkllama](https://github.com/NotPunchnox/rkllama) (community Ollama-compatible server for RK3588)
  - A minimal hand-rolled server against `librkllmrt.so` (see `examples/rkllm_api_demo/` in airockchip/rknn-llm)
- Pick based on code quality, maintenance status, and feature fit.
- Install as a systemd unit so it survives reboots.
- Expose on a port; document the API shape (OpenAI-compatible, Ollama-compatible, or custom).
- Deliverables: `serving/` with install script, systemd unit, runbook, and an end-to-end test that hits the HTTP endpoint from the host machine and validates a non-empty response.

## Scope guardrails — stay inside these

- **Userspace only.** Kernel / DT / DKMS problems go to [rknpu-rk3588 issues](https://github.com/antonioacg/rknpu-rk3588/issues), not fixed here.
- **No model binaries in git.** The `.gitignore` blocks them. Distribute as release artifacts or document the conversion step so consumers rebuild locally.
- **Known performance ceiling.** The driver currently pins the NPU at 200 MHz / 800 mV (simple_ondemand devfreq governor doesn't get the busy signal it needs). Expect ~1/3 of vendor-quoted tok/s. Do **not** try to fix this here — it's driver-repo territory.
- **Do not write to `/sys/class/devfreq/fdab0000.npu/*`** — hangs the board hard. The driver repo documents this; don't rediscover the hard way.

## Suggested first task (pick one, not both)

1. **Conversion spike** — get rkllm-toolkit working on your workstation, convert a tiny model (e.g. TinyLlama 1.1B) end to end to validate the pipeline, then graduate to Gemma.
2. **Serving spike** — clone rkllama on the board, feed it any pre-converted `.rkllm` from airockchip's model zoo, get it responding to an HTTP POST. Ignores conversion entirely.

Either is fine. Do ONE. Small end-to-end beats half-built everything.

## References

| What | Where |
|---|---|
| Driver / DT / DKMS (parent) | https://github.com/antonioacg/rknpu-rk3588 |
| Vendor runtime + rkllm-toolkit | https://github.com/airockchip/rknn-llm |
| rkllama (community HTTP server) | https://github.com/NotPunchnox/rkllama |
| rknn-toolkit2 (general RKNN, reference) | https://github.com/airockchip/rknn-toolkit2 |
| Board SSH + workstation paths | `CLAUDE.local.md` in this repo (create it to match the one in rknpu-rk3588) |

## Before your first commit

- Create `CLAUDE.local.md` with your workstation + board paths (gitignored — see existing `.gitignore` entry).
- Verify the driver is working: ssh to the board, run the smoke test from the sibling repo, confirm `123 inf/s` on MobileNet. If that doesn't work, stop and file a driver bug — nothing here will work until that's green.
