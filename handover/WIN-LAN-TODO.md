# Todo: LAN-Zugang vom Windows-Notebook (einmal durchlaufen)

## Prompt fuer den Windows-Agenten (kopieren und einfuegen)

> Lies in diesem Repo `handover/WIN-LAN-HANDOVER.md` und dieses Dokument, und
> arbeite beide Punkte exakt in der angegebenen Reihenfolge durch (Schritt 1 bis
> 5, inklusive 2b Cache und 4b Zugangswerte) - auf diesem Windows-Notebook gegen
> `192.168.0.198` und die Namen unter `cachyos-x8664`. Fuehre nur die dort
> stehenden PowerShell-Befehle aus und keine anderen. Aendere nichts an Firewall,
> Router, hosts-Datei ueber den angegebenen Rahmen hinaus oder am Linux-Rechner.
> Gib keine Zugangsdaten, API-Schluessel oder Token aus und schreibe sie in keine
> Datei, kein Protokoll und keinen Commit. Lege das vollstaendige Protokoll als
> `handover/WIN-LAN-REPORT-<JJJJ-MM-TT>.md` ab (Tabelle Schritt / Befehl /
> erwartet / erhalten / Bewertung, bei Abweichungen die wortliche Ausgabe, dazu
> ein Abschnitt "nicht geprueft" mit Grund) und commite und pushe es. Melde am
> Ende knapp, ob die Abnahme bestanden ist oder was fehlt.

Erwartete Ergebnisse stehen in `handover/WIN-LAN-HANDOVER.md`; ein abweichender
Wert ist ein Fund, kein Grund, eigenmaechtig an der Konfiguration zu drehen.

Kontext und Grenzen: `handover/WIN-LAN-HANDOVER.md`. Alles unten laeuft in der
**PowerShell als Administrator** auf dem Notebook. Erwartete Ergebnisse stehen
jeweils dabei; Abweichung = Punkt 7 (Protokoll) statt weiterraten.

## 1. Verbindung zum Rechner

```powershell
Test-NetConnection 192.168.0.198 -Port 443     # TcpTestSucceeded : True
Test-NetConnection 192.168.0.198 -Port 8081    # TcpTestSucceeded : True
```

Beide `False` => Firewall, IP oder der Rechner schlaeft. Dann nicht weiter,
sondern direkt Punkt 7 melden.

## 2. Name aufgeloest? (DNS-Zone, keine hosts-Datei)

Zwei Wege nicht verwechseln: `ping cachyos-x8664` (einteilig) laeuft ueber mDNS
und loest auf eine Adresse auf, an der **kein** Dienst lauscht (gemessen:
WLAN `192.168.0.47`). Fuer alles hier zaehlt nur der **zweiteilige** Name.

```powershell
Get-DnsClientServerAddress | Select-Object InterfaceAlias,ServerAddresses
# erwartet: 192.168.0.198 steht vorn; wenn nicht:
Set-DnsClientServerAddress -InterfaceAlias WLAN -ServerAddresses 192.168.0.198,192.168.0.1
ipconfig /flushdns

Resolve-DnsName homepage.cachyos-x8664          # erwartet: 192.168.0.198
Resolve-DnsName grafana.cachyos-x8664           # erwartet: 192.168.0.198
nslookup -type=A example.com 192.168.0.198      # erwartet: Fehler/leer (kein offener Resolver)
```

Haengt Windows eine Suchendung an (der Router verteilt eine Domain), lautet die
Frage nicht "funktioniert die Zone?" sondern "welcher Name laeuft durch?". Das
zeigt die Detailausgabe - die letzte Zeile mit der eigentlichen Anfrage:

```powershell
nslookup -debug homepage.cachyos-x8664
# erschienen dort Namen wie homepage.cachyos-x8664.lan oder ...fritz.box, ist das
# die Suchendung. Die meldet man dem Linux-Betreiber; sie kommt in
# LAN_DNS_SUFFIXES in config/host.env, danach make local-dns.
```

`Get-NetAdapter | Select-Object Name` nennt den richtigen InterfaceAlias
(`WLAN` oder `Wi-Fi`). Die DNS-Einstellung betrifft nur dieses Geraet;
dauerhaft gehoert `192.168.0.198` als DNS im Router eingetragen.

Liefert `Resolve-DnsName homepage.cachyos-x8664` **nichts**, obwohl der
Linux-Rechner die Zone beantwortet (`nslookup ... 192.168.0.198` oben klappt):
der Adapter nutzt die Zone nicht. Dann uebergangsweise hosts-Eintrag - und im
Protokoll vermerken, dass die DNS-Zone am Geraet weiter fehlt:

```powershell
Add-Content -Path $env:WINDIR\System32\drivers\etc\hosts -Value "192.168.0.198 homepage.cachyos-x8664 grafana.cachyos-x8664 littlem.cachyos-x8664 llm-direct.cachyos-x8664 dozzle.cachyos-x8664 direct-llm.cachyos-x8664"
ipconfig /flushdns
```

## 2b. Cache zuruecksetzen (wenn EIN Name nicht will, die anderen aber schon)

Windows und der Browser cachen eine **abgelehnte** Anfrage pro Name. Ein Name,
der vor der DNS-Zone schon einmal angefragt wurde, bleibt deshalb eine Zeit lang
nicht auffindbar, obwohl die Zone laengst antwortet - genau das Verhalten "mein
Nachbarname geht, meiner nicht".

