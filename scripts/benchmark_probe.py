#!/usr/bin/env python3
"""Ein einzelner Lastlauf gegen die Inferenz-API.

Misst zwei unterschiedliche Dinge, die leicht verwechselt werden:

* time_to_first_token  - Vorlaufzeit (Prefill, Spekulativ-Aufbau, Warmup)
* steady_tokens_per_second - tatsaechliche Schreibgeschwindigkeit danach

Die Gesamtzahl eines Requests enthaelt immer die Vorlaufzeit und ist deshalb
immer kleiner als die Schreibgeschwindigkeit. Nur die steady-Zahl ist mit
Angaben wie "200 Token/s" vergleichbar.

Benutzung:  ./scripts/benchmark_probe.py --prompt "..." --max-tokens 256
 Ausgabe:   ein JSON-Objekt in einer Zeile
"""
from __future__ import annotations

import argparse
import http.client
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request


def gpu_state() -> dict:
    try:
        out = subprocess.run(
            ["nvidia-smi",
             "--query-gpu=utilization.gpu,memory.used,power.draw,temperature.gpu,clocks.sm",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=8, check=True).stdout.strip()
    except Exception:
        return {}
    if not out:
        return {}
    used, total = [], []
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) >= 5:
            used.append({"utilization_percent": float(parts[0]),
                         "memory_used_mib": float(parts[1]),
                         "power_watts": float(parts[2]),
                         "temperature_c": float(parts[3]),
                         "sm_clock_mhz": float(parts[4])})
    if not used:
        return {}
    return {"gpus": used}


def sglang_gauge(name: str, port: int) -> float | None:
    try:
        body = urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=5).read().decode()
    except Exception:
        return None
    for line in body.splitlines():
        if line.startswith(name + "{") or line.startswith(name + " "):
            try:
                return float(line.rsplit(" ", 1)[1])
            except ValueError:
                return None
    return None


def one_request(args, prompt: str) -> dict:
    payload = {
        "model": args.model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": args.max_tokens,
        "temperature": 0.0,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    req = urllib.request.Request(
        f"{args.base_url}/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    started = time.perf_counter()
    ttft = None
    chunks = 0
    chars = 0
    usage: dict = {}
    text_tail = ""
    error = None
    try:
        with urllib.request.urlopen(req, timeout=args.timeout) as resp:
            for raw in resp:
                if not raw.startswith(b"data:"):
                    continue
                body = raw[5:].strip()
                if body == b"[DONE]":
                    break
                try:
                    event = json.loads(body)
                except json.JSONDecodeError:
                    continue
                if event.get("usage"):
                    usage = event["usage"]
                for choice in event.get("choices", []):
                    piece = (choice.get("delta") or {}).get("content") or ""
                    if piece:
                        if ttft is None:
                            ttft = time.perf_counter() - started
                        chunks += 1
                        chars += len(piece)
                        text_tail = (text_tail + piece)[-160:]
    except (urllib.error.URLError, TimeoutError, ConnectionError,
            http.client.HTTPException) as exc:
        error = f"{type(exc).__name__}: {exc}"
    total = time.perf_counter() - started
    tokens = usage.get("completion_tokens")
    tokens_from_chunks = tokens is None
    if tokens is None:
        # SSE-Chunks sind keine Token; der Ersatz ist eine grobe Schaetzung.
        tokens = max(chunks, 1)
    steady_window = max(total - (ttft or 0.0), 1e-6)
    return {
        "ok": error is None,
        "error": error,
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": tokens,
        "tokens_from_chunks": tokens_from_chunks,
        "time_to_first_token_seconds": round(ttft or total, 3),
        "total_seconds": round(total, 3),
        "steady_tokens_per_second": round(tokens / steady_window, 2) if tokens else 0.0,
        "overall_tokens_per_second": round(tokens / max(total, 1e-6), 2),
        "answer_tail": text_tail,
    }


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--base-url", default="http://127.0.0.1:8001/v1")
    p.add_argument("--model", default="pennyroyal")
    p.add_argument("--prompt", default="Antworte mit genau einem langen Absatz ueber ZFS.")
    p.add_argument("--prompt-repeat", type=int, default=1, help="Wiederholt den Prompttext (fuer laengere Vorlaufzeit)")
    p.add_argument("--max-tokens", type=int, default=256)
    p.add_argument("--timeout", type=int, default=600)
    p.add_argument("--sample-metrics", action="store_true", help="sglang-Metriken und GPU-Zustaende mit aufzeichnen")
    args = p.parse_args()
    port = int(args.base_url.rsplit(":", 1)[1].split("/")[0])
    prompt = args.prompt if args.prompt_repeat == 1 else " ".join([args.prompt] * args.prompt_repeat)
    before = gpu_state() if args.sample_metrics else {}
    running_before = sglang_gauge("sglang:num_running_reqs", port) if args.sample_metrics else None
    result = one_request(args, prompt)
    after = gpu_state() if args.sample_metrics else {}
    if args.sample_metrics:
        result["gpu_before"] = before
        result["gpu_after"] = after
        result["sglang_gen_throughput_now"] = sglang_gauge("sglang:gen_throughput", port)
        result["sglang_spec_accept_length"] = sglang_gauge("sglang:spec_accept_length", port)
        result["sglang_running_before"] = running_before
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
