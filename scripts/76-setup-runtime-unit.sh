#!/usr/bin/env bash
# Baut die Unit fuer die Inferenz-Laufzeit, die auf diesem Rechner wirklich laeuft.
#
#   ./scripts/76-setup-runtime-unit.sh                      Unit aus dem Spec erzeugen
#   ./scripts/76-setup-runtime-unit.sh --check              vergleichen, nichts schreiben
#   ./scripts/76-setup-runtime-unit.sh --import-from-container NAME
#                                                           Spec aus dem laufenden Container uebernehmen
#
# Warum zwei Schritte: `make drift` laeuft die Generatoren in einer weggeworfenen
# Arbeitskopfe ohne laufenden Container. Der Generator darf deshalb nur eine
# versionierte Datei lesen - `config/runtime/flash-next.spec`. Die Aufnahme aus dem
# Container ist ein ausdruecklicher, einmaliger Schritt des Betreibers; ohne ihn
# stünden in der Unit geratene Standards, und das Modell wuerde nach einem Neustart
# mit anderen Schaltern laufen als vor dem Neustart.
#
# Sicherheit: die Aufnahme legt zusaetzlich state/runtime-restore-<name>.sh an -
# ein lauffaehiges `podman run` mit genau dem Zustand des Containers. Damit ist der
# Weg zurueck frei, falls die Unit sich nicht bewaehrt. Zugangswerte landen nie im
# Repo: Variablen mit secret-aehnlichem Namen gehen nach
# ~/.config/llm-infra/runtime-<name>.env (0600), der Rest in den Spec.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"

name="${RUNTIME_CONTAINER_NAME:-flash-next}"
spec="${root}/config/runtime/${name}.spec"
unit="${root}/quadlet/${name}.container"
container="${RUNTIME_CONTAINER:-flash-next-v3}"

mode=generate
for a in "$@"; do
  case "$a" in
    --check) mode=check ;;
    --import-from-container) mode=import ;;
    --*) die "unbekannte Option: $a" ;;
    *) container="$a" ;;
  esac
done

# -----------------------------------------------------------------------------
# Aufnahme: Ist-Zustand des Containers -> versionierter Spec
# -----------------------------------------------------------------------------
if [[ "${mode}" == 'import' ]]; then
  command -v podman >/dev/null 2>&1 || die 'podman fehlt.'
  podman inspect "${container}" >/dev/null 2>&1 \
    || die "Container ${container} existiert nicht. Naechster Befehl: podman ps --format '{{.Names}}'"
  install -d -m 0755 "${root}/config/runtime" "${root}/state"

  RUNTIME_NAME="${name}" SRC_CONTAINER="${container}" SPEC_OUT="${spec}" \
  RESTORE_OUT="${root}/state/runtime-restore-${container}.sh" \
  SECRETS_OUT="${SECRETS_DIR}/runtime-${name}.env" python3 <<'PY'
import json, os, re, shlex, subprocess, sys

name = os.environ['RUNTIME_NAME']
src = os.environ['SRC_CONTAINER']
spec_out = os.environ['SPEC_OUT']
restore_out = os.environ['RESTORE_OUT']
secrets_out = os.environ['SECRETS_OUT']

d = json.loads(subprocess.run(['podman', 'inspect', src], capture_output=True, text=True,
                              check=True).stdout)[0]
hc, cfg = d['HostConfig'], d['Config']
image = cfg.get('Image') or d.get('Image')

# Env des Bildes: was schon das Bild mitbringt, hoert nicht in die Unit.
bild = subprocess.run(['podman', 'image', 'inspect', image, '--format',
                       '{{range .Config.Env}}{{println .}}{{end}}'],
                      capture_output=True, text=True, check=True).stdout
bild_namen = {z.split('=', 1)[0] for z in bild.splitlines() if '=' in z}

# Vom Container-Eigner gesetzte Variablen; podman-eigene Ueberschreiben wir.
ueberspringen = {'HOME', 'HOSTNAME', 'container', 'PATH', 'PWD', 'TERM', 'LANG', 'LC_ALL'}
geheim = re.compile(r'(^|_)(API_?KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|AUTH)($|_)', re.I)
umgebung, geheimnisse = [], []
for eintrag in cfg.get('Env') or []:
    if '=' not in eintrag:
        continue
    k, v = eintrag.split('=', 1)
    if k in ueberspringen or k in bild_namen:
        continue
    (geheimnisse if geheim.search(k) else umgebung).append((k, v))

