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
gerouteten Adressen. `scripts/vllm-pub-forwarder.py` hoert deshalb auf
`127.0.0.1` plus allen lokalen Schnittstellen auf Port 30001 und reicht an
`127.0.0.1:30000` weiter.

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

`auto` bindet die Host-Adressen, also auch `192.168.0.198` (und `192.168.0.47`
ueber WLAN). Port 30001 ist damit im LAN lesbar; er liefert die Modell-API und
deren Metriken **ohne** Zugangswert. Das war vorher genauso und ist bewusste
Abweichung von der Regel "Ports nur auf 127.0.0.1", weil die Container sonst
nichts erreichen.

Steuern:

* `VLLM_PUBLIC_BIND=<adresse>` in `systemd/llm-vllm-forwarder.service`
  (oder per `systemctl --user edit`) verengt die Bindung auf eine Adresse.
* Sauberste Loesung: die Runtime selbst ans Inferenz-Netz haengen
  (`--network llm-inference`), dann faellt der offene Host-Port ganz weg. Das
  erfordert einen Neustart der Laufzeit (~15 Minuten, laufende Anfragen enden)
  und ist ein eigener, ausdruecklicher Schritt - siehe
  `docs/operations.md`, Abschnitt Runtime-Neustart.

## Ausfallbilder

| Bild | Ursache | naechster Befehl |
|---|---|---|
| Prometheus-Job `vllm` down, Ziel `host.containers.internal:30001` | Weiterleiter laeuft nicht oder bindet nur Loopback | `./scripts/73-setup-vllm-forwarder.sh --check` |
| Gateway antwortet auf lokale Modelle mit 502/Connection error | Weiterleiter oder Runtime unten | `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:30001/v1/models` |
| LiteLLM 502 mit `TransferEncodingError: Not enough data to satisfy transfer length header` unter Last | Der Weiterleiter trug die Vorlaufzeit der Laufzeit als 10-s-Socket-Timeout ab und brach den Stuck-Strom ab | `./scripts/test-vllm-forwarder.sh` (rot gegen die alte Fassung) |
| `bind 192.168.0.x:30001 uebersprungen: Address already in use` | zweite Instanz (meist retired Unit wieder aktiviert) | `systemctl --user list-units --all \| grep -E 'vllm\|forwarder'` |
