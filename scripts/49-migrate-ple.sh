#!/usr/bin/env bash
# PLE-Tabelle auf die native Blockflaeche umziehen - zerstoerungsfrei.
#
#   ./scripts/49-migrate-ple.sh             kopieren, pruefen, Zeiger umstellen
#   ./scripts/49-migrate-ple.sh --nur-pruefen
#   ./scripts/49-migrate-ple.sh --alt-loeschen   (erst nach einem erfolgreichen Lauf!)
#
# Die alte Loop-Datei bleibt erhalten, bis der neue Pfad nachweislich funktioniert.
# Der laufende Container wird nicht beroehrt: er haengt weiter an seinem alten
# Einhaengepunkt, die neue Unit zeigt erst nach dem naechsten Start auf die native Flaeche.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${PLE_STORAGE_MOUNT:=/srv/llm/ple-ext4}"
: "${PLE_NATIVE_MOUNT:=/srv/llm/ple-native}"
: "${PENNY_PLE_NVME_MODEL:=/srv/llm/ple-ext4/Qwen3.8-Flash-Next-PLE-NVME}"
ple_name="$(basename "${PENNY_PLE_NVME_MODEL}")"
src="${PLE_STORAGE_MOUNT}/${ple_name}"
dst="${PLE_NATIVE_MOUNT}/${ple_name}"
host_env="${root}/config/host.env"

mode=run
case "${1:-}" in
  --nur-pruefen) mode=check ;;
  --alt-loeschen) mode=cleanup ;;
esac

check_files() {
  # Die PLE-Ablage ist absichtlich eine Mischung: die Tabellen sind echte Dateien,
  # die Begleitdateien sind Verweise auf /models (die es nur im Container gibt).
  # Deshalb prueft diese Funktion den Index und die Tabellen, aber nicht die
  # Verweise - die duerfen auf dem Host ins Leere zeigen.
  local dir="$1"
  [[ -d "${dir}" ]] || { echo "FEHLT: Ordner nicht da: ${dir}" >&2; return 1; }
  # config.json und der Index können Verweise auf /models sein (nur im Container
  # aufloesbar). Deshalb gilt: Eintrag vorhanden (Verweis oder Datei) reicht.
  [[ -e "${dir}/model.safetensors.index.json" || -L "${dir}/model.safetensors.index.json" ]] \
    || { echo "FEHLT: Index fehlt in ${dir}" >&2; return 1; }
  [[ -e "${dir}/config.json" || -L "${dir}/config.json" ]] \
    || { echo "FEHLT: config.json fehlt in ${dir}" >&2; return 1; }
  local count
  count="$(find "${dir}" -maxdepth 1 -name '*.safetensors' | wc -l)"
  (( count > 0 )) || { echo "FEHLT: keine safetensors in ${dir}" >&2; return 1; }
  printf '%s' "${count}"
}

if [[ "${mode}" == cleanup ]]; then
  if ! mountpoint -q "${PLE_NATIVE_MOUNT}"; then
    echo "Abbruch: native Flaeche ist nicht eingehaengt; erst einrichten." >&2; exit 1
  fi
  check_files "${dst}" >/dev/null || { echo 'Abbruch: neue Tabelle ist nicht vollstaendig.' >&2; exit 1; }
  echo 'Die alte Loop-Datei wird NICHT automatisch geloescht, weil sie dein einziger'
  echo 'Rueckweg ist, falls die neue Flaeche ausfaellt. Von Hand, nach dem Test:'
  echo "  sudo umount ${PLE_STORAGE_MOUNT} 2>/dev/null; sudo losetup -D 2>/dev/null"
  echo "  sudo rm -f ${PLE_STORAGE_IMAGE:-/srv/llm/ple-nvme.ext4}"
  echo "  und in /etc/fstab die Loop-Zeile entfernen"
  exit 0
fi

mkdir -p "${dst}"
if ! mountpoint -q "${PLE_NATIVE_MOUNT}"; then
  echo "FEHLT: ${PLE_NATIVE_MOUNT} ist nicht eingehaengt." >&2
  echo "Jetzt ausführen: ./scripts/46-create-ple-volume.sh" >&2
  exit 1
fi
src_count="$(check_files "${src}")" || exit 1
log "Quellentabelle: ${src} (${src_count} Tabellendateien)"

if [[ "${mode}" == run ]]; then
  dst_count="$(check_files "${dst}" 2>/dev/null || echo 0)"
  if [[ "${dst_count}" == "${src_count}" ]]; then
    log "Ziel bereits vorhanden und zaehlgleich (${dst_count}); kopieren wird uebersprungen."
  else
    free_bytes="$(df -P -B1 "${PLE_NATIVE_MOUNT}" | awk 'NR==2 {print $4}')"
    need_bytes="$(du -sb --apparent-size "${src}" | awk '{print $1}')"
    if (( need_bytes > free_bytes )); then
      echo "FEHLT: Auf ${PLE_NATIVE_MOUNT} ist zu wenig Platz (${need_bytes} noetig, ${free_bytes} frei)." >&2
      echo "Groesse des Volumes anpassen: ./scripts/46-create-ple-volume.sh --size 120" >&2
      exit 1
    fi
    log "Kopiere ${need_bytes} Bytes (das dauert einige Minuten; Verweise bleiben Verweise) ..."
    # --safe-links waere falsch: die Verweise zeigen absichtlich auf /models
    # (nur im Container gueltig) und muessten erhalten bleiben.
    rsync -a --info=progress2 "${src}/" "${dst}/"
  fi
