#!/usr/bin/env bash
# Crashguard: beobachtet Quadlet-Container im Experimentierbetrieb (Forks, neue
# Configs, neue Parameter). Ein kaputter Pod wird von systemd nach
# CRASHGUARD_MAX_FAILS Versuchen in den failed-Zustand gestellt (StartLimit);
# Crashguard erkennt das und rollt konsistent zurueck: Image (digest-piniert),
# Quadlet-Datei und mitgegebene Share-/Config-Dateien aus einem Snapshot auf
# dem lokalen Git-Branch crashguard-lkg - analog zu einem OpenShift-Rollback
# auf die letzte Release-Version. Kein Dauer-Neustartkapitel, kein Ping-Pong:
# ist auch das LKG kaputt, greift die Loopsperre bis zum manuellen Reset.
#
#   ./scripts/crashguard.sh check                    ein Durchlauf (Timer ruft das)
#   ./scripts/crashguard.sh status                   Uebersicht aller Einheiten
#   ./scripts/crashguard.sh promote <unit> [--label L]  konsistenten LKG-Snapshot erzeugen
#   ./scripts/crashguard.sh rollback <unit> [--to L]   zurueck auf Snapshot (default: latest)
#   ./scripts/crashguard.sh list-lkg <unit>            verfuegbare Snapshots
#   ./scripts/crashguard.sh mark-good <unit>           Alias fuer promote --label manual
#   ./scripts/crashguard.sh arm|disarm <unit>          StartLimit-Dropin setzen/entfernen
#   ./scripts/crashguard.sh reset <unit>               Loopsperre/Zaehler freigeben
#   ./scripts/crashguard.sh --install|--uninstall
#
# Zusatz-Shares zum Snapshoten pro Unit in config/host.env:
#   CRASHGUARD_TRACK_pennyroyal="/pfad/datei /pfad2/datei"
#
# Schutzregeln (wie litellm-watchdog.sh): GPU-Sperre (copilot-sm120-gpu.lock)
# blockiert Rollbacks in dieser Runde; laufende Anfragen werden nicht gestoert,
# weil Crashguard nur bei bereits failed-Zustand eingreift. Git-Zugriffe sind
# reine Plumbing-Kommandos auf refs/heads/crashguard-lkg - Working Tree, Index
# und Hauptbranch anderer Agenten bleiben unberuehrt.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/lib/common.sh"
# shellcheck disable=SC1091
source "${root}/lib/units.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${CRASHGUARD_UNITS:=pennyroyal bonsai litellm}"
: "${CRASHGUARD_MAX_FAILS:=2}"
: "${CRASHGUARD_GRACE_S:=240}"
: "${CRASHGUARD_WINDOW_S:=3600}"
LKG_BRANCH="crashguard-lkg"
state_dir="${STATE_DIR}/crashguard"
log_file="${state_dir}/crashguard.log"
mkdir -p "${state_dir}"

say() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "${log_file}"; }

unit_state_dir() { local d="${state_dir}/$1"; mkdir -p "$d"; printf '%s' "$d"; }
quadlet_file() { printf '%s/%s.container' "${UNIT_DIR}" "$1"; }
dropin_dir() { printf '%s/%s.service.d' "${HOME}/.config/systemd/user" "$1"; }
current_image() {
  local f; f="$(quadlet_file "$1")"
  [[ -f "$f" ]] || return 0
  awk -F= '/^Image=/{print substr($0, 7); exit}' "$f"
}
image_id() { podman image inspect --format '{{.Id}}' "$1" 2>/dev/null || true; }
container_health() { podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null || true; }
props() { systemctl --user show "$1.service" -p ActiveState -p SubState -p NRestarts -p Result 2>/dev/null; }
read_props() { # read_props <unit> <array-var> -> ActiveState SubState NRestarts Result
  local out; out="$(props "$1")"; local -n _o="$2"
  _o[0]="$(awk -F= '/^ActiveState=/{print $2; exit}' <<<"$out")"
  _o[1]="$(awk -F= '/^SubState=/{print $2; exit}' <<<"$out")"
  _o[2]="$(awk -F= '/^NRestarts=/{print $2; exit}' <<<"$out")"
  _o[3]="$(awk -F= '/^Result=/{print $2; exit}' <<<"$out")"; }
