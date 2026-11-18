#!/usr/bin/env bash
# Single implementation of "install a Quadlet from the repository into the
# rootless user configuration". Every deployment script must use these helpers
# so that a unit can never be installed half-finished in two different ways.

# shellcheck shell=bash
# shellcheck disable=SC2034  # diese Listen werden von den Aufrufern verwendet
UNIT_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/containers/systemd"
WANTS_DIR="${UNIT_DIR}/default.target.wants"
SYSTEMD_SRC_DIR="${REPO_ROOT}/systemd"

# Units belonging to the inference plane (GPU, model, gateway, chat).
INFERENCE_UNITS=(
  llm-inference.network
  litellm-postgres.container
  pennyroyal.container
  flash-next.container
  litellm.container
  open-webui.container
)
# Units belonging to the observability plane (metrics, logs, portal).
OBSERVABILITY_UNITS=(
  llm-observability.network
  prometheus.container
  grafana.container
  loki.container
  alloy.container
  alertmanager.container
  dozzle.container
  llm-gpu-exporter.container
  llm-node-exporter.container
  llm-cadvisor.container
  homepage.container
  wiki.container
  llm-proxy.container
  incident-agent.container
)
# Optional units that need operator credentials before they make sense.
OPTIONAL_UNITS=(llm-autossh.container komodo-periphery.container)

# Fruehere Namen von Einheiten, die umbenannt wurden. Sie werden bei jedem Deploy
# entfernt, sonst bleiben zwei Units mit demselben Containernamen uebrig und
# bringten sich gegenseitig zum Neustart.
LEGACY_UNITS=(gpu-exporter.container node-exporter.container)

# Plain-User-Units, die dieses Repo zusaetzlich zu den Quadlets aus systemd/
# installiert. Zusammen mit INFERENCE_UNITS und OBSERVABILITY_UNITS ergibt das
# die Menge der Dienste, deren Zustand der Kennzahlensammler berichtet.
HOST_UNITS=(llm-reverse-tunnel llm-vllm-forwarder)

# Timer, deren Ablauf der Betrieb erwartet (Namen ohne .timer).
MONITOR_TIMERS=(llm-infra-collect-facts llm-runtime-watchdog llm-litellm-watchdog
                llm-crashguard llm-infra-gitops wiki-rebuild llm-stack-status llm-backup)

# --- Inferenz-Laufzeit -------------------------------------------------------
# Kanonische Ansprache der Laufzeit an einem Ort: API, Metriken, Containername
# und Image fuer Pruefskripte (healthcheck, doctor) und den Kennzahlensammler.
# Die Werte eines konkreten Rechners stehen in config/host.env, deshalb bestimmt
# diese Datei sie. Aufrufer lesen erst host.env und rufen danach runtime_identity
# auf:
#   source lib/units.sh
#   [[ -f config/host.env ]] && source config/host.env
#   runtime_identity
# Die Defaults beschreiben das Quadlet-Deployment (Container pennyroyal auf
# 127.0.0.1:8001). Ein direkt mit podman gestartetes vLLM hat keine eigene Unit;
# es setzt RUNTIME_UNIT leer und nennt Container, Port und Image in host.env.
runtime_identity() {
  RUNTIME_UNIT="${RUNTIME_UNIT-pennyroyal}"          # leer = laeuft ohne eigene Unit
  RUNTIME_CONTAINER="${RUNTIME_CONTAINER-pennyroyal}"
  RUNTIME_HOST="${RUNTIME_HOST-127.0.0.1}"
  RUNTIME_PORT="${RUNTIME_PORT-${PENNYROYAL_PORT:-8001}}"
  RUNTIME_HEALTH_PATH="${RUNTIME_HEALTH_PATH-/health}"
  RUNTIME_METRICS_PATH="${RUNTIME_METRICS_PATH-/metrics}"
  RUNTIME_MODELS_PATH="${RUNTIME_MODELS_PATH-/v1/models}"
  RUNTIME_IMAGE="${RUNTIME_IMAGE-${PENNYROYAL_IMAGE-ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3}}"
  RUNTIME_URL="http://${RUNTIME_HOST}:${RUNTIME_PORT}"
  RUNTIME_SERVICE="${RUNTIME_UNIT:+${RUNTIME_UNIT}.service}"
  RUNTIME_LEGACY_SERVICE='pennyroyal.service'
  return 0
}