zeilen = [
    '# GENERIERT von scripts/76-setup-runtime-unit.sh --import-from-container {}'.format(src),
    '# Massgeblich ist diese Datei, nicht die Unit-Datei: sie beschreibt die Laufzeit,',
    '# mit der der Rechner wirklich arbeitet. Neu aufnehmen nach einer absichtlichen',
    '# Aenderung am Container, danach ./scripts/76-setup-runtime-unit.sh und make drift.',
    'IMAGE={}'.format(image),
    'CONTAINER_NAME={}'.format(src),
    'NETWORK={}'.format(hc.get('NetworkMode') or 'pasta'),
    'IPC_MODE={}'.format(hc.get('IpcMode') or 'shareable'),
    'SHM_SIZE={}'.format(int(int(hc.get('ShmSize') or 0) / (1024 ** 3))),
    'WORKING_DIR={}'.format(cfg.get('WorkingDir') or '/workspace'),
    'ENTRYPOINT={}'.format(' '.join(shlex.quote(x) for x in (cfg.get('Entrypoint') or []))),
    'STOP_SIGNAL={}'.format(cfg.get('StopSignal') or 'SIGTERM'),
]
for b in hc.get('PortBindings') or {}:
    for t in (hc['PortBindings'][b] or []):
        host_ip, host_port, container_port = t.get('HostIp') or '127.0.0.1', t.get('HostPort'), b.split('/')[0]
        zeilen.append('PUBLISH={}:{}:{}'.format(host_ip, host_port, container_port))
for dev in hc.get('Devices') or []:
    zeilen.append('ADD_DEVICE={}'.format(dev['PathOnHost']))
for bind in hc.get('Binds') or []:
    quelle, ziel = bind.split(':', 2)[:2]
    zeilen.append('VOLUME={}:{}'.format(quelle, ziel))
for ul in hc.get('Ulimits') or []:
    kern = ul['Name'].replace('RLIMIT_', '').lower()
    zeilen.append('ULIMIT={}:{}:{}'.format(kern, ul['Soft'], ul['Hard']))
for so in hc.get('SecurityOpt') or []:
    if so not in ('label=disable',):
        zeilen.append('SECURITY_OPT={}'.format(so))
for k, v in sorted(umgebung):
    zeilen.append('ENV={}={}'.format(k, v))
for arg in cfg.get('Cmd') or []:
    zeilen.append('EXEC_ARG={}'.format(arg))

with open(spec_out, 'w', encoding='utf-8') as fh:
    fh.write('\n'.join(zeilen) + '\n')
os.chmod(spec_out, 0o644)

# Zugangswerte bleiben ausserhalb von Git.
if geheimnisse:
    os.makedirs(os.path.dirname(secrets_out), exist_ok=True)
    with open(secrets_out, 'w', encoding='utf-8') as fh:
        for k, v in sorted(geheimnisse):
            fh.write('{}={}\n'.format(k, shlex.quote(v)))
    os.chmod(secrets_out, 0o600)

# Rueckweg: ein lauffaehiger Aufruf mit genau dem aufgenommenen Zustand.
cmd = ['podman', 'run', '--name', src, '-d', '--restart', 'no',
       '--network', hc.get('NetworkMode') or 'pasta',
       '--ipc', hc.get('IpcMode') or 'shareable',
       '--shm-size', '{}g'.format(int(int(hc.get('ShmSize') or 0) / (1024 ** 3))),
       '--workdir', cfg.get('WorkingDir') or '/workspace']
for b in hc.get('PortBindings') or {}:
    for t in (hc['PortBindings'][b] or []):
        cmd += ['-p', '{}:{}:{}'.format(t.get('HostIp') or '127.0.0.1', t['HostPort'], b.split('/')[0])]
for dev in hc.get('Devices') or []:
    cmd += ['--device', dev['PathOnHost']]
for bind in hc.get('Binds') or []:
    cmd += ['-v', bind]
