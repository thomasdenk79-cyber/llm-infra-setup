#!/usr/bin/env python3
"""NVMe-/Festplatten-SMART-Werte als Prometheus-Messwerte.

stdin: JSON von 'smartctl --json=c -a'   Umgebungsvariable: SMART_DEV
"""
import json
import os
import sys

data = json.load(sys.stdin)
dev = os.environ.get('SMART_DEV', 'unknown')
nv = data.get('nvme_smart_health_information_log') or {}
abstract = data.get('abstract') or {}
temp = (abstract.get('temp') or {}).get('current')
if isinstance(temp, (int, float)):
    print(f'llm_smart_temperature_celsius{{device="{dev}"}} {temp}')
print(f'llm_smart_status_ok{{device="{dev}"}} {1 if (data.get("smart_status") or {}).get("passed") else 0}')
print(f'llm_smart_percentage_used{{device="{dev}"}} {abstract.get("percentage_used") or nv.get("percentage_used") or 0}')
print(f'llm_smart_available_spare{{device="{dev}"}} {abstract.get("available_ata_spare") or nv.get("available_spare") or 0}')
print(f'llm_smart_critical_warning{{device="{dev}"}} {nv.get("critical_warning") or 0}')
print(f'llm_smart_media_errors{{device="{dev}"}} {nv.get("media_errors") or 0}')
print(f'llm_smart_unsafe_shutdowns{{device="{dev}"}} {nv.get("unsafe_shutdowns") or 0}')
print(f'llm_smart_data_written_bytes{{device="{dev}"}} {int((nv.get("data_units_written") or 0) * 1000000)}')
print(f'llm_smart_data_read_bytes{{device="{dev}"}} {int((nv.get("data_units_read") or 0) * 1000000)}')
