# Betrieb

Optionale Dienste reproduzierbar erzeugen:

```bash
cp config/gateway.env.example config/gateway.env
cp config/autossh.env.example config/autossh.env
cp config/komodo.env.example config/komodo.env
make gateway autossh komodo
```

Lokale Env-Dateien enthalten Zugangsdaten und sind nicht versioniert. Die Generatoren schreiben Quadlet-Dateien nach `quadlet/`; Units erst nach Prüfung der Zielhosts und Secrets aktivieren.

GPU-unabhängige Dienste werden mit `make deploy-non-gpu` gestartet. Das Kommando erzeugt Grafana- und PostgreSQL-Secrets außerhalb von Git und aktiviert Observability ohne Pennyroyal.

`llmctl status` zeigt alle vorbereiteten User-Units, und `llmctl urls` gibt die lokalen URLs aus.
