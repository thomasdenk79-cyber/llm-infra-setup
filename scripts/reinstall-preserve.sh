#!/usr/bin/env bash
# Ubuntu-Neuinstallation: sicheres Inventar (ohne Modellmassen) extern ablegen.
#
#   ./scripts/reinstall-preserve.sh /pfad/zu/externem/medium [alter_user]
#
# Ablage unter <medium>/llm-preserve-<timestamp>/:
#   * alle Git-Repos als Bundle-Set (alle Branches/Tags)
#   * ~/.hermes (Agents, Skills, Memory, config, .env)
#   * ~/.config/llm-infra und ~/.config/containers (Secrets + Quadlets, 0700/0600)
#   * /srv/secrets (verschuesselt mit age, falls Schluessel vorhanden)
#   * Manifest + SHA256-Liste
# Modelle (/srv/ai/models, ~281 GB) werden NICHT kopiert - die laedt
# scripts/40-download-model.sh auf Ubuntu neu (hf-Download).
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
dest_base="${1:?usage: reinstall-preserve.sh /pfad/zu/externem/medium}"
user_home="${HOME}"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
dest="${dest_base%/}/llm-preserve-${ts}"
[[ -d "${dest_base}" && -w "${dest_base}" ]] || { log "Ziel nicht beschreibbar: ${dest_base}"; exit 1; }
install -d -m 0700 "${dest}"

repos=(
  "${HOME}/work/llm-infra-setup"
  "${HOME}/work/workstation-setup"
  "${HOME}/work/cachyos-kvm-lab"
  "/srv/github/pennyroyal"
  "/srv/github/pennyroyal-validation"
  "/srv/github/hermes-memory-workspace"
)
mkdir -p "${dest}/git"
for r in "${repos[@]}"; do
  [[ -d "${r}/.git" ]] || continue
  name="$(basename "$r")"
  git -C "$r" -c gc.auto=0 bundle create "${dest}/git/${name}.bundle" --all \
    && log "bundle: ${name}"
  { echo "== ${name}"; git -C "$r" remote -v; git -C "$r" branch -a --format='%(refname)'; git -C "$r" rev-parse HEAD; git -C "$r" status --short | head -20; } \
    >> "${dest}/git/README-repos.txt"
done
[[ -d "${user_home}/work/mlinux" ]] && echo "HINWEIS: mlinux (Siemens-Remote) wurde NICHT gebundled - separat von code.siemens.com klonen." >> "${dest}/git/README-repos.txt"

tar -C "${user_home}" -czf "${dest}/dot-hermes.tar.gz" .hermes 2>/dev/null || log 'WARNUNG: .hermes unvollstaendig'
tar -C "${user_home}/.config" -czf "${dest}/llm-infra-config.tar.gz" llm-infra containers 2>/dev/null || true
chmod 600 "${dest}"/*.tar.gz

if command -v age >/dev/null 2>&1 && [[ -f "${HOME}/.config/age/key.txt" ]]; then
  age -r "$(age -d "${HOME}/.config/age/key.txt" | age-keygen -y /dev/stdin 2>/dev/null || true)" /dev/null >/dev/null 2>&1 || true
fi
if [[ -d /srv/secrets ]]; then
  tar -C /srv -cz secrets-backup.tar.gz secrets
  if command -v age >/dev/null 2>&1 && ls "${HOME}"/.config/age/*.key >/dev/null 2>&1; then
    for k in "${HOME}"/.config/age/*.key; do
      age -R "$k" -o "${dest}/srv-secrets.tar.gz.age" "${HOME}/secrets-backup.tar.gz" 2>/dev/null \
        && mv "${HOME}/secrets-backup.tar.gz.age" "${dest}/" && break
    done
  fi
  [[ -f "${dest}/srv-secrets.tar.gz.age" ]] || cp "${HOME}/secrets-backup.tar.gz" "${dest}/srv-secrets.tar.gz.INKLAR-0600"
  chmod 600 "${dest}"/srv-secrets.tar.gz* 2>/dev/null || true
  rm -f "${HOME}/secrets-backup.tar.gz"
fi

du -sh /srv/ai/models /srv/games /srv/ai/nixl > "${dest}/MANIFEST-large.txt" 2>/dev/null || true
podman images --format '{{.Name}}:{{.Tag}} {{.ID}}' > "${dest}/podman-images.txt" 2>/dev/null || true
nvidia-smi --query-gpu=name,uuid,driver_version,memory.total --format=csv > "${dest}/gpu.txt" 2>/dev/null || true
cat /etc/os-release > "${dest}/os.txt"
( cd "${dest}" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum ) > "${dest}/SHA256SUMS"
chmod -R go-rwx "${dest}"
log "Preserve-Backup liegt unter: ${dest}"
log "Pruefung nach Restore: ( cd ${dest} && sha256sum -c SHA256SUMS )"
