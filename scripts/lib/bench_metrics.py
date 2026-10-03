#!/usr/bin/env python3
"""Letzte Benchmark-Ergebnisse als Prometheus-Messwerte.

Umgebungsvariable: BENCH_FILE
"""
import json
import os
import sys

path = os.environ.get('BENCH_FILE', '')
try:
    data = json.load(open(path, encoding='utf-8'))
except Exception as exc:
    print(f'# Benchmarkdatei nicht lesbar: {exc}', file=sys.stderr)
    raise SystemExit(0)
profile = str(data.get('profile', 'unknown'))
for key, metric in (
    ('steady_tokens_per_second_median', 'llm_benchmark_steady_tokens_per_second'),
    ('time_to_first_token_seconds_median', 'llm_benchmark_time_to_first_token_seconds'),
    ('aggregate_tokens_per_second', 'llm_benchmark_aggregate_tokens_per_second'),
    ('sglang_spec_accept_length', 'llm_benchmark_spec_accept_length'),
):
    value = data.get(key)
    if isinstance(value, (int, float)):
        print(f'{metric}{{profile="{profile}"}} {value}')
