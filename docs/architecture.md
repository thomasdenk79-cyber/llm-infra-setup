# Architektur

Stand: 2026-10-02. Diese Datei ist die einzige Architekturbeschreibung; sie ersetzt
die frueheren Duplikate (frueher gab es `architecture.md` und `ARCHITECTURE.md` mit
ungleichem Inhalt).

## Wozu das hier

Ein einzelner Arbeitsplatzrechner (CachyOS, ThinkPad L15 Gen 2 mit externer
NVIDIA RTX PRO 6000 Blackwell) betreibt ein lokales Sprachmodell ohne Cloud.
Alle Bauteile sind als Skripte und Unit-Dateien in diesem Repository abgelegt,
damit ein Neubau des Rechners nur `git clone` und `./setup.sh` braucht.

## Grundregel E1: die GPU gehoert dem Modell

Die Grafikkarte ist ausschliesslich fuer die LLM-Inferenz reserviert. Andere
Container, VMs oder Trainingslaeufe bekommen keinen Zugriff auf die GPU, und die
Inferenz nutzt bewusst nur einen GPU-Kern (TP1). Details und Begruendung in
`docs/adr/0013-*.md`.

## Bauteile

| Bauteil | Port (nur 127.0.0.1) | Netz | Aufgabe | Unit |
|---|---|---|---|---|
| Pennyroyal/SGLang | 8001 | llm-inference | Modell ausfuehren, OpenAI-API | `quadlet/pennyroyal.container` |
| LiteLLM | 4000 | llm-inference | ein Schluessel, eine Adresse, Abrechnung | `quadlet/litellm.container` |
| PostgreSQL | 5432 | llm-inference | Virtuelle Schluessel und Nutzungsdaten | `quadlet/litellm-postgres.container` |
| Open WebUI | 3001 | llm-inference | Chat, Dateien, RAG | `quadlet/open-webui.container` |
| Prometheus | 9090 | beide | Metriken sammeln und alarmieren | `quadlet/prometheus.container` |
| Grafana | 3000 | llm-observability | Dashboards | `quadlet/grafana.container` |
| Loki | 3100 | llm-observability | Protokolle speichern | `quadlet/loki.container` |
| Alloy | - | llm-observability | Container-Protokolle zu Loki bringen | `quadlet/alloy.container` |
| Dozzle | 8080 | llm-observability | Live-Protokolle im Browser | `quadlet/dozzle.container` |
| Homepage (Portal) | 3002 | llm-observability | Einstiegseite fuer den Betreiber | `quadlet/homepage.container` |
| Wiki (Caddy, statisch) | 3003 | llm-observability | Wissens-Wiki aus ~/work/hermes-wiki (Rebuild-Timer 30 min) | `quadlet/wiki.container` |
| node_exporter | 9100 | llm-observability | CPU, RAM, Platte, ZFS, Host-Kennzahlen | `quadlet/llm-node-exporter.container` |
| GPU-Exporter | 9835 | llm-observability | GPU-Temperatur, Takt, VRAM, Drosselung | `quadlet/llm-gpu-exporter.container` |

Zusaetzlich zwei User-Timer: `llm-infra-collect-facts.timer` (Host-Kennzahlen
alle 30 Sekunden) und `llm-runtime-watchdog.timer` (wacht ueber die Runtime).

## Netzwerk: warum die Runtime nur an einem Netz haengt

Zwei Netze sind sinnvoll: die Inferenz-Umgebung (Modell, Gateway, Datenbank,
Chat) und die Beobachtungs-Umgebung (Metriken, Protokolle, Portal). Die Frage
ist, wo Prometheus hin gehoert.

Entscheidung: **Prometheus haengt an beiden Netzen; die Runtime bleibt an einem.**

* Die Runtime soll moeglichst wenig mitspielen: keine Beobachtungsseite in ihrem
  Netz, keine zusaetzliche Interface, kein Neustart, wenn sich etwas an der
  Beobachtung aendert.
* Prometheus ist der einzige Baustein, der beide Seiten sehen muss. Ein zweites
  `Network=` im Prometheus-Quadlet fuegt es dem Inferenz-Netz hinzu und kann
  `pennyroyal:8001/metrics` direkt erreichen.
* Die Richtung passt ausserdem: Prometheus holt sich die Zahlen, die Runtime
  schickt nichts aktiv weg.

Die fruehere Version dieser Datei behauptete, Prometheus erreiche die Runtime;
das war falsch, weil beide in getrennten Netzen lagen und der Name
`pennyroyal:8001` im Observability-Netz nicht aufloesbar ist (geprueft am
2026-10-02, Fehlerbild: `up{job="pennyroyal"} == 0`).

Der GPU-Exporter braucht die Grafikkarte (CDI-Geraet), aber kein Inferenz-Netz:
gemessen wird ueber NVML, nicht ueber den Modell-Port.

## Woher die Host-Kennzahlen kommen

Rootless Container kommen nicht an die Loopback-Ports des Hosts, und
Loopback-Ports des Containers sieht der Host nicht. Der node_exporter liest
deshalb den Host ueber die schreibgeschuetzte Einhaengung `/host`:
CPU, RAM, Platte, Netzwerk, Temperaturen und ZFS stammen von dort.