```powershell
nslookup homepage.cachyos-x8664 192.168.0.198   # liefert die Zone direkt?
ipconfig /flushdns                               # Windows-Cache
# Browser-Host-Cache leeren: edge://net-internals/#dns  bzw.  chrome://net-internals/#dns
# danach ein InPrivate-Fenster oeffnen und erneut versuchen
```

Liefert die erste Zeile die Adresse, der Browser aber weiterhin
`ERR_NAME_NOT_RESOLVED`, ist es der Cache des Browsers - nicht die Zone und nicht
die Firewall. Erst nach diesem Schritt weiter pruefen.

## 3. Stammzertifikat holen und pruefen

```powershell
Invoke-WebRequest http://192.168.0.198:8081/caddy-local-authority-root.crt -OutFile "$env:USERPROFILE\caddy-root.crt"
certutil -dump "$env:USERPROFILE\caddy-root.crt" | Select-String -Pattern "SHA256"
```

Erwarteter SHA-256-Fingerprint:

```
6A:C7:44:AE:12:0E:66:FE:25:8A:FA:5C:D2:68:F1:42:E8:C3:90:92:48:60:BB:ED:77:96:9B:5C:2D:88:31:09
```

Nur bei exakt diesem Wert importieren:

```powershell
certutil -addstore -f Root "$env:USERPROFILE\caddy-root.crt"
```

## 4. Routen gegen ihre erwarteten Codes

```powershell
foreach ($r in 'homepage=200','littlem=200','llm-direct=200','grafana=301','dozzle=401') {
  $n, $c = $r -split '='
  $got = curl.exe -s -o NUL -w '%{http_code}' "https://$n.cachyos-x8664/"
  "{0,-11} erwartet {1}  erhalten {2}  {3}" -f $n, $c, $got, $(if ($got -eq $c) { 'OK' } else { 'ABWEICHUNG' })
}
curl.exe -s -o NUL -w 'grafana gefolgt: %{http_code} %{url_effective}\n' -L https://grafana.cachyos-x8664/
curl.exe -s -o NUL -w 'direct-llm models: %{http_code}\n' https://direct-llm.cachyos-x8664/v1/models
```

Erwartet: fuenf Routen-Zeilen mit `OK`, letzte Zeile `grafana gefolgt: 200
https://grafana.cachyos-x8664/grafana/` und `direct-llm models: 200`.
**401** bei `dozzle` ohne Zugangswerte ist richtig; `direct-llm` antwortet
absichtlich ohne API-Schluessel oder Proxy-Anmeldung.

## 4b. Mit Zugangswerten (beweist die Endpunkte, nicht nur die Route)

Der Gateway-Schluessel liegt auf dem Linux-Rechner in
`~/.config/llm-infra/gateway.env` als `LITELLM_MASTER_KEY` (ausgeben lassen:
`make show-credentials`). Er **gehoert nicht** in diese Datei, ins Protokoll oder
in einen Commit - hier nur als Platzhalter.

```powershell
$k = Read-Host 'Gateway-Schluessel (LITELLM_MASTER_KEY)'   # nicht abtippen, einfuegen
curl.exe -s https://llm-direct.cachyos-x8664/v1/models -H "Authorization: Bearer $k"
# erwartet: 200 mit Modelliste (qwen3.8-flash-next, standard-balanced, ...)
curl.exe -s https://littlem.cachyos-x8664/v1/models -H "Authorization: Bearer $k"
# erwartet: dasselbe - littlem und llm-direct sind beide der Gateway
$k = $null; Clear-Host
```

Ohne Gateway-Schluessel ist **401** auf `littlem` und `llm-direct` erwartet.
`direct-llm` liefert **200 ohne API-Schluessel**. Ein 401 mit
`"No api key passed in."` zeigt: Route und TLS sind in Ordnung, es fehlt nur der
Schluessel - also kein Netzfehler und kein Grund, an der Firewall zu drehen.

## 5. Browser

`https://homepage.cachyos-x8664/` ohne Zertifikatswarnung oeffnen. Warnung =
Stamm fehlt oder ist ein anderer (Punkt 3 wiederholen, Fingerprint vergleichen).

## 6. Aufraeumen (nur wenn hosts-Datei genutzt wurde)

```powershell
# Nur ausfuehren, wenn Punkt 2 den hosts-Ubergangsweg genutzt hat und DNS
# inzwischen funktioniert:
# (Notepad als Administrator) $env:WINDIR\System32\drivers\etc\hosts
```

## 7. Protokoll

Datei `handover/WIN-LAN-REPORT-<JJJJ-MM-TT>.md` im Repo anlegen, Inhalt:

```markdown
# Notebook-Abnahme <Datum>, Geraet: <Windows-Hostname>

| Schritt | Befehl | erwartet | erhalten | Bewertung |
|---|---|---|---|---|
| 1 | Test-NetConnection 443 | True |  |  |
| 2 | Resolve-DnsName homepage | 192.168.0.198 |  |  |
| 3 | Fingerprint | 6A:C7:...:31:09 |  |  |
| 4 | fuenf Routen plus direct-llm Modelle | 200/200/200/301/401; direct-llm 200 |  |  |
| 4b | llm-direct `/v1/models` mit Schluessel | 200 mit Modelliste |  |  |
| 4b | direct-llm `/v1/models` ohne Zugangswerte | 200 mit Modelliste |  |  |
| 5 | Browser homepage | 200 ohne Warnung |  |  |

## Abweichungen
<Vollstaendige Ausgabe, Wort fuer Wort>

## Nicht geprueft
<Grund>
```

Danach `git add handover/ && git commit && git push`. Commit ohne Zugangswerte,
ohne Token, ohne Bilder von anderen Geraeten.
