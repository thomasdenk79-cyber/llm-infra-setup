#!/usr/bin/env python3
"""Legt opencode so ein, dass es den Gateway lokal und ueber den Tunnel nutzt."""

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SECRETS = Path(os.environ.get("LLM_INFRA_SECRETS_DIR", os.path.expanduser("~/.config/llm-infra")))
SCHLUESSELDATEI = SECRETS / "gateway-proxy" / "opencode.key"
CA_DATEI = SECRETS / "gateway-proxy" / "caddy-root-ca.pem"
STORE = SECRETS / "gateway-proxy" / "issued-keys.txt"
OPENCODE_CONFIG = Path(os.path.expanduser("~/.config/opencode/opencode.jsonc"))
GATEWAY_LOKAL = "http://127.0.0.1:4000/v1"


def log(text):
    print("[{}] {}".format(datetime.datetime.now().astimezone().isoformat(timespec="seconds"), text))


def die(text):
    log("FEHLER: " + text)
    sys.exit(1)


def hole_ca():
    """Holt das Root-Zertifikat der Caddy-Internen-CA vom Gateway-Rechner."""
    proxy_env = REPO / "config" / "gateway-proxy.env"
    if not proxy_env.is_file():
        die("Fehlt: config/gateway-proxy.env - naechster Befehl: cp config/gateway-proxy.env.example config/gateway-proxy.env")
    werte = dict(re.findall(r"^([A-Z_]+)=(.*)$", proxy_env.read_text(), re.M))
    dns = werte.get("GATEWAY_DNS_NAME", "").strip()
    benutzer = werte.get("GATEWAY_VM_USER", "azureuser").strip()
    schluessel = werte.get("GATEWAY_BOOTSTRAP_KEY", "%h/.ssh/id_ed25519").replace("%h", os.path.expanduser("~"))
    if not dns:
        die("GATEWAY_DNS_NAME ist in config/gateway-proxy.env nicht gesetzt")
    known_hosts = Path(os.path.expanduser("~/.local/share/llm-infra/ssh/gateway-known_hosts"))
    known_hosts.parent.mkdir(parents=True, exist_ok=True)
    befehl = [
        "ssh", "-i", schluessel, "-o", "BatchMode=yes", "-o", "ConnectTimeout=12",
        "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=" + str(known_hosts),
        benutzer + "@" + dns,
        "sudo cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt 2>/dev/null "
        "|| cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt 2>/dev/null",
    ]
    ergebnis = subprocess.run(befehl, capture_output=True, text=True)
    if "BEGIN CERTIFICATE" not in ergebnis.stdout:
        die("Root-Zertifikat des Gateways nicht bekommen: " + (ergebnis.stderr.strip()[:200] or "leere Antwort"))
    CA_DATEI.parent.mkdir(parents=True, exist_ok=True)
    CA_DATEI.write_text(ergebnis.stdout.strip() + "\n")
    os.chmod(CA_DATEI, 0o644)
    log("Gateway-CA gespeichert: " + str(CA_DATEI))


def schluessel_fuer(person):
    if not STORE.is_file():
        die("Fehlt: " + str(STORE) + " - naechster Befehl: ./scripts/71-gateway-keys.sh --issue " + person)
    for zeile in STORE.read_text().splitlines():
        teile = zeile.split("\t")
        if len(teile) >= 3 and teile[0] == person:
            return teile[2]
    die("Kein Schluessel fuer " + person + " in " + str(STORE) + " - naechster Befehl: ./scripts/71-gateway-keys.sh --issue " + person)


def eintrag(anzeigen, base_url):
    return {
        "name": anzeigen,
        "npm": "@ai-sdk/openai-compatible",
        "options": {
            "baseURL": base_url,
            "apiKey": "{file:" + str(SCHLUESSELDATEI) + "}",
        },
        "models": {
            modell: {"name": modell, "limit": {"context": 131072, "output": 8192}}
            for modell in ("standard-balanced", "standard-efficient", "standard-intelligent", "qwen3.8-flash-next")
        },
    }


def ca_im_systemtrust():
    """Prueft, ob die Gateway-CA im Systemtrust liegt (ohne sie lehnt opencode
    die selbstausgestellte Kette ab; Bun beruecksichtigt NODE_EXTRA_CA_CERTS nicht)."""
    if not CA_DATEI.is_file():
        return False
    ergebnis = subprocess.run(["trust", "list", "--filter=ca-anchors"], capture_output=True, text=True)
    return "Caddy Local Authority" in ergebnis.stdout


