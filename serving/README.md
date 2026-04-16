# serving/

On-device LLM HTTP serving on the RK3588 NPU. Wraps
[NotPunchnox/rkllama](https://github.com/NotPunchnox/rkllama) (community
Ollama-compatible server bundling `librkllmrt.so` 1.2.3) behind a systemd unit.

The conversion half lives in [`conversion/`](../conversion/) (TODO; not yet
materialized — see [AGENT_PROMPT.md](../AGENT_PROMPT.md)). This directory is
self-contained: with any RK3588-compatible `.rkllm` file you can serve it from
the board with no further repo state.

## Status

End-to-end validated 2026-04-16 on Orange Pi 5 Pro / Armbian Trixie / kernel
`6.18.22-current-rockchip64` / driver `rknpu 0.9.8` / runtime `librkllmrt 1.2.3`:

| Model | Quant | Size | Throughput (wall) |
|-------|-------|-----:|------------------:|
| `Qwen2.5-0.5B-Instruct` (`ThomasTheMaker/...-RKLLM-1.2.0`) | w8a8 | 754 MB | ~9.2 tok/s |

The 9.2 tok/s number is **expected to be ~1/3 of vendor-quoted** because the
upstream rknpu driver currently pins the NPU at 200 MHz / 800 mV — see
[antonioacg/rknpu-rk3588](https://github.com/antonioacg/rknpu-rk3588) for the
driver-side fix tracker.

## What's here

| Path | What |
|------|------|
| `install.sh` | Idempotent user-local installer: apt deps, uv, Python 3.12 venv, rkllama clone + pip install, models dir scaffold. Refuses to run as root. |
| `systemd/rkllama.service` | Unit file. Runs as the unprivileged install user. Hard-blocks writes to `/sys/class/devfreq` even if escalated (see "Why never root" below). |
| `tests/e2e.sh` | HTTP smoke test — pings `/api/version`, asserts model in `/api/tags`, generates one response, validates non-empty. Runs from any client (your laptop, the board, CI). |

## Quick start

### On the board (one-time install)

```bash
# As the user that will own the rkllama install — NOT root.
git clone https://github.com/antonioacg/gemma-rk3588.git
cd gemma-rk3588/serving
./install.sh
```

`install.sh` will: install `libgl1` + `libglib2.0-0` (sudo prompt — needed by
`opencv-python` which rkllama imports), bootstrap `uv` to `~/.local/bin`, fetch
a managed Python 3.12, clone rkllama, `pip install` it (slow — pulls torch,
transformers, whisper, etc., ~5 min on a board), and create
`~/RKLLAMA/models/`. It does **not** download any model file.

### Drop a model

`Qwen2.5-0.5B-Instruct` validates the pipeline (the install script
pre-creates a `Modelfile` for it):

```bash
cd ~/RKLLAMA/models/Qwen2.5-0.5B-Instruct
curl -fLO https://huggingface.co/ThomasTheMaker/Qwen2.5-0.5B-Instruct-RKLLM-1.2.0/resolve/main/Qwen2.5-0.5B-Instruct-1.2.0.rkllm
```

Other RK3588 candidates (must be built for `rkllm-runtime 1.2.x` — the 1.1.x →
1.2.x file header is incompatible):

- `dulimov/Qwen3-0.6B-rk3588-1.2.1-unsloth` — 889 MB
- `imkebe/gemma-3-1b-it-rk3588-1.2.0` — 1.6 GB (gated, needs HF login)

### Verify CMA pool

LLM weight loading needs more contiguous DMA memory than the Armbian default
gives you. Confirm before enabling the service:

```bash
grep CmaTotal /proc/meminfo   # want >= 2097152 (2 GiB)
```

If it's `262144` (256 MiB Armbian default), edit `/boot/armbianEnv.txt`:

```diff
-extraargs=cma=256M
+extraargs=cma=2G
```

…and reboot. Without this, `rkllm_init` returns `-1` with kernel log
`failed to malloc npu memory, size: 493961216`. Tracked upstream in
[antonioacg/rknpu-rk3588#4](https://github.com/antonioacg/rknpu-rk3588/issues/4).

### Enable the service

```bash
sudo install -m 0644 systemd/rkllama.service /etc/systemd/system/
# Optional: drop an override if your username/paths differ:
#   sudo systemctl edit rkllama.service
sudo systemctl daemon-reload
sudo systemctl enable --now rkllama.service
sudo systemctl status rkllama.service --no-pager
```

### Smoke test from your laptop

```bash
./tests/e2e.sh http://<board-ip>:8080 Qwen2.5-0.5B-Instruct
```

Expected output ends with `PASS — response non-empty` and a coherent sentence
about whatever you asked.

## API surface

rkllama implements (a subset of) the Ollama HTTP API on port `8080` plus a
partial OpenAI surface. The endpoints actually exercised by this spike:

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/version` | server reachable |
| `GET` | `/api/tags` | list models registered under `--models` dir |
| `POST` | `/api/generate` | one-shot completion (stream optional) |
| `POST` | `/api/chat` | chat-template completion (also Ollama-compat) |

Full surface in [rkllama's docs](https://github.com/NotPunchnox/rkllama/blob/main/documentation/api/ollama-compatibility.md).
**Note**: rkllama uses milliseconds for `eval_duration` / `prompt_eval_duration`
where Ollama uses nanoseconds — beware if you're plumbing into Ollama clients
that compute tok/s from those fields.

## Why never root

`rkllama_server` checks `os.getuid() == 0` at startup and, if true, runs
`fix_freq_rk3588.sh`, which writes to `/sys/class/devfreq/fdab0000.npu/governor`
and `.../userspace/set_freq`. The rknpu-rk3588 driver repo
[documents](https://github.com/antonioacg/rknpu-rk3588/blob/main/CLAUDE.md)
this sysfs path as a board-freeze trigger on the current driver / kernel
combination. As a normal user the entire freq block is skipped.

Belt-and-braces in the systemd unit:

- `User=` is unprivileged
- `NoNewPrivileges=true`
- `ReadOnlyPaths=/sys/class/devfreq` — even an exploit that gets root inside
  the unit can't trip the freeze

**Do NOT** use rkllama's upstream Docker image: it runs the server as root
inside a `privileged: true` container and *will* hit the sysfs writes.

## Operations

```bash
# logs
sudo journalctl -u rkllama.service -f
# tail of rkllama's own debug log
tail -f ~/RKLLAMA/logs/server.log    # only when --debug is passed

# restart
sudo systemctl restart rkllama.service

# stop while debugging
sudo systemctl stop rkllama.service
~/rkllama/.venv/bin/rkllama_server --models ~/RKLLAMA/models --debug
```

## Known issues / escape hatches

- **Bundled `librkllmrt.so` 1.2.3 has a garbage-output bug** for some models
  ([rkllama#102](https://github.com/NotPunchnox/rkllama/issues/102)). If
  generation degrades into `&&&&` or repeated tokens after a few words,
  swap the blob in `~/rkllama/.venv/lib/python3.12/site-packages/rkllama/lib/librkllmrt.so`
  for a v1.2.1 build from `airockchip/rknn-llm`.
- **rkllama's Python orchestration is reportedly 2.5×–3× slower than thin
  C servers** ([rkllama#125](https://github.com/NotPunchnox/rkllama/issues/125)).
  If we can't reach the ≥10 tok/s target on Gemma even after the driver-OPP
  fix lands, the escape hatch is to replace this directory with a minimal
  Flask wrapper around `librkllmrt.so` directly. The vendor C demo is at
  `airockchip/rknn-llm/examples/rkllm_api_demo/`.
- **Heavy install footprint** — rkllama declares torch, whisper, diffusers,
  opencv as required deps even for text-only serving. ~4–6 GB on disk.
  Trimming this needs an upstream PR or a fork.
