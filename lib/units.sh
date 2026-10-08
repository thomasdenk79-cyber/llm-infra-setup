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
  dozzle.container
  llm-gpu-exporter.container
  llm-node-exporter.container
  homepage.container
  wiki.container
)
# Optional units that need operator credentials before they make sense.
OPTIONAL_UNITS=(llm-autossh.container komodo-periphery.container)

# Fruehere Namen von Einheiten, die umbenannt wurden. Sie werden bei jedem Deploy
# entfernt, sonst bleiben zwei Units mit demselben Containernamen uebrig und
# bringten sich gegenseitig zum Neustart.
LEGACY_UNITS=(gpu-exporter.container node-exporter.container)

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
  # render_unit <file-name>  -> installs under UNIT_DIR with placeholder
  # substitution and enables it through default.target.wants.
  local name="$1" src="${REPO_ROOT}/quadlet/$1"
  [[ -f "${src}" ]] || { log "FEHLT: quadlet/${name} existiert nicht (erst Generator ausführen)."; return 1; }
  install -d -m 0755 "${UNIT_DIR}" "${WANTS_DIR}"
  sed "s#@CONFIG_ROOT@#${REPO_ROOT}#g" "${src}" > "${UNIT_DIR}/${name}.tmp"
  chmod 0644 "${UNIT_DIR}/${name}.tmp"
  mv -f "${UNIT_DIR}/${name}.tmp" "${UNIT_DIR}/${name}"
  ln -sfn "../${name}" "${WANTS_DIR}/${name}"
  log "unit installiert: ${UNIT_DIR}/${name}"
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
