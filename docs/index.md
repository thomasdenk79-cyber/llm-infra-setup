# LLM Infrastructure

Diese Dokumentation beschreibt das reproduzierbare Setup für RTX PRO 6000, ZFS, Podman, Pennyroyal/SGLang, LiteLLM und Observability.

## Schnellstart

```bash
make validate
make preflight
llmctl status
```

Die eigentliche Hostausführung folgt der Reihenfolge in [Installation](install.md). Geheimnisse bleiben außerhalb von Git.

```mermaid
graph LR
  Client --> LiteLLM[:4000]
  LiteLLM --> Pennyroyal[:8001]
  Pennyroyal --> GPU[RTX PRO 6000]
  Prometheus --> Grafana
  Alloy --> Loki
```
