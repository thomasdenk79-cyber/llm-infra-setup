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
         'make podman   (erst wenn keine Inferenz laeuft - die GPU gehoert der Laufzeit, AGENTS.md Regel 2)'
  else
    good "CDI vorhanden (${age} s alt)"
  fi
else
  bad 'Keine CDI-Gerätedefinition; Container sehen die GPU nicht.' 'make podman   (Laufzeit vorher stilllegen - AGENTS.md Regel 2)'
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
# --- Alarmkette und Protokollpipeline (Befunde der Review-Welle 2026-11-18:
# genau diese Glieder liess der Doctor unprueft, deren Ausfall still ist) ---
for probe in "alertmanager|9093|/-/ready" "loki|3100|/ready" "grafana|3000|/grafana/api/health" "llm-node-exporter|9100|/metrics" "llm-gpu-exporter|9835|/metrics" "llm-cadvisor|9188|/healthz"; do
  IFS='|' read -r name port pfad <<< "${probe}"
  if curl -fsS --max-time 5 "http://127.0.0.1:${port}${pfad}" >/dev/null 2>&1; then
    good "${name} antwortet (${pfad})"
  else
    bad "${name} nicht erreichbar (${pfad})" "systemctl --user status ${name}.service --no-pager"
  fi
done

# Wiki-Portal: Auslieferung, Baustempel gegen Git-HEAD, Timer-Ergebnis
: "${WIKI_DIR:=${HOME}/work/hermes-wiki}"
if systemctl --user is-active --quiet wiki.service 2>/dev/null || podman ps --format '{{.Names}}' | grep -q '^llm-wiki$'; then
  wc_http="$(curl -s -o /tmp/llm-wiki-probe.$$ -w '%{http_code}' --max-time 5 http://127.0.0.1:3003/ 2>/dev/null || echo 000)"
  wc_gross=$([[ $(stat -c %s /tmp/llm-wiki-probe.$$ 2>/dev/null || echo 0) -gt 1000 ]] && echo ja || echo nein)
  rm -f /tmp/llm-wiki-probe.$$
  if [[ "${wc_http}" == 200 && "${wc_gross}" == ja ]]; then
    ok 'Wiki-Portal liefert (>1 kB)'
  else
    warn "Wiki-Portal HTTP ${wc_http} bzw. Inhalt ${wc_gross}" 'systemctl --user status llm-wiki.service --no-pager; ./scripts/wiki-rebuild.sh --force'
  fi
  stamp_w="$(cat "${WIKI_DIR}/.built-sha" 2>/dev/null || echo -)"
  head_w="$(git -C "${WIKI_DIR}" rev-parse HEAD 2>/dev/null || echo -)"
  if [[ -d "${WIKI_DIR}" && "${stamp_w}" != "${head_w}" ]]; then
    warn 'Wiki-Baustempel hinter Git-HEAD' './scripts/wiki-rebuild.sh --force'
  fi
  # Result ist das zuverlaessige Feld; ExecMainCode zaehlt nur den Exit-Typ.
  res_t="$(systemctl --user show wiki-rebuild.service -p Result --value 2>/dev/null || echo -)"
  st_t="$(systemctl --user show wiki-rebuild.service -p ExecMainStatus --value 2>/dev/null || echo -)"
  if [[ -n "${res_t}" && "${res_t}" != "success" && "${res_t}" != "-" ]]; then
    warn "Letzter Rebuild endete nicht sauber (${res_t}/Status ${st_t})" 'journalctl --user -u wiki-rebuild.service -n 40'
  fi
fi
if systemctl --user is-active --quiet alloy.service; then
  good 'Alloy laeuft'
else
  bad 'Alloy laeuft nicht - Container-Protokolle stehen still' 'systemctl --user status alloy.service --no-pager'
fi
nstreams=$(curl -fsS --max-time 8 -G 'http://127.0.0.1:3100/loki/api/v1/query' \
  --data-urlencode 'query=count by (container) (count_over_time({job="containerlogs"}[10m]))' 2>/dev/null \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]["result"]))' 2>/dev/null || echo 0)
