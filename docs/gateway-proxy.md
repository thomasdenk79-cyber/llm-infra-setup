# Oeffentlicher Zugang ueber den Gateway-Rechner (Stand 2026-11-16)

Die Kollegen erreichen den Stapel ausschliesslich ueber Port 443 des Azure-
Gateway-Rechners `edipoc-gateway.westeurope.cloudapp.azure.com`
(oeffentliche IP `20.73.54.102`). Auf diesem Rechner hier bleibt alles auf
`127.0.0.1` gebunden; nach draussen geht nichts ausser dem ausgehenden
SSH-Tunnel. Der Tunnel spiegelt LiteLLM (4000), Grafana (3000) und Homepage
(3002) auf den Loopback des Gateway-Rechners, und der Caddy dort macht fuer
beide Seiten das TLS an 443.

Gebaut und geprueft wird das komplette Stueck von einem Skript:
`scripts/70-setup-gateway-proxy.sh`. Es ist idempotent, die laufende
Konfiguration darf also jederzeit gegen die Vorlage nachgezogen werden.

```bash
./scripts/70-setup-gateway-proxy.sh --status    # Kurzbild des Ist-Zustands
```

## Dateiaufbau

| Datei | Aufgabe |
|---|---|
| `scripts/70-setup-gateway-proxy.sh` | zentrales Skript: Pruefen, Einrichten, Status, Basic-Auth-Hashes |
| `config/gateway-proxy.env.example` | Vorlage der Zielangaben (DNS-Name, IP, Ports, TLS-Modus) |
| `config/gateway-proxy.env` | echte Zielangaben; liegt lokal, nicht in Git (`config/*.env` ist ignoriert) |
| `config/gateway/Caddyfile.template` | Vorlage des Caddyfiles auf dem Gateway (Platzhalter werden lokal eingesetzt) |
| `systemd/llm-reverse-tunnel.service` | Vorlage der Tunnel-Unit; installiert nach `~/.config/systemd/user/` |
| `scripts/71-gateway-keys.sh` | persoenliche Virtual-Keys des Gateways ausgeben und widerrufen |
| `~/.ssh/llm_gateway_tunnel_ed25519` | eigener Schluessel nur fuer den Tunnel (nie der Anmeldeschluessel) |
| `~/.config/llm-infra/gateway-proxy/team-users.txt` | Basic-Auth-Personen, eine Zeile pro Person: `benutzer bcrypt-hash` (0600, ausserhalb von Git) |
| `~/.local/share/llm-infra/ssh/gateway-known_hosts` | eigene known_hosts-Datei des Tunnels |
| `~/.local/state/llm-gateway-tunnel.autossh.log` | Log des autossh |

Wer zum ersten Mal hier liest, soll sehen, was zusammengehoert. Nach dem Lesen:

```bash
ls -l ~/.ssh/llm_gateway_tunnel_ed25519 ~/.config/llm-infra/gateway-proxy/team-users.txt
```

## Einrichten

1. Zielangaben anlegen (enthalt keine Geheimnisse, nur die Rechnerangaben):

   ```bash
   cp config/gateway-proxy.env.example config/gateway-proxy.env
   nano config/gateway-proxy.env      # GATEWAY_DNS_NAME und GATEWAY_PUBLIC_IP eintragen
   ```

2. Pruefen, nichts aendern (Schluessel, SSH, Unit, Gateway-Listener, oeffentlicher Pfad):

   ```bash
   ./scripts/70-setup-gateway-proxy.sh --check
   ```

3. Einrichten ohne Argumente. Das Skript erzeugt den Tunnel-Schluessel, setzt
   die `authorized_keys`-Zeile auf dem Gateway, rendert das Caddyfile aus der
   Vorlage, laesst es von `caddy validate` auf dem Gateway pruefen, installiert
   es (Vorher-Sicherung nach `/etc/caddy/Caddyfile.bak.<UTC>`) und startet die
   Unit. Der erste Lauf kann den neuen Tunnel-Schluessel selbst noch nicht
   benutzen: fuer die Erstversorgung dient der Anmeldeschluessel
   (`GATEWAY_BOOTSTRAP_KEY`, Standard `~/.ssh/id_ed25519`), danach wird er
   nicht mehr gebraucht.

   ```bash
   ./scripts/70-setup-gateway-proxy.sh
   ```

