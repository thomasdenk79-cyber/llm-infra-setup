# Fehlerbilder

Jeder Abschnitt: woran man es erkennt, warum es passiert, was zu tun ist.

## Nach einem Neustart startet die Runtime nicht

*Erkenntnis:* `systemctl --user status pennyroyal.service` zeigt einen Fehler,
im Journal steht etwas wie `no such file or directory` oder der Container startet
nicht, obwohl das Modell da ist.

*Ursache:* Der SSD-Speicher fuer die Einbettungstabellen (`/srv/llm/ple-ext4`)
war nur von Hand eingehaengt und fehlt damit nach einem Neustart. Die Unit-Datei
verlangt diesen Pfad (`RequiresMountsFor`).

*Loesung:*

```bash
./scripts/47-setup-ple-storage.sh
./scripts/doctor.sh
```

Das Skript ergaenzt den Eintrag in `/etc/fstab` (mit `nofail`, damit der Rechner
auch ohne die Platte hochfaehrt). Der Doctor prueft den fstab-Zustand dauerhaft
uber die Kennzahl `llm_ple_in_fstab`.

## Runtime kommt nicht hoch

```bash
journalctl --user -u pennyroyal.service -n 200 --no-pager | tail -60
```

| Meldung im Journal | Grund | Massnahme |
|---|---|---|
| `OSError: Function not implemented (os error 38)` | io_uring wird vom Seccomp-Profil oder von ZFS blockiert | `make pennyroyal` erzeugt die Unit mit `seccomp=unconfined` und ext4-Loop fuer PLE; PLE liegt nicht auf ZFS |
| `CUDA out of memory` | zu viel reserviert oder ein anderes Programm belegt die Karte | `nvidia-smi`, Runtime neu starten; `PENNY_HICACHE_SIZE_GB` pruefen |
| `Required executable missing` | Bild oder Startskript passt nicht zusammen | `make pennyroyal`, dann `./scripts/apply-runtime-unit.sh` |
| `Target checkpoint incomplete` | Modell unvollstaendig | `make model` (setzt fort), danach `make model-verify` |
| `tokenizer differs from the qualified FR-Spec tokenizer` | anderes Modell als fuer dieses Startskript freigegeben | `config/model.env` pruefen, nicht mit Gewalt starten |
| Kein `nvidia.com/gpu` in `nvidia-ctk cdi list` | CDI veraltet (neuer Treiber, Karte umgesteckt) | `make podman` |
| Container startet, API aber nie gesund | Kaltstart laeuft noch (15 Minuten) | `journalctl ... -f` zuwarten lassen |

## Chat antwortet nicht, aber die API schon

*Ursache:* Open WebUI ist nicht mit dem Gateway verbunden, oder der erste Account
fehlt (die Registrierung war schon aus).

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/health
podman logs open-webui 2>&1 | tail -20
```

Der Schluessel in `~/.config/llm-infra/open-webui.env` muss mit
`LITELLM_MASTER_KEY` aus `gateway.env` uebereinstimmen; nach einem
`rotate-secrets.sh` beide Dateien neu schreiben.

## Grafana will das Passwort nicht

```bash
podman secret inspect grafana_admin_password >/dev/null || ./scripts/ensure-credentials.sh
./scripts/reset-grafana-password.sh
systemctl --user restart grafana.service
```

## Prometheus zeigt `pennyroyal` als down

Die Runtime antwortet, aber die Unit-Datei des Prometheus war noch die aeltere
Version ohne Inferenz-Netz.

```bash
./scripts/apply-runtime-unit.sh --dry-run     # zeigt den Unterschied
./scripts/apply-runtime-unit.sh               # installiert die neue Datei
curl -s 'http://127.0.0.1:9090/api/v1/query?query=up' | python3 -m json.tool | grep -A2 job
```

## Host-Kennzahlen fehlen in Grafana

```bash
./scripts/collect-host-facts.sh            # schreibt die Datei neu
curl -s http://127.0.0.1:9100/metrics | grep node_textfile_scrape_error
```

Der Wert muss `0` sein. `1` bedeutet, dass eine Familie in der Textdatei keine
`# TYPE`-Zeile hat (oder dass die Datei beim Schreiben beschadigt war). Die
assemble-Funktion in `scripts/collect-host-facts.sh` fuegt sie automatisch ein.

