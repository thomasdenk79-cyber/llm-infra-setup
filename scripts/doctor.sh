#!/usr/bin/env bash
# Gefuehrter Gesundheits- und Einrichtungscheck.
#
#   ./scripts/doctor.sh            alle Pruefpunkte
#   ./scripts/doctor.sh --short    nur die wichtigsten
#
# Ausgabe ist so gebaut, dass ein Betreiber ohne Vorwissen den naechsten Befehl
# abtippen kann: erst was kaputt ist, dann warum, dann der exakte Befehl.
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
# Die Bibliothek setzt -e; fuer eine Diagnose ist das falsch, weil ein einzelner
# nicht vorhandener Wert den gesamten Lauf abbrechen wuerde. Weiter ohne -e.
set +e
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
# Ansprache der Laufzeit (Host, Port, Container, Unit, Image) kommt aus
# lib/units.sh; config/host.env ist vorher eingelesen und bestimmt die Werte.
runtime_identity
: "${LITELLM_PORT:=4000}"
: "${LLM_MODELS_DIR:=/srv/llm/models}"
: "${PLE_STORAGE_MOUNT:=/srv/llm/ple-ext4}"
short=0
[[ "${1:-}" == "--short" ]] && short=1
fails=0; warns=0; checks=0
declare -a hints=()

title() { checks=$((checks+1)); printf '\n\033[1m[%2d] %s\033[0m\n' "${checks}" "$*"; }
good()  { printf '     \033[32mOK\033[0m      %s\n' "$*"; }
note()  { printf '     \033[36mHINWEIS\033[0m  %s\n' "$*"; }
warn()  { warns=$((warns+1)); printf '     \033[33mWARNUNG\033[0m %s\n' "$*"; [[ -n "${2:-}" ]] && { printf '     -> %s\n' "$2"; hints+=("$2"); }; }
bad()   { fails=$((fails+1)); printf '     \033[31mFEHLER\033[0m  %s\n' "$*"; [[ -n "${2:-}" ]] && { printf '     -> als naechstes: %s\n' "$2"; hints+=("$2"); } }

# 1 Konfiguration -------------------------------------------------------------
title 'Lokale Konfiguration'
if [[ -f "${root}/config/host.env" ]]; then
  good 'config/host.env vorhanden'
else
  warn 'config/host.env fehlt; es gelten nur die Defaults aus den Beispielen.' \
       'cp config/host.env.example config/host.env'
fi

# 2 sudo ----------------------------------------------------------------------
title 'Automatisierung (sudo ohne Passwortabfrage)'
if sudo -n true 2>/dev/null; then
  good 'sudo arbeitet ohne Nachfrage (noetig fuer ./setup.sh)'
else
  note 'sudo fragt nach einem Passwort. Gefuehrter Ablauf funktioniert dann nur '
  note 'mit dabei, wenn du die Skripte selbst ausführst (make install, make zfs, ...).'
fi

# 3 GPU -----------------------------------------------------------------------
title 'GPU'
if ! command -v nvidia-smi >/dev/null 2>&1; then
  bad 'nvidia-smi fehlt.' 'make nvidia-driver   (danach Neustart, dann ./setup.sh erneut)'
elif ! nvidia-smi -L >/dev/null 2>&1; then
  bad 'Treiber installiert, aber keine GPU erreichbar.' 'GPU anstecken und neu starten; danach make podman'
