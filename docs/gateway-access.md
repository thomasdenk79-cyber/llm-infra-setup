# Gateway-Zugriff fuer Teammitglieder

## Verbindung

Der Gateway auf `20.73.54.102` wird per Reverse-SSH-Tunnel mit LiteLLM, Grafana
und Homepage auf CachyOS verbunden. Der dedizierte SSH-Schluessel darf am
Gateway nur Loopback-Reverse-Forwards bereitstellen; die drei Dienste werden
nicht an der oeffentlichen Netzwerkschnittstelle gebunden.
Der verifizierte SSH-Host-Key-Fingerprint (ED25519) lautet
`SHA256:rDkL6da/9HUzecqAq5JS0TB1lhQh8F3fKsdA85AbjGo`.

Die LiteLLM-API ist zusaetzlich oeffentlich ueber HTTPS/443 freigegeben
(unten, Abschnitt Oeffentliche HTTPS-Freigabe); dafuer genuegt der
persoenliche Virtual Key. Fuer Grafana und Homepage bleibt jeder Nutzer auf
einen eigenen SSH-Zugang zum Gateway angewiesen:

```bash
ssh -i "$HOME\.ssh\id_rsa" -N `
  -L 4000:127.0.0.1:4000 `
  -L 3000:127.0.0.1:3000 `
  -L 3002:127.0.0.1:3002 `
  azureuser@20.73.54.102
```

Solange das SSH-Fenster offen ist, sind die Dienste erreichbar:

| Dienst | Adresse auf dem Client |
|---|---|
| LiteLLM API | `http://127.0.0.1:4000/v1` (alternativ oeffentlich ueber HTTPS/443) |
| Grafana | `http://127.0.0.1:3000` |
| Homepage | `http://127.0.0.1:3002` |

Der API-Token wird als Bearer-Token bzw. `OPENAI_API_KEY` gesetzt. Grafana
verwendet seine eigenen Zugangsdaten, nicht den LiteLLM-Token. Der SSH-Tunnel
verschluesselt die Verbindung zwischen Client und Gateway; der Reverse-Tunnel
verschluesselt die Verbindung zwischen Gateway und CachyOS.

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

Die LiteLLM-API ist ueber die Azure-Gateway-VM oeffentlich auf Port 443
erreichbar; der Zugriffsschutz ist der persoenliche Virtual Key. Eingerichtet
und idempotent nachziehbar mit `./scripts/70-setup-gateway-proxy.sh`
(`make gateway-proxy`, Status: `make gateway-proxy-check`).

* Oeffentlicher Endpunkt: `https://edipoc-gateway.westeurope.cloudapp.azure.com/v1`
* Reverse-Proxy: Caddy 2.11 auf der VM, Let's-Encrypt-Zertifikat ueber
  TLS-ALPN (port 443 genuegt). Die Konfiguration liegt versioniert in
  `gateway/Caddyfile.template`; Werte in `config/gateway.env` (nicht in Git).
* Freigegebene Pfade: nur `/v1/*`, `/health/liveliness`, `/health/readiness`.
  Alles andere antwortet 404 - Grafana, Homepage und etwaige Verwaltungs-
  oberflaechen sind oeffentlich nicht erreichbar.
* Der Proxy leitet auf `127.0.0.1:4000`; dort endet der Reverse-Tunnel von
  CachyOS. An der oeffentlichen Schnittstelle der VM lauscht nur Caddy.

Der API-Zugriff fuer ein Teammitglied (kein Tunnel noetig, nur der persoenliche
Schluessel aus `~/.config/llm-infra/team-api-tokens/`):

```bash
curl https://edipoc-gateway.westeurope.cloudapp.azure.com/v1/models \
  -H "Authorization: Bearer <persoenlicher-key>"
```

Grafana und Homepage erfordern weiterhin den zusaetzlichen SSH-Tunnel pro
Person (siehe Abschnitt Verbindung). Die Verwaltungs-Schluessel der
CachyOS-Maschine: `~/.ssh/llm_gateway_reverse_ed25519` (Tunnel, am Gateway mit
`permitlisten` eingeschraenkt) und `~/.ssh/llm_gateway_admin_ed25519`
(VM-Verwaltung; wird vom Skript erzeugt und hinterlegt).

## Nachziehen der Absicherung (offen)

* Azure-NSG war zum Teststart weit geoeffnet (22, 80?, 443, 3000, 8080). Nach
  dem Testlauf auf 22 und 443 zurueckfahren; 3000/8080 brauchen keine
  Internetregel, die Dienste binden am Gateway nur Loopback.
* LiteLLM-Rollenrechtest pruefen: oeffentlich soll nur die Chat-API dienen,
  nicht die Verwaltungs-API (Schluesselverwaltung bleibt localhost-only).
* Fuehrt ein Betreiber die Azure-CLI (`az`), kann das Skript die NSG-Regel
  pruefen statt sie nur zu testen.