if [[ "${nstreams}" -gt 0 ]]; then
  good "Protokollfluss lebt: ${nstreams} Container-Quellen in 10 min"
else
  bad 'Keine frischen Container-Protokolle in Loki (Alloy alive, aber Pipeline durch?)' 'journalctl --user -u alloy.service -n 50 --no-pager'
fi
if curl -fsS --max-time 5 'http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22incident-agent%22%7D' | grep -q '"value"'; then
  good 'Incident-Agent erreichbar (Target up)'
else
  warn 'Incident-Agent-Target nicht up - Vorfallsanalyse ausser Betrieb' 'systemctl --user status incident-agent.service --no-pager'
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
# http_code <url> [weitere curl-Schalter...] -> dreistelliger Code, '000' bei
# Abbruch. curl schreibt den Formatstring auch beim Abbruch, ein zweites '000'
# daneben ergaebe "000000" - deshalb hier die eine Quelle.
http_code() {
  local url="$1"; shift
  local c
  c="$(curl -s -o /dev/null -w '%{http_code}' "$@" "${url}" 2>/dev/null)"
  [[ "${c}" =~ ^[0-9]{3}$ ]] || c='000'
  printf '%s' "${c}"
}
# Jeder benannte Zugang fuehrt durch denselben Container llm-proxy. Geprueft wird
# deshalb von aussen nach innen und die Kette endet beim ersten Ausfall: Unit ->
# Listener -> Vertrauen -> Zugaege. Sonst erschiene ein einziger Ausloeser (eine
# geaenderte DHCP-Adresse zum Beispiel) als vier gleiche Fehlerzeilen.
proxy_unit='llm-proxy.service'
proxy_ca="${HOME}/.local/share/llm-infra/caddy/ca/caddy-local-authority-root.crt"
proxy_chain=1
if systemctl --user is-active --quiet "${proxy_unit}" 2>/dev/null; then
  good 'Lokaler Proxy (llm-proxy) laeuft'
  # "laeuft" heisst nur, dass podman den Container angelegt hat. Horcht Caddy
  # auch? Ohne diese Zeile gilt eine Unit als gesund, die keinen einzigen Zugang
  # beantwortet (Bildfall: Sysctl-Grenze zurueckgesetzt, Container steht da).
  if ss -tlnH 2>/dev/null | grep -q '127\.0\.0\.1:443 '; then
    good 'Listener auf 127.0.0.1:443'
  else
    bad 'Unit laeuft, aber auf 127.0.0.1:443 horcht niemand.' \
        "journalctl --user -u ${proxy_unit} -n 80 --no-pager   (Veroeffentlichungen: systemctl --user cat ${proxy_unit})"
    proxy_chain=0
  fi
else
  # Der Grund entscheidet ueber den naechsten Befehl: 'Permission denied' ist die
  # Sysctl-Grenze, 'Cannot assign requested address' eine Adresse, die dem
  # Rechner nicht (mehr) gehoert, 'no such host' ein Zielname im falschen Netz.
  # Ein Neustart der Unit ueberlebt nichts davon - erst --check lesen.
  grund="$(journalctl --user -u "${proxy_unit}" -n 60 --no-pager 2>/dev/null \
    | grep -Eo 'Listen failed[^"]*|Cannot assign requested address|Permission denied|no such host' | tail -1)"
  if [[ -n "${grund}" ]]; then
    bad "Lokaler Proxy laeuft nicht; letzte Meldung: ${grund}." \
        './scripts/74-setup-local-proxy.sh --check   (Adressen: ip -4 addr   Grenze: sysctl net.ipv4.ip_unprivileged_port_start)'
  else
    bad 'Lokaler Proxy laeuft nicht; die benannten Zugaege sind dann nicht erreichbar.' \
        "journalctl --user -u ${proxy_unit} -n 80 --no-pager   (danach ausrollen: ./scripts/74-setup-local-proxy.sh)"
  fi
  proxy_chain=0