else
  good "$(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null)"
  mem_used="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null)"
  mem_tot="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null)"
  if [[ -n "${mem_used}" && -n "${mem_tot}" ]] && (( mem_used * 100 / mem_tot > 97 )); then
    warn 'VRAM ist zu >97 % belegt; neue Anfragen können fehlschlagen.' 'make bench und GPU-Dashboard beobachten'
  fi
  if [[ "${short}" == 0 ]]; then
    for d in /sys/bus/pci/devices/*; do
      [[ -f "${d}/vendor" ]] && grep -q 0x10de "${d}/vendor" 2>/dev/null || continue
      # nur die Grafikkarte (Klasse 0x0302), nicht deren Audio-/USB-Funktionen
      grep -q '^0x03' "${d}/class" 2>/dev/null || continue   # Klasse 0x03 = Grafikkarte
      w="$(cat "${d}/current_link_width" 2>/dev/null || echo 0)"
      ws="$(cat "${d}/current_link_speed" 2>/dev/null || echo 0)"
      mw="$(cat "${d}/max_link_width" 2>/dev/null || echo 0)"
      mws="$(cat "${d}/max_link_speed" 2>/dev/null || echo 0)"
      if (( w < mw || ws+0 < mws+0 )); then
        note "GPU haengt an ${ws} x${w} statt ${mws} x${mw} (Thunderbolt-Breuecke)."
        note 'Nachgemessen ist das NICHT die Schreibraten-Grenze: waehrend des'
        note 'Schreibens fließen darueber nur 3-25 MB/s. Erwaehnt, weil eine'
        note 'direkte x16-Schacht den Vorlesedatenweg der Tabellen verbessert.'
        note 'Einordnung: docs/performance.md'
      else
        good "PCIe-Anbindung voll (${ws} x${w})"
      fi
    done
  fi
fi

# 4 CDI -----------------------------------------------------------------------
title 'GPU-fuer-Container (CDI)'
if [[ -f /etc/cdi/nvidia.yaml ]]; then
  age=$(( $(date +%s) - $(stat -c %Y /etc/cdi/nvidia.yaml 2>/dev/null || echo "$(date +%s)") ))
  if (( age > 86400 )); then
    warn "CDI-Beschreibung ist $(( age / 3600 )) h alt; nach Treiber- oder Hardwareaenderungen veraltet." \
         'make podman'
  else
    good "CDI vorhanden (${age} s alt)"
  fi
else
  bad 'Keine CDI-Gerätedefinition; Container sehen die GPU nicht.' 'make podman'
fi

# 5 Modell --------------------------------------------------------------------
title 'Modell auf dem Datentraeger'
model_dir="${LLM_MODELS_DIR}/$(basename "${MODEL_ID:-RadixArk/Qwen3.8-Flash-Next-NVFP4}")"
if [[ -f "${model_dir}/config.json" && -f "${model_dir}/model.safetensors.index.json" ]]; then
  shards="$(find "${model_dir}" -maxdepth 1 -name '*.safetensors' 2>/dev/null | wc -l)"
  good "Modellverzeichnis mit ${shards} Shard-Dateien: ${model_dir}"
  if find "${model_dir}" -maxdepth 1 -name '*.incomplete' 2>/dev/null | grep -q .; then
    bad 'Unvollständige (.incomplete) Modelldateien gefunden.' 'make model    (setzt fort)'
  fi
else
  bad 'Modell ist nicht vollständig vorhanden.' 'make model'
fi

# 6 PLE-Speicher --------------------------------------------------------------
title 'PLE-Speicher (SSD-Auslagerung der Einbettungen)'
# Hat dieser Rechner keinen PLE-Speicher, ist "nicht eingerichtet" der Zustand
# und kein Fehler. Dieselbe Regel wie im Kennzahlensammler (ple_configured),
# damit Doctor und Alarmmeldung nie auseinanderlaufen.
if ! ple_configured; then
  note 'Dieser Rechner hat keinen PLE-Speicher - die Pruefung entfaellt.'
  note 'PLE einrichten: ./scripts/47-setup-ple-storage.sh, danach PLE_* in config/host.env.'
elif "${root}/scripts/47-setup-ple-storage.sh" --verify >/tmp/llm-doctor-ple.$$ 2>&1; then
  good 'eingehaengt, in /etc/fstab eingetragen, ext4'
else
  bad 'PLE-Speicher ist nicht korrekt eingerichtet.' './scripts/47-setup-ple-storage.sh'
  sed 's/^/     /' /tmp/llm-doctor-ple.$$
fi
rm -f /tmp/llm-doctor-ple.$$

# 7 Image ---------------------------------------------------------------------
title 'Runtime-Image'
if command -v podman >/dev/null 2>&1; then
  img="${RUNTIME_IMAGE}"
  # Laeuft die Laufzeit, zaehlt das Image, aus dem sie wirklich gestartet ist.
  if runtime_is_running && [[ -n "${RUNTIME_CONTAINER}" ]]; then
    running_img="$(podman inspect "${RUNTIME_CONTAINER}" -f '{{.Config.Image}}' 2>/dev/null || true)"
    [[ -n "${running_img}" ]] && img="${running_img}"
  fi
  pinned="$(sed -n 's/^pennyroyal_image:[[:space:]]*//p' "${root}/versions.lock" 2>/dev/null | head -1)"
  if podman image exists "${img}" 2>/dev/null; then
    good "Image vorhanden: ${img}"
    if [[ -n "${pinned}" && "${img}" != "${pinned}" ]]; then
      # Ein eigenes (lokal gebauten) Image hat einen Speicher-Digest, aber nie
      # den gepinnten Registry-Digest; ein Vergleich waere eine Dauermeldung
      # ohne Aussage. Gepinnt ist nur das Pennyroyal-Image aus versions.lock.
      note "Laufzeit-Image ist nicht das gepinnte Image (${pinned}); Digest-Vergleich entfaellt."
    else
      dig="$(podman image inspect "${img}" --format '{{.Digest}}' 2>/dev/null || true)"
      if [[ -z "${dig}" ]]; then
        note 'Image ohne Registry-Digest; versions.lock-Vergleich entfaellt.'
      elif grep -qF "${dig}" "${root}/versions.lock" 2>/dev/null; then
        good 'Digest stimmt mit versions.lock ueberein'
      else
        warn 'Image-Digest weicht von versions.lock ab.' './scripts/50-install-pennyroyal.sh && git diff versions.lock quadlet'
      fi
    fi
  elif runtime_is_running; then
    warn "Image ${img} ist nicht als lokales Image auffindbar, die Laufzeit laeuft aber." 'podman images'
  else
    bad "Image ${img} fehlt." 'make pennyroyal   (eigene Images: podman images)'
  fi