## SMART zeigt keine Werte

`sudo -n smartctl ...` braucht sudo ohne Passwortabfrage. Ohne diesen Zugang
bleibt `llm_smart_available 0`; der Doctor meldet es.

## Gateway-Log voll 401: "No api key passed in." / "Malformed API Key"

Beide Meldungen sind dieselbe Fehlerklasse: ein interner Pruef- oder
Scrape-Laeufer (Prometheus, healthcheck, TUI, Dashboard-Probe) ruft die
master-key-geschuetzten Endpunkte `/health` oder `/metrics` ohne gueltigen
`Authorization: Bearer ...` auf. Das Gateway selbst ist gesund; die
Lebensanzeige `/health/liveliness` ist der einzige keyless Endpunkt und
liefert immer 200 ohne Authentifizierung.

```bash
journalctl --user -u litellm.service --since -1h --no-pager | grep -E 'GET /health|GET /metrics' | tail
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/health/liveliness   # 200 = Gateway ok
```

Regel: interne Tests immer gegen `/health/liveliness`; ein Prometheus-Scrape
auf `/metrics` braucht den Bearer aus einer Secret-Datei
(`authorization.credentials_file`, Vorbereitet in
`config/monitoring/prometheus.yml`), nie Klartext im YAML. Vor dem Fix meldete
auch `./scripts/healthcheck.sh` "Gateway nicht erreichbar", obwohl der
Container lief - derselbe Grund (Test gegen `/health` statt Liveliness).

## Luna-Token abgelaufen

Stufe 3 antwortet nicht mehr oder das Journal zeigt einen neuen Device-Code:

```bash
journalctl --user -u litellm.service --since -30m --no-pager | grep -i -E 'device|code|chatgpt|token'
ls -l ~/.config/llm-infra/chatgpt-tokens/    # auth.json muss existieren und erneuert werden
```

Den angezeigten Device-Code unter https://chat.openai.com/codex (oder dem vom
Provider genannten Pfad) innerhalb der Gueltigkeit bestaetigen; das Token
landet dann von selbst wieder im Volume-Ordner. War der Ordner leer oder
gehorte das Token einem frueheren fluechtigen Containerpfad
(`/root/.config/litellm/chatgpt`), hilft nur einmalig ein frischer Login -
das Volume haelt das Token seit dem Fix auch ueber Gateway-Neustarts.

## Client meldet "Clean EOF, no finish_reason" beim Stream

Herkunft ist der Hermes-Client; er sieht einen sauber beendeten Stream ohne
`finish_reason`. Das ist in dieser Infrastruktur erwartbar, wenn genau in dem
Fenster `litellm.service` (oder die Runtime) neu gestartet wurde - etwa durch
einen Deploy oder den Gateway-Waechter: laufende SSE-Streams werden beim
Container-Stopp sauber geschlossen, ohne dass das Schlusspaket geschrieben
wurde. Einmalige Warnungen kurz nach einem Neustart sind daher ein
Restart-Artefakt, kein Fehler der Kette.

```bash
journalctl --user -u litellm.service --since -6h --no-pager | grep -E 'Stopped|Started' # Ueberlappung pruefen
```

Haufen sie sich OHNE Neustarts, ist ein Proxy/Timeout in der Kette verdaechtig:
Runtime-Metriken (`sglang:num_running_reqs`), Bonsai-Log und Cooldown-Ereignisse
im Gateway-Journal pruefen; notfalls mit
`./scripts/litellm-failover-drill.sh` die Stufen durchmessen.

## Der benannte HTTPS-Zugang klemmt (llm-proxy)

Alles, was ueber Namen laeuft (`homepage.localhost`, `grafana.localhost` und die
LAN-Namen auf `LAN_DOMAIN`), haengt an einem Container: `llm-proxy`. Deshalb
immer in dieser Reihenfolge ansehen - sie ist dieselbe wie im Doctor
(aussen nach innen):