fi

# --- Pruefung: Dateinamen, Groessen, Indexinhalt, Stichproben-Pruefsumme ------
python3 - "${src}" "${dst}" <<'PY'
"""Vergleich Quell- und Zielablage.

Die PLE-Ablage besteht aus:
  * ple/layer-0.bin   - die eigentliche Tabelle (ein Block, ~48 GiB)
  * ssd-stream.json   - Beschreibung, wie die Runtime darin liest
  * model.safetensors.index.json und wenige echte Shard-Dateien
  * sehr viele Verweise auf /models (die nur im Container aufloesbar sind)

Die Verweise werden als Verweise verglichen (Zieltext), die echten Dateien nach
Groesse, und bei der grossen Tabelle zusaetzlich mit Stichproben-Pruefsummen vom
Anfang, der Mitte und dem Ende. Ein Voll-Hash von 48 GiB waer langsamer als der
Kopier itself und bringt nichts zusaetzliches.
"""
import hashlib, json, os, pathlib, sys

src, dst = map(pathlib.Path, sys.argv[1:3])
problems = []

def sample_digest(path: pathlib.Path) -> str:
    size = path.stat().st_size
    chunk = 64 * 1024 * 1024
    h = hashlib.sha256()
    with open(path, 'rb') as handle:
        for start in (0, size // 2, max(0, size - chunk)):
            handle.seek(start)
            h.update(handle.read(chunk))
    return h.hexdigest()

# 1) Indexdateien muessen identisch sein
a, b = src / 'model.safetensors.index.json', dst / 'model.safetensors.index.json'
if not b.is_file():
    problems.append('Indexdatei fehlt im Ziel')
elif json.loads(a.read_text()) != json.loads(b.read_text()):
    problems.append('Indexdateien unterscheiden sich')

# 2) Alle echten Dateien verglichen (Groesse), die grosse zusaetzlich mit Stichprobe
real = []
for path in sorted(src.rglob('*')):
    if path.is_symlink() or not path.is_file():
        continue
    rel = path.relative_to(src)
    other = dst / rel
    if not other.is_file():
        problems.append(f'fehlt im Ziel: {rel}')
        continue
    if path.stat().st_size != other.stat().st_size:
        problems.append(f'Groesse anders: {rel} ({path.stat().st_size} gegen {other.stat().st_size})')
        continue
    real.append(rel)
    if path.stat().st_size > 64 * 1024 * 1024:
        if sample_digest(path) != sample_digest(other):
            problems.append(f'Inhalt unterschiedlich (Stichprobe): {rel}')

# 3) Verweise muissen als gleiche Verweise angekommen sein
links = 0
for path in sorted(src.rglob('*')):
    if not path.is_symlink():
        continue
    rel = path.relative_to(src)
    other = dst / rel
    links += 1
    if not other.is_symlink():
        problems.append(f'Verweis fehlt oder ist eine echte Datei: {rel}')
    elif os.readlink(path) != os.readlink(other):
        problems.append(f'Verweis zeigt woanders hin: {rel}')

if problems:
    print('PRUEFUNG FEHLERHALFT:')
    for line in problems[:15]:
        print('   ', line)
    if len(problems) > 15:
        print(f'    ... und {len(problems) - 15} weitere')
    raise SystemExit(1)
print(f'PRUEFUNG OK: {len(real)} echte Dateien kopiert (darunter die Tabelle), {links} Verweise erhalten')
for rel in real:
    print(f'   {rel}  {(src / rel).stat().st_size / 2**30:.2f} GiB')
PY

# --- Zeiger in der lokalen Konfiguration umstellen ----------------------------
if [[ "${mode}" == check ]]; then
  log 'Prueflauf: config/host.env wird absichtlich nicht geaendert.'
  exit 0
fi
if grep -q '^PENNY_PLE_NVME_MODEL=' "${host_env}"; then
  sed -i "s#^PENNY_PLE_NVME_MODEL=.*#PENNY_PLE_NVME_MODEL=${dst}#" "${host_env}"
else
  printf 'PENNY_PLE_NVME_MODEL=%s\n' "${dst}" >> "${host_env}"
fi
log "config/host.env zeigt jetzt auf ${dst}"
log 'Der laufende Container bleibt unangetastet; wirksam wird der neue Pfad beim naechsten Start.'
printf '\nNaechste Schritte\n'
printf '  1. Native Unit erzeugen:   PLE_Pfad wird gelesen -> ./scripts/50-install-pennyroyal.sh\n'
printf '  2. Warmfahren (Seite-Cache): ./scripts/ple-preload.sh\n'
printf '  3. Wenn die GPU frei ist:   ./scripts/apply-tuning.sh\n'
