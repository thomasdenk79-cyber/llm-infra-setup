# Modell-Laufzeit und Weiterleiter (Stand 2026-11-16)

Kurzfassung fuer den Betrieb der Inferenz-Laufzeit auf diesem Rechner und den
Port, ueber den Gateway und Beobachtungsstapel sie erreichen.

## Was laeuft

| Punkt | Wert |
|---|---|
| Container | `flash-next-v3` |
| Bild | `localhost/qwen38-fp4-tp1:v3` (Digest in `versions.lock`) |
| Prozess | vLLM, eine Karte, `TP_SIZE` 1 |
| API | `http://127.0.0.1:30000/v1` (nur Loopback) |
| Metriken | `http://127.0.0.1:30000/metrics` |
| Netz | keines - der Container haengt an keinem Podman-Netz |

Der Container stammt aus dem Laufzeit-Repo (`luni-vllm-flash-next`) und ist hier
ad hoc gestartet, nicht aus einer Quadlet-Unit dieses Repos. Pruefen:

```bash
podman ps --filter name=flash-next-v3 --format '{{.Names}} {{.Status}} {{.Image}}'
curl -s http://127.0.0.1:30000/health | head -c 200
./scripts/healthcheck.sh
```

## Warum es einen Weiterleiter gibt

LiteLLM (`FLASH_NEXT_API_BASE`) und der Prometheus-Job `vllm` laufen in
Containern. Rootless Podman mit pasta reicht Pakete an die Host-Loopback **nicht**
durch: ein Versuch gegen `host.containers.internal:30000` bringt
`Connection refused`. Erreichbar ist der Host fuer Container nur ueber seine
gerouteten Adressen - und zwar nur unter der **bevorzugten**: `ip route get`
waehlt die Route mit dem niedrigsten Metric, hier `enp0s31f6`.
`scripts/vllm-pub-forwarder.py` hoert deshalb auf `127.0.0.1`, auf dieser
Adresse und auf den Podman-Gateways (Port 30001) und reicht an
`127.0.0.1:30000` weiter. Die uebrigen Schnittstellen bleiben zu;
`VLLM_PUBLIC_BIND=all` stellt den alten Zustand (alle Schnittstellen) wieder her.
Ein Binden der Podman-Gateways allein reicht **nicht** - gemessen 2026-11-17:
`up{job="vllm"}` fiel auf 0 und die Route `direct-llm` lief auf 502, weil die
Gateways im Host-Namespace nicht gebunden werden koennen.

```bash
./scripts/73-setup-vllm-forwarder.sh            # installieren und starten
./scripts/73-setup-vllm-forwarder.sh --check    # nur pruefen
systemctl --user status llm-vllm-forwarder.service
journalctl --user -u llm-vllm-forwarder.service -n 20
```

Zwei fruehere Zustandsquellen sind retired und duerfen nicht parallel laufen
(beide binden 30001):

* `luni-vllm-pub.service` → `~/.config/systemd/user/luni-vllm-pub.service.retired-20261116`
* das zugehörige Skript unter `~/LUNI-P0-V3/logs/vllm_pub_forwarder.py` (unversioniert)

## Was der Weiterleiter im Netz sichtbar macht

`auto` bindet die Adresse der bevorzugten Standard-Route, also `192.168.0.198`.
Port 30001 ist damit im Kabel-LAN lesbar; er liefert die Modell-API und deren
Metriken **ohne** Zugangswert - die Basic-Auth der Route `direct-llm` gilt nur
fuer ihren eigenen Pfad. Das ist die bewusste Abweichung von der Regel "Ports nur
auf 127.0.0.1", weil die Container sonst nichts erreichen. Seit der Review-Runde 2026-11-17 ist zumindest die WLAN-Adresse (`192.168.0.47`)
nicht mehr gebunden: zwei
Default-Routes (LAN metric 100, WLAN metric 600) fuehrten dazu, dass der
Weiterleiter das Funknetz mithoerte.