Alles, was nur der Host selbst messen kann (ZFS-Poolzustand, NVMe-SMART,
PCIe-Anbindung der GPU, ob die PLE-Datei in `/etc/fstab` steht, Zustand der
User-Dienste, letzte Messung), schreibt `scripts/collect-host-facts.sh` als
Textdatei in den Ordner `~/.local/share/llm-infra/node-exporter/textfile`,
den der node_exporter einsammelt. Das vermeidet einen zweiten Exporter und
macht die Zahlen auch sichtbar, wenn Prometheus selbst das Problem ist.

## Speicher

```
/srv (ZFS-Pool, z. B. zpcachyossrv)
  /srv/llm/models        Dataset llm/models, lz4, recordsize=1M, atime=off
                         primarycache=metadata  (Modelldaten nicht im ARC)
  /srv/llm/cache         Compiler- und JIT-Puffer, persistent
  /srv/llm/nixl          NIXL-Dateicache fuer Schichtzwischenspeicher
  /srv/llm/ple-nvme.ext4 sparse Datei, 110 GiB, ext4
  /srv/llm/ple-ext4      Einhaengepunkt davon (Loop, nofail in /etc/fstab)
```

Die Modellgewichte liegen auf ZFS, weil dort Kompression, Snapshot und
Rechteverwaltung schon vorhanden sind. Der SSD-Bereich fuer die
Einbettungstabellen (PLE) ist absichtlich **ext4 in einer Loop-Datei**, nicht
ZFS direkt: der Vorleser der Runtime benutzt `io_uring`, und ZFS-Dateisysteme
unterstuetzen diesen Pfad an dieser Stelle nicht (Fehler `os error 38`).
Mehr dazu in `docs/performance.md` und ADR 0011.

Der ZFS ARC wird auf `ZFS_ARC_MAX_GB` (Standard 16 GiB) begrenzt, damit der
RAM fuer das Modell frei bleibt; die Begruendung steht im Skript
`scripts/20-zfs-setup.sh`.

## Schluessel und Passwoerter

| Was | Wo | Art |
|---|---|---|
| Postgres-Zugang | `~/.config/llm-infra/postgres.env` | automatisch erzeugt, 0600 |
| Gateway-Schluessel | `~/.config/llm-infra/gateway.env` | automatisch erzeugt, 0600 |
| Chat-Geheimnis | `~/.config/llm-infra/open-webui.env` | automatisch erzeugt, 0600 |
| Grafana-Passwort | Podman-Secret `grafana_admin_password` | automatisch erzeugt |
| Alles lesbar auf einen Blick | `~/.config/llm-infra/credentials.txt` | 0600 |

Im Repository stehen nur Platzhalter. Die frueheren, fest eingetragenen
Standard-Passwoerter (`sk-llm-infra-local`, `llm-infra` usw.) sind nicht mehr
im Code; `make validate` prueft darauf.

## Ablaufpfade (was wann zu benutzen ist)

| Ziel | Befehl | Was passiert |
|---|---|---|
| Neuer Rechner, alles auf einmal | `./setup.sh` | Phasen 1-8, idempotent, fuehrt am Ende `doctor.sh` aus |
| Nur Pruefen, nichts aendern | `./setup.sh --check` | zeigt Diagnose |
| Etwas kaputt? | `./scripts/doctor.sh` | gezielte Fragen, konkrete Befehle |
| Nur Portal/Chat/Beobachtung (ohne GPU) | `make deploy-non-gpu` | ohne Modelleinheit |
| Kompletter Stack nach Neustart | `make deploy-ready` | prueft Voraussetzungen, startet alles |
| Unit-Aenderung aus dem Repo aktivieren | `make apply-units` | bricht ab, wenn Anfragen laufen |
| Nur die Runtime starten | `make deploy` | minimal |

`make deploy-ready` startet eine **laufende** Runtime nicht neu; es zeigt nur,
dass Laeufer und Unit-Datei auseinanderlaufen. Der Neustart ist ein eigener,
bewusster Schritt (`make apply-units`), weil ein Kaltstart rund 15 Minuten dauert.

## Beobachtungskette

```
SGLang /metrics  ─┐
node_exporter   ──┼─> Prometheus ──> Grafana (4 Dashboards)
gpu_exporter    ──┘        │
                           └─> Alarmregeln config/monitoring/alerts.yml
Container-logs ──> Alloy (Podman-Socket) ──> Loki ──> Grafana/Dozzle
```

## Was bewusst nicht dabei ist

* Kein Knoten-Cluster, kein Cluster-Verwaltungswerkzeug, keine Kubernetes.
* Keine VMs/GPU-Durchreichung (siehe ADR-KVM-Hinweis im README).
* Kein automatischer Fernzugriff: der Wartungstunnel ist ein optionaler,
  gesonderter Schritt (`make autossh`).
* Die GPU wird nicht mit anderen Arbeitslasten geteilt (Grundregel E1).
