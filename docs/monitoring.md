# Monitoring-Betrieb (Stand 2026-10-08)

Stack: Prometheus (Scrape) + Alloy/loki.source.docker (Logs -> Loki) + Grafana
(Dashboards, Datei-provisioniert, aenderbar NUR ueber dieses Repo) +
node/gpu-exporter + Textfile-Collector.

## Datenflusse
- Metriken: Exporter -> Prometheus (30d Retention) -> Grafana.
- Logs: Podman-Socket -> Alloy -> Loki -> Grafana Explore/Dashboards.
- Host-Fakten (llm_*): `scripts/collect-host-facts.sh` alle 30s ueber
  systemd-user-Timer `llm-infra-collect-facts.timer` in den Textfile-Ordner.
  Ausfall der Fakten? -> `systemctl --user status llm-infra-collect-facts.timer`.

## Bekannte Datengrenzen (bewusst, kein Bug)
| Signal | Wo verfuegbar | Warum |
|---|---|---|
| llm_zfs_*, llm_smart_*, node_zfs_* | nur echter KVM-CachyOS-Host | WSL: kein ZFS, keine nvme-Devs |
| llm_pcie_* | nur echter Host | WSL haengt GPU an dxgkrnl, lspci blind |
| node_cpu_scaling_frequency_hertz | nur echter Host | WSL zeigt keinen cpufreq-Treiber |
| Pennyroyal Warnung "CP delta rule" | - | flashinfer upstream-Fallback, folgenlos |
| Tokenwarnung 262682>262144 | - | Base-Tokenizer-Check vor YaRN-Faktor 2.0, Fehlalarm moeglich; beobachten |

## Fixed 2026-10-08
1. node-exporter schrie 720 Fehler/3h: WSL dubliziert /run/user-tmpfs ->
   `--collector.filesystem.mount-points-exclude='^/run/user(/.*)?$'`.
2. llm_*-Fakten fehlten komplett: Timer war nie installiert -> enabled.
3. Open-WebUI quatschte totes Ollama an -> ENABLE_OLLAMA_API=false.
4. Homepage-Konfig lebte ausserhalb des Repos -> nach config/homepage/
   umgezogen, Quadlet-Mount geaendert (GitOps jetzt konsistent).
5. Grafana-Dashboards 02/04 bekennen ihre WSL-Datengrenze als Hinweis-Panel.

## Beobachtungsliste
- litellm "Malformed API Key" vereinzelt (Client sendet Key ohne Bearer-
  Praefix; Kandidat: Open-WebUI-Version-Probe). Taucht es gehaeuft auf: Loki
  `job="litellm" |= "Malformed"` nach Client-IP durchsuchen.
- Alloy meldet nach Container-Recreates kurz "no such container" (selbstheilend).