```bash
./scripts/doctor.sh | sed -n '/Lokaler Zugang/,/^$/p'   # gefuehrte Diagnose
./scripts/74-setup-local-proxy.sh --status              # Unit, Listener, Netze, LAN, CA, Sysctl
./scripts/74-setup-local-proxy.sh --check               # Ende-zu-Ende gegen alle Namen
journalctl --user -u llm-proxy.service -n 80 --no-pager # Caddy oder podman?
```

| Bild | Ursache | naechster Befehl |
|---|---|---|
| `curl` ohne `-k` bricht ab, mit `--cacert` geht es | Caddy-CA nicht im Systemvertrauen | `./scripts/74-setup-local-proxy.sh --ca-import` |
| Unit `active`, aber kein Listener auf 443 | Caddy startet durch, podman konnte den Port nicht binden | `journalctl --user -u llm-proxy.service -n 80 --no-pager`; Sysctl-Grenze: `sysctl -n net.ipv4.ip_unprivileged_port_start` (muss <= 443) |
| Unit startet gar nicht mehr, Journal: `Listen failed ... Cannot assign requested address` | `LAN_BIND_IPS` nennt eine Adresse, die der Rechner nicht (mehr) hat - DHCP-Wechsel | `ip -4 addr show`, dann `LAN_BIND_IPS` in `config/host.env` nachziehen und `./scripts/74-setup-local-proxy.sh` |
| Journal: `Permission denied` beim Binden | Kernelgrenze zurueckgesetzt (System-Update, `sysctl --system`) | `./scripts/74-setup-local-proxy.sh` (schreibt `/etc/sysctl.d/99-llm-infra-local-proxy.conf` neu) |
| `502` auf einer Route | Ziel loest im Netz nicht auf oder der Dienst steht | `podman network inspect llm-observability`, `podman ps`; fuer `direct-llm`: `systemctl --user status llm-vllm-forwarder.service` |
| `403` oder TLS-Abbruch auf einem Namen | kein `handle` fuer den Namen - die Fallback-Site antwortet | Namen in der Vorlage `config/proxy/Caddyfile.template` ergaenzen, dann `make local-proxy` |
| `401` trotz richtiger Dozzle-Zugangswerte | Tippfehler im Client | Wert gegenpruefen: `cat ~/.config/llm-infra/proxy/lan-credentials.txt` (Datei 0600, niemals ins Git) |
| `401` mit `{"error":{"message":"Authentication Error, No api key passed in."}}` auf `llm-direct` | kein Verbindungsfehler - der Gateway (LiteLLM) verlangt seinen API-Schluessel als `Authorization: Bearer` | Schluessel auf dem Linux-Rechner: `make show-credentials` (liegt als `LITELLM_MASTER_KEY` in `~/.config/llm-infra/gateway.env`). Geraetetest: `curl.exe -s https://llm-direct.cachyos-x8664/v1/models -H "Authorization: Bearer <schluessel>"` - erwartet 200 mit Modelliste. Bewusst **kein** Basic-Auth auf `littlem`/`llm-direct`; `direct-llm` geht ohne API-Schluessel direkt zur vLLM-API, waehrend Dozzle Basic-Auth nutzt |
| `400` vom Portal unter `homepage.<LAN_DOMAIN>` | Host-Header nicht freigegeben | `HOMEPAGE_ALLOWED_HOSTS` in `config/host.env` ergaenzen, dann `make homepage` |
| Name loest auf einem Fremdgeraet nicht auf | keine DNS-Zone im Netz aktiv - das Geraet haengt an einem DNS, das den Namen nicht kennt | auf dem Linux-Rechner: `make local-dns`, danach `192.168.0.198` im Router als DNS eintragen; ohne Router-Zugang: `./scripts/74-setup-local-proxy.sh --windows-setup` in der PowerShell (Administrator) ausfuehren oder `scripts/windows-lan-client-setup.ps1 -LanIp <ip> -Domain <name> -CertPath <root.crt>` |
| `ping cachyos-x8664` geht, `https://homepage.cachyos-x8664/` gibt `ERR_NAME_NOT_RESOLVED` | zwei verschiedene Wege: der **einteilige** Name laeuft ueber mDNS (Avahi antwortet auf `<hostname>.local`, gemessen auf die WLAN-Adresse `192.168.0.47`), der **zweiteilige** braucht die DNS-Zone aus `scripts/75` | am Geraet: `nslookup homepage.cachyos-x8664 192.168.0.198` (muss die Adresse liefern), dann `Set-DnsClientServerAddress -InterfaceAlias WLAN -ServerAddresses 192.168.0.198,192.168.0.1` und `ipconfig /flushdns`. Der Arzt meldet die mDNS-Abweichung (Pruefpunkt "Lokaler Zugang ueber Namen") |
| EIN Name geht, ein zweiter nicht | der defekte Name wurde schon vor der Zone angefragt - Windows und der Browser cachen die abgelehnte Antwort pro Name | am Geraet: `nslookup <name> 192.168.0.198` (direkt gegen die Zone), dann `ipconfig /flushdns` und den Host-Cache des Browsers leeren (`edge://net-internals/#dns` / `chrome://net-internals/#dns`), InPrivate-Fenster testen |
| Name bekannt, Verbindung laeuft in Zeit | Paketfilter laesst 443 aus dem Heimnetz nicht durch | `sudo ufw status numbered` (erwartet: `443/tcp ALLOW IN 192.168.0.0/24`); Ankunftszahler: `sudo nft list ruleset | grep 'dport 443'`. Die Regel pflegt `workstation-setup`, nicht dieses Repo |
| Reload hilft nicht, Konfig aendert nichts | `ExecReload`pruefen, dann erst neu starten | `systemctl --user show llm-proxy.service -p ExecReload --value`; Gegenprobe `podman inspect llm-proxy -f '{{.State.StartedAt}}'` vor und nach `systemctl --user reload llm-proxy.service` |