else
  bad 'podman fehlt.' 'make install'
fi

# 8 Units ---------------------------------------------------------------------
title 'Unit-Dateien: Repo gegen Laeufer'
if driftdiff="$("${root}/scripts/apply-runtime-unit.sh" --list 2>/dev/null)"; then
  good 'Repo und installierte Units sind identisch'
else
  warn 'Einige installierte Units unterscheiden sich vom Repo (aendert sich erst nach Neustart).' \
       './scripts/apply-runtime-unit.sh --dry-run'
  printf '%s\n' "${driftdiff}" | grep '^ANDERS' | sed 's/^/     /'
fi

# 9 Runtime -------------------------------------------------------------------
# RUNTIME_SERVICE war hier bisher nur benutzt, aber nie gesetzt: die Zeile "Unit
# laeuft" konnte damit nie erscheinen, und nach dem Anlegen einer Unit blieb die
# Warnung stehen. Bestimmt wird sie jetzt aus host.env (RUNTIME_UNIT); findet die
# Konfiguration nichts, sucht der Arztlauf die Unit zum Container beim Namen.
RUNTIME_SERVICE=""
if [[ -n "${RUNTIME_UNIT:-}" ]]; then
  RUNTIME_SERVICE="${RUNTIME_UNIT}.service"
else
  # Die Unit heisst nicht nach dem Container (flash-next.container besitzt
  # ContainerName=flash-next-v3). gesucht wird deshalb zuerst in quadlet/, wo die
  # Wahrheit steht; die Namenssuche bleibt als zweiter Weg stehen.
  gefunde_unit=''
  for datei in "${root}"/quadlet/*.container; do
    [[ -f "${datei}" ]] || continue
    if grep -qs "^ContainerName=${RUNTIME_CONTAINER:-__keiner__}\$" "${datei}"; then
      gefunde_unit="$(basename "${datei}" .container).service"
      break
    fi
  done
  if [[ -z "${gefunde_unit}" ]]; then
    gefunde_unit="$(systemctl --user list-unit-files --no-legend "${RUNTIME_CONTAINER}*.service" 2>/dev/null | awk '{print $1; exit}')"
  fi
  RUNTIME_SERVICE="${gefunde_unit:-}"
fi

title 'Inferenz-Laufzeit'
if runtime_is_running; then
  if [[ -n "${RUNTIME_SERVICE}" ]] && systemctl --user is-active --quiet "${RUNTIME_SERVICE}"; then
    good "Unit ${RUNTIME_SERVICE} laeuft"
  elif [[ -n "${RUNTIME_SERVICE}" ]]; then
    warn "Unit ${RUNTIME_SERVICE} ist bekannt, aber nicht aktiv - das Modell laeuft an ihr vorbei." \
         "systemctl --user start ${RUNTIME_SERVICE}    (pruefen vorher: ./scripts/apply-runtime-unit.sh --list)"
  else
    # Ein Container ohne Unit ueberlebt keinen Neustart: er wurde von Hand gestartet,
    # ohne dass quadlet/ oder eine Unit-Datei ihn beschreibt. Als 'gut' durchgehen
    # darf das nicht, sonst gilt die Laufzeit als verwaltet, obwohl sie niemand
    # wieder hochfaehrt. Der Fall ist entscheidungsneutral: sobald eine Unit ihn
    # besitzt, schlaegt diese Zeile von selbst in good um.
    warn "Container ${RUNTIME_CONTAINER} laeuft, aber keine Unit verwaltet ihn - nach einem Neustart ist das Modell weg." \
         'Betreiber entscheiden: Unit einrichten (./scripts/apply-runtime-unit.sh, bricht bei laufenden Anfragen ab) oder bewusst von Hand starten.'
    if ! grep -qs "ContainerName=${RUNTIME_CONTAINER}" "${root}"/quadlet/*.container; then
      note "In quadlet/ fehlt eine Unit, die ${RUNTIME_CONTAINER} beschreibt - die committete Pennyroyal-Unit nennt einen anderen Container und ein anderes Bild."
    fi
  fi
  if curl -fsS --max-time 8 "${RUNTIME_URL}${RUNTIME_HEALTH_PATH}" >/dev/null 2>&1; then
    good "${RUNTIME_HEALTH_PATH} antwortet auf ${RUNTIME_URL}"
    m="$(curl -fsS --max-time 8 "${RUNTIME_URL}${RUNTIME_METRICS_PATH}" 2>/dev/null || true)"
    # Kein exit in awk: das wuerde curl eine geschlossene Pipeline zeigen und die
    # Diagnose mit SIGPIPE-Code beenden, obwohl alles in Ordnung ist.
    metric() { printf '%s\n' "${m}" | awk -v name="$1" 'index($0, name "{")==1 {if(!seen){print $2; seen=1}}'; }
    thr="$(metric sglang:gen_throughput)"
    acc="$(metric sglang:spec_accept_length)"
    run_req="$(metric sglang:num_running_reqs)"
    [[ -n "${run_req}" ]] || run_req="$(metric vllm:num_requests_running)"
    if [[ -n "${thr}" || -n "${acc}" ]]; then
      note "Token/s gerade: ${thr:-keine Last}   Spekulativ accepted/forward: ${acc:-?}   laufende Anfragen: ${run_req:-0}"
    else
      # vLLM fuehrt keine Momentanrate; Warteschlange und Zaehler sind die
      # Werte, die zu dieser Laufzeit passen.
      waiting="$(metric vllm:num_requests_waiting)"
      tokens="$(metric vllm:generation_tokens_total)"
      note "Laufende Anfragen: ${run_req:-0}   Wartend: ${waiting:-0}   Geschriebene Token insgesamt: ${tokens:-?}"
    fi
  else
    bad "Die Laufzeit laeuft, aber ${RUNTIME_HEALTH_PATH} antwortet nicht (Kaltstart dauert ~15 Minuten)." \
        "$(runtime_logs_hint)"
  fi
else
  note "Die Laufzeit (${RUNTIME_CONTAINER}) laeuft gerade nicht."
  hint_unit='make deploy-ready'
  if [[ "${short}" == 1 ]]; then hints+=("${hint_unit}"); fi
  printf '     -> starten mit: make deploy-ready   (oder ohne GPU: make deploy-non-gpu)\n'
  if [[ -n "${RUNTIME_SERVICE}" ]] && systemctl --user status "${RUNTIME_SERVICE}" --no-pager -n 0 2>/dev/null | grep -q 'Result: exit-code'; then
    bad 'Die Unit ist zuletzt fehlgeschlagen.' "$(runtime_logs_hint)"
  fi
fi
if [[ "${short}" == 0 ]]; then
  if [[ -n "${RUNTIME_SERVICE}" ]]; then
    oom_evidence="$(journalctl --user -u "${RUNTIME_SERVICE}" -n 400 --no-pager 2>/dev/null || true)"
  else
    oom_evidence="$(podman logs --tail 400 "${RUNTIME_CONTAINER}" 2>&1 || true)"
  fi
  if printf '%s' "${oom_evidence}" | grep -Eqi 'CUDA out of memory|out-of-memory|Killed|oom-kill'; then
    bad 'Letzte Meldungen deuten auf Speicherprobleme (CUDA OOM / OOM-Killer).' \
        'docs/performance.md#arbeitsspeicher-hicache'
  fi
fi

# 9b Pennyroyal (optional) ----------------------------------------------------
title 'Pennyroyal (optional, Legacy)'
# Pennyroyal ist die Quadlet-Runtime des Referenzrechners. Laeuft hier vLLM als
# Container, ist ihre Abwesenheit der Normalzustand - diese Pruefung kann
# deshalb keinen Fehler liefern, sie zeigt nur, was zu sehen ist.
if [[ "${RUNTIME_UNIT}" == "pennyroyal" ]]; then
  good 'Pennyroyal ist die aktive Laufzeit (siehe Pruefpunkt 9)'
elif unit_exists "${RUNTIME_LEGACY_SERVICE}"; then
  if systemctl --user is-active --quiet "${RUNTIME_LEGACY_SERVICE}"; then
    warn "Pennyroyal laeuft mit, ist aber nicht die aktive Laufzeit (${RUNTIME_CONTAINER} auf ${RUNTIME_URL})." \
         "systemctl --user status ${RUNTIME_LEGACY_SERVICE} --no-pager"
  else
    note "Pennyroyal-Unit ist installiert, steht aber; aktive Laufzeit ist ${RUNTIME_CONTAINER}."
  fi
else
  good "Pennyroyal ist nicht installiert - aktive Laufzeit ist ${RUNTIME_CONTAINER} auf ${RUNTIME_URL}."
fi

# 10 RAM / Platz --------------------------------------------------------------
title 'Arbeitsspeicher und Platte'
avail_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
swap_used_kb="$(awk '/^SwapUsed/ {print $2}' /proc/meminfo)"
if [[ -n "${avail_kb}" ]] && (( avail_kb < 4 * 1024 * 1024 )); then
  warn 'Weniger als 4 GiB RAM frei; Modell- oder Observability-Start kann fehlschlagen.' 'make stop   oder PENNY_HICACHE_SIZE_GB=0 (docs/performance.md)'
else
  good "RAM frei: $(( avail_kb / 1024 / 1024 )) GiB"
fi
[[ -n "${swap_used_kb}" ]] && (( swap_used_kb > 8 * 1024 * 1024 )) && warn 'Viel Swap benutzt (>8 GiB): Host war knapp.' 'docs/performance.md#arbeitsspeicher-hicache'
df -P "${LLM_MODELS_DIR}" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); if ($5+0 > 88) { print "     WARNUNG: " $6 " ist " $5 " % voll"; exit 1 } else { print "     OK      " $6 " " $5 " % voll" } }' || warns=$((warns+1))

# 11 Secrets ------------------------------------------------------------------
title 'Zugangsdaten'
if [[ -f "${HOME}/.config/llm-infra/credentials.txt" ]]; then
  good 'Zugangsdatei vorhanden (0600, ausserhalb von Git)'
  if grep -qE 'sk-llm-infra-local|llm-infra-salt|POSTGRES_PASSWORD=llm-infra$' "${HOME}/.config/llm-infra/"*.env 2>/dev/null; then
    bad 'Es liegen noch die alten Standard-Passwoerter in den Env-Dateien.' './scripts/rotate-secrets.sh'
  fi
else
  warn 'Noch keine Zugangsdaten erzeugt.' './scripts/ensure-credentials.sh'
fi
if ! podman secret inspect grafana_admin_password >/dev/null 2>&1; then
  warn 'Podman-Secret grafana_admin_password fehlt; Grafana startet nicht.' './scripts/ensure-credentials.sh'
fi

# 12 Gateway und Beobachtung --------------------------------------------------
title 'Gateway und Beobachtung'
# /health antwortet nur mit gueltigem Schluessel; die Lebensanzeige nicht.
if curl -fsS --max-time 5 "http://127.0.0.1:${LITELLM_PORT}/health/liveliness" >/dev/null 2>&1; then
  good 'Gateway (LiteLLM) antwortet'
elif systemctl --user is-active --quiet litellm.service 2>/dev/null; then
  warn 'Gateway-Unit laeuft, aber die Lebensanzeige antwortet nicht.' 'journalctl --user -u litellm.service -n 60 --no-pager'
else
  note 'Gateway laeuft nicht (ist optional; Antworten gehen auch direkt an die Runtime).' 'make deploy-non-gpu'
fi
if curl -fsS --max-time 5 'http://127.0.0.1:9090/-/ready' >/dev/null 2>&1; then
  good 'Prometheus laeuft'
  python3 - <<'PY'
import json, urllib.request
try:
    d = json.load(urllib.request.urlopen('http://127.0.0.1:9090/api/v1/query?query=up', timeout=5))
except Exception as exc:
    print('     HINWEIS  up-Abfrage fehlgeschlagen:', exc); raise SystemExit
res = d.get('data', {}).get('result', [])
down = [r['metric'].get('job', '?') for r in res if r['value'][1] == '0']
print(f'     HINWEIS  Targets erreichbar: {sum(1 for r in res if r["value"][1] == "1")} / {len(res)}')
for job in sorted(set(down)):
    print(f'     NICHT ERREICHBAR: job={job}')
PY
else
  note 'Prometheus laeuft nicht.' 'make monitoring'
fi
if systemctl --user is-active --quiet llm-infra-collect-facts.timer; then
  good 'Kennzahlen-Timer laeuft'
else
  warn 'Kennzahlen-Timer laeuft nicht (Host-Metriken bleiben leer).' 'make monitoring'
fi

# 13 Backup -------------------------------------------------------------------
title 'Backup'
newest="$(ls -1t "${root}/state/backups"/*.tar.gz 2>/dev/null | head -1)"
if [[ -n "${newest}" ]]; then
  age_days=$(( ( $(date +%s) - $(stat -c %Y "${newest}") ) / 86400 ))
  if (( age_days > 7 )); then warn "Letzter Backup ist ${age_days} Tage alt." './scripts/backup.sh'; else good "Backup vor ${age_days} Tagen: $(basename "${newest}")"; fi
else
  warn 'Noch kein Backup im Repo.' './scripts/backup.sh'
fi

# 14 Lokaler Zugang ueber Namen ------------------------------------------------
title 'Lokaler Zugang ueber Namen'
# Prueft den verwalteten Proxy und beide benannten Flaechen. curl laeuft ohne -k:
# faellt die Verankerung der lokalen Caddy-CA weg, liefert die Abfrage 000 und
# dieser Pruefpunkt schlaegt fehl, statt eine funktionsfreie Kachel zu melden.
if systemctl --user is-active --quiet llm-proxy.service 2>/dev/null; then
  good 'Lokaler Proxy (llm-proxy) laeuft'
else
  warn 'Lokaler Proxy laeuft nicht; die benannten Zugaege sind dann nicht erreichbar.' './scripts/74-setup-local-proxy.sh'
fi
for url in 'https://homepage.localhost/' 'https://grafana.localhost/grafana/'; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "${url}" 2>/dev/null || printf '000')"
  if [[ "${code}" == '200' ]]; then
    good "Benannter Zugang antwortet: ${url}"
  else
    bad "Benannter Zugang antwortet nicht (${code}): ${url}" './scripts/74-setup-local-proxy.sh --check'
  fi
done

# 15 Chat-Dienst ---------------------------------------------------------------
title 'Chat-Dienst'
# Der Chat ist die einzige Flaeche, die Anwenderinnen und Anwender direkt
# ansprechen: Laeuft die Unit, antwortet die Anwendung, und haelt sie einen
# eigenen Gateway-Schluessel? Der letzte Punkt ist der wichtige - der
# Master-Schluessel des Gateways kann Schluessel anlegen und loeschen und darf
# deshalb in der Chat-Umgebung nicht stehen. Verglichen wird nur, nie ausgegeben.
if systemctl --user is-active --quiet open-webui.service 2>/dev/null; then
  good 'Chat-Unit (open-webui) laeuft'
else
  warn 'Chat-Unit laeuft nicht; die Chat-Oberflaeche ist dann nicht erreichbar.' './scripts/60-install-open-webui.sh'
fi
chat_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 'http://127.0.0.1:3001/health' 2>/dev/null || printf '000')"
if [[ "${chat_code}" == '200' ]]; then
  good 'Chat-Dienst antwortet auf /health'
else
  bad "Chat-Dienst antwortet nicht auf /health (${chat_code})." './scripts/60-install-open-webui.sh --check'
fi
chat_schluessel="$(sed -n 's/^OPENAI_API_KEY=//p' "${SECRETS_DIR}/open-webui.env" 2>/dev/null | head -1)"
master_schluessel="$(sed -n 's/^LITELLM_MASTER_KEY=//p' "${SECRETS_DIR}/gateway.env" 2>/dev/null | head -1)"
if [[ -z "${chat_schluessel}" ]]; then
  bad 'Chat-Umgebung hat keinen Gateway-Schluessel.' './scripts/60-install-open-webui.sh'
elif [[ -n "${master_schluessel}" && "${chat_schluessel}" == "${master_schluessel}" ]]; then
  bad 'Chat-Umgebung haelt den Master-Schluessel des Gateways - der darf Schluessel anlegen und loeschen.' \
    "chat_schluessel-Zeile in ${SECRETS_DIR}/open-webui.env loeschen, dann ./scripts/60-install-open-webui.sh --provision"
else
  good 'Chat-Dienst haelt einen eigenen Gateway-Schluessel (nicht den Master)'
fi

# Abschluss -------------------------------------------------------------------
printf '\n\033[1mErgebnis\033[0m\n'
printf '  %d Pruefpunkte, %d Fehler, %d Warnungen\n' "${checks}" "${fails}" "${warns}"
if (( fails == 0 && warns == 0 )); then
  printf '  \033[32mAlles in Ordnung.\033[0m\n'
elif (( ${#hints[@]} > 0 )); then
  printf '  \033[1mWichtigster naechster Schritt:\033[0m %s\n' "${hints[0]}"
  if (( ${#hints[@]} > 1 )); then
    printf '  Danach:\n'
    for h in "${hints[@]:1}"; do printf '    %s\n' "$h"; done
  fi
else
  printf '  Bitte Log pruefen: %s\n' "$(runtime_logs_hint)"
fi
exit $(( fails > 0 ? 1 : 0 ))
