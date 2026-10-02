# Betrieb

Optionale Dienste reproduzierbar erzeugen:

```bash
cp config/gateway.env.example config/gateway.env
cp config/autossh.env.example config/autossh.env
cp config/komodo.env.example config/komodo.env
make gateway autossh komodo
```

Lokale Env-Dateien enthalten Zugangsdaten und sind nicht versioniert. Die Generatoren schreiben Quadlet-Dateien nach `quadlet/`; Units erst nach Prüfung der Zielhosts und Secrets aktivieren.

GPU-unabhängige Dienste können separat gestartet werden:

```bash
make deploy-non-gpu
```

Das startet PostgreSQL, LiteLLM, Open WebUI, Homepage sowie Loki, Prometheus, Grafana, Alloy und Dozzle. Das Portal ist unter `http://127.0.0.1:3002` erreichbar, Open WebUI unter `http://127.0.0.1:3001`. Das Grafana-Adminpasswort und die PostgreSQL-, Gateway- und Open-WebUI-Secrets werden außerhalb des Repositories erzeugt. Modellanfragen warten bis Pennyroyal wieder läuft.

Für den einfachen Einstieg genügt danach:

```bash
make portal
```

Lokale Standardzugänge im geschützten Heimnetz: Grafana `admin`/`admin`, LiteLLM `sk-llm-infra-local`, PostgreSQL `litellm`/`llm-infra`.

`llmctl status` zeigt den Zustand aller vorbereiteten User-Units; `llmctl urls` listet die lokalen Endpunkte. Das Benchmark-Skript verwendet standardmäßig den servierten Alias `qwen3.8-flash-next`.
