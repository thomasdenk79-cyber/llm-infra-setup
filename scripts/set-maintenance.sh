#!/usr/bin/env bash
# Wartungsfenster fuer die Statusseiten an- und abmelden.
#
# Waehrend ein Fenster gilt, melden die Seiten MAINTENANCE statt STOERUNG
# (Sammler liest maintenance.json, Panel 'Wartungsfenster' zeigt grund und bis).
#
#   ./scripts/set-maintenance.sh start <dienst|*> [grund] [bis]
#   ./scripts/set-maintenance.sh end   <dienst|*>
#   ./scripts/set-maintenance.sh status
#
# Beispiel:
#   ./scripts/set-maintenance.sh start litellm "Rollout 2026-11-18" "12:30"
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
DATEI="${LLM_INCIDENT_STATE_DIR:-${HOME}/.local/share/llm-infra/incident}/maintenance.json"

case "${1:-}" in
  start)
    dienst="${2:?Dienstname oder * fehlt}"
    grund="${3:-geplante Arbeiten}"
    bis="${4:-}"
    install -d -m 0755 "$(dirname "${DATEI}")"
    python3 - "${DATEI}" "${dienst}" "${grund}" "${bis}" <<'PY'
import datetime, json, os, sys
datei, dienst, grund, bis = sys.argv[1:5]
try:
    eintraege = json.load(open(datei, encoding="utf-8"))
    if not isinstance(eintraege, list):
        eintraege = [eintraege]
except Exception:
    eintraege = []
eintraege = [e for e in eintraege if e.get("service") != dienst]
if not bis:
    bis = (datetime.datetime.now() + datetime.timedelta(minutes=30)).strftime("%H:%M")
eintraege.append({"service": dienst, "grund": grund, "bis": bis})
tmp = datei + ".tmp"
json.dump(eintraege, open(tmp, "w", encoding="utf-8"), ensure_ascii=False)
os.replace(tmp, datei)
print("Wartungsfenster eingetragen: %s bis %s (%s)" % (dienst, bis, grund))
PY
    ;;
  end)
    dienst="${2:?Dienstname oder * fehlt}"
    [[ -r "${DATEI}" ]] || { log 'Kein Wartungsfenster hinterlegt.'; exit 0; }
    python3 - "${DATEI}" "${dienst}" <<'PY'
import json, os, sys
datei, dienst = sys.argv[1:3]
try:
    eintraege = json.load(open(datei, encoding="utf-8"))
    if not isinstance(eintraege, list):
        eintraege = [eintraege]
except Exception:
    eintraege = []
vor = len(eintraege)
eintraege = [e for e in eintraege if e.get("service") != dienst]
tmp = datei + ".tmp"
json.dump(eintraege, open(tmp, "w", encoding="utf-8"), ensure_ascii=False)
os.replace(tmp, datei)
print("entfernt: %d" % (vor - len(eintraege)) if vor != len(eintraege) else "kein Fenster gefunden")
PY
    ;;
  status|"")
    if [[ -r "${DATEI}" ]]; then cat "${DATEI}"; else echo '[]'; fi
    ;;
  *)
    die "Befehl start|end|status erwartet, erhalten: ${1}"
    ;;
esac
log 'Naechster Schritt: ./scripts/collect-stack-status.sh --pruefen (zeigt llm_maintenance_info)'