4. Basic-Auth-Personen anlegen (Passwortabfrage, Hash kostet 14 Runden,
   gespeichert in `team-users.txt`):

   ```bash
   ./scripts/70-setup-gateway-proxy.sh --hash BENUTZER
   ./scripts/70-setup-gateway-proxy.sh          # Hashes ausrollen
   ```

   Fehlt die Datei lokal, holt das Skript vorhandene Hashes einmalig vom
   laufenden Caddyfile auf dem Gateway, statt sie zu verlieren.

5. Ergebnisbild:

   ```bash
   ./scripts/70-setup-gateway-proxy.sh --status
   ```

## Oeffentliche Routen

Gemessen am 2026-11-16, jeweils per `curl -sk -o /dev/null -w '%{http_code}'`
gegen `https://edipoc-gateway.westeurope.cloudapp.azure.com`:

| Route | Ziel auf dem Gateway | Schutz | Messwert |
|---|---|---|---|
| `/health/liveliness` (auch `/health/readiness`) | `127.0.0.1:4000` LiteLLM | keylos (bewusst) | 200 |
| `/v1`, `/v1/*` | `127.0.0.1:4000` LiteLLM | persoenlicher Virtual-Key | 401 ohne Schluessel |
| `/grafana/` | `127.0.0.1:3000` Grafana (Unterpfad) | Basic-Auth pro Person | 401 ohne Zugangsdaten |
| `/` (restliche Pfade) | `127.0.0.1:3002` Homepage | Basic-Auth pro Person | 401 ohne Zugangsdaten |

Dieselben Antworten liefert die Roh-IP `https://20.73.54.102/...`; sie steht
als zweite Adresse im Serverblock, dazu `default_sni` (siehe Fehlerfaelle).

Nach dem Anlegen: Schluessel ausgeben und verschluesselt uebergeben, nie im
Chat-Verlauf:

```bash
./scripts/71-gateway-keys.sh --issue BENUTZER
./scripts/71-gateway-keys.sh --list
```

## Sicherheitsmodell

- Oeffentlicher Port ist ausschliesslich 443 (Caddy). Der Tunnel bindet
  nirgends auf `0.0.0.0`, jeder Forward endet auf `127.0.0.1` des Gateways.
- Die `authorized_keys`-Zeile des Tunnel-Schluessels traegt
  `restrict,port-forwarding,no-agent-forwarding,no-X11-forwarding` und
  `permitlisten` fuer genau `127.0.0.1:4000`, `127.0.0.1:3000`,
  `127.0.0.1:3002`. Alles andere bleibt verriegelt; ein Diebstahl des
  Schluessels oeffnet keine weiteren Ports.
- Vor jeder Aenderung an `authorized_keys` sichert das Skript die Datei auf
  dem Gateway nach `~/.ssh/authorized_keys.bak.<UTC>`.
- LiteLLM ist ohne persoenlichen Virtual-Key nicht nutzbar. Die Schluessel
  liegen in der PostgreSQL des Gateways, je Person mit Limit
  (60 Anfragen/min, 2 Mio. Token, 365 Tage); der Master-Key verlaesst den
  Rechner nie.
- Grafana und Homepage brauchen zusaetzlich Basic-Auth pro Person
  (bcrypt-Hashes in `team-users.txt`).
- Die Caddy-Admin-API hoert auf dem Gateway nur auf `127.0.0.1:2019`. Ohne
  sie schlaegt ein schonendes `systemctl reload caddy` fehl (der ExecReload
  braucht sie), und das Zurueckfallen auf `systemctl restart caddy` wuerde
  jede laufende Kollegen-Anfrage abbrechen.
- Ein zusaetzlicher Wartungs-SSH-Port ist vorbereitet, aber Standard aus
  (`GATEWAY_ADMIN_FORWARD_PORT=0`).
- Vorhandene Basic-Auth-Personen auf diesem Rechner: 5
  (`owner, thomas, martin, johannes, holger`).

Pruefen laesst sich das Modell ohne Aenderung:

```bash
./scripts/70-setup-gateway-proxy.sh --check
./scripts/71-gateway-keys.sh --check
```

## Fehlerfaelle

### autossh exited wiederholt