fi
# Vertrauen: ohne verankerte Caddy-CA antwortet der Proxy zwar, aber curl und
# Browser brechen ab. Das ist ein Warnung mit eigenem Befehl, kein Zugangsausfall
# - mit --cacert funktioniert alles.
ca_im_trust() {
  # True, wenn das System dem Caddy-Stamm vertraut. Zuerst die Ausliste des
  # trust-Programms; findet sie nichts, entscheidet das Verhalten eines echten
  # request (200 ohne -k) - dasselbe Ergebnis, aber auf jedem System gleich.
  if command -v trust >/dev/null 2>&1 \
     && trust list --filter=ca-anchors 2>/dev/null | grep -qi 'Caddy Local Authority'; then
    return 0
  fi
  [[ "$(http_code 'https://homepage.localhost/' --max-time 6)" == '200' ]]
}
if [[ ! -f "${proxy_ca}" ]]; then
  warn "CA-Datei ${proxy_ca} fehlt; kein Client kann den Zertifikaten vertrauen." \
       './scripts/74-setup-local-proxy.sh --ca-export   (CA-Datei und Fingerabdruck ausgeben; danach --ca-import)'
elif (( ${proxy_chain} == 1 )); then
  if ca_im_trust; then
    good 'Caddy-CA im Systemvertrauen verankert (curl und Browser ohne Warnung)'
  else
    warn 'Caddy-CA ist nicht im Systemvertrauen; curl ohne -k und der Browser brechen ab.' \
         './scripts/74-setup-local-proxy.sh --ca-import   (sudo, nur dieser Rechner)'
  fi
fi
if (( ${proxy_chain} == 1 )); then
  for url in 'https://homepage.localhost/' 'https://grafana.localhost/grafana/'; do
    code="$(http_code "${url}" --max-time 6)"
    if [[ "${code}" == '200' ]]; then
      good "Benannter Zugang antwortet: ${url}"
      continue
    fi
    # Unterscheide "niemand antwortet" von "Antwort, aber niemand vertraut ihr":
    # mit der CA-Datei als Vorlage funktioniert derselbe request wieder.
    if [[ -f "${proxy_ca}" ]] \
       && [[ "$(http_code "${url}" --max-time 6 --cacert "${proxy_ca}")" == '200' ]]; then
      warn "Benannter Zugang antwortet nur mit ausdruecklicher CA: ${url} (${code})" \
           './scripts/74-setup-local-proxy.sh --ca-import'
    else
      bad "Benannter Zugang antwortet nicht (${code}): ${url}" './scripts/74-setup-local-proxy.sh --check'
    fi
  done
fi

# Loopback-Namen: alle bedienten Seiten unter https://NAME.localhost (Review
# 2026-11-18: Zugang ohne IP-Adressen). Pfade sind die, die ohne Weiterleitung
# 200 liefern.
for eintrag in \
    "homepage:/" "grafana:/grafana/" "dozzle:/" "wiki:/" \
    "prometheus:/graph/" "alertmanager:/" "litellm:/" "loki:/" \
    "cadvisor:/containers/" "local-llm:/health"; do
  nm="${eintrag%%:*}"; pf="${eintrag#*:}"
  code=$(curl -skL -o /dev/null -w '%{http_code}' --max-time 8 \
    --resolve "${nm}.localhost:443:127.0.0.1" "https://${nm}.localhost${pf}" 2>/dev/null || echo 000)
  if [[ "${code}" == 200 ]]; then
    good "Namenszugang https://${nm}.localhost${pf} antwortet mit 200"
  else
    bad "https://${nm}.localhost${pf} liefert ${code}" \
        "./scripts/74-setup-local-proxy.sh --check   (und: systemctl --user status ${proxy_unit})"
  fi
done

