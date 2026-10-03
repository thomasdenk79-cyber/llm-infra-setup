#!/usr/bin/env python3
"""Baut aus rohen Messwertzeilen eine gueltige Prometheus-Textdatei.

Der Textfile-Collector des node_exporter verwirft eine komplette Datei, wenn auch
nur einer Familie die TYPE-Angabe fehlt. Deshalb werden HELP/TYPE-Zeilen hier
automatisch und in richtiger Reihenfolge ergaenzt.

Aufruf:  assemble_textfile.py <rohe-datei>      (Ausgabe nach stdout)
"""
from __future__ import annotations

import re
import sys

SAMPLE = re.compile(r'^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)(?P<labels>\{[^}]*\})?\s+(?P<value>[-+0-9eE.]+|NaN|\+Inf|-Inf)\s*$')


def main() -> int:
    path = sys.argv[1]
    families: dict[str, list[str]] = {}
    order: list[str] = []
    skipped: list[str] = []
    with open(path, encoding='utf-8') as handle:
        for line in handle:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            match = SAMPLE.match(line)
            if not match:
                skipped.append(line)
                continue
            name = match.group('name')
            if name not in families:
                families[name] = []
                order.append(name)
            families[name].append(line)
    if skipped:
        print(f'# Warnung: {len(skipped)} ungueltige Zeilen uebersprungen', file=sys.stderr)
        for line in skipped[:3]:
            print(f'#   {line[:120]}', file=sys.stderr)
    for name in order:
        print(f'# HELP {name} llm-infra Host-Kennzahl (scripts/collect-host-facts.sh)')
        print(f'# TYPE {name} gauge')
        for line in families[name]:
            print(line)
    return 0


if __name__ == '__main__':
    sys.exit(main())