def main():
    parser = argparse.ArgumentParser(description="opencode an den LLM-Gateway anbinden")
    parser.add_argument("--person", default="owner", help="Name aus issued-keys.txt (Standard: owner)")
    parser.add_argument("--check", action="store_true", help="nur pruefen, nichts schreiben")
    parser.add_argument("--ohne-ca", action="store_true", help="Gateway-CA nicht holen")
    parser.add_argument("--ca-import", action="store_true",
                        help="Gateway-CA in den Systemtrust aufnehmen (sudo trust anchor)")
    args = parser.parse_args()

    if not OPENCODE_CONFIG.is_file():
        die("Fehlt: " + str(OPENCODE_CONFIG) + " - opencode ist nicht eingerichtet")
    try:
        konfig = json.loads(OPENCODE_CONFIG.read_text())
    except json.JSONDecodeError as fehler:
        die("opencode.jsonc ist kein lesbares JSON (" + str(fehler) + ") - vorlage: config/opencode.jsonc.example")

    schluessel = schluessel_fuer(args.person)
    dns = ""
    proxy_env = REPO / "config" / "gateway-proxy.env"
    if proxy_env.is_file():
        treffer = re.search(r"^GATEWAY_DNS_NAME=(.*)$", proxy_env.read_text(), re.M)
        dns = treffer.group(1).strip() if treffer else ""

    provider = konfig.setdefault("provider", {})
    geplant = {
        "luni-gateway": eintrag("Luni Gateway (lokal)", GATEWAY_LOKAL),
    }
    if dns:
        geplant["luni-oeffentlich"] = eintrag("Luni Gateway (oeffentlich)",
                                              "https://" + dns + "/v1")

    if args.check:
        for name, wert in geplant.items():
            ist = provider.get(name)
            status = "OK" if ist == wert else "ANDERS"
            print("{:7s} {:16s} {}".format(status, name, wert["options"]["baseURL"]))
        print("Schluesseldatei: {} {}".format(SCHLUESSELDATEI, "vorhanden" if SCHLUESSELDATEI.is_file() else "fehlt"))
        print("Gateway-CA     : {} {}".format(CA_DATEI, "vorhanden" if CA_DATEI.is_file() else "fehlt"))
        print("Systemtrust    : {}".format("verankert" if ca_im_systemtrust() else "NICHT verankert (sudo trust anchor --store ...)"))
        return 0

    SCHLUESSELDATEI.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(SCHLUESSELDATEI.parent, 0o700)
    SCHLUESSELDATEI.write_text(schluessel + "\n")
    os.chmod(SCHLUESSELDATEI, 0o600)
    log("Schluessel fuer {} abgelegt: {} (0600)".format(args.person, SCHLUESSELDATEI))

    if not args.ohne_ca and (not CA_DATEI.is_file()):
        hole_ca()
    if args.ca_import and not ca_im_systemtrust():
        ergebnis = subprocess.run(["sudo", "trust", "anchor", "--store", str(CA_DATEI)], capture_output=True, text=True)
        if ergebnis.returncode != 0:
            die("CA konnte nicht in den Systemtrust: " + (ergebnis.stderr.strip()[:200] or "unbekannter Fehler"))
        subprocess.run(["sudo", "update-ca-trust"], capture_output=True, text=True)
        log("Gateway-CA im Systemtrust verankert (entfernen: sudo trust anchor --remove " + str(CA_DATEI) + ")")

    sicherung = OPENCODE_CONFIG.with_name(OPENCODE_CONFIG.name + ".bak-gateway-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(OPENCODE_CONFIG, sicherung)
    log("Sicherung: " + str(sicherung))

    unveraendert = True
    for name, wert in geplant.items():
        if provider.get(name) != wert:
            provider[name] = wert
            unveraendert = False
    if unveraendert:
        log("opencode.jsonc ist bereits aktuell")
        return 0
    OPENCODE_CONFIG.write_text(json.dumps(konfig, indent=2, ensure_ascii=False) + "\n")
    log("opencode.jsonc aktualisiert: " + ", ".join(geplant))
    print("Naechste Befehle")
    print("  lokal:       opencode run -m luni-gateway/standard-balanced 'Antworte nur mit JA'")
    if dns:
        if ca_im_systemtrust():
            print("  oeffentlich: opencode run -m luni-oeffentlich/standard-balanced 'Antworte nur mit JA'")
        else:
            print("  oeffentlich einmal freigeben (sudo, nur dieser Rechner):")
            print("    ./scripts/72-setup-opencode.py --ca-import")
            print("    opencode run -m luni-oeffentlich/standard-balanced 'Antworte nur mit JA'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