Offene Aufgabe (Hochnummer 19 in `docs/HANDOFF.md`): der richtige Weg ist ein
Weiterleiter **als Container** in `llm-inference`/`llm-observability` mit
`--network=pasta,map_host_loopback=true`, damit er die Host-Loopback sieht und
nichts mehr an eine Host-Adresse binden muss. Dann fallen die Konsumenten auf
`llm-vllm-forwarder:30001` zurueck und `VLLM_PUBLIC_BIND` wird ueberfluessig.

Steuern:

* `VLLM_PUBLIC_BIND=<adresse>` in `systemd/llm-vllm-forwarder.service`
  (oder per `systemctl --user edit`) verengt die Bindung auf eine Adresse.
* Sauberste Loesung: die Runtime selbst ans Inferenz-Netz haengen
  (`--network llm-inference`), dann faellt der offene Host-Port ganz weg. Das
  erfordert einen Neustart der Laufzeit (~15 Minuten, laufende Anfragen enden)
  und ist ein eigener, ausdruecklicher Schritt - siehe
  `docs/operations.md`, Abschnitt Runtime-Neustart.

## Wer aus dem Netz durch den Weiterleiter geht

Der LAN-Proxy (`llm-proxy`, `scripts/74-setup-local-proxy.sh`) reicht die Route
`https://direct-llm.<LAN_DOMAIN>/v1/models` an `host.containers.internal:30001`
durch - also an genau diesen Weiterleiter, nicht an die Runtime. Zwei Folgen:

* Der Weiterleiter ist ein betriebskritischer Pfad fuer den LAN-Zugang, nicht
  nur fuer Prometheus und Gateway. `./scripts/doctor.sh` prueft Unit und
  Host-Port (Pruefpunkt *Lokaler Zugang ueber Namen*), weil ein Test der Route
  ohne Zugangswerte immer `401` liefert und damit gesund aussieht, auch wenn der
  Weiterleiter tot ist (Caddy fragt die Basic-Auth **vor** dem Weiterreichen ab).
* Da der Proxy die Basic-Auth selbst prueft, bleibt die Route hinter einem
  Zugangswert verborgen (`~/.config/llm-infra/proxy/lan-credentials.txt`, 0600).
  Der offene Host-Port 30001 bleibt davon unbeeinflusst - er liefert weiterhin
  ohne Zugangswert, weshalb `VLLM_PUBLIC_BIND` die Adresse eng halten sollte.

## Ausfallbilder

| Bild | Ursache | naechster Befehl |
|---|---|---|
| Prometheus-Job `vllm` down, Ziel `host.containers.internal:30001` | Weiterleiter laeuft nicht oder bindet nur Loopback | `./scripts/73-setup-vllm-forwarder.sh --check` |
| Gateway antwortet auf lokale Modelle mit 502/Connection error | Weiterleiter oder Runtime unten | `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:30001/v1/models` |
| LiteLLM 502 mit `TransferEncodingError: Not enough data to satisfy transfer length header` unter Last | Der Weiterleiter trug die Vorlaufzeit der Laufzeit als 10-s-Socket-Timeout ab und brach den Stuck-Strom ab | `./scripts/test-vllm-forwarder.sh` (rot gegen die alte Fassung) |
| `bind 192.168.0.x:30001 uebersprungen: Address already in use` | zweite Instanz (meist retired Unit wieder aktiviert) | `systemctl --user list-units --all \| grep -E 'vllm\|forwarder'` |
| `502` auf `https://direct-llm.<LAN_DOMAIN>/v1/models` im LAN | Weiterleiter steht, oder die Runtime antwortet nicht | `systemctl --user status llm-vllm-forwarder.service`, Gegencheck `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:30001/v1/models`; gefuehrt: `./scripts/doctor.sh` (Pruefpunkt *Lokaler Zugang ueber Namen*) |
