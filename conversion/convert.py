#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Convert a HuggingFace causal-LM checkpoint to an RK3588-compatible .rkllm
file using rkllm-toolkit. CPU-only by default — runs on stock GitHub-hosted
ubuntu-latest (4 vCPU / 16 GB RAM / ~14 GB SSD usable).

Steps:
  1. Resolve the HF model directory (download with huggingface_hub if a repo
     id is passed; use the path as-is if a directory).
  2. Build a calibration JSON by running the unquantized model over a list
     of prompts (one per line, ascii or unicode). Mirrors the upstream
     pattern in airockchip/rknn-llm/examples/rkllm_api_demo/export/.
  3. Quantize + export via rkllm.api.RKLLM.

Defaults are tuned for "smallest viable spike, w8a8, 3-core, 4096 ctx".

Usage:
    python convert.py \\
        --model Qwen/Qwen2.5-0.5B-Instruct \\
        --output out/qwen2.5-0.5b-instruct_w8a8_rk3588.rkllm \\
        --prompts calibration/prompts.txt
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--model", required=True,
                   help="HF repo id (e.g. Qwen/Qwen2.5-0.5B-Instruct) OR local directory")
    p.add_argument("--output", required=True, type=Path,
                   help="Path to write the .rkllm file (parent dirs auto-created)")
    p.add_argument("--prompts", default="calibration/prompts.txt", type=Path,
                   help="Newline-delimited calibration prompts (default: calibration/prompts.txt)")
    p.add_argument("--hf-cache", default="hf-cache", type=Path,
                   help="huggingface_hub local cache dir for the source model (default: hf-cache)")
    p.add_argument("--calibration-json", default="data_quant.json", type=Path,
                   help="Where to write the generated calibration json (default: data_quant.json)")
    p.add_argument("--device", default="cpu", choices=["cpu", "cuda"],
                   help="Device for the unquantized fwd-pass during calibration (default: cpu)")
    p.add_argument("--dtype", default="float16", choices=["float32", "float16", "bfloat16"],
                   help="Weight dtype during load — float16 halves peak RAM (default: float16)")
    p.add_argument("--quant", default="w8a8",
                   help="rkllm quantized_dtype (default: w8a8 — only widely-supported option on RK3588)")
    p.add_argument("--quant-algorithm", default="normal", choices=["normal", "grq", "gdq"],
                   help="rkllm quantized_algorithm (default: normal — CPU-friendly)")
    p.add_argument("--num-npu-core", type=int, default=3,
                   help="RK3588 has 3 NPU cores (default: 3)")
    p.add_argument("--max-context", type=int, default=4096,
                   help="rkllm max_context (must be a multiple of 32, <=16384; default: 4096)")
    p.add_argument("--optimization-level", type=int, default=0, choices=[0, 1],
                   help="0 = faster build, optimised runtime (per benchmark.md); 1 = slower build, more accurate (default: 0)")
    p.add_argument("--hybrid-rate", type=float, default=0.0,
                   help="Fraction of layers kept in fp16 (default: 0)")
    p.add_argument("--max-new-tokens", type=int, default=128,
                   help="max_new_tokens used when generating calibration targets (default: 128)")
    p.add_argument("--skip-calibration", action="store_true",
                   help="If --calibration-json already exists, reuse it instead of regenerating")
    return p.parse_args()


def resolve_model_dir(model_arg: str, hf_cache: Path) -> Path:
    """Return a local directory containing the HF model. Download if needed."""
    p = Path(model_arg)
    if p.exists() and p.is_dir():
        print(f"[convert] using local model dir: {p}")
        return p

    from huggingface_hub import snapshot_download
    hf_cache.mkdir(parents=True, exist_ok=True)
    print(f"[convert] downloading {model_arg} into {hf_cache}/ …")
    local_dir = Path(snapshot_download(
        repo_id=model_arg,
        local_dir=str(hf_cache / model_arg.replace("/", "__")),
        # Skip the bulky GGUF / ONNX / TFLite siblings that some repos ship.
        ignore_patterns=["*.gguf", "*.onnx", "*.tflite", "original/*"],
    ))
    print(f"[convert] downloaded to {local_dir}")
    return local_dir


