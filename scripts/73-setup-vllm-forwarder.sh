#!/usr/bin/env bash
# Weiterleiter der Modell-Runtime ins Inferenz-Netz installieren.
#
#   ./scripts/73-setup-vllm-forwarder.sh           Unit installieren und starten
#   ./scripts/73-setup-vllm-forwarder.sh --check   nur pruefen
#
# Noetig, solange die Runtime ihr API nur auf 127.0.0.1 veroeffentlicht (Port
# 30000) und Container im Inferenz-Netz die Host-Loopback nicht sehen. Ohne
# diesen Weiterleiter finden Prometheus (Job vllm) und LiteLLM die Runtime nicht.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

if [[ "${1:-}" == "--check" ]]; then
  missing=0
  [[ -f "${SYSTEMD_USER_DIR}/llm-vllm-forwarder.service" ]] || { printf 'FEHLT: Unit nicht installiert\n'; missing=1; }
  unit_is_active llm-vllm-forwarder.service || { printf 'FEHLT: llm-vllm-forwarder.service laeuft nicht\n'; missing=1; }
  [[ "${missing}" == 0 ]] && printf 'OK: Runtime-Weiterleiter laeuft\n'
  exit "${missing}"
fi

need_cmd python3 'Jetzt ausführen: make install'
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "${root}/scripts/vllm-pub-forwarder.py"
install_systemd_units "${SYSTEMD_USER_DIR}" llm-vllm-forwarder.service
systemd_reload
systemctl --user enable --now llm-vllm-forwarder.service >/dev/null 2>&1 || true
systemctl --user restart llm-vllm-forwarder.service
log 'Runtime-Weiterleiter installiert.'
