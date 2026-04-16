# conversion/

HuggingFace `.safetensors` → RK3588 `.rkllm` via Rockchip's
[`rkllm-toolkit`](https://github.com/airockchip/rknn-llm/tree/main/rkllm-toolkit).
The output drops directly into the [`serving/`](../serving/) flow.

## Status

Designed and **end-to-end validated** on stock GitHub-hosted `ubuntu-latest`
(4 vCPU / 16 GB RAM / ~21 GB free SSD after `jlumbroso/free-disk-space`,
no GPU). CPU-only path is first-class in rkllm-toolkit for `w8a8 + normal`
quantization.

| Model | Param count | Output `.rkllm` size | Build time on ubuntu-latest | Fits? |
|-------|------------:|---------------------:|----------------------------:|-------|
| `Qwen/Qwen2.5-0.5B-Instruct` | 0.5 B | 799 MB | **~16 min total** (5 min deps install, 1 min HF download, 7 min calibration+quant, 30 s upload) | ✅ verified |
| `TinyLlama/TinyLlama-1.1B-Chat-v1.0` | 1.1 B | ~1.1 GB | likely 25-40 min | likely yes (RAM tight, disk fine) |
| `google/gemma-3-1b-it` | 1.0 B | ~1.5 GB | likely 25-40 min | gated — pass `hf_token` workflow input |
| `google/gemma-4-e2b` (ultimate target) | ~6 B raw | ~3-4 GB | n/a | **no** — projected ~25 GB peak RAM, needs self-hosted or paid larger runner |

The Qwen2.5-0.5B output ran on the board at ~8 tok/s wall, comparable to the
community-converted version of the same model (~9 tok/s) — within the
expected variance from different calibration sets.

## What's here

| Path | What |
|------|------|
| `requirements.txt` | Pinned to `airockchip/rknn-llm@release-v1.2.3`. Identical version pins as the librkllmrt.so 1.2.3 bundled with rkllama on the board, so the runtime can load what we produce. |
| `convert.py` | Wraps `rkllm.api.RKLLM`. Resolves a HF repo id (or local dir), generates the calibration JSON by running the unquantized model over `calibration/prompts.txt`, then quantizes + exports `.rkllm`. |
| `calibration/prompts.txt` | ~20 generic English prompts (general QA, code, math, reasoning, summarization). For best quality, replace with prompts representative of your end use case. |
| `../.github/workflows/convert.yml` | `workflow_dispatch` job: free disk → install deps → download HF weights → run `convert.py` → verify magic bytes → upload `.rkllm` as artifact. |

## CI flow (recommended)

1. Push the repo to GitHub (CI is on `ubuntu-latest`, no self-hosted runner needed).
2. Actions → "convert" → Run workflow with:
   - `model_id`: HF repo path (e.g. `Qwen/Qwen2.5-0.5B-Instruct`)
   - `output_basename`: filename stem (e.g. `qwen2.5-0.5b-instruct`)
   - `max_context`: usually 4096
   - `hf_token`: only needed for gated repos (Gemma, Llama). Leave empty otherwise.
3. The `.rkllm` artifact appears under the run when the job completes.
   Download it and drop into `~/RKLLAMA/models/<name>/` on the board (see
   [`serving/README.md`](../serving/README.md)).

## Manual flow (local x86_64 Linux box)

```bash
cd conversion
python3.11 -m venv .venv
source .venv/bin/activate
BUILD_CUDA_EXT=0 pip install -r requirements.txt   # see "auto_gptq quirk" below

python convert.py \
    --model Qwen/Qwen2.5-0.5B-Instruct \
    --output out/qwen2.5-0.5b-instruct_w8a8_rk3588.rkllm \
    --prompts calibration/prompts.txt
```

Won't work on macOS or Windows — `rkllm_toolkit` ships `linux_x86_64` wheels
only.

### auto_gptq quirk

`auto_gptq==0.7.1` (a transitive dep) tries to compile a CUDA extension at
`pip install` time. On any host without a CUDA toolchain (which includes the
GHA runners), the install fails unless you pre-set:

```bash
export BUILD_CUDA_EXT=0
```

The flag tells auto-gptq to fall back to a slow Python implementation. That's
fine here — rkllm-toolkit only uses auto-gptq as a *loader* for pre-quantized
GPTQ models, not as the quantizer (the actual quant happens in
`rkllm.base.quantizer`, a compiled `.so`).

## Calibration

`build()` requires a calibration JSON in the form
`[{"input": "...", "target": "..."}, ...]`. `convert.py` builds it on the fly
by running the unquantized model over `calibration/prompts.txt` (one prompt
per line). The shipped prompts are deliberately generic — for production use,
swap them for ~30 prompts representative of your end use case (a domain shift
between calibration and serving prompts hurts quantization quality more than
the toolkit version does).

If you want to skip the calibration generation step (e.g. iterating on quant
settings only), pass `--skip-calibration` and a pre-built `--calibration-json`.

## Gemma 4 E2B (the actual project target)

Won't fit in `ubuntu-latest`. Three options when we get there, in rough order
of effort:

1. **Self-hosted runner with ≥32 GB RAM and ≥50 GB SSD.** Could run on a
   Linux desktop, a NUC, or a long-lived workstation under a runner token.
2. **Paid larger GHA runner** — `ubuntu-latest-8-core` etc. Currently billed
   per-minute and only on private repos by default. `ubuntu-latest-16gb-arm`
   is also a possibility but ARM wheel availability for `auto_gptq` is
   unclear.
3. **One-shot ephemeral cloud worker** triggered by `repository_dispatch` —
   spin up an EC2 / GCE instance via a small Lambda/Function, run the
   conversion there, push the `.rkllm` to a release asset, terminate.

We'll pick when we get to E2B. For now: keep the surface small, prove the
spike works on stock runners.

## Why we don't vendor the wheel

`requirements.txt` pulls the wheel from the upstream tag URL:

```
rkllm_toolkit @ https://github.com/airockchip/rknn-llm/raw/release-v1.2.3/rkllm-toolkit/packages/rkllm_toolkit-1.2.3-cp311-cp311-linux_x86_64.whl
```

This pins the bytes (the URL points at a specific git ref), satisfies
[`CLAUDE.md`'s "do not vendor rkllm-toolkit"](../CLAUDE.md) rule, and keeps
the repo small. License is BSD-3 (see
[upstream LICENSE](https://github.com/airockchip/rknn-llm/blob/main/LICENSE))
so redistributing this URL is fine.

When bumping rkllm-toolkit, update **both** sides at once:

- `conversion/requirements.txt` — the wheel URL (controls what we *produce*)
- `serving/` — rkllama or hand-rolled server bundles `librkllmrt.so` (controls
  what *consumes* the .rkllm). The two MUST agree on major version or
  `rkllm_init` fails.
