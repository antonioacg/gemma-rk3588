#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end smoke test: hit a running rkllama server from any client (your
# Mac, the board itself, CI), assert that the model is registered and that
# /api/generate returns a non-empty coherent response.
#
# Usage:
#   tests/e2e.sh [BASE_URL] [MODEL] [PROMPT]
#
# Defaults:
#   BASE_URL = http://localhost:8080
#   MODEL    = Qwen2.5-0.5B-Instruct
#   PROMPT   = "Write one sentence about Rockchip NPU."
#
# Exit codes:
#   0  ok
#   1  /api/version unreachable
#   2  model not in /api/tags
#   3  /api/generate returned an error or empty response

set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"
MODEL="${2:-Qwen2.5-0.5B-Instruct}"
PROMPT="${3:-Write one sentence about Rockchip NPU.}"

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

echo "=== rkllama e2e: ${BASE_URL} / model=${MODEL} ==="

# 1. Server reachable?
if ! ver="$(curl -fsS --max-time 5 "${BASE_URL}/api/version")"; then
    red "FAIL: ${BASE_URL}/api/version unreachable"
    exit 1
fi
echo "version : ${ver}"

# 2. Model present in /api/tags?
tags="$(curl -fsS --max-time 5 "${BASE_URL}/api/tags")"
if ! MODEL="${MODEL}" TAGS="${tags}" python3 - <<'PY'
import json, os, sys
data = json.loads(os.environ["TAGS"])
names = [m.get("name") or m.get("model") for m in data.get("models", [])]
sys.exit(0 if os.environ["MODEL"] in names else 1)
PY
then
    red "FAIL: model '${MODEL}' not in /api/tags"
    echo "${tags}" >&2
    exit 2
fi
echo "tags    : ${MODEL} present"

# 3. Build the request body via python — avoids any shell quoting hazards.
body="$(MODEL="${MODEL}" PROMPT="${PROMPT}" python3 - <<'PY'
import json, os
print(json.dumps({"model": os.environ["MODEL"], "prompt": os.environ["PROMPT"], "stream": False}))
PY
)"

echo "prompt  : ${PROMPT}"
echo -n "request : "
start_epoch="$(python3 -c 'import time; print(time.time())')"
resp="$(curl -fsS --max-time 180 -X POST "${BASE_URL}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "${body}")"
end_epoch="$(python3 -c 'import time; print(time.time())')"
elapsed="$(python3 -c "print(f'{${end_epoch} - ${start_epoch}:.2f}')")"
echo "${elapsed}s"

# 4. Validate response and extract metrics
if ! RESP="${resp}" ELAPSED="${elapsed}" python3 - <<'PY'
import json, os, sys
r = json.loads(os.environ["RESP"])
if "error" in r:
    print("ERROR:", r["error"], file=sys.stderr)
    sys.exit(1)
text = (r.get("response") or "").strip()
if not text:
    print("EMPTY response field", file=sys.stderr)
    sys.exit(1)
ec = r.get("eval_count") or 0
elapsed = float(os.environ["ELAPSED"])
toks_per_sec_wall = ec / elapsed if elapsed > 0 else 0
print(f"length  : {len(text)} chars")
print(f"tokens  : {ec}")
print(f"tok/s   : {toks_per_sec_wall:.2f} (wall, includes network)")
print(f"---")
print(text[:500])
PY
then
    red "FAIL: response invalid or empty"
    echo "${resp}" >&2
    exit 3
fi

green "PASS — response non-empty"
