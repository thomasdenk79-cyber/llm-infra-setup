#!/usr/bin/env bash
# Prüft, ob die committeten Unit-Dateien genau das Ergebnis der Generatoren sind.
#
# Hintergrund: Mehrere Units werden von Skripten geschrieben. Aendert jemand eine
# Unit-Datei von Hand statt des Generators, driften Repository und Wirklichkeit
# auseinander - dieser Lauf faellt dann auf. Laeuft auch im CI (`make ci`).
#
#   ./scripts/check-drift.sh              pruefen, nichts anruehren
#
# So wird geprueft, ohne etwas zu veraendern: die Generatoren laufen in einer
# weggeworfenen Arbeitskopfe des committeten Standes (git worktree), und die
# Drift-Kapsel aus lib/units.sh (LLM_DRIFT=1) sorgt dafuer, dass dabei keine Unit
# in ~/.config/containers/systemd landet, kein daemon-reload laeuft und kein
# Container startet. Beides ist hier zwingend: die Generatoren sind
# Installations-skripte, ein unbewachter Prueflauf wuerde sonst die lebende
# Konfiguration ausrollen - und bei einem Generator, der eine andere Laufzeit
# beschreibt, stünde am Ende ein fremdes Bild in der Unit-Datei des laufenden
# Betriebs.
#
# Frueher liefen die Generatoren im Arbeitsverzeichnis; der Vergleich war dann
# "Generator schreibt, git diff zeigt". Das war derselbe Eingriff, den die Pruefung
# melden soll. --restore ist deshalb weggefallen: es gibt nichts mehr
# zurueckzuholen.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
source "${root}/lib/common.sh"

for arg in "$@"; do
  case "${arg}" in
    --restore) die '--restore gibt es nicht mehr: die Pruefung laeuft in einer weggeworfenen Arbeitskopfe und aendert nichts. Bei Abweichung im echten Baum: git restore -- quadlet config/litellm.yaml' ;;
    *) die "Unbekannte Option: ${arg}" ;;
  esac
done

if ! command -v podman >/dev/null 2>&1; then
  echo 'uebersprungen: podman nicht vorhanden (z. B. CI-Laufer).'
  exit 0
fi

tracked="$(git status --porcelain -- quadlet config/litellm.yaml config/proxy/Caddyfile 2>/dev/null)"
if [[ -n "${tracked}" ]]; then
  echo 'Im Arbeitsverzeichnis liegen ungecommittete Aenderungen an generierten Dateien.'
  echo 'Bitte zuerst committen oder mit git restore zuruecknehmen, dann erneut pruefen:'
  printf '%s\n' "${tracked}"
  exit 1
fi

tmp="$(mktemp -d -t llm-drift-XXXXXX)"
wt="${tmp}/repo"
cleanup() {
  git worktree remove --force "${wt}" >/dev/null 2>&1 || rm -rf "${wt}"
  rm -rf "${tmp}"
}
trap cleanup EXIT

run git worktree add --detach "${wt}" HEAD

# Die Generatoren lesen Skripte, lib/, config/ und versions.lock aus ihrem eigenen
# Verzeichnis. Der Vergleich soll deren aktuelle (arbeitsverzeichnis-)Fassung gegen
# den committeten Stand stellen, also diese Bestaende in die Kopfe uebertragen -
# sonst pruefte make drift einen Stand, den niemand ausrollen will.
for pfad in scripts lib config quadlet systemd; do
  [[ -d "${root}/${pfad}" ]] && cp -a "${root}/${pfad}/." "${wt}/${pfad}/"
done
[[ -f "${root}/versions.lock" ]] && cp -a "${root}/versions.lock" "${wt}/versions.lock"

export LLM_DRIFT=1
export LLM_DRIFT_UNIT_DIR="${tmp}/units"