Die Unit laeuft mit `Restart=always`, `RestartSec=15`, `ExitOnForwardFailure=yes`
und `AUTOSSH_GATETIME=0`; ein Exit ist also selbstheilend, aber sichtbar.

```bash
journalctl --user -u llm-reverse-tunnel.service -n 50 --no-pager
tail -n 40 ~/.local/state/llm-gateway-tunnel.autossh.log
```

Ueblich: der Gateway-Rechner wurde neu gestartet oder das Netz riss ab. Laeuft
der Tunnel danach nicht, haelt sich autossh meist an einem halboffenen Forward
fest; ein Neustart der Unit loest das:
`systemctl --user restart llm-reverse-tunnel.service`.

### permitlisten-Verweigerung

Symptom: der Tunnel will nicht, das Journal zeigt
`Warning: remote port forwarding failed for listen port ...`. Ursache ist fast
immer eine `authorized_keys`-Zeile ohne (oder mit falschen) `permitlisten`, zum
Beispiel nach einer Handkorrektur auf dem Gateway. Das Skript schreibt die
Zeile neu und ersetzt die alte ueber die Comment-Zeile des Schluessels:

```bash
./scripts/70-setup-gateway-proxy.sh && ./scripts/70-setup-gateway-proxy.sh --check
```

### 502 direkt nach einem Caddy-Neustart

Caddy ist nach einem Reload/restart sofort da, die Tunnel-Listener auf
`127.0.0.1:4000|3000|3002` aber erst wieder, wenn autossh den Tunnel neu
aufgebaut hat (bis zu `RestartSec=15` plus Verbindungszeit). Kurze 502-Phasen
sind normal. Bleiben sie bestehen, zuerst pruefen, ob der Gateway ueberhaupt
hoert, dann die Unit neu starten:

```bash
./scripts/70-setup-gateway-proxy.sh --status
systemctl --user restart llm-reverse-tunnel.service
```

### Zertifikatswarnung bei der Roh-IP

`tls internal` mit `default_sni` liefert beim Zugriff ueber
`https://20.73.54.102/` das Zertifikat des DNS-Namens: Warnung wegen
Namensabweichung, zusaetzlich stammt es aus Caddys interner CA. Gegenmittel:
die interne CA auf den Kollegen-Rechnern importieren, oder echtes TLS
umstellen (`GATEWAY_TLS_MODE=acme` plus `GATEWAY_LE_EMAIL` in
`config/gateway-proxy.env`, danach das Skript erneut laufen lassen).

Zum Nachmessen der vier oeffentlichen Routen:

```bash
for p in /health/liveliness /v1/models / /grafana/; do
  printf '%-22s %s\n' "$p" "$(curl -sk -o /dev/null -w '%{http_code}' \
    --resolve edipoc-gateway.westeurope.cloudapp.azure.com:443:20.73.54.102 \
    https://edipoc-gateway.westeurope.cloudapp.azure.com$p)"
done
```

## Was retired wurde

Die alte, unverwaltete `reverse-tunnel.service` (Direkt-Tunnel zu Caddy/SSH/
LiteLLM ohne `permitlisten`-Beschraenkung, Report aus `~/LUNI-P0-V3`) ist
ausser Dienst: gestoppt, deaktiviert und wiederherstellbar umbenannt auf
`~/.config/systemd/user/reverse-tunnel.service.retired-20261116`. Ersetzt
durch die verwaltete `llm-reverse-tunnel.service` aus diesem Repo. Der
wartungshalber optionale `llm-autossh.container` (`scripts/61-install-autossh.sh`)
ist davon nicht betroffen; er bleibt die optionale Einheit fuer den
Wartungstunnel.

Vergleich lesen, nichts aendern:

```bash
diff ~/.config/systemd/user/reverse-tunnel.service.retired-20261116 \
     ~/.config/systemd/user/llm-reverse-tunnel.service
```

## Naechste Befehle

```bash
./scripts/70-setup-gateway-proxy.sh --check      # ist alles in Ordnung?
./scripts/70-setup-gateway-proxy.sh --status     # Kurzbild
./scripts/71-gateway-keys.sh --list              # wer hat einen Gateway-Schluessel?
./scripts/60-install-monitoring.sh --check       # Beobachtung dazu geprueft?
```
