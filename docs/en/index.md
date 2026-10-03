# Local LLM infrastructure (English summary)

One machine, one local model, no cloud calls. CachyOS, rootless Podman Quadlets,
ZFS storage, Pennyroyal/SGLang serving `Qwen3.8-Flash-Next-NVFP4`.

Bringing everything up is one repeatable command:

```bash
./setup.sh            # runs all phases, skips what is already done
./scripts/doctor.sh   # guided checks that print the exact next command
```

Components and localhost-only ports: runtime 8001, LiteLLM gateway 4000,
Open WebUI 3001, homepage portal 3002, Grafana 3000, Prometheus 9090, Loki 3100,
Dozzle 8080, node_exporter 9100, GPU exporter 9835. Two Podman networks keep the
inference plane and the observability plane apart; Prometheus is the single
component attached to both (see `docs/adr/0009-scrape-across-networks.md`).

Generated credentials live outside the repository under `~/.config/llm-infra/`
with mode 0600; `./scripts/show-credentials.sh` prints them.

Further reading (German, kept as the source of truth): `docs/architecture.md`,
`docs/operations.md`, `docs/performance.md`, `docs/troubleshooting.md`.
