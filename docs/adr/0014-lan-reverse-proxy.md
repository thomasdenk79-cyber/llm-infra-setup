# ADR 0014: LAN-Zugriff über Nginx-Reverse-Proxy

## Status

Angenommen am 2026-10-04.

## Entscheidung

Die lokalen Weboberflächen werden nach jeder Installation und nach einer
Recovery standardmäßig über einen systemweiten Nginx-Reverse-Proxy im LAN
bereitgestellt. Die Containerports bleiben weiterhin an `127.0.0.1` gebunden;
Nginx veröffentlicht nur die ausdrücklich vorgesehenen Oberflächen auf der
CachyOS-LAN-Adresse.

Aktuelle Weiterleitungen:

Der bevorzugte Einstieg ist HTTPS auf Port 443. Die Pfade sind:

| HTTPS-Pfad | Ziel |
|---|---|
| `/grafana/` | Grafana |
| `/webui/` | Open WebUI |
| `/portal/` | LLM-Portal/Homepage |
| `/logs/` | Dozzle/Containerlogs |

Zusätzlich bleiben die einzelnen LAN-Ports als Diagnose-/Fallback-Zugriff
erreichbar:

| LAN-Port | Ziel | Zweck |
|---:|---|---|
| 3000 | `127.0.0.1:3000` | Grafana |
| 3001 | `127.0.0.1:3001` | Open WebUI |
| 3002 | `127.0.0.1:3002` | LLM-Portal/Homepage |
| 8080 | `127.0.0.1:8080` | Dozzle/Containerlogs |

Nginx läuft als `nginx.service` und wird beim Systemstart aktiviert. LiteLLM,
Pennyroyal und interne Datenbankports werden nicht über diesen Proxy
veröffentlicht.

UFW erlaubt Port 443 sowie die HTTP-Weiterleitung auf Port 80 ausschließlich
aus `192.168.0.0/24`; die Diagnoseports `3000:3002/tcp` und `8080/tcp` sind
ebenfalls nur in diesem Netz offen. Nach einer Neuinstallation gehören diese
Firewall-Regeln und das lokale Zertifikat ebenfalls zur Einrichtung.

## Begründung

Der Zugriff von Windows-Arbeitsplätzen soll ohne SSH-Tunnel möglich sein,
während die Container selbst nicht direkt im LAN lauschen. Die Trennung hält
die bestehenden Container-Netz- und Loopback-Grenzen intakt und bietet einen
einheitlichen Ort für spätere TLS- oder Zugriffsregeln.

## Betriebsprüfung

Nach Einrichtung oder Neustart prüfen:

```bash
systemctl is-active nginx
nginx -t
ss -ltnp | rg ':(3000|3001|3002|8080)'
```

Die Aufrufe erfolgen im LAN über `http://<CACHYOS-IP>:3000` (Grafana),
`:3001` (WebUI), `:3002` (Portal) und `:8080` (Logs).
