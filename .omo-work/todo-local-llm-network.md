# TODO: LAN HTTPS and Azure Reverse Tunnel

> **Stand 2026-11-17 (Copilot):** Punkte 1-9 und 11 umgesetzt und auf dem
> Linux-Rechner gemessen (`./scripts/74-setup-local-proxy.sh --check` endet mit
> rc=0; Details in `docs/status.md`, Abschnitt "LAN-Zugang ueber HTTPS", und
> `CHANGELOG.md`). Punkt 10 ist teilweise erledigt: alle Pruefungen sind von der
> Maschine aus messbar ausgefuehrt, die Gegenproben **auf** dem Windows-PC stehen
> noch aus (Geraet in der Sitzung nicht erreichbar) - Befehle dafuer stehen in
> `docs/operations.md`, Abschnitt "Windows 11". Punkte 6 und 7 waren bereits vor
> dieser Runde erfuellt (`llm-reverse-tunnel.service` läuft, oeffentlich 200/401
> gemessen) und sind jetzt in `docs/operations.md` (Abschnitt "Zwei Wege, zwei
> Adressen") dokumentiert.



This task is for local LLM agents only. Do not start it until the Qwen3.8 fork is running and has passed the first GPU smoke test.

## Objective

Make the existing Podman services reachable from the Windows workstation through Caddy on HTTPS port 443.

## Required hostnames

- `https://homepage.cachyos-x8664`
- `https://littlem.cachyos-x8664`
- `https://direct-llm.cachyos-x8664`
- Keep the existing local HTTPS entries working.

## Work items

1. Inspect the existing `llm-infra-setup` Caddy template, Quadlets, service bindings, and health checks.
2. Add authenticated or intentionally read-only routes for Homepage, Grafana, Dozzle, LiteLLM, and the direct vLLM endpoint.
3. Bind Caddy safely for LAN access on TCP 443; do not expose backend ports directly.
4. Define local name resolution for `cachyos-x8664` and document Windows 11 hosts/DNS setup.
5. Generate or reuse the local CA and server certificate, install the root CA on Windows 11, and document trust verification.
6. Inspect the existing `autossh` Quadlet and configuration template.
7. Configure an SSH reverse tunnel from this workstation to the Azure VM gateway, forwarding the required public `:443` entry to the local Caddy listener.
8. Keep secrets outside Git; use the existing secrets files and Podman/systemd ownership model.
9. Implement idempotent `check`, `plan`, and `apply` steps; validate Caddy configuration before reload.
10. Test from the Windows workstation: TLS trust, each hostname, Grafana, Dozzle, LiteLLM, direct vLLM health, tunnel reconnect, and service restart recovery.
11. Update the operator guide with URLs, certificate installation, SSH tunnel lifecycle, rollback, and troubleshooting.

## Constraints

- Do not modify protected `luni-base` or `workstation-setup` without explicit authorization.
- Do not expose Prometheus, Alertmanager, or backend container ports directly.
- Do not print or commit private keys, tokens, or passwords.
- Preserve the current localhost-only access as a fallback until LAN access is verified.
