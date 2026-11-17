#!/usr/bin/env python3
"""Build the colleague-facing, local-only Windows setup archive."""

from __future__ import annotations

import hashlib
import base64
import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "handover" / "windows-local-llm"
OUTPUT = ROOT / "config" / "proxy" / "site" / "anleitung" / "anleitung.zip"
EXPECTED_SHA256 = "6AC744AE120E66FE258AFA5CD268F142E8C390924860BBED77969B5C2D883109"
FILES = (
    "README.md",
    "Install-LocalLlm.ps1",
    "Run-OpenCode-Local.ps1",
    "Run-Copilot-Local.ps1",
    "Set-LocalRoutes.ps1",
    "opencode-local.cmd",
    "copilot-local.cmd",
    "caddy-local-authority-root.crt",
)


def main() -> None:
    cert_path = SOURCE / "caddy-local-authority-root.crt"
    pem = cert_path.read_text(encoding="ascii")
    match = re.search(
        r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", pem, re.S
    )
    if not match:
        raise SystemExit("Caddy-Root ist kein PEM-Zertifikat")
    der = base64.b64decode(re.sub(r"\s", "", match.group(1)))
    fingerprint = hashlib.sha256(der).hexdigest().upper()
    if fingerprint != EXPECTED_SHA256:
        raise SystemExit(f"Caddy-Root Fingerprint stimmt nicht: {fingerprint}")
    missing = [name for name in FILES if not (SOURCE / name).is_file()]
    if missing:
        raise SystemExit("Paketdatei(en) fehlen: " + ", ".join(missing))

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUTPUT, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in FILES:
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, (SOURCE / name).read_bytes())
    with zipfile.ZipFile(OUTPUT) as archive:
        bad = archive.testzip()
        if bad:
            raise SystemExit(f"ZIP-Pruefung fehlgeschlagen bei {bad}")
        if set(archive.namelist()) != set(FILES):
            raise SystemExit("Unerwarteter Inhalt im ZIP")
    print(f"Windows-Paket erstellt: {OUTPUT.relative_to(ROOT)} ({OUTPUT.stat().st_size} Bytes)")


if __name__ == "__main__":
    main()
