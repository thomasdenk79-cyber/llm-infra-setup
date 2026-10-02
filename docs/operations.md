# Betrieb

Optionale Dienste reproduzierbar erzeugen:

```bash
cp config/gateway.env.example config/gateway.env
cp config/autossh.env.example config/autossh.env
cp config/komodo.env.example config/komodo.env
make gateway autossh komodo
```

Lokale Env-Dateien enthalten Zugangsdaten und sind nicht versioniert. Die Generatoren schreiben Quadlet-Dateien nach `quadlet/`; Units erst nach Prüfung der Zielhosts und Secrets aktivieren.
