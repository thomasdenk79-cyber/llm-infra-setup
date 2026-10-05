# Gateway-Zugriff fuer Teammitglieder

## Verbindung

Der Gateway auf `20.73.54.102` (`edipoc-gateway.westeurope.cloudapp.azure.com`)
wird per Reverse-SSH-Tunnel mit LiteLLM, Grafana und Homepage auf CachyOS
verbunden. Der dedizierte Tunnel-Schluessel darf am Gateway nur
Loopback-Reverse-Forwards bereitstellen; die drei Dienste binden dort
ausschliesslich auf `127.0.0.1`. Der verifizierte SSH-Host-Key-Fingerprint
(ED25519) lautet `SHA256:rDkL6da/9HUzecqAq5JS0TB1lhQh8F3fKsdA85AbjGo`.

Der taegliche Zugang ist HTTPS/443 ueber Caddy (Abschnitt
"Oeffentliche HTTPS-Freigabe"). Der SSH-Tunnel bleibt die
Notfall-/Verwaltungsroute:

```bash
ssh -i "$HOME\.ssh\id_rsa" -N `
  -L 4000:127.0.0.1:4000 `
  -L 3000:127.0.0.1:3000 `
  -L 3002:127.0.0.1:3002 `
  azureuser@20.73.54.102
```

| Dienst | 443-Weg (normal) | Tunnel-Weg (Notfall) |
|---|---|---|
| LiteLLM API | `https://<fqdn>/v1` + Token | `http://127.0.0.1:4000/v1` |
| Grafana | `https://<fqdn>/grafana/` + Basic-Auth | `http://127.0.0.1:3000` |
| Homepage | `https://<fqdn>/` + Basic-Auth | `http://127.0.0.1:3002` |

Der API-Token wird als Bearer-Token bzw. `OPENAI_API_KEY` gesetzt. Die
Basic-Auth-Passwoerter sind nicht der LiteLLM-Token.

## Virtual Keys

LiteLLM bekommt pro Person einen eigenen Virtual Key mit Zugriff nur auf
`qwen3.8-flash-next`. Der Master-Key ist ausschliesslich fuer Administration
bestimmt und darf nicht an Teammitglieder verteilt werden. Erzeugte
Team-Tokens werden ausserhalb von Git unter
`~/.config/llm-infra/team-api-tokens/` abgelegt, je Datei mit Modus `0600`.
Tokens nicht in Shell-History, Tickets oder Chatraeume kopieren.

Einen verlorenen Token ueber LiteLLM widerrufen und fuer dieselbe Person einen
neuen erzeugen; niemals einen persoenlichen Token fuer mehrere Nutzer teilen.
Budgets und Ablaufzeiten sind noch nicht festgelegt und muessen vor einer
groesseren Freigabe abgestimmt werden.

## Oeffentliche HTTPS-Freigabe (in Betrieb seit 2026-10-05)

Alles laeuft ueber **eine** Port-443-Regel der Azure-NSG; Caddy 2.11 auf der VM
entscheidet nach Pfad. Eingerichtet und idempotent nachziehbar mit
`./scripts/70-setup-gateway-proxy.sh` (`make gateway-proxy`,
Status `make gateway-proxy-check`).

* `/v1/*`, `/health/liveliness`, `/health/readiness` -> LiteLLM
  (`127.0.0.1:4000`). Schutz: persoenlicher Virtual Key, ohne Token 401.
* `/grafana/` -> Grafana (`127.0.0.1:3000`) im Unterpfad
  (`GF_SERVER_SERVE_FROM_SUB_PATH`). Schutz: Basic-Auth pro Person **und**
  Grafana-Login.
* `/` (restliche Pfade) -> Homepage (`127.0.0.1:3002`). Schutz: Basic-Auth
  pro Person. Ohne gueltige Zugangsdaten antwortet 401.
* Team-Namen in `GATEWAY_TEAM_USERS`; Passwoerter erzeugt das Skript einmalig
  in `~/.config/llm-infra/gateway-web-auth/<name>.txt` (0600) - niemals in
  Git, Tickets oder Chats.