for ul in hc.get('Ulimits') or []:
    cmd += ['--ulimit', '{}={}:{}'.format(ul['Name'].replace('RLIMIT_', '').lower(), ul['Soft'], ul['Hard'])]
for so in hc.get('SecurityOpt') or []:
    cmd += ['--security-opt', so]
for k, v in sorted(umgebung + geheimnisse):
    cmd += ['-e', '{}={}'.format(k, v)]
entry = cfg.get('Entrypoint') or []
cmd += ['--entrypoint', entry[0]] if entry else []
cmd.append(image)
cmd += cfg.get('Cmd') or []
with open(restore_out, 'w', encoding='utf-8') as fh:
    fh.write('#!/usr/bin/env bash\n'
             '# Rueckweg nach scripts/76-setup-runtime-unit.sh --import-from-container {}\n'
             '# Legt den Container genau so an, wie er zum Aufnahmezeitpunkt lief.\n'
             'set -Eeuo pipefail\n'.format(src))
    fh.write(' '.join(shlex.quote(x) for x in cmd) + '\n')
os.chmod(restore_out, 0o700)

print('Spec geschrieben: {} ({} Zeilen)'.format(spec_out, len(zeilen)))
print('Rueckweg gelegt: {} (Ausfuehren bringt den alten Zustand zurueck)'.format(restore_out))
if geheimnisse:
    print('Zugangswerte separat (0600, nicht in Git): {} mit {} Eintraegen'.format(secrets_out, len(geheimnisse)))
else:
    print('Keine secret-aehnlichen Umgebungsvariablen gefunden.')
print('Variablen uebernommen: {}'.format(len(umgebung)))
PY

  exit 0
fi

# -----------------------------------------------------------------------------
# Generator: versionierter Spec -> Quadlet-Datei
# -----------------------------------------------------------------------------
# Ohne Spec ist nichts gewonnen: geraten wird hier nicht. In der Drift-Pruefung ist
# ein fehlender Spec allerdings kein Fehler, sondern "nichts zu vergleichen" - dort
# wird uebersprungen, im Betrieb bricht das Skript ab und nennt den Aufnahmeschritt.
if [[ ! -f "${spec}" ]]; then
  if [[ "${LLM_DRIFT:-0}" == 1 ]]; then
    log "Spec fehlt (${spec}) - in der Drift-Pruefung uebersprungen."
    exit 0
  fi
  die "Spec fehlt: ${spec}. Einmal aufnehmen mit: ./scripts/76-setup-runtime-unit.sh --import-from-container ${container}"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

RUNTIME_NAME="${name}" SPEC_IN="${spec}" UNIT_OUT="${tmp}/${name}.container" \
SECRETS_ENV="${SECRETS_DIR}/runtime-${name}.env" python3 <<'PY'
import os

spec_in = os.environ['SPEC_IN']
unit_out = os.environ['UNIT_OUT']
name = os.environ['RUNTIME_NAME']
secrets_env = os.environ['SECRETS_ENV']

werte = {}
listen = {}
with open(spec_in, encoding='utf-8') as fh:
    for zeile in fh:
        zeile = zeile.rstrip('\n')
        if not zeile or zeile.startswith('#') or '=' not in zeile:
            continue
        k, v = zeile.split('=', 1)
        if k in ('ADD_DEVICE', 'VOLUME', 'ULIMIT', 'SECURITY_OPT', 'ENV', 'EXEC_ARG', 'PUBLISH'):
            listen.setdefault(k, []).append(v)
        else:
            werte[k] = v


def zitieren(wert):
    """Systemd/Quadlet-Argument: einfach halten, nur bei Bedarf in einfache Anfuehrung."""
    if wert == '':
        return "''"
    if all(c not in wert for c in ' \t"\'\\$`'):
        return wert
    return "'" + wert.replace("'", "'\\''") + "'"