# Diese Skripte schreiben quadlet/ und config/litellm.yaml; ihre Ausgabe ist der
# Soll-Stand, gegen den der committete Stand verglichen wird.
for generator in \
  ./scripts/50-install-pennyroyal.sh \
  ./scripts/60-install-gateway.sh \
  ./scripts/60-install-open-webui.sh \
  ./scripts/60-install-homepage.sh \
  ./scripts/60-install-wiki.sh \
  ./scripts/63-install-postgres.sh \
  ./scripts/65-install-gpu-exporter.sh \
  ./scripts/80-setup-incident-agent.sh \
  ./scripts/76-setup-runtime-unit.sh \
  ./scripts/74-setup-local-proxy.sh
do
  [[ -x "${root}/${generator#./}" ]] || die "Generator fehlt oder ist nicht ausführbar: ${generator}"
  ( cd "${wt}" && run "${generator}" ) >/dev/null 2>&1 \
    || die "Generator lief nicht durch: ${generator}  (von Hand nachfahren: ${root}/${generator#./})"
done

# --- Dokumentierte Ausnahmen -------------------------------------------------
# Dateien, deren committete Fassung bewusst nicht dem Generatorergebnis entspricht.
# Eine Ausnahme ist eine Entscheidung mit Begruendung, kein Wegsehen: die Abweichung
# wird bei jedem Lauf ausgegeben (Kurzstatistik plus Begruendung), und der Verweis auf
# die Begruendung muss stimmen - sonst ist der Eintrag ein Fehler, keine Ausnahme.
#   quadlet/pennyroyal.container
#     Betreiber-Fork localhost/flash-next-sm120:serving statt dem Upstream-Bild
#     ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3. Der Fork traegt die sm120-Schalter
#     und die mamba-19-lazy-Konfiguration; der Generator kennt den Fork nicht, weil
#     er das Upstream-Image pinnt. Betreiberentscheidung vom 2026-11-16, Begruendung
#     in docs/status.md (Abschnitt 'Pennyroyal-Abweichung').
ausnahmen=( 'quadlet/pennyroyal.container' )

# Der Vergleich nimmt die Ausnahmen per Pfadausschluss heraus; geprueft wird trotzdem
# gegen dieselbe weggeworfene Kopfe.
pruef_pfade=( quadlet config/litellm.yaml config/proxy/Caddyfile )
for ausnahme in "${ausnahmen[@]}"; do
  pruef_pfade+=( ":(exclude)${ausnahme}" )
done

for ausnahme in "${ausnahmen[@]}"; do
  if ! git -C "${wt}" diff --quiet -- "${ausnahme}"; then
    printf '\nAUSNAHME aktiv (bewusste Abweichung, nicht versteckt): %s\n' "${ausnahme}"
    git -C "${wt}" --no-pager diff --stat -- "${ausnahme}" | sed 's/^/     /'
    printf '     Begruendung: Betreiber-Fork statt Upstream-Bild - docs/status.md, Abschnitt "Pennyroyal-Abweichung".\n'
    printf '     Aufloesen: entweder den Fork in den Generator schreiben, oder git checkout HEAD -- %s\n' "${ausnahme}"
  fi
done

if git -C "${wt}" diff --quiet -- "${pruef_pfade[@]}"; then
  echo 'KEINE DRIFT: committete Units entsprechen den Generatoren (dokumentierte Ausnahmen ausgenommen).'
  exit 0
fi

echo 'DRIFT GEFUNDEN - die Generatoren erzeugen etwas anderes als committet ist:'
git -C "${wt}" --no-pager diff -- "${pruef_pfade[@]}"
echo
echo 'Das Arbeitsverzeichnis ist unveraendert; verglichen wurde die weggeworfene Kopfe.'
echo 'Entweder die Aenderung ist gewollt: git add quadlet config/litellm.yaml config/proxy/Caddyfile && git commit'
echo 'Oder sie war ein Versehen:          git restore -- quadlet config/litellm.yaml config/proxy/Caddyfile'
echo 'Und wenn der Generator selbst falsch ist: im Generator-Skript aendern, dann erneut pruefen.'
echo 'Neue Ausnahme anlegen: nur in diesem Skript, mit Begruendung und Datum - nie durch stillschweigendes Weglassen.'
exit 1