def build_calibration(model_dir: Path, prompts_file: Path, output_json: Path,
                      device: str, max_new_tokens: int) -> None:
    """Run the un-quantized model over the prompts list and write the
    calibration JSON expected by rkllm.build()."""
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    raw = prompts_file.read_text(encoding="utf-8").splitlines()
    prompts = [ln for ln in (l.strip() for l in raw) if ln and not ln.startswith("#")]
    if not prompts:
        raise SystemExit(f"[convert] no prompts found in {prompts_file}")
    print(f"[convert] {len(prompts)} calibration prompts loaded from {prompts_file}")

    print(f"[convert] loading model from {model_dir} (device={device}) for calibration generation")
    tok = AutoTokenizer.from_pretrained(str(model_dir), trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        str(model_dir),
        trust_remote_code=True,
        torch_dtype=torch.float32,  # match upstream calibration generator
    ).to(device).eval()

    gen_kwargs = dict(max_new_tokens=max_new_tokens, do_sample=False, temperature=1.0)
    cali = []
    for i, q in enumerate(prompts, 1):
        # Apply chat template if the tokenizer ships one (instruction-tuned models).
        if getattr(tok, "chat_template", None):
            messages_str = tok.apply_chat_template(
                [{"role": "user", "content": q}], tokenize=False, add_generation_prompt=True,
            )
        else:
            messages_str = q
        try:
            inputs = tok(messages_str, return_tensors="pt").to(device)
            with torch.inference_mode():
                outputs = model.generate(**inputs, **gen_kwargs)
            full = tok.decode(outputs[0], skip_special_tokens=True)
            target = full[len(messages_str):]
        except Exception as e:  # noqa: BLE001 — calibration is best-effort
            print(f"[convert] WARN prompt {i}/{len(prompts)} failed ({e!r}); using empty target")
            target = ""
        cali.append({"input": messages_str, "target": target})
        print(f"[convert] cal {i:>2}/{len(prompts)}: {len(target)} chars")

    output_json.parent.mkdir(parents=True, exist_ok=True)
    output_json.write_text(json.dumps(cali, ensure_ascii=False))
    print(f"[convert] wrote calibration json: {output_json} ({output_json.stat().st_size} bytes)")

    # Free the calibration model before rkllm-toolkit loads its own copy.
    del model
    import gc; gc.collect()
    if device == "cuda":
        torch.cuda.empty_cache()


def run_rkllm(model_dir: Path, output_path: Path, dataset_json: Path, args: argparse.Namespace) -> None:
    from rkllm.api import RKLLM
    output_path.parent.mkdir(parents=True, exist_ok=True)

    llm = RKLLM()
    print(f"[convert] rkllm load_huggingface(device={args.device}, dtype={args.dtype})")
    if llm.load_huggingface(model=str(model_dir), model_lora=None, device=args.device,
                            dtype=args.dtype, custom_config=None, load_weight=True) != 0:
        raise SystemExit("[convert] load_huggingface failed")

    # Upstream's docstring spells the constants as upper case.
    target_platform = "RK3588"
    quantized_dtype = args.quant.upper() if args.quant.lower().startswith("w") else args.quant
    print(
        f"[convert] rkllm.build(target={target_platform}, quant={quantized_dtype}, "
        f"alg={args.quant_algorithm}, opt={args.optimization_level}, "
        f"cores={args.num_npu_core}, max_ctx={args.max_context}, hybrid_rate={args.hybrid_rate})"
    )
    if llm.build(do_quantization=True,
                 optimization_level=args.optimization_level,
                 quantized_dtype=quantized_dtype,
                 quantized_algorithm=args.quant_algorithm,
                 target_platform=target_platform,
                 num_npu_core=args.num_npu_core,
                 extra_qparams=None,
                 dataset=str(dataset_json),
                 hybrid_rate=args.hybrid_rate,
                 max_context=args.max_context) != 0:
        raise SystemExit("[convert] build failed")

    print(f"[convert] export_rkllm({output_path})")
    if llm.export_rkllm(str(output_path)) != 0:
        raise SystemExit("[convert] export failed")
    size_mb = output_path.stat().st_size / (1024 * 1024)
    print(f"[convert] done. {output_path} ({size_mb:.1f} MB)")


def main() -> None:
    args = parse_args()

    # rkllm-toolkit reads CUDA_VISIBLE_DEVICES at import time. Force unset on CPU.
    if args.device == "cpu":
        os.environ["CUDA_VISIBLE_DEVICES"] = ""

    model_dir = resolve_model_dir(args.model, args.hf_cache)

    if args.skip_calibration and args.calibration_json.exists():
        print(f"[convert] reusing existing calibration json: {args.calibration_json}")
    else:
        build_calibration(
            model_dir=model_dir,
            prompts_file=args.prompts,
            output_json=args.calibration_json,
            device=args.device,
            max_new_tokens=args.max_new_tokens,
        )

    run_rkllm(model_dir=model_dir, output_path=args.output,
              dataset_json=args.calibration_json, args=args)


if __name__ == "__main__":
    sys.exit(main())
