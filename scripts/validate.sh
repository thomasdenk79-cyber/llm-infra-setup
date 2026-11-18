#!/usr/bin/env bash
# Repository-Qualitaetspruefung. Laeuft lokal (make validate) und in CI.
# Kein Punkt hier startet Container oder aendert am Host.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
rc=0

echo '--- Syntax (bash -n) ---'
bash -n scripts/*.sh scripts/lib/*.sh lib/*.sh setup.sh
echo 'bash syntax OK'

echo '--- Stil (shellcheck) ---'
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning scripts/*.sh scripts/lib/*.sh lib/*.sh setup.sh || rc=1
else
  echo 'shellcheck nicht installiert (make install bringt es); uebersprungen.'
fi

echo '--- YAML und JSON ---'
command -v yamllint >/dev/null 2>&1 && yamllint -d relaxed config systemd >/dev/null
if command -v python >/dev/null 2>&1; then
  python - <<'PY'
import json, pathlib, re, sys
try:
    import yaml
except ImportError:
    yaml = None
bad = 0
for p in sorted(pathlib.Path('.').rglob('*.json')):
    if '.git' in p.parts or '__pycache__' in p.parts:
        continue
    try:
        json.loads(p.read_text())
    except Exception as exc:
        print(f'JSON FEHLER {p}: {exc}'); bad = 1
if yaml:
    for pattern in ('config/**/*.yml', 'config/**/*.yaml', 'systemd/**/*.yml', 'mkdocs.yml', '.pre-commit-config.yaml'):
        for p in sorted(pathlib.Path('.').glob(pattern)):
            try:
                list(yaml.safe_load_all(p.read_text()))
            except Exception as exc:
                print(f'YAML FEHLER {p}: {exc}'); bad = 1
    print('YAML/JSON OK')
else:
    print('pyyaml fehlt - YAML-Inhalt nicht gepruft')
sys.exit(bad)
PY
fi

echo '--- Python-Syntax ---'
python -m py_compile scripts/benchmark_probe.py tui/llmctl.py
echo 'python OK'

echo '--- Quadlet-Struktur ---'
python - <<'PY'
import pathlib, sys
allowed_container = {'Unit', 'Container', 'Service', 'Install', 'X-Container'}
allowed_network = {'Unit', 'Network'}
bad = 0
for p in sorted(pathlib.Path('quadlet').iterdir()):
    sections = [line.strip() for line in p.read_text().splitlines() if line.startswith('[')]
    wanted = allowed_network if p.suffix == '.network' else allowed_container
    for s in sections:
        name = s.strip('[]')
        if name not in wanted:
            print(f'QUADLET FEHLER {p}: unbekannte Sektion [{name}]'); bad = 1
    if p.suffix == '.container' and 'Image=' not in p.read_text():
        print(f'QUADLET FEHLER {p}: Image fehlt'); bad = 1
import yaml, re as _re
# Bildpin-Dreieck: fuer jedes registancezeigte Image=<name>:<tag> in quadlet/
# muss das Tag in versions.lock als eigenes Token auftauchen (Befund der
# Review-Welle 2026-11-18: einseitige Tag-Erhohungen durften durchlaufen).
# Eigengebaute localhost/-Bilder sind ausgenommen (kein Registry-Pin moeglich).
lock = pathlib.Path('versions.lock').read_text()
for p in sorted(pathlib.Path('quadlet').iterdir()):
    if p.suffix != '.container':
        continue
    for zeile in p.read_text().splitlines():
        if not zeile.startswith('Image='):
            continue
        ref = zeile.split('=', 1)[1].split('@')[0]
        name, _, tag = ref.rpartition(':')
        if name.startswith('localhost/') or '@' in zeile:
            continue
        tag_n = tag[1:] if tag.startswith('v') else tag
        if not any(_re.search(r'(?<![\d.])' + _re.escape(v) + r'(?![\d.])', lock) for v in (tag, tag_n)):
            print(f'LOCK FEHLER {p}: Tag {tag} von {name} nicht in versions.lock'); bad = 1
# Homepage: layout-Schluessel und service-Gruppen muessen deckungsgleich sein
# (die in settings.yaml versprochene Pruefung existierte bisher nicht).
try:
    services = yaml.safe_load(open('config/homepage/services.yaml'))
    settings = yaml.safe_load(open('config/homepage/settings.yaml'))
    gruppen = set()
    # services.yaml ist eine Liste von Gruppenobjekten (Schluessel = Gruppenname)
    eintraege = services.get('services', []) if isinstance(services, dict) else services
    for eintrag in eintraege:
        if isinstance(eintrag, dict):
            gruppen.update(eintrag.keys())
    layout = set((settings.get('layout') or {}).keys())
    for fehl in sorted(gruppen - layout):
        print(f'HOMEPAGE FEHLER: Gruppe {fehl!r} fehlt im layout von settings.yaml'); bad = 1
    for verwaist in sorted(layout - gruppen):
        print(f'HOMEPAGE FEHLER: layout-Schluessel {verwaist!r} ohne Gruppe in services.yaml'); bad = 1
except FileNotFoundError:
    pass
sys.exit(bad)
PY