runtime_logs_hint() {
  # Der Befehl, der die Logzeilen der Laufzeit zeigt: Unit-Log oder Container.
  if [[ -n "${RUNTIME_SERVICE}" ]]; then
    printf 'journalctl --user -u %s -n 120 --no-pager' "${RUNTIME_SERVICE}"
  else
    printf 'podman logs --tail 120 %s' "${RUNTIME_CONTAINER}"
  fi
}

runtime_is_running() {
  # True, wenn die Laufzeit laeuft: uber ihre Unit oder als (unmanaged) Container.
  if [[ -n "${RUNTIME_SERVICE}" ]] && systemctl --user is-active --quiet "${RUNTIME_SERVICE}"; then
    return 0
  fi
  [[ -n "${RUNTIME_CONTAINER}" ]] && have podman \
    && podman ps --format '{{.Names}}' 2>/dev/null | grep -qx -- "${RUNTIME_CONTAINER}"
}

prune_legacy_units() {
  local name
  for name in "${LEGACY_UNITS[@]}"; do
    [[ -e "${UNIT_DIR}/${name}" || -e "${WANTS_DIR}/${name}" ]] || continue
    systemctl --user stop --no-block "$(unit_service_name "${name}")" 2>/dev/null || true
    rm -f "${UNIT_DIR}/${name}" "${WANTS_DIR}/${name}"
    log 'veraltete Einheit entfernt: '"${name}"
  done
}

unit_service_name() {
  local name="$1"
  case "${name}" in
    *.container) printf '%s.service\n' "${name%.container}" ;;
    *.network)   printf '%s-network.service\n' "${name%.network}" ;;
    *.pod)       printf '%s-pod.service\n' "${name%.pod}" ;;
    *)           printf '%s\n' "${name}" ;;
  esac
}

render_unit() {
  # render_unit <file-name>  -> installiert unter UNIT_DIR mit Platzhalterersetzung.
  # Autostart richtet sich nach der Unit-Datei: nur Dateien mit WantedBy= bekommen
  # den .wants-Verweis. Eine Referenz-Unit ohne WantedBy bleibt installiert und ist
  # manuell startbar, laeuft aber beim naechsten Login nicht an - sonst wuerde die
  # Pennyroyal-Referenz bei jedem Start ein zweites Bild auf die Grafikkarte setzen
  # (oder mit fehlendem Bild endlos neu versuchen).
  local name="$1" src="${REPO_ROOT}/quadlet/$1"
  [[ -f "${src}" ]] || { log "FEHLT: quadlet/${name} existiert nicht (erst Generator ausführen)."; return 1; }
  install -d -m 0755 "${UNIT_DIR}" "${WANTS_DIR}"
  sed "s#@CONFIG_ROOT@#${REPO_ROOT}#g" "${src}" > "${UNIT_DIR}/${name}.tmp"
  chmod 0644 "${UNIT_DIR}/${name}.tmp"
  mv -f "${UNIT_DIR}/${name}.tmp" "${UNIT_DIR}/${name}"
  if grep -qs '^WantedBy=' "${src}"; then
    ln -sfn "../${name}" "${WANTS_DIR}/${name}"
    log "unit installiert und auf Autostart gesetzt: ${UNIT_DIR}/${name}"
  else
    rm -f "${WANTS_DIR}/${name}"
    log "unit installiert, ohne Autostart (kein WantedBy in ${name}): ${UNIT_DIR}/${name}"
  fi
}

install_units() {
  local name
  for name in "$@"; do render_unit "${name}"; done
}

install_systemd_units() {
  # System-level or plain user units shipped in systemd/ (watchdog, exporters).
  local name src dst_dir="$1"; shift
  for name in "$@"; do
    src="${SYSTEMD_SRC_DIR}/${name}"
    [[ -f "${src}" ]] || { log "FEHLT: systemd/${name} fehlt."; return 1; }
    install -d -m 0755 "${dst_dir}"
    sed "s#@CONFIG_ROOT@#${REPO_ROOT}#g" "${src}" > "${dst_dir}/${name}"
    chmod 0644 "${dst_dir}/${name}"
  done
}

systemd_reload() { systemctl --user daemon-reload; }