gpu_lock_busy() {
  local lock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/copilot-sm120-gpu.lock"
  [[ -e "${lock}" ]] || return 1
  local fd; exec 9<>"${lock}" 2>/dev/null || return 1
  if flock -n 9; then flock -u 9; exec 9>&-; return 1; fi
  exec 9>&-
  return 0
}
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || true; }

arm_dropin() {
  local u="$1" d; d="$(dropin_dir "$u")"
  install -d -m 0755 "$d"
  printf '# generiert von scripts/crashguard.sh\n[Unit]\nStartLimitBurst=%s\nStartLimitIntervalSec=%s\n' \
    "${CRASHGUARD_MAX_FAILS}" "${CRASHGUARD_WINDOW_S}" > "${d}/50-crashguard.conf"
  log "Dropin gesetzt: ${u} (Burst=${CRASHGUARD_MAX_FAILS}, Fenster=${CRASHGUARD_WINDOW_S}s)"
}

tracked_files() {
  # Zu snapshotende Dateien einer Unit: installierte Quadlet-Datei, Repo-Quadlet-
  # Quelle (falls vorhanden), Einzel-Volume-/EnvironmentFile-Quellen aus der
  # Quadlet-Datei, plus CRASHGUARD_TRACK_<unit> aus host.env.
  local u="$1" f line host
  f="$(quadlet_file "$u")"
  [[ -f "$f" ]] && printf '%s\n' "$f"
  [[ -f "${root}/quadlet/${u}.container" ]] && printf '%s\n' "${root}/quadlet/${u}.container"
  while IFS= read -r line; do
    host="${line%%:*}"
    [[ "$host" == /* && -f "$host" ]] && printf '%s\n' "$host"
  done < <(grep -E '^(Volume|EnvironmentFile)=' "$f" 2>/dev/null | cut -d= -f2-)
  local var="CRASHGUARD_TRACK_${u//-/_}" extra
  extra="${!var:-}"
  for host in $extra; do [[ -f "$host" ]] && printf '%s\n' "$host"; done
}

promote_lkg() {
  local u="$1" label="${2:-}"
  local img id head d
  img="$(current_image "$u")"; [[ -n "$img" ]] || { say "KEIN Image= in $(quadlet_file "$u") - nichts zu promovieren."; return 1; }
  id="$(image_id "$img")"; [[ -n "$id" ]] || { say "WARN Image ${img} nicht im Store - keine LKG-Promotion."; return 1; }
  [[ -n "$label" ]] || label="auto-$(date +%Y%m%d-%H%M%S)"
  label="${label//[^A-Za-z0-9._-]/_}"
  head="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo none)"
  d="$(mktemp -d)"
  local rc=0 pyout
  pyout="$(python3 - "$root" "$LKG_BRANCH" "$u" "$label" "$img" "$id" "$head" "$(tracked_files "$u" | tr '\n' ',')" "$d" <<'PY'
import sys, os, json, hashlib, subprocess
root, branch, unit, label, img, iid, head, files_csv, work = sys.argv[1:10]
files = [f for f in files_csv.split(",") if f]
rel = f"snapshots/{unit}/{label}"
manifest = {"unit": unit, "label": label,
            "ts": subprocess.run(["date","-Is"],capture_output=True,text=True).stdout.strip(),
            "image_ref": img, "image_id": iid, "git_head": head, "files": []}
os.makedirs(os.path.join(work, rel, "files"), exist_ok=True)
def git(*a, **kw):
    return subprocess.run(["git","-C",root,*a], capture_output=True, text=True, check=True, **kw)
blobs = {}
for i, fp in enumerate(files):
    try:
        data = open(fp, "rb").read()
    except OSError:
        continue
    name = f"{i:02d}-{os.path.basename(fp)}"
    r = f"{rel}/files/{name}"
    with open(os.path.join(work, r), "wb") as fh:
        fh.write(data)
    blobs[r] = git("hash-object", "-w", os.path.join(work, r)).stdout.strip()
    manifest["files"].append({"host_path": fp, "rel": r, "sha256": hashlib.sha256(data).hexdigest()})
with open(os.path.join(work, f"{rel}/manifest.json"), "w") as fh:
    json.dump(manifest, fh, indent=1)
blobs[f"{rel}/manifest.json"] = git("hash-object", "-w", os.path.join(work, f"{rel}/manifest.json")).stdout.strip()
def build_tree(entries):
    files_, dirs = {}, {}
    for p, h in entries.items():
        first, sep, rest = p.partition("/")
        if sep == "":
            files_[first] = h
        else:
            dirs.setdefault(first, {})[rest] = h
    items = {n: ("100644 blob", h) for n, h in files_.items()}
    for n, kids in dirs.items():
        items[n] = ("40000 tree", build_tree(kids))
    listing = "".join(f"{m} {h}\t{n}\n" for n, (m, h) in sorted(items.items()))
    return subprocess.run(["git","-C",root,"mktree"], input=listing, capture_output=True,
                          text=True, check=True).stdout.strip()
top = build_tree(blobs)
for _ in range(3):
    old = subprocess.run(["git","-C",root,"rev-parse","--verify","--quiet","refs/heads/"+branch],
                         capture_output=True, text=True).stdout.strip()
    args = ["commit-tree", top, "-m", f"lkg({unit}): {label} image={img} id={iid[:19]}"]
    if old:
        args[1:1] = ["-p", old]
    commit = git(*args).stdout.strip()
    if old:
        rc = subprocess.run(["git","-C",root,"update-ref","refs/heads/"+branch, commit, old]).returncode
    else:
        rc = subprocess.run(["git","-C",root,"update-ref","refs/heads/"+branch, commit]).returncode
    if rc == 0:
        break
print(commit[:12])
PY
)" || rc=$?
  [[ -n "${d:-}" ]] && rm -rf "$d"
  if (( rc != 0 )) || [[ -z "$pyout" ]]; then
    say "FEHLER ${u}: LKG-Snapshot fehlgeschlagen (rc=${rc})"
    return 1
  fi
  say "LKG-Snapshot gespeichert: ${u} label=${label} image=${img} (${id:7:12}) commit=${pyout}"
}

latest_lkg_label() {
  local u="$1"
  git -C "$root" log --format='%s' "${LKG_BRANCH}" -- "snapshots/${u}/" 2>/dev/null \
    | head -1 | sed -E 's/^lkg\([^)]*\): ([^ ]+) .*/\1/' || true
}

list_lkg() {
  local u="$1"
  git -C "$root" log --format='%cd %s' --date=short "${LKG_BRANCH}" -- "snapshots/${u}/" 2>/dev/null || \
    { say "Kein Branch ${LKG_BRANCH} - noch keine Snapshots."; return 1; }
}

rollback_unit() {
  local u="$1" label="${2:-}" d f cur img id
  d="$(unit_state_dir "$u")"
  [[ -n "$label" ]] || label="$(latest_lkg_label "$u")"
  [[ -n "$label" ]] || { say "FEHLER ${u}: kein LKG-Snapshot vorhanden."; return 1; }
  if gpu_lock_busy; then say "${u}: GPU-Sperre belegt - Rollback verschoben (naechste Runde)."; return 0; fi
  f="$(quadlet_file "$u")"
  cur="$(current_image "$u")"
  say "${u}: Rollback auf Snapshot '${label}' (aktuell: Image=${cur:-?})."
  [[ -e "${f}.bak-crashguard" ]] && cp -a "${f}.bak-crashguard" "${f}.bak-crashguard.$(date +%s)" || cp -a "$f" "${f}.bak-crashguard"
  local mtmp; mtmp="$(mktemp)"
  git -C "$root" show "${LKG_BRANCH}:snapshots/${u}/${label}/manifest.json" > "$mtmp" 2>/dev/null \
    || { rm -f "$mtmp"; say "FEHLER ${u}: Snapshot ${label} nicht gefunden."; touch "${d}/halted"; return 1; }
  img=$(python3 -c "import json,sys; print(json.load(open('$mtmp'))['image_ref'])")
  id=$(python3 -c "import json,sys; print(json.load(open('$mtmp'))['image_id'])")
  if [[ -z "$(image_id "${id}")" ]]; then
    say "${u}: LKG-Image nicht im Store - versuche Pull ${img}"
    podman pull "${img%%:*}@${id}" 2>>"${log_file}" || { rm -f "$mtmp"; say "FEHLER ${u}: Image nicht beschaffbar. Handarbeit noetig."; touch "${d}/halted"; return 1; }
  fi
  python3 - "$root" "$LKG_BRANCH" "$u" "$label" "$mtmp" "$f" "$img" "$id" <<'PY'
import sys, os, json, hashlib, subprocess
root, branch, unit, label, mtmp, quadlet, img, iid = sys.argv[1:9]
manifest = json.load(open(mtmp))
# 1) installierte Quadlet-Datei aus Snapshot wiederherstellen (Image digest-piniert)
for entry in manifest["files"]:
    hp = entry["host_path"]
    if hp.endswith(f"/{unit}.container") and "/containers/systemd/" in hp:
        blob = subprocess.run(["git","-C",root,"show",f"{branch}:{entry['rel']}"], capture_output=True, check=True).stdout
        lines, done = [], False
        for ln in blob.decode().splitlines(True):
            if ln.startswith("Image=") and not done:
                # Podman erlaubt name:tag@digest NICHT - name@digest ist Pflicht.
                lines.append(f"Image={img.split('@')[0].split(':')[0]}@{iid}\n"); done = True
            elif ln.startswith("Image="):
                continue
            else:
                lines.append(ln)
        open(quadlet, "w").writelines(lines)
        break
# 2) Share-/Config-Dateien restaurieren, deren Inhalt vom Snapshot abweicht.
#    Repo-Quadlet-Quellen werden NICHT überschrieben (andere Agenten arbeiten dort).
restored = []
for entry in manifest["files"]:
    hp = entry["host_path"]
    if hp.endswith(".container"):
        continue
    cur_hash = hashlib.sha256(open(hp, "rb").read()).hexdigest() if os.path.exists(hp) else None
    if cur_hash == entry["sha256"]:
        continue
    blob = subprocess.run(["git","-C",root,"show",f"{branch}:{entry['rel']}"], capture_output=True, check=True).stdout
    if os.path.exists(hp):
        subprocess.run(["cp","-a",hp,hp+".bak-crashguard"], check=False)
    open(hp, "wb").write(blob)
    restored.append(hp)
print(",".join(restored) if restored else "none")
PY
  rm -f "$mtmp"
  systemctl --user stop "${u}.service" 2>/dev/null || true
  systemctl --user reset-failed "${u}.service" 2>/dev/null || true
  systemd_reload
  systemctl --user start --no-block "${u}.service" || say "WARN ${u}: Start nach Rollback fehlgeschlagen."
  echo 0 > "${d}/fails"
  say "Rollback abgeschlossen: ${u} -> ${label}"
}

check_unit() {
  local u="$1" d active sub restarts result health img cur_id now last_stable fails
  d="$(unit_state_dir "$u")"
  if [[ -e "${d}/halted" ]]; then
    say "${u}: Loopsperre aktiv - kein Eingriff (freigeben: crashguard.sh reset ${u})"
    return 0
  fi
  local -a pv=(); read_props "$u" pv
  active="${pv[0]}"; sub="${pv[1]}"; restarts="${pv[2]:-0}"; result="${pv[3]}"
  if [[ -z "$active" && -z "$sub" ]]; then
    say "${u}: Unit nicht gefunden (Quadlet fehlt?) - übersprungen."; return 0
  fi
  restarts="${restarts:-0}"
  now="$(date +%s)"
  img="$(current_image "$u")"
  cur_id="$(image_id "$img")"

  if [[ "$sub" == running ]]; then
    health="$(container_health "$u")"
    if [[ -z "$health" || "$health" == healthy ]]; then
      last_stable="$(cat "${d}/stable_since" 2>/dev/null || echo 0)"
      if [[ "$(cat "${d}/last_restarts" 2>/dev/null || echo x)" != "$restarts" ]]; then
        last_stable="$now"; echo "$now" > "${d}/stable_since"; echo "$restarts" > "${d}/last_restarts"
      fi
      if (( now - last_stable >= CRASHGUARD_GRACE_S )); then
        local want_id latest_label latest_id
        latest_label="$(latest_lkg_label "$u")"
        if [[ -n "$latest_label" ]]; then
          latest_id="$(git -C "$root" show "${LKG_BRANCH}:snapshots/${u}/${latest_label}/manifest.json" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["image_id"])' 2>/dev/null || true)"
        fi
        if [[ -n "$cur_id" && "$cur_id" != "${latest_id:-}" ]]; then
          promote_lkg "$u" || true
        fi
        if [[ "$(cat "${d}/fails" 2>/dev/null || echo 0)" != 0 ]]; then
          echo 0 > "${d}/fails"; say "${u}: wieder stabil (${CRASHGUARD_GRACE_S}s grace) - Zaehler zurueckgesetzt."
        fi
      fi
      systemctl --user reset-failed "${u}.service" 2>/dev/null || true
    fi
    return 0
  fi

  if [[ "$sub" == failed || "$result" == exit-code || "$result" == failure ]]; then
    fails="$(cat "${d}/fails" 2>/dev/null || echo 0)"
    fails=$((fails + 1)); echo "$fails" > "${d}/fails"
    echo 0 > "${d}/stable_since"
    if (( fails < 2 )); then
      say "${u}: failed (Result=${result}, NRestarts=${restarts}) - beobachte noch (Versuch ${fails})."
      return 0
    fi
    local latest_label latest_id
    latest_label="$(latest_lkg_label "$u")"
    if [[ -z "$latest_label" ]]; then
      say "FEHLER ${u}: Crashloop, aber KEIN LKG-Snapshot. Arbeitsenden Stand promoting: crashguard.sh promote ${u} --label release-x (im gesunden Zustand)."
      touch "${d}/halted"; return 1
    fi
    latest_id="$(git -C "$root" show "${LKG_BRANCH}:snapshots/${u}/${latest_label}/manifest.json" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["image_id"])' 2>/dev/null || true)"
    if [[ -n "$cur_id" && "$cur_id" == "$latest_id" ]]; then
      say "FEHLER ${u}: auch das LKG-Image (latest='${latest_label}') startet nicht - Loopsperre, Handarbeit noetig. Journal: journalctl --user -u ${u}.service -n 120 --no-pager"
      touch "${d}/halted"; return 1
    fi
    say "${u}: Crashloop bestaetigt (${fails} Runden failed) - konsistenter Rollback auf Snapshot."
    rollback_unit "$u" "$latest_label"
    return 1
  fi
  return 0
}

status_unit() {
  local u="$1" d active sub restarts result img latest
  d="$(unit_state_dir "$u")"
  local -a pv=(); read_props "$u" pv
  active="${pv[0]:-?}"; sub="${pv[1]:-?}"; restarts="${pv[2]:-0}"; result="${pv[3]:-}"
  img="$(current_image "$u")"
  latest="$(latest_lkg_label "$u")"; latest="${latest:-none}"
  local halted; halted=$([[ -e "${d}/halted" ]] && printf 'HALT' || printf 'ok')
  printf '%-16s %-12s R:%-4s LKG=%-24s [%s] image=%s\n' "$u" "${active}/${sub}" "${restarts:-0}" "$latest" "$halted" "${img:-?}"
}

declare -a units=(); read -ra units <<< "${CRASHGUARD_UNITS}"
cmd="${1:-check}"; shift || true
extra_units="" TARGET="" LABEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --units) extra_units="${2//,/ }"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --to) LABEL="$2"; shift 2 ;;
    --grace) CRASHGUARD_GRACE_S="$2"; shift 2 ;;
    --max-fails) CRASHGUARD_MAX_FAILS="$2"; shift 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done