echo '--- Geheimnisse ---'
if rg -n --hidden -g '!state/**' -g '!.git/**' -g '!setup_prompt.md' -g '!.omo-work/**' \
   '(hf_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|BEGIN (OPENSSH|RSA|EC) PRIVATE KEY)' .; then
  echo 'MOEGLICHES GEHEIMNIS gefunden (siehe Zeilen oben).' >&2
  rc=1
else
  echo 'keine Muster fuer Geheimnisse im Repo'
fi
# Die alten Standard-Passwoerter duerfen nicht mehr in versionierten Dateien stehen.
# Ausgenommen sind nur die beiden Pruefskripte selbst, die diese Werte suchen.
if rg -n --hidden -g '!.git/**' -g '!state/**' -g '!docs/**' -g '!README.md' -g '!setup_prompt.md' \
   -g '!.omo-work/**' \
   -g '!scripts/validate.sh' -g '!scripts/doctor.sh' -g '!CHANGELOG.md' \
   'sk-llm-infra-local|llm-infra-salt|llm-infra-webui-local|POSTGRES_PASSWORD=llm-infra$' .; then
  echo 'SCHWACHES STANDARD-PASSWORT in versionierter Datei gefunden.' >&2
  echo 'Abhilfe: ./scripts/rotate-secrets.sh' >&2
  rc=1
else
  echo 'keine alten Standard-Passwoerter im Code'
fi

echo '--- Pflichtdateien ---'
for required in AGENTS.md README.md CHANGELOG.md versions.lock mkdocs.yml docs/adr lib/common.sh lib/units.sh lib/secrets.sh docs/performance.md docs/COMPLIANCE.md; do
  [[ -e "${required}" ]] || { echo "FEHLT: ${required}" >&2; rc=1; }
done

echo '--- Prometheus-Konfiguration ---'
if command -v promtool >/dev/null 2>&1; then
  promtool check rules config/monitoring/alerts.yml || rc=1
  tmpcfg="$(mktemp --suffix=.yml)"
  sed "s#/etc/prometheus/conf/#${root}/config/monitoring/#" config/monitoring/prometheus.yml > "${tmpcfg}"
  promtool check config "${tmpcfg}" || rc=1
  rm -f "${tmpcfg}"
elif command -v podman >/dev/null 2>&1 && \
     [[ "$(podman ps --format '{{.Names}}' 2>/dev/null || true)" == *systemd-prometheus* ]]; then
  # promtool ist nicht installiert, aber der laufende Prometheus-Container hat es
  # und prueft damit exakt die Dateien, die er auch benutzt.
  podman exec --user 0 systemd-prometheus promtool check rules /etc/prometheus/conf/alerts.yml || rc=1
  podman exec --user 0 systemd-prometheus promtool check config /etc/prometheus/conf/prometheus.yml || rc=1
else
  echo 'weder promtool noch ein laufender Prometheus-Container vorhanden; nur YAML-Pruefung.'
fi

echo '--- Grafana-Dashboards ---'
python3 - <<'PY'
import json, pathlib, sys
bad = 0
for p in sorted(pathlib.Path('config/monitoring/grafana/provisioning/dashboards').glob('*.json')):
    try:
        d = json.loads(p.read_text())
    except Exception as exc:
        print(f'DASHBOARD FEHLER {p}: {exc}'); bad = 1; continue
    if not d.get('panels'):
        print(f'DASHBOARD FEHLER {p}: keine Panels'); bad = 1
    if not d.get('uid'):
        print(f'DASHBOARD FEHLER {p}: uid fehlt (Provisioning braucht uid)'); bad = 1
    for panel in d.get('panels', []):
        if panel.get('type') in ('row', 'text'):
            continue          # Reihen-Ueberschriften und reine Text-Panels (z.B.
                              # Datengrenze-Hinweise) enthalten per Definition keine Anfrage
        if not panel.get('targets'):
            print(f'DASHBOARD FEHLER {p}: Panel ohne Anfrage: {panel.get("title")}'); bad = 1
print(f'{len(list(pathlib.Path("config/monitoring/grafana/provisioning/dashboards").glob("*.json")))} Dashboards geprueft')
sys.exit(bad)
PY

# Digester contra Bestand: jedes *_image mit passendem *_image_digest muss
# den Digest in den RepoDigests des lokalen Bildes haben (Config-Ids als Pin
# waren in zwei Reviews Befund; Manifest-Digeste sind das Pull-Ziel).
if command -v podman >/dev/null 2>&1; then
  while read -r base image; do
    dig="$(awk -F': ' -v f="${base}_image_digest" '$1==f{gsub(/ /,"",$2); print $2; exit}' versions.lock)"
    [[ -z "${dig}" || "${image}" == localhost/* ]] && continue
    rd="$(podman image inspect "${image%%@*}" --format '{{range .RepoDigests}}{{.}} {{end}}' 2>/dev/null || true)"
    if [[ -n "${rd}" && "${rd}" != *"${dig}"* ]]; then
      echo "FEHLER: ${base}_image_digest ${dig} ist kein RepoDigest von ${image} (Bestand: ${rd})" >&2
      rc=1
    fi
  done < <(awk -F': ' '/^[a-z0-9_]+_image: /{print $1, $2}' versions.lock)
fi

echo
if (( rc == 0 )); then
  echo 'Repository-Pruefung: OK'
else
  echo 'Repository-Pruefung: FEHLER (siehe Meldungen oben)' >&2
fi
exit "${rc}"
