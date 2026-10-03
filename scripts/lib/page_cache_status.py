#!/usr/bin/env python3
"""Zeigt, wie viel einer Datei im Seitenspeicher des Rechners liegt.

Benutzt den mincore-Aufruf der C-Bibliothek (nur Standardbibliothek noetig).
Umgebungsvariable PLE_DIR zeigt auf den Ordner mit den *.safetensors-Dateien.

  ./scripts/ple-preload.sh --status
"""
from __future__ import annotations

import ctypes
import ctypes.util
import os
import pathlib
import sys

PROT_READ = 0x1
MAP_PRIVATE = 0x02
PAGE = os.sysconf('SC_PAGE_SIZE')

libc = ctypes.CDLL(ctypes.util.find_library('c') or 'libc.so.6', use_errno=True)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int,
                      ctypes.c_int, ctypes.c_long]
libc.munmap.restype = ctypes.c_int
libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
libc.mincore.restype = ctypes.c_int
libc.mincore.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p]


def resident_fraction(path: pathlib.Path) -> float | None:
    """Anteil der Datei in Seiten (0.0 bis 1.0), oder None bei Fehler."""
    size = path.stat().st_size
    if size < PAGE:
        return None
    with open(path, 'rb') as handle:
        addr = libc.mmap(None, size, PROT_READ, MAP_PRIVATE, handle.fileno(), 0)
        if addr in (None, ctypes.c_void_p(-1).value):
            return None
        try:
            vector = ctypes.create_string_buffer((size + PAGE - 1) // PAGE)
            if libc.mincore(addr, size, vector) != 0:
                return None
            return sum(1 for byte in bytes(vector.raw) if byte & 1) * PAGE / size
        finally:
            libc.munmap(addr, size)


def main() -> int:
    directory = pathlib.Path(os.environ.get('PLE_DIR', '.'))
    candidates = sorted(set(directory.glob('*.safetensors')) | set(directory.glob('ple/*.bin')))
    files = [p for p in candidates if p.is_symlink() or p.is_file()]
    if not files:
        print(f'keine Tabellendateien in {directory}')
        return 1
    total_bytes = resident_bytes = 0
    links = sum(1 for p in files if p.is_symlink())
    print(f'Ordner: {directory}')
    if links:
        print(f'  Hinweis: {links} Eintraege sind Verweise auf /models (die bestehen nur im')
        print(f'           Container); sie belegen hier keinen Speicher und werden uebersprungen.')
    files = [p for p in files if not p.is_symlink()]
    for path in files:
        size = path.lstat().st_size
        fraction = resident_fraction(path)
        if fraction is None:
            print(f'  {path.name:40} {size / 2**30:6.2f} GiB  (nicht pruefbar)')
            continue
        total_bytes += size
        resident_bytes += int(size * fraction)
        print(f'  {path.name:40} {size / 2**30:6.2f} GiB  im Speicher: {fraction * 100:5.1f} %')
    if total_bytes:
        overall = 100 * resident_bytes / total_bytes
        print(f'Gesamt {total_bytes / 2**30:.1f} GiB, davon im Seitenspeicher: {overall:.1f} %')
        if overall < 50:
            print('Tipp: ./scripts/ple-preload.sh  (einmal durchlesen, damit die erste Anfrage nicht von der SSD startet)')
        return 0
    return 1


if __name__ == '__main__':
    sys.exit(main())
