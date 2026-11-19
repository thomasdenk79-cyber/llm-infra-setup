# LUNI Gateway-Kit — lokales Qwen3.8 via LiteLLM
Online-Anleitung (immer aktuell): https://edipoc-gateway.westeurope.cloudapp.azure.com/anleitung/
Endpoint: https://edipoc-gateway.westeurope.cloudapp.azure.com/v1  (OpenAI-kompatibel)
Auth:     persoenlicher Virtual-Key (Authorization: Bearer <sk-...>) — NIE ins Git/Logs.

## Modelle (3 Routen — Reasoning und Kontext steuert das Gateway)
| Modellname               | Profil     | Reasoning | Kontext (input) |
|--------------------------|------------|-----------|-----------------|
| local-short-none         | efficient  | aus       | ~132k Tokens    |
| local-medium-xhigh       | balanced   | xhigh     | ~242k Tokens    |
| local-long-xhigh         | intelligent| xhigh     | ~462k Tokens    |

Standardfall: **local-medium-xhigh**. Roher Alias qwen3.8-flash-next (512k, ohne
Reasoning-Vorgabe) ist ebenfalls sichtbar, fuer Kollegen aber unnoetig.

## 0) EMPFOHLEN: Ein-Klick-Installer
Einfach **install-all.bat** doppelklicken. Er macht alles automatisch:
Zertifikat importieren, opencode + Copilot CLI installieren/aktualisieren,
NODE_EXTRA_CA_CERTS/Copilot-BYOK-Umgebung setzen, nach dem API-Key fragen
(Eingabe wird versteckt, nie angezeigt) und opencode-Konfig schreiben.
Alternativ manuell (Schritte 1-5 unten).

## 1) Zertifikat importieren (einmalig, ohne Admin moeglich)
./install-cert.ps1          (oder: import root.crt in "Eigene Zertifikate -> Entraute Stammzertifizierungsstellen")
Getestet: Zscaler MITMT den Traffic zum Gateway NICHT - dieser Schritt ist also PFLICHT.

## 2) Funktionstest (Windows)
curl.exe --ssl-no-revoke -H "Authorization: Bearer sk-IHR-KEY" https://edipoc-gateway.westeurope.cloudapp.azure.com/v1/models
(Ohne --ssl-no-revoke meckert Windows die fehlende Sperrliste des Gateway-Zerts - Cosmetic, Import Schritt 1 ist trotzdem noetig.)
curl -X POST -H "Authorization: Bearer sk-IHR-KEY" -H "Content-Type: application/json" ^
  -d "{\"model\":\"local-medium-xhigh\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":20}" ^
  https://edipoc-gateway.westeurope.cloudapp.azure.com/v1/chat/completions

## 3) WICHTIG fuer Node-basierte CLIs (opencode, GitHub Copilot CLI)
Diese nutzen den Windows-Zertifikatsspeicher NICHT. Zusätzlich Umgebungsvariable setzen:
  setx NODE_EXTRA_CA_CERTS "<Pfad>\kollegen-gateway-kit\root.crt"
(dann neue Shell/Terminals; der Installer erledigt das.)

## 4) opencode (Snippet fuer opencode.json)
{
  "provider": {
    "luni": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "https://edipoc-gateway.westeurope.cloudapp.azure.com/v1",
        "apiKey": "{env:LUNI_API_KEY}"
      },
      "models": {
        "local-short-none":   { "name": "LUNI efficient" },
        "local-medium-xhigh": { "name": "LUNI balanced" },
        "local-long-xhigh":   { "name": "LUNI intelligent" }
      }
    }
  }
}
Nutzung: opencode run -m luni/local-medium-xhigh 'hallo'

## 5) Copilot CLI (BYOK) — oder generische OpenAI-Clients
Der Installer setzt: COPILOT_PROVIDER_TYPE=openai, COPILOT_PROVIDER_BASE_URL,
COPILOT_PROVIDER_API_KEY, COPILOT_MODEL=local-medium-xhigh, LUNI_API_KEY.
Danach einfach `copilot` starten. Manuell/anderen Clients:
OPENAI_BASE_URL=https://edipoc-gateway.westeurope.cloudapp.azure.com/v1
OPENAI_API_KEY=sk-IHR-KEY (Modellwahl: local-medium-xhigh)

## 6) Hilfe
Grafana-Dashboards & Homepage: https://edipoc-gateway.westeurope.cloudapp.azure.com/
(Basic-Auth-Zugangsdaten von Thomas, Person = euer Alias.)

## Verifiziert (2026-11-19, Thomas' P16 unter Zscaler)
- GET /v1/models -> 200, Routen lokal verfuegbar
- POST /v1/chat/completions -> Antwort kommt durch
- Zscaler MITMT dieses Zertifikat NICHT -> Import Schritt 1 ist Pflicht