[[ -n "$extra_units" ]] && read -ra units <<< "$extra_units"

case "${cmd}" in
  check)   for u in "${units[@]}"; do check_unit "$u" || true; done ;;
  status)  log 'Crashguard-Status:'; for u in "${units[@]}"; do status_unit "$u"; done ;;
  promote|mark-good) [[ -n "${TARGET:-}" ]] || { echo 'usage: crashguard.sh promote <unit> [--label L]' >&2; exit 2; }
                     promote_lkg "$TARGET" "${LABEL:-${cmd}}" ;;
  rollback) [[ -n "${TARGET:-}" ]] || { echo 'usage: crashguard.sh rollback <unit> [--to LABEL]' >&2; exit 2; }
            TARGET="${TARGET%.service}"; TARGET="${TARGET%.container}"
            rollback_unit "$TARGET" "${LABEL:-}" ;;
  list-lkg) [[ -n "${TARGET:-}" ]] && list_lkg "$TARGET" ;;
  arm)    [[ -n "${TARGET:-}" ]] || { echo 'usage: crashguard.sh arm <unit>' >&2; exit 2; }
          TARGET="${TARGET%.service}"; TARGET="${TARGET%.container}"
          arm_dropin "$TARGET"; systemd_reload; systemctl --user reset-failed "${TARGET}.service" 2>/dev/null || true ;;
  disarm) [[ -n "${TARGET:-}" ]] || { echo 'usage: crashguard.sh disarm <unit>' >&2; exit 2; }
          TARGET="${TARGET%.service}"; TARGET="${TARGET%.container}"
          rm -f "$(dropin_dir "${TARGET}")/50-crashguard.conf"; systemd_reload ;;
  reset)  [[ -n "${TARGET:-}" ]] || { echo 'usage: crashguard.sh reset <unit>' >&2; exit 2; }
          TARGET="${TARGET%.service}"; TARGET="${TARGET%.container}"
          d="$(unit_state_dir "${TARGET}")"; rm -f "${d}/halted" "${d}/fails" "${d}/stable_since" "${d}/last_restarts"
          say "${TARGET}: Zustand zurueckgesetzt (Loopsperre geloescht)." ;;
  --install|install)
    install_systemd_units "${HOME}/.config/systemd/user" llm-crashguard.service llm-crashguard.timer
    systemd_reload
    systemctl --user enable --now llm-crashguard.timer
    for u in "${units[@]}"; do arm_dropin "$u"; done
    systemd_reload
    say 'Crashguard-Timer aktiv (Intervall 60s). Naechster Schritt: ./scripts/crashguard.sh status' ;;
  --uninstall|uninstall)
    systemctl --user disable --now llm-crashguard.timer 2>/dev/null || true
    rm -f "${HOME}/.config/systemd/user/llm-crashguard.service" "${HOME}/.config/systemd/user/llm-crashguard.timer"
    for u in "${units[@]}"; do rm -f "$(dropin_dir "$u")/50-crashguard.conf"; done
    systemd_reload
    say 'Crashguard deinstalliert (Snapshots bleiben im Branch crashguard-lkg).' ;;
  *) printf 'usage: %s [check|status|promote <u> [--label L]|rollback <u> [--to L]|list-lkg <u>|arm <u>|disarm <u>|reset <u>|--install|--uninstall] [--units a,b]\n' "$0" >&2; exit 2 ;;
esac