# LAN-Anteil: nur wenn config/host.env Adressen nennt. Der Arztlauf bleibt knapp
# (Adresse, Listener, Portal, LAN-Zugriffe, Weiterleiter);
# die vollstaendige Pruefung - alle Namen, erwartete HTTP-Codes, Loopback-
# Ausschliesslichkeit der Backend-Ports - macht der Generator selbst mit
# ./scripts/74-setup-local-proxy.sh --check.
if [[ -n "${LAN_BIND_IPS//[[:space:],]/}" ]]; then
  lan_dom="${LAN_DOMAIN:-$(hostname 2>/dev/null || echo llmhost)}"
  ROLLEN_TXT="homepage grafana littlem llm-direct dozzle direct-llm"
  lan_ip="$(printf '%s' "${LAN_BIND_IPS}" | tr ',' ' ' | awk '{print $1}')"
  # Erste Frage vor jedem Listener: gehoert die Adresse ueberhaupt zu diesem
  # Rechner? Wechselt DHCP die Adresse, verweigert podman die Veroeffentlichung
  # (gemessen: pasta "Listen failed ... Cannot assign requested address") und der
  # Container startet GAR NICHT mehr - auch nicht fuer 127.0.0.1:443. Der
  # Loopback-Zugang faellt also mit, nicht nur der Zugang im Netz.
  if ip -4 -o addr show scope global 2>/dev/null | grep -qE "[[:space:]]${lan_ip}/"; then
    good "LAN-Adresse ${lan_ip} ist auf diesem Rechner konfiguriert"
  else
    bad "LAN_BIND_IPS nennt ${lan_ip}, aber der Rechner hat diese Adresse nicht - der Proxy startet deshalb nicht (auch 127.0.0.1:443 fehlt)." \
        "ip -4 addr show   (dann LAN_BIND_IPS in config/host.env auf die aktuelle Adresse setzen, danach: ./scripts/74-setup-local-proxy.sh)"
    proxy_chain=0
  fi
  if (( ${proxy_chain} == 1 )); then
    if ss -tlnH 2>/dev/null | grep -q "${lan_ip}:443 "; then
      good "LAN-Listener auf ${lan_ip}:443"
    else
      bad "Kein LAN-Listener auf ${lan_ip}:443" \
          "journalctl --user -u ${proxy_unit} -n 80 --no-pager   (danach: ./scripts/74-setup-local-proxy.sh --check)"
      proxy_chain=0
    fi
  fi
  if (( ${proxy_chain} == 1 )); then
    # Reachbarkeit ist die Frage, nicht das Vertrauen - dafuer oben die CA-Zeile.
    # Mit der CA-Datei als Vorlage geprueft, damit ein fehlendes Systemvertrauen
    # nicht zusaetzlich als Zugangsausfall erscheint.
    if [[ -f "${proxy_ca}" ]]; then
      code="$(http_code "https://homepage.${lan_dom}/" --max-time 8 --cacert "${proxy_ca}" --resolve "homepage.${lan_dom}:443:${lan_ip}")"
    else
      code="$(http_code "https://homepage.${lan_dom}/" --max-time 8 -k --resolve "homepage.${lan_dom}:443:${lan_ip}")"
    fi
    if [[ "${code}" == '200' ]]; then
      good "LAN-Zugang antwortet: https://homepage.${lan_dom}/"
    elif [[ "${code}" == '400' ]]; then
      # Das Portal prueft seinen eigenen Host-Header; der Proxy ist unschuldig.
      bad "Portal weist unter https://homepage.${lan_dom}/ mit 400 ab (Host-Header abgelehnt)." \
          "homepage.${lan_dom} in HOMEPAGE_ALLOWED_HOSTS in config/host.env eintragen, dann: make homepage"
    else
      bad "LAN-Zugang antwortet nicht (${code}): https://homepage.${lan_dom}/" './scripts/74-setup-local-proxy.sh --check'
    fi
    # Die Log-Route ist Betreiberentscheidung vom 2026-11-17 bewusst ohne
    # Proxy-Anmeldung (docs/status.md, Abschnitt LAN-Zugang): Dozzle haengt im
    # vertrauenswuerdigen privaten LAN. 74 --check prueft die Rolle gegen den
    # Generator; hier ist 200 der Soll-Wert, alles andere ein echter Defekt.
    code="$(http_code "https://dozzle.${lan_dom}/" --max-time 8 -k --resolve "dozzle.${lan_dom}:443:${lan_ip}")"
    if [[ "${code}" == '200' ]]; then
      good "LAN-Log-Route liefert ohne Anmeldung 200 (privates LAN, Betreiberentscheidung)"
    else
      bad "LAN-Log-Route antwortet mit ${code} statt 200 - Generatorstand pruefen" './scripts/74-setup-local-proxy.sh --check'
    fi
    # Namensaufloesung: ohne Zone braucht jedes Geraet hosts-Eintraege, und
    # "Name laedt auf dem Notebook nicht auf" ist der haufigste Betreiberfall.
    if [[ -f '/etc/llm-infra/dnsmasq/lan-zone.conf' ]] && systemctl is-active --quiet dnsmasq.service; then
      if command -v dig >/dev/null 2>&1 \
         && [[ "$(dig +short "@${lan_ip}" "homepage.${lan_dom}" A 2>/dev/null | head -1)" == "${lan_ip}" ]]; then
        good "Namensaufloesung im Netz: homepage.${lan_dom} -> ${lan_ip}"
      else
        warn "dnsmasq laeuft, antwortet aber nicht auf homepage.${lan_dom}" './scripts/75-setup-local-dns.sh --check'
      fi
    else
      note "kein DNS fuer ${lan_dom} - Geraete brauchen hosts-Eintraege (74 --print-hosts) oder Zone ausrollen: ./scripts/75-setup-local-dns.sh"
    fi
    # mDNS ist der Pfad fuer EINTEILIGE Namen: der Rechnername alone loest oft
    # ueber Avahi auf, und zwar auf eine Adresse, an der gar kein Dienst lauscht
    # (gemessen: cachyos-x8664.local -> 192.168.0.47, die WLAN-Adresse, waehrend
    # alle Dienste nur auf LAN_BIND_IPS gebunden sind). Geraete, die
    # "ping cachyos-x8664" testen und dann http://cachyos-x8664:3000 probieren,
    # laufen damit an der LAN-Bindung vorbei.
    # /etc/hosts ist ein zweiter Schreiber fuer genau diese Namen (stand hier
    # schon vor der Zone drin). Zwei Quellen fuer eine Tatsache sind der klassische
    # stale-IP-Fehler: DHCP aendert die Adresse, die Zone zieht mit, hosts nicht.
    hosts_zeile="$(grep -hE "[[:space:]]${ROLLEN_TXT// /|}" /etc/hosts 2>/dev/null | head -1)"
    if [[ -n "${hosts_zeile}" ]]; then
      hosts_ip="${hosts_zeile%%[[:space:]]*}"
      if [[ "${hosts_ip}" == "${lan_ip}" ]]; then
        good "/etc/hosts und DNS-Zone nennen dieselbe Adresse (${hosts_ip})"
      else
        bad "/etc/hosts nennt ${hosts_ip} fuer die LAN-Namen, die Zone aber ${lan_ip} - zwei Quellen, zwei Antworten." \
            "/etc/hosts berichtigen (Eintrag am Zeilenanfang mit ${lan_ip}) oder die hosts-Zeile loeschen und allein der Zone vertrauen, danach: ./scripts/75-setup-local-dns.sh --check"
      fi
    else
      note "kein /etc/hosts-Eintrag fuer die LAN-Namen - die Zone ist die einzige Quelle (gut so)"
    fi
    if command -v avahi-resolve >/dev/null 2>&1; then
      mdns_ant="$(avahi-resolve -n "$(hostname 2>/dev/null || echo llmhost).local" 2>/dev/null | awk 'NF==2 {print $2}' | head -1)"
      lan_soll=" $(printf '%s' "${LAN_BIND_IPS}" | tr ',' ' ') "
      if [[ -n "${mdns_ant}" ]] && [[ "${lan_soll}" != *" ${mdns_ant} "* ]]; then
        # Kein Fehler und keine Reparatur: der Betreiber entscheidet ueber Avahi.
        note "mDNS nennt fuer $(hostname).local ${mdns_ant}, gebunden ist${lan_soll}- dort lauscht kein Dienst. Einteilige Namen sind zum Pruefen unbrauchbar, immer homepage.${lan_dom} verwenden (docs/troubleshooting.md, Zeile mDNS)." 
      elif [[ -n "${mdns_ant}" ]]; then
        good "mDNS und LAN-Bindung nennen dieselbe Adresse (${mdns_ant})"
      fi
    fi
  fi
  # Die Route https://direct-llm.<dom>/ haengt am Weiterleiter des Rechners
  # (scripts/73). Die API ist ohne Schluessel oder Proxy-Anmeldung erreichbar;
  # deshalb prueft der Arztlauf Unit und Host-Port statt einen 401 zu erwarten.
  if systemctl --user is-active --quiet llm-vllm-forwarder.service 2>/dev/null; then
    if runtime_is_running; then
      fwd_port="${VLLM_FORWARD_PORT:-30001}"
      fwd_code="$(http_code "http://127.0.0.1:${fwd_port}/v1/models" --max-time 6)"
      if [[ "${fwd_code}" == '200' ]]; then
        good "Weiterleiter reicht durch (127.0.0.1:${fwd_port}) - die direkte vLLM-Route ist nutzbar"
      else
        warn "Weiterleiter-Unit laeuft, aber 127.0.0.1:${fwd_port} antwortet nicht (${fwd_code}); https://direct-llm.${lan_dom}/ liefert dann 502." \
             './scripts/73-setup-vllm-forwarder.sh --check   (docs/runtime.md, Abschnitt Ausfallbilder)'
      fi
    else
      note 'Weiterleiter nur der Unit nach geprueft - die Laufzeit antwortet gerade nicht.'
    fi
  else
    warn "Weiterleiter (llm-vllm-forwarder.service) steht; https://direct-llm.${lan_dom}/ und der Prometheus-Job vllm fallen aus." \
         './scripts/73-setup-vllm-forwarder.sh --check   (starten: ./scripts/73-setup-vllm-forwarder.sh)'
  fi
  # Repo-Regel aus AGENTS.md: jeder neue Dienst hat ein Metrikziel in Prometheus.
  # Solange der Proxy keins hat, ist das ein HINWEIS ohne Fehlerzaehler - sonst
  # waere der Arztlauf dauerhaft gelb, ohne dass ein Betreiber etwas tun koennte.
  if curl -s --max-time 4 'http://127.0.0.1:9090/-/ready' >/dev/null 2>&1; then
    jobliste="$(curl -s --max-time 5 'http://127.0.0.1:9090/api/v1/label/job/values' 2>/dev/null || true)"
    if printf '%s' "${jobliste}" | grep -qiE '"(llm-proxy|caddy|proxy)"'; then
      if curl -s --max-time 5 'http://127.0.0.1:9090/api/v1/query?query=up' 2>/dev/null | grep -q '"job":"\(llm-\)\?\(proxy\|caddy\)"'; then
        good 'Proxy-Metrikziel ist in Prometheus gemeldet'
      else
        warn 'Proxy-Metrikziel ist in Prometheus gemeldet, aber nicht erreichbar.' 'curl -s http://127.0.0.1:9090/targets | grep -i proxy'
      fi
    else
      note 'Der Proxy hat kein Metrikziel in Prometheus (seine Logs laufen ueber Loki). Anlegen: config/monitoring/prometheus.yml, docs/operations.md.'
    fi
  fi
else
  note 'LAN ist zu (LAN_BIND_IPS in config/host.env leer) - Zugang nur auf diesem Rechner.'
fi

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

# 16b Neustartfestigkeit -------------------------------------------------------
title 'Neustartfestigkeit (Autostart nach Neustart)'
# Ein Reboot ist der eigentliche Test dieses Stapels. Zwei Bedingungen bestimmen,
# ob der benannte HTTPS-Zugang danach wieder da ist: der Benutzermanager muss ohne
# Anmeldung laufen (linger) und die Unit muss in default.target.wants stehen.
betreiber_name="${USER:-$(id -un)}"
linger=''
command -v loginctl >/dev/null 2>&1 && linger="$(loginctl show-user "${betreiber_name}" -p Linger --value 2>/dev/null)"
if [[ "${linger}" == 'yes' ]]; then
  good 'linger ist aktiv - der Benutzermanager startet ohne Anmeldung'
elif [[ -z "${linger}" ]]; then
  note 'loginctl nicht verfuegbar - linger konnte nicht geprueft werden.'
else
  # Kein automatischer Fehler: laeuft der Benutzermanager in dieser Boot-Runde
  # nachweislich schon (Desktop-Anmeldung startet ihn mit), ist der Zustand
  # aktuell bedienbar - aber nur so lange die Anmeldung mitmacht.
  benutzer_start="$(systemctl show "user@$(id -u).service" -p ExecMainStartTimestamp --value 2>/dev/null)"
  boot_tag="$(uptime -s 2>/dev/null | cut -d' ' -f1)"
  # Die Zeitstempel tragen den Wochentag vor ("Sun 2026-11-15 04:26:35 CET"),
  # uptime -s nicht - verglichen wird deshalb der Datumsanteil, nicht der Anfang.
  if [[ -n "${benutzer_start}" && "${benutzer_start}" != 'n/a' && -n "${boot_tag}" \
        && "${benutzer_start}" == *"${boot_tag}"* ]]; then
    warn "linger ist nicht gesetzt; der Benutzermanager lief in dieser Boot-Runde nur wegen der Desktop-Anmeldung (${benutzer_start}). Ohne grafische Anmeldung startet der ganze Stapel nicht - auch llm-proxy nicht." \
         "sudo loginctl enable-linger ${betreiber_name}   (pruefen: loginctl show-user ${betreiber_name} -p Linger)"
  else
    bad 'linger ist nicht gesetzt und der Benutzermanager lief in dieser Boot-Runde nicht von selbst - nach einem Neustart bleibt der gesamte Stapel stehen.' \
        "sudo loginctl enable-linger ${betreiber_name}   (danach: systemctl --user is-enabled llm-proxy.service)"
  fi
fi
# Autostart des Proxies: quadlet/llm-proxy.container traegt WantedBy=default.target,
# also muss der Verweis in default.target.wants liegen (setzt lib/units.sh beim
# Ausrollen). Fehlt er, startet die Unit beim naechsten Boot nicht mit.
if [[ -e "${HOME}/.config/containers/systemd/default.target.wants/llm-proxy.container" ]]; then
  good 'llm-proxy ist in default.target.wants eingetragen'
else
  warn 'llm-proxy hat keinen Autostart-Verweis; nach einem Neustart bleibt der benannte Zugang weg.' \
       './scripts/74-setup-local-proxy.sh   (setzt den Verweis ueber lib/units.sh)'
fi
if [[ -f "${HOME}/.config/containers/systemd/llm-proxy.container" ]]; then
  good 'installierte Proxy-Unit vorhanden'
  # Laeuft etwas anderes als der Repo-Stand? Das ist der Fall "Repo geaendert,
  # der Rechner startet morgen die alte Unit weiter".
  if installed_unit_diff 'llm-proxy.container' >/dev/null 2>&1; then
    good 'installierte Proxy-Unit entspricht dem Repo (reine Caddyfile-Aenderungen laden nur nach)'
  else
    warn 'Die installierte Proxy-Unit unterscheidet sich vom Repo; sie laeuft bis zum naechsten Ausrollen weiter.' \
         './scripts/74-setup-local-proxy.sh --plan   (zeigt den Unterschied, aendert nichts)'
  fi
else
  bad 'Die installierte Proxy-Unit fehlt in ~/.config/containers/systemd/.' \
      './scripts/74-setup-local-proxy.sh   (danach: systemctl --user daemon-reload)'
fi
# Neustart-Schleifen bleiben sonst unsichtbar: Restart=on-failure holt Caddy alle
# 15 s zurueck, und "active" kann trotzdem ein kaputtes Ziel bedeuten.
nrestarts="$(systemctl --user show "${proxy_unit}" -p NRestarts --value 2>/dev/null)"
ergebnis="$(systemctl --user show "${proxy_unit}" -p Result --value 2>/dev/null)"
if [[ -n "${nrestarts}" && "${nrestarts}" != '0' ]]; then
  warn "llm-proxy ist in dieser Boot-Runde ${nrestarts}-mal neu gestartet (Result: ${ergebnis:-?})." \
       "journalctl --user -u ${proxy_unit} --since -1h --no-pager | tail -40"
elif [[ -n "${ergebnis}" && "${ergebnis}" != 'ok' && "${ergebnis}" != 'success' && "${ergebnis}" != 'done' ]]; then
  # "success" ist der Normalzustand einer laufenden Unit, kein Ausfall.
  warn "Letzter Ausfall von llm-proxy: Result=${ergebnis}." "journalctl --user -u ${proxy_unit} -n 80 --no-pager"
fi
# Speicher unter ~/.local/share/llm-infra/caddy (Zertifikate und Bestand der
# lokalen CA): waechst normal nur im KB-Bereich; ein Sprung deutet auf ein
# zerschossenes Zertifikats-Verhalten hin.
caddy_home="${HOME}/.local/share/llm-infra/caddy"
if [[ -d "${caddy_home}" ]]; then
  caddy_kb="$(du -sk "${caddy_home}" 2>/dev/null | awk '{print $1}')"
  if [[ -n "${caddy_kb}" ]] && (( caddy_kb > 204800 )); then
    warn "Der Proxy-Bestand unter ${caddy_home} ist $(( caddy_kb / 1024 )) MiB gross (ueblich sind einige hundert KiB)." \
         'du -h --max-depth=2 ~/.local/share/llm-infra/caddy   (CA-Bestand: docs/operations.md, Abschnitt Zertifikate)'
  else
    good "Proxy-Bestand unter ${caddy_home}: ${caddy_kb:-?} KiB"
  fi
fi

# 17 Waechter -------------------------------------------------------------------
title 'Waechter'
# Beide Waechter gehoeren zum Stapel: der Gateway-Waechter startet nur litellm neu,
# der Laufzeit-Waechter warnt standardmaessig nur. Ein Timer, der nicht wieder
# bewaffnet wird, ist schlimmer als gar keiner - er wirkt aktiv und prueft nie wieder.
for timer in llm-litellm-watchdog.timer llm-runtime-watchdog.timer llm-stack-status.timer llm-infra-collect-facts.timer llm-backup.timer; do
  fall=''
  case "${timer}" in
    llm-litellm-watchdog.*) fall='./scripts/litellm-watchdog.sh --install' ;;
    llm-runtime-watchdog.*) fall='./scripts/runtime-watchdog.sh --install' ;;
    llm-stack-status.*) fall='./scripts/collect-stack-status.sh' ;;
    llm-infra-collect-facts.*) fall='./scripts/collect-host-facts.sh' ;;
    llm-backup.*) fall='./scripts/backup.sh --install' ;;
  esac
  if ! systemctl --user is-active --quiet "${timer}" 2>/dev/null; then
    warn "Timer ${timer} laeuft nicht; die Ueberwachung faellt still weg." "${fall}"
    continue
  fi
  real="$(systemctl --user show "${timer}" -p NextElapseUSecRealtime --value 2>/dev/null)"
  mono="$(systemctl --user show "${timer}" -p NextElapseUSecMonotonic --value 2>/dev/null)"
  if [[ -z "${real}" && -z "${mono}" ]]; then
    warn "Timer ${timer} ist aktiv, hat aber keine naechste Laufzeit - er feuert einmal und dann nie wieder." \
      "systemctl --user restart ${timer}   (und nachsehen: systemctl --user cat ${timer})"
  else
    # Die show-Werte sind Uhrzeitpunkte (Realtime bzw. Monotonic), keine Countdowns -
    # die Leserbereitung holt sich die Restzeit lieber aus der Timer-Liste selbst.
    plan="$(systemctl --user list-timers --all --no-pager 2>/dev/null | grep -F "${timer}" | head -1)"
    ueber="$(printf '%s' "${plan}" \
      | sed -E 's/^[A-Za-z]{3} [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} +[A-Za-z]{2,5} +//; s/[A-Za-z]{3} [0-9]{4}-.*$//' \
      | sed -E 's/ +$//')"
    good "Timer ${timer} laeuft, naechster Lauf in ${ueber:-bald}"
  fi
done

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