Nach einem Neustart des Rechners zusaetzlich die Autostart-Kette pruefen
(linger, `default.target.wants`): `./scripts/doctor.sh`, Pruefpunkt
*Neustartfestigkeit*. Anleitung: `docs/operations.md`, Abschnitt "Nach einem
Neustart: ist der Zugang wieder da?".

## Windows-Client sieht nichts im Netz

Drei Moeglichkeiten, in dieser Reihenfolge:

```powershell
# 1) Name bekannt?  (DNS-Zone von scripts/75 oder hosts-Datei)
ping homepage.cachyos-x8664          # muss auf die LAN-Adresse des Rechners zeigen
# 2) Route da?      (erwartete Codes: 200, 301, 401, 401)
curl.exe -s -o NUL -w "%{http_code}`n" https://homepage.cachyos-x8664/
# 3) Root vertraut? (Zertifikatsfehler = Stamm fehlt oder Stamm ist ein anderer)
certutil -dump C:\temp\caddy-local-authority-root.crt   # Fingerprint gegen --ca-export
```

Der Linux-Rechner liefert beide Voraussetzungen:

```bash
./scripts/74-setup-local-proxy.sh --print-hosts   # hosts-Zeile
./scripts/74-setup-local-proxy.sh --ca-export     # Stammdatei und Fingerprint
```

Einmal gesetzt macht das das Begleit-Skript auf Windows (`-RemoveOnly` fuer den
Rueckbau): `windows-lan-client-setup.ps1 -LanIp <adresse> -Domain <name> -CertPath <datei>`. Bricht TLS sofort ab, ist fast immer die hosts-Zeile auf eine alte
Adresse gerichtet (DHCP-Wechsel auf diesem Rechner) oder der Stamm wurde nach
einem Container-Reset neu ausgestellt, auf Windows aber nicht erneut importiert.

## Etwas wurde versehentlich von Hand geaendert

Repo und Laeufer laufen auseinander:

```bash
./scripts/apply-runtime-unit.sh --list     # was ist anders?
make drift                               # committete Units gegen Generatoren
```

## Zwei Units streiten um denselben Containernamen

Passiert nach Umbenennungen (alte Unit-Datei noch im User-Ordner). Die Deploy-
Skripte entfernen bekannte Altlasten selbststaendig (`prune_legacy_units` in
`lib/units.sh`). Manuell:

```bash
ls ~/.config/containers/systemd
systemctl --user cat <name>.service | grep Image=
```
