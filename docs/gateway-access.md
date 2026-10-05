# Gateway-Zugriff fuer Teammitglieder

## Verbindung

Der Gateway auf `20.73.54.102` wird per Reverse-SSH-Tunnel mit LiteLLM auf
CachyOS verbunden. Der SSH-Schluessel des Tunnels ist dediziert und darf am
Gateway nur `127.0.0.1:4000` als Reverse-Forward bereitstellen. Der Port wird
nicht an der oeffentlichen Netzwerkschnittstelle gebunden.
Der verifizierte SSH-Host-Key-Fingerprint (ED25519) lautet
`SHA256:rDkL6da/9HUzecqAq5JS0TB1lhQh8F3fKsdA85AbjGo`.

Bis ein DNS-Name und ein vertrauenswuerdiger HTTPS-Endpunkt eingerichtet sind,
bleibt der API-Zugriff absichtlich auf SSH-Portweiterleitung beschraenkt. Jeder
Nutzer braucht dafuer einen eigenen SSH-Zugang zum Gateway und einen eigenen
LiteLLM-Virtual-Key:

```bash
ssh -N -L 4000:127.0.0.1:4000 azureuser@20.73.54.102
```

Anwendungen verwenden danach `http://127.0.0.1:4000/v1`. Der API-Token wird
als Bearer-Token bzw. `OPENAI_API_KEY` gesetzt. Der SSH-Tunnel verschluesselt
die Verbindung zwischen dem Client und dem Gateway; der Reverse-Tunnel
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

## Oeffentliche HTTPS-Freigabe

Den API-Port nicht direkt per HTTP im Internet freigeben. Vor einer
oeffentlichen Freigabe sind ein DNS-Name, HTTPS-Zertifikat, eine passende
Azure-Netzwerkregel fuer TCP/443 sowie ein externer Verbindungstest
erforderlich. Bis dahin bleibt der Gateway-Port auf dem Gateway-Loopback.