* TLS: mit `GATEWAY_TLS=internal` stellt Caddy eine eigene CA aus (passt zur
  beschraenkten NSG). Das Stammzertifikat liegt nach dem Setup unter
  `state/gateway/caddy-root.crt` und muss auf den Client-Rechnern einmalig als
  vertrauenswuerdig installiert werden (sonst Browser-Warnung/`-k`).
  Alternative `GATEWAY_TLS=letsencrypt`: vertrauenswuerdig, erfordert aber
  dauerhaft oeffentlich erreichbares 443 (auch fuer die Erneuerung).
* Verwaltungs-Schluessel der CachyOS-Maschine:
  `~/.ssh/llm_gateway_reverse_ed25519` (Tunnel, `permitlisten`-beschraenkt)
  und `~/.ssh/llm_gateway_admin_ed25519` (VM-Verwaltung).

## Entra-ID-Login (in Vorbereitung)

On-Premises-Active-Directory (LDAP) ist von der Azure-VM aus nicht erreichbar
(Siemens-Firewall) - die praxistaugliche Bruicke ist **Entra ID** als
cloudseitiges Spiegelbild des Firmen-AD (GID/E-Mail bleiben dieselben).

Erledigt am 2026-10-05: Sicherheitsgruppe **edipoc-gateway-llm**
(Objekt-ID `892544c5-1696-46ad-ac09-ad40488b117b`, Mandant
`siemens.onmicrosoft.com`, 4 Mitglieder: martin.citak, holger.heise,
thomas.denk, Johannes.Holzhaeuer @siemens.com; Betreiber-E-Mail noch
hinzufuegen). Die Gruppen-ID ist in `config/gateway.env` hinterlegt
(`GATEWAY_AZUREAD_GROUP_OBJECT_ID`) und wird von Grafana als
`GF_AUTH_AZUREAD_ALLOWED_GROUPS` gesetzt.

Offen (scheitert derzeit an den Rechten fuer die App-Registrierung - ggf.
IT-Ticket mit exakt diesen Vorgaben):

1. App-Registrierung, Kontotyp "Nur Organisation dieses Mandanten".
2. Umleitungs-URI (Web): `https://edipoc-gateway.westeurope.cloudapp.azure.com/login/azuread`.
3. Clientgeheimnis (~12 Monate), Werte (Tenant-ID, Client-ID, Secret) in
   `config/gateway.env` eintragen.
4. Eigenschaften -> "Zuweisung erforderlich" = Ja, Gruppe von oben zuweisen.
5. `./scripts/70-setup-gateway-proxy.sh` erneut laufen lassen - es schreibt
   `~/.config/llm-infra/grafana.env` (0600) und startet nur Grafana neu.

Danach genuegt in Grafana der Entra-Button; die Basic-Auth bleibt als
zweite Schicht vor dem Proxy. Die LiteLLM-API laeuft weiter rein per Token
(Maschinenzugriff passt nicht in Browser-OAuth). Bis die App-Registrierung
steht, bleibt die Basic-Auth der einzige Browser-Zugang.

## Brandmauer-Regeln (Azure-NSG)

Zielzustand, vom Skript in Abschnitt 8 immer aktuell angezeigt
(Portal-Wortlaut plus `az`-Befehl):

| Regel | Port | Quelle |
|---|---|---|
| `allow-ssh-cachyos` | 22 | nur `GATEWAY_ALLOWED_SSH_CIDRS` (CachyOS, aktuell `92.209.14.229/32`) |
| `allow-web-team` | 80, 443 | nur `GATEWAY_ALLOWED_WEB_CIDRS` (Zscaler Muenchen `147.161.168.0/22`, `147.161.176.0/23`, `147.161.250.0/23` + eigene Netze) |
| loeschen | 3000, 8080 | keine Internetregel noetig - die VM-Dienste binden nur Loopback |

* Kein `Any` mehr auf Port 22. Das Team benoetigt ihn nicht mehr: Grafana und
  Homepage laufen ueber 443 mit Login.
* Oeffentliche IP der CachyOS-Maschine nach Neueinwahl pruefen und nachziehen:
  `curl -s https://api.ipify.org`; das Skript warnt bei
  Selbst-Aussperrung (`make gateway-proxy-check`).
* Bei `GATEWAY_TLS=letsencrypt` muss 443 zusaetzlich auf `Any`, sonst
  scheitert die Zertifikatserneuerung.
* LiteLLM-Rollenrechte pruefen: oeffentlich dient nur die Chat-API unter
  `/v1`; Schluesselverwaltung bleibt localhost-only.