ZEILEN = []
ZEILEN.append('# GENERIERT von scripts/76-setup-runtime-unit.sh - dort aendern, nicht hier.')
ZEILEN.append('# Massgeblich ist config/runtime/{}.spec; die Datei hier ist dessen Ausgabe.'.format(name))
ZEILEN.append('# Bild, Schalter und Geraete kommen aus der Aufnahme des laufenden Containers,')
ZEILEN.append('# damit die Laufzeit nach einem Neustart exakt so laeuft wie vorher.')
ZEILEN.append('')
ZEILEN.append('[Unit]')
ZEILEN.append('Description=LLM-Inferenz-Laufzeit {} (vLLM, sm120-Schalter aus dem Betreiber-Fork)'.format(name))
ZEILEN.append('After=network-online.target')
ZEILEN.append('Wants=network-online.target')
ZEILEN.append('')
ZEILEN.append('[Container]')
ZEILEN.append('Image={}'.format(werte['IMAGE']))
ZEILEN.append('ContainerName={}'.format(werte.get('CONTAINER_NAME', name)))
ZEILEN.append('Network={}'.format(werte.get('NETWORK', 'pasta')))
for p in listen.get('PUBLISH', []):
    ZEILEN.append('PublishPort={}'.format(p))
for d in listen.get('ADD_DEVICE', []):
    ZEILEN.append('AddDevice={}'.format(d))
for v in listen.get('VOLUME', []):
    ZEILEN.append('Volume={}'.format(v))
ZEILEN.append('ShmSize={}g'.format(werte.get('SHM_SIZE', '16')))
ZEILEN.append('IpcMode={}'.format(werte.get('IPC_MODE', 'shareable')))
ZEILEN.append('WorkingDir={}'.format(werte.get('WORKING_DIR', '/workspace')))
for s in listen.get('SECURITY_OPT', []):
    ZEILEN.append('SecurityOpt={}'.format(s))
for u in listen.get('ULIMIT', []):
    # Quadlet kennt die Form aus podman --ulimit: name=weich:hart.
    kern, weich, hart = u.split(':')
    ZEILEN.append('Ulimit={}={}:{}'.format(kern, weich, hart))
ZEILEN.append('StopSignal={}'.format(werte.get('STOP_SIGNAL', 'SIGTERM')))
for e in listen.get('ENV', []):
    k, _, v = e.partition('=')
    ZEILEN.append('Environment={}={}'.format(k, zitieren(v)))
if os.path.exists(secrets_env):
    ZEILEN.append('EnvironmentFile={}'.format(secrets_env))
if werte.get('ENTRYPOINT'):
    ZEILEN.append('Entrypoint={}'.format(werte['ENTRYPOINT']))
ZEILEN.append('Exec={}'.format(' '.join(zitieren(a) for a in listen.get('EXEC_ARG', []))))
ZEILEN.append('Label=llm-infra.runtime=1')
ZEILEN.append('')
ZEILEN.append('[Service]')
ZEILEN.append('Restart={}'.format(werte.get('RESTART', 'always')))
ZEILEN.append('RestartSec=15')
# vLLM braucht Minuten bis die API antwortet; ein Startlimit wuerde den Versuch
# abbrechen und das Modell waere umsonst geladen.
ZEILEN.append('TimeoutStartSec=infinity')
ZEILEN.append('TimeoutStopSec=180')
ZEILEN.append('')
ZEILEN.append('[Install]')
ZEILEN.append('WantedBy=default.target')
ZEILEN.append('')

with open(unit_out, 'w', encoding='utf-8') as fh:
    fh.write('\n'.join(ZEILEN))
print('Unit erzeugt: {} ({} Zeilen)'.format(unit_out, len(ZEILEN)))
PY

if [[ "${mode}" == 'check' ]]; then
  if cmp -s "${tmp}/${name}.container" "${unit}"; then
    printf 'Unit entspricht dem Spec: %s\n' "${unit}"
  else
    printf 'Unit weicht vom Spec ab: %s\n  Naechster Befehl: ./scripts/76-setup-runtime-unit.sh && make drift\n' "${unit}"
    diff -u "${unit}" "${tmp}/${name}.container" | head -40 || true
    exit 1
  fi
  exit 0
fi

install -m 0644 "${tmp}/${name}.container" "${unit}"
log "Unit geschrieben: ${unit}"
log 'Anwenden: ./scripts/apply-runtime-unit.sh   (prueft zuerst auf laufende Anfragen)'
log "Danach:   systemctl --user start ${name}.service   und   make healthcheck"
