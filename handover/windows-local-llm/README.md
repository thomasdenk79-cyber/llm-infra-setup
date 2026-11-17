# Windows-Zugang zu den lokalen LLM-Modellen

Dieses Paket richtet **nur** den internen LiteLLM-Zugang ein:

- API: `https://littlem.cachyos-x8664/v1`
- Modelle: `local-short-none`, `local-medium-xhigh`, `local-long-xhigh`
- kein Azure-Endpunkt, kein oeffentlicher Tunnel und keine `standard-*`-Modelle
- persoenlicher LiteLLM-Virtual-Key erforderlich

`homepage.localhost` zeigt immer auf den gerade verwendeten Rechner. Kolleginnen
und Kollegen verwenden deshalb die LAN-Namen mit `cachyos-x8664`.

## Einrichten

1. Im vertrauenswuerdigen Heim-/Labornetz das ZIP herunterladen. Vor dem
   Zertifikat-Import geht der Bootstrap ueber HTTP:
   `http://192.168.0.198:8081/anleitung/anleitung.zip`.
   Nach dem Import ist auch
   `https://homepage.cachyos-x8664/anleitung/anleitung.zip` verfuegbar.
2. ZIP entpacken und im entpackten Ordner `Install.cmd` doppelklicken. Vorher
   den SHA-256-Hash des ZIPs mit dem Wert auf der HTTPS-Anleitungsseite
   vergleichen:

   ```powershell
   Get-FileHash ..\anleitung.zip -Algorithm SHA256
   ```

   Der Starter fragt ausdruecklich nach Bestaetigung, entfernt nur dann den
   Internet-Zonenmarker von den Paket-PS1-Dateien und startet den Installer.
   Er aendert **keine** Execution Policy. Das ist fuer die verwaltete
   `RemoteSigned`-Richtlinie vorgesehen. Bei `AllSigned` oder `Restricted` muss
   die IT das Paket signieren oder freigeben; die Richtlinie nicht umgehen.
3. Der Installer prueft den SHA-256-Fingerprint des mitgelieferten Caddy-Roots,
   importiert ihn nur fuer den aktuellen Windows-Benutzer, fragt nach dem
   persoenlichen Virtual-Key und prueft damit `GET /v1/models`. Der Key wird
   erst nach erfolgreicher Pruefung DPAPI-verschluesselt im Benutzerprofil
   gespeichert. Er steht weder in der ZIP-Datei noch in der OpenCode-Konfiguration.
4. Falls der Installer wegen nicht aufgeloestem `littlem.cachyos-x8664` abbricht,
   eine PowerShell **als
   Administrator** oeffnen und einmal ausfuehren:

   ```powershell
   .\Set-LocalRoutes.ps1
   ```

   Danach `Install.cmd` erneut starten. Wenn das interne DNS den Namen
   bereits aufloest, ist dieser Admin-Schritt nicht erforderlich.
5. Ein neues Terminal oeffnen und `opencode-local` oder `copilot-local` starten.
   Copilot kann beim ersten Start zusaetzlich die GitHub-Anmeldung verlangen.

Die vorhandene OpenCode-Konfiguration wird vor der Aenderung gesichert.
OpenCode bekommt eine Richtlinie, die alle Provider ausser `luni-local`
blockiert; das gilt auch fuer weitere Provider aus Projektkonfigurationen.
Als Standard wird `luni-local/local-medium-xhigh` gesetzt. Im
OpenCode-Modellwaehler stehen nur die drei `local-*`-Modelle dieses Providers.
Copilot CLI startet mit `local-medium-xhigh`; fuer einen anderen
lokalen Alias kann vor dem Start ` $env:LOCAL_LLM_MODEL = 'local-short-none' `
oder `local-long-xhigh` gesetzt werden.

## Direkter API-Test

In PowerShell (im entpackten Ordner); der Key wird nur in der aktuellen
PowerShell-Sitzung gehalten:

```powershell
$env:LITELLM_API_KEY = Read-Host 'Persoenlicher LiteLLM-Virtual-Key'
curl.exe --ssl-no-revoke --cacert .\caddy-local-authority-root.crt `
  --fail-with-body --silent --show-error `
  -H "Authorization: Bearer $env:LITELLM_API_KEY" `
  https://littlem.cachyos-x8664/v1/models

$body = '{"model":"local-medium-xhigh","messages":[{"role":"user","content":"Antworte nur mit OK."}]}'
curl.exe --ssl-no-revoke --cacert .\caddy-local-authority-root.crt `
  --fail-with-body --silent --show-error `
  -H "Authorization: Bearer $env:LITELLM_API_KEY" `
  -H 'Content-Type: application/json' `
  --data-raw $body `
  https://littlem.cachyos-x8664/v1/chat/completions
Remove-Item Env:LITELLM_API_KEY
```

`401` bedeutet meist, dass der Key fehlt, falsch ist oder fuer LiteLLM nicht
freigeschaltet wurde. Die Zertifikatswarnung nicht mit `-k` umgehen. Nur das
mitgelieferte Root mit dem erwarteten Fingerprint installieren.

## Zertifikat-Fingerprint und Vertrauensgrenze

```text
SHA-256 (DER): 6AC744AE120E66FE258AFA5CD268F142E8C390924860BBED77969B5C2D883109
Subject: Caddy Local Authority - 2026 ECC Root
```

Das Root-Zertifikat ist ein oeffentlicher Vertrauensanker, kein API-Key. Der
Import gilt fuer Zertifikate dieser lokalen Caddy-CA. Deshalb nur im
vertrauenswuerdigen Netz verwenden. Die HTTP-Bootstrap-Adresse liefert
ausschliesslich das oeffentliche Root-Zertifikat und dieses ZIP; andere Pfade
werden abgewiesen.

**Wichtig:** Im bisherigen Chat gepostete Zugangsschluessel gelten als
offengelegt und muessen rotiert werden. Verwende hier ausschliesslich einen
persoenlichen, neu ausgestellten LiteLLM-Virtual-Key, niemals den Master-Key.
