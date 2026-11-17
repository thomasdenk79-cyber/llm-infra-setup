# Todo: LAN-Zugang vom Windows-Notebook (einmal durchlaufen)

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
foreach ($r in 'homepage=200','littlem=200','llm-direct=200','grafana=301','dozzle=401','direct-llm=401') {
  $n, $c = $r -split '='
  $got = curl.exe -s -o NUL -w '%{http_code}' "https://$n.cachyos-x8664/"
  "{0,-11} erwartet {1}  erhalten {2}  {3}" -f $n, $c, $got, $(if ($got -eq $c) { 'OK' } else { 'ABWEICHUNG' })
}
curl.exe -s -o NUL -w 'grafana gefolgt: %{http_code} %{url_effective}\n' -L https://grafana.cachyos-x8664/
```

Erwartet: sechs Zeilen mit `OK`, letzte Zeile `grafana gefolgt: 200
https://grafana.cachyos-x8664/grafana/`. **401** bei `dozzle` und `direct-llm`
ist richtig - ohne Zugangswerte, und Zugangswerte gehoeren nirgends hin.

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
| 4 | sechs Routen | 200/200/200/301/401/401 |  |  |
| 5 | Browser homepage | 200 ohne Warnung |  |  |

## Abweichungen
<Vollstaendige Ausgabe, Wort fuer Wort>

## Nicht geprueft
<Grund>
```

Danach `git add handover/ && git commit && git push`. Commit ohne Zugangswerte,
ohne Token, ohne Bilder von anderen Geraeten.
