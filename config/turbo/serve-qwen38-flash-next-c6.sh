#!/usr/bin/env bash
# Produktionsprofil fuer mratsim/sglang-qwen38fn-sm120-turbo r24.
# Die Datei wird im separaten Turbo-Container ausgefuehrt; Pennyroyal bleibt
# ein unabhaengiger Fallback auf Port 8001.
set -Eeuo pipefail

MODEL_PATH="${TARGET_MODEL:-/models/Qwen3.8-Flash-Next-NVFP4}"
PORT="${SGLANG_PORT:-8001}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-262144}"
MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.98}"
HICACHE_SIZE_GB="${HICACHE_SIZE_GB:-8}"
MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-6}"
MAX_MAMBA_CACHE_SIZE="${MAX_MAMBA_CACHE_SIZE:-27}"

[[ -f "$MODEL_PATH/config.json" ]] || { echo "Turbo-Modell fehlt: $MODEL_PATH" >&2; exit 2; }
[[ -f "$MODEL_PATH/model.safetensors.index.json" ]] || { echo "Turbo-Index fehlt: $MODEL_PATH" >&2; exit 2; }

export SGLANG_SM120_ONLINE_MXFP8="${SGLANG_SM120_ONLINE_MXFP8:-true}"
export SGLANG_MM_PREPROCESS_DEVICE="${SGLANG_MM_PREPROCESS_DEVICE:-cpu}"
export SGLANG_QWEN4_PLE_NVME_PATH="${SGLANG_QWEN4_PLE_NVME_PATH:-$MODEL_PATH}"
export SGLANG_QWEN4_PLE_NVME_BACKEND="${SGLANG_QWEN4_PLE_NVME_BACKEND:-mmap}"
export SGLANG_RUST_BUILD_MODE="${SGLANG_RUST_BUILD_MODE:-auto}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export SAFETENSORS_FAST_GPU=1
export SGLANG_ENABLE_HEALTH_ENDPOINT_GENERATION=1
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/cache}"
export SGLANG_CACHE_DIR="${SGLANG_CACHE_DIR:-/cache/sglang-generated}"
export TRANSFORMERS_OFFLINE=1 HF_HUB_OFFLINE=1

args=(
  serve
  --host 0.0.0.0 --port "$PORT"
  --served-model-name Qwen3.8-Flash-Next
  --model-path "$MODEL_PATH"
  --reasoning-parser auto --tool-call-parser auto
  --warmups sm120_turbo_structured_output
  --linear-attn-prefill-backend flashinfer --linear-attn-decode-backend flashinfer
  --moe-runner-backend flashinfer_cutlass
  --max-mamba-cache-size "$MAX_MAMBA_CACHE_SIZE"
  --mamba-radix-cache-strategy extra_buffer_lazy
  --mamba-track-interval 64 --mamba-ssm-dtype bfloat16
  --tp 1 --dtype bfloat16 --quantization modelopt_fp4
  --kv-cache-dtype fp8_e4m3
  --context-length "$CONTEXT_LENGTH"
  --max-total-tokens 1048576
  --mem-fraction-static "$MEM_FRACTION_STATIC"
  --page-size 64 --chunked-prefill-size 4096
  --max-running-requests "$MAX_RUNNING_REQUESTS"
  --speculative-algorithm NEXTN --speculative-num-steps 3
  --speculative-eagle-topk 1 --speculative-num-draft-tokens 4
  --gdn-mtp-cache-mode none
  --enable-hierarchical-cache --hicache-size "$HICACHE_SIZE_GB"
  --hicache-write-policy write_through
  --enable-metrics --enable-cache-report --enable-request-time-stats-logging
  --disable-cuda-graph
  --sleep-on-idle
)

printf 'turbo-c6: model=%s context=%s mem_fraction=%s C%s mamba=%s hicache=%sGB ple=file:%s online_mxfp8=%s kv=fp8_e4m3\n' \
  "$MODEL_PATH" "$CONTEXT_LENGTH" "$MEM_FRACTION_STATIC" "$MAX_RUNNING_REQUESTS" \
  "$MAX_MAMBA_CACHE_SIZE" "$HICACHE_SIZE_GB" "$SGLANG_QWEN4_PLE_NVME_PATH" "$SGLANG_QWEN4_PLE_NVME_BACKEND" "$SGLANG_SM120_ONLINE_MXFP8" >&2
exec sglang "${args[@]}"