start_units() {
  # --no-block ist Absicht: systemctl wuerde sonst bis zum Ende des Starts
  # warten und bei einer fehlschlagenden Unit scheinbar haengen. Stattdessen
  # kurz nachsehen und jede Unit einzeln melden.
  local name svc state
  for name in "$@"; do
    svc="$(unit_service_name "${name}")"
    systemctl --user start --no-block "${svc}" 2>/dev/null \
      || log "WARNUNG: ${svc} konnte nicht gestartet werden (siehe: journalctl --user -u ${svc} -n 80)"
  done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    state=0
    for name in "$@"; do
      systemctl --user is-active --quiet "$(unit_service_name "${name}")" || state=1
    done
    [[ "${state}" == 0 ]] && break
    sleep 3
  done
  for name in "$@"; do
    svc="$(unit_service_name "${name}")"
    if systemctl --user is-active --quiet "${svc}"; then
      log "laeuft: ${svc}"
    else
      log "FEHLER: ${svc} laeuft nicht. Naechster Schritt: journalctl --user -u ${svc} -n 80 --no-pager"
    fi
  done
  return "${state}"
}

unit_is_active() { systemctl --user is-active --quiet "$(unit_service_name "$1")"; }

unit_exists() {
  # True, wenn die Einheit auf diesem Rechner installiert ist. LoadState statt
  # is-active: eine vorhandene, aber stehende Einheit ist messbar, eine
  # fehlende ("not-found") hat keinen Zustand und bekommt deshalb nichts.
  case "$(systemctl --user show "$1" -p LoadState --value 2>/dev/null || true)" in
    loaded|masked) return 0 ;;
    *) return 1 ;;
  esac
}

installed_unit_diff() {
  # Reports whether the installed unit differs from the rendered repository
  # version, which is how operators notice that a change needs a restart.
  local name="$1" rendered
  [[ -f "${UNIT_DIR}/${name}" ]] || { printf 'NOT-INSTALLED %s\n' "${name}"; return 1; }
  rendered="$(mktemp)"
  sed "s#@CONFIG_ROOT@#${REPO_ROOT}#g" "${REPO_ROOT}/quadlet/${name}" > "${rendered}"
  if diff -u "${UNIT_DIR}/${name}" "${rendered}"; then
    rm -f "${rendered}"; return 0
  fi
  rm -f "${rendered}"; return 1
}

# ---------------------------------------------------------------------------
# Drift-Kapsel. check-drift.sh laesst die Generatoren laufen, um ihre Ausgabe mit
# dem committeten Stand zu vergleichen. Ohne diese Kapsel waere das ein echter
# Ausrolllauf: Units nach ~/.config/containers/systemd installiert,
# daemon-reload ausgeloesen und Container gestartet - ein Prueflauf (und damit
# `make ci`) wuerde die lebende Konfiguration veraendern. Mit LLM_DRIFT=1 landen
# alle Ausroll-Schritte in einem leeren Ordner, und systemctl bleibt zu. Die
# Definitionen stehen am Dateiende, weil sie die oberen sonst wieder verdecken
# wuerden (die Datei wird von oben nach unten ausgefuehrt).
if [[ "${LLM_DRIFT:-0}" == '1' ]]; then
  UNIT_DIR="${LLM_DRIFT_UNIT_DIR:-${TMPDIR:-/tmp}/llm-drift-units}"
  WANTS_DIR="${UNIT_DIR}/default.target.wants"

  prune_legacy_units()     { log "LLM_DRIFT: veraltete Einheiten unberuehrt (Verzeichnis ${UNIT_DIR})"; }
  systemd_reload()         { log 'LLM_DRIFT: daemon-reload uebersprungen'; }
  start_units()            { log "LLM_DRIFT: Start uebersprungen: $*"; }

  # Die Funktion verdeckt das kommando: einzelne Generatoren rufen systemctl
  # direkt auf (reload/restart der eigenen Unit) statt ueber start_units. Ohne
  # diese Kapsel wuerde ein Prueflauf den laufenden Proxy neu starten.
  systemctl() { log "LLM_DRIFT: systemctl $* uebersprungen"; return 0; }

  install_systemd_units() {
    # Gleiche Arbeit, aber in den Drift-Ordner statt in die lebende Konfiguration.
    local name src dst_dir="$1"; shift
    for name in "$@"; do
      src="${SYSTEMD_SRC_DIR}/${name}"
      [[ -f "${src}" ]] || { log "FEHLT: systemd/${name} fehlt."; return 1; }
      install -d -m 0755 "${UNIT_DIR}"
      sed "s#@CONFIG_ROOT@#${REPO_ROOT}#g" "${src}" > "${UNIT_DIR}/${name}"
      chmod 0644 "${UNIT_DIR}/${name}"
    done
    log "LLM_DRIFT: systemd-Dateien nach ${UNIT_DIR} geschrieben"
  }
fi
