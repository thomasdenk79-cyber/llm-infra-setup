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

Das startet PostgreSQL sowie das Observability-Netz, Loki, Prometheus, Grafana, Alloy und Dozzle. Das Grafana-Adminpasswort und das PostgreSQL-Passwort werden außerhalb des Repositories erzeugt. Gateway, Autossh und Pennyroyal bleiben bis zur Runtime-Validierung bewusst getrennt.
