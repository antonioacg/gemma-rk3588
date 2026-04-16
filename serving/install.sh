#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Install rkllama on an RK3588 board (Armbian Trixie / Debian 13) as a
# user-local service. Idempotent: safe to re-run.
#
# Boundaries:
#   - userspace only; assumes the rknpu kernel driver is already installed
#     (see sibling repo antonioacg/rknpu-rk3588). /dev/dri/renderD129 must
#     exist before this script will succeed.
#   - NEVER run this as root. rkllama's server.py runs a NPU-freq fix
#     script when uid == 0 that writes to /sys/class/devfreq/fdab0000.npu/*,
#     which is documented as a board-freeze trigger by rknpu-rk3588. As long
#     as you stay non-root the dangerous block is skipped.
#
# Optional environment overrides:
#   RKLLAMA_REF       — git ref of NotPunchnox/rkllama to install (default: main)
#   RKLLAMA_HOME      — install dir (default: ~/rkllama)
#   RKLLAMA_MODELS    — models dir (default: ~/RKLLAMA/models)
#   PYTHON_VERSION    — Python version uv resolves (default: 3.12; rkllama
#                       bundles rknn_toolkit_lite2 wheels only for 3.9–3.12)

set -euo pipefail

if [ "$(id -u)" = "0" ]; then
    echo "Refusing to run as root. Re-run as the user that will own rkllama." >&2
    echo "(rkllama writes to /sys/class/devfreq/fdab0000.npu/* when uid == 0;" >&2
    echo " that path is documented as a board-freeze trigger by rknpu-rk3588.)" >&2
    exit 1
fi

if [ ! -c /dev/dri/renderD129 ]; then
    echo "Error: /dev/dri/renderD129 not present — load rknpu.ko first" >&2
    echo "(see https://github.com/antonioacg/rknpu-rk3588 for driver install)" >&2
    exit 1
fi

if ! id -nG "$(whoami)" | tr ' ' '\n' | grep -qx render; then
    echo "Error: $(whoami) is not in the 'render' group — rkllama can't open /dev/dri/renderD129" >&2
    echo "Run: sudo usermod -aG render $(whoami) && log out + back in" >&2
    exit 1
fi

RKLLAMA_REF="${RKLLAMA_REF:-main}"
RKLLAMA_HOME="${RKLLAMA_HOME:-${HOME}/rkllama}"
RKLLAMA_MODELS="${RKLLAMA_MODELS:-${HOME}/RKLLAMA/models}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"

echo "==> rkllama install (ref=${RKLLAMA_REF}, home=${RKLLAMA_HOME}, models=${RKLLAMA_MODELS})"

# 1. System packages — opencv-python (rkllama dep) needs libGL / libglib at
#    runtime. Minimal Armbian images don't ship these.
need_pkg=()
ldconfig -p | grep -q 'libGL.so.1'    || need_pkg+=(libgl1)
ldconfig -p | grep -q 'libglib-2.0'   || need_pkg+=(libglib2.0-0)
if [ ${#need_pkg[@]} -gt 0 ]; then
    echo "==> apt install: ${need_pkg[*]} (sudo)"
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends "${need_pkg[@]}"
fi

# 2. uv — single-binary Python toolchain manager. Used to fetch a managed
#    Python 3.12 (Trixie ships only 3.13 and rkllama's bundled wheels stop
#    at 3.12).
if ! command -v uv >/dev/null 2>&1 && [ ! -x "${HOME}/.local/bin/uv" ]; then
    echo "==> install uv (user-local)"
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="${HOME}/.local/bin:${PATH}"

# 3. rkllama clone
if [ ! -d "${RKLLAMA_HOME}/.git" ]; then
    echo "==> clone rkllama"
    git clone https://github.com/NotPunchnox/rkllama.git "${RKLLAMA_HOME}"
fi
git -C "${RKLLAMA_HOME}" fetch --tags --quiet
git -C "${RKLLAMA_HOME}" checkout --quiet "${RKLLAMA_REF}"

# 4. venv with managed Python; bootstrap pip (rkllama's relative file://
#    wheel paths in pyproject.toml don't resolve under uv pip install, so we
#    fall back to stock pip inside the venv).
if [ ! -x "${RKLLAMA_HOME}/.venv/bin/python" ]; then
    echo "==> create venv (Python ${PYTHON_VERSION})"
    uv venv --python "${PYTHON_VERSION}" "${RKLLAMA_HOME}/.venv"
fi
"${RKLLAMA_HOME}/.venv/bin/python" -m ensurepip --upgrade --quiet
"${RKLLAMA_HOME}/.venv/bin/python" -m pip install --quiet --upgrade pip

if ! "${RKLLAMA_HOME}/.venv/bin/python" -c 'import rkllama' 2>/dev/null; then
    echo "==> pip install rkllama (this pulls torch + transformers — slow)"
    "${RKLLAMA_HOME}/.venv/bin/python" -m pip install "${RKLLAMA_HOME}"
fi

# 5. Models dir + sample Modelfile (only created if absent — never overwrites)
mkdir -p "${RKLLAMA_MODELS}"
sample_dir="${RKLLAMA_MODELS}/Qwen2.5-0.5B-Instruct"
if [ ! -d "${sample_dir}" ]; then
    echo "==> create sample model dir at ${sample_dir} (no .rkllm download)"
    mkdir -p "${sample_dir}"
    cat > "${sample_dir}/Modelfile" <<'EOF'
FROM="Qwen2.5-0.5B-Instruct-1.2.0.rkllm"
HUGGINGFACE_PATH="Qwen/Qwen2.5-0.5B-Instruct"
SYSTEM="You are a helpful assistant."
TEMPERATURE=0.8
EOF
fi

cat <<EOF

==> install complete
    rkllama venv : ${RKLLAMA_HOME}/.venv
    models dir   : ${RKLLAMA_MODELS}

Next steps:
  1. Drop a .rkllm file (RK3588-compatible, runtime 1.2.x) next to the Modelfile, e.g.:
       cd ${sample_dir}
       curl -fLO https://huggingface.co/ThomasTheMaker/Qwen2.5-0.5B-Instruct-RKLLM-1.2.0/resolve/main/Qwen2.5-0.5B-Instruct-1.2.0.rkllm
  2. Verify the kernel CMA pool is at least 2 GiB (LLM weights need contiguous DMA):
       grep CmaTotal /proc/meminfo  # want >= 2097152
     If not, edit /boot/armbianEnv.txt (extraargs=cma=2G), reboot.
     Tracked upstream in antonioacg/rknpu-rk3588#4.
  3. Install + enable the systemd unit:
       sudo install -m 0644 systemd/rkllama.service /etc/systemd/system/
       sudo systemctl daemon-reload
       sudo systemctl enable --now rkllama.service
  4. Smoke test from your client:
       tests/e2e.sh http://<board-ip>:8080 Qwen2.5-0.5B-Instruct
EOF
