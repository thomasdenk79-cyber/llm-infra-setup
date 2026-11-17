# Notebook-Abnahme 2026-11-17, Geraet: Windows-Notebook (Hostname nicht erhoben)

Pruefung vom Windows-Notebook gegen `192.168.0.198`. Keine Aenderungen an
Firewall, Router oder Linux-Rechner. Zugangswerte wurden weder ausgegeben noch
in Dateien oder dieses Protokoll geschrieben.

| Schritt | Befehl | erwartet | erhalten | Bewertung |
|---|---|---|---|---|
| 1 | `Test-NetConnection 192.168.0.198 -Port 443` | `TcpTestSucceeded: True` | `True`, Ethernet, Quelle `192.168.0.123` | OK |
| 1 | `Test-NetConnection 192.168.0.198 -Port 8081` | `TcpTestSucceeded: True` | `True`, Ethernet, Quelle `192.168.0.123` | OK |
| 2 | DNS-Server des aktiven Adapters | `192.168.0.198` zuerst | Anfangs Ethernet `192.168.0.1`; nach `gsudo` Ethernet `192.168.0.198, 192.168.0.1` | OK nach lokaler DNS-Anpassung |
| 2 | `Resolve-DnsName homepage.cachyos-x8664` | `192.168.0.198` | Anfangs NXDOMAIN; nach DNS-Anpassung `192.168.0.198` | OK nach Anpassung |
| 2 | `Resolve-DnsName grafana.cachyos-x8664` | `192.168.0.198` | Anfangs NXDOMAIN; nach DNS-Anpassung `192.168.0.198` | OK nach Anpassung |
| 2 | `nslookup -type=A example.com 192.168.0.198` | Fehler/leer, kein offener Resolver | `Query refused` (mit zusaetzlichen DNS-Timeouts) | OK |
| 2b | `nslookup homepage.cachyos-x8664 192.168.0.198`; `ipconfig /flushdns` | Zone liefert `.198`; Cache geleert | Zone liefert `.198`; Cache-Leerung mit `gsudo` erfolgreich | Teilweise OK; Browser-Cache nicht direkt geprueft |
| 3 | Zertifikat herunterladen und SHA-256 pruefen | Fingerprint `6A:C7:44:AE:12:0E:66:FE:25:8A:FA:5C:D2:68:F1:42:E8:C3:90:92:48:60:BB:ED:77:96:9B:5C:2D:88:31:09` | Fingerprint stimmt exakt ueberein | OK |
| 3 | `certutil -addstore -f Root ...` | Zertifikat im Root-Speicher | Import mit `gsudo` erfolgreich | OK |
| 4 | Fuenf HTTPS-Routen plus direct-llm `/v1/models` | `200/200/200/301/401`; direct-llm ohne Key `200` | Alle sechs `000`; curl-Exitcode `35` | ABWEICHUNG |
| 4 | Grafana-Weiterleitung | `200`, URL endet `/grafana/` | `000`, URL blieb `https://grafana.cachyos-x8664/` | ABWEICHUNG |
| 4b | `/v1/models` auf `llm-direct` und `littlem` mit vorhandenem Gateway-Wert | `200` mit Modelliste | Beide HTTP-Status `000`; kein Body | ABWEICHUNG |
| 4b | `/v1/models` auf `direct-llm` ohne Zugangswerte | `200` ohne API-Schluessel oder Proxy-Login | curl vor der Konfigurationsaenderung: HTTP-Status `000`, Exitcode `35`; Browser-Abfrage war noch die alte Konfiguration | NICHT GEPRUEFT |
| 5 | Browser: `https://homepage.cachyos-x8664/`, ohne Zertifikatswarnung | Seite erreichbar, keine Warnung | Benutzer bestaetigte, dass die URL jetzt aufrufbar ist; Warnungsstatus nicht unabhaengig beobachtet | Benutzerbestaetigt, teilweise geprueft |

## Ausgaben der erfolgreichen Pruefungen

### Schritt 1

`Test-NetConnection 192.168.0.198 -Port 443`:

```text
ComputerName     : 192.168.0.198
RemoteAddress    : 192.168.0.198
RemotePort       : 443
InterfaceAlias   : Ethernet
SourceAddress    : 192.168.0.123
TcpTestSucceeded : True
```

`Test-NetConnection 192.168.0.198 -Port 8081`:

```text
ComputerName     : 192.168.0.198
RemoteAddress    : 192.168.0.198
RemotePort       : 8081
InterfaceAlias   : Ethernet
SourceAddress    : 192.168.0.123
TcpTestSucceeded : True
```

### Schritt 2

Vor der Anpassung, relevante Zeilen aus
`Get-DnsClientServerAddress | Select-Object InterfaceAlias,ServerAddresses`:

```text
InterfaceAlias                     ServerAddresses
Ethernet                           {192.168.0.1}
Ethernet                           {}
WLAN                               {192.168.0.198, 192.168.0.1}
WLAN                               {}
```

Nach `gsudo Set-DnsClientServerAddress`:

```text
InterfaceAlias                     ServerAddresses
Ethernet                           {192.168.0.198, 192.168.0.1}
Ethernet                           {}
WLAN                               {192.168.0.198, 192.168.0.1}
WLAN                               {}
```

`Resolve-DnsName homepage.cachyos-x8664` nach der Anpassung:

```text
Name                                           Type   TTL   Section    IPAddress
homepage.cachyos-x8664                         A      0     Answer     192.168.0.198
```

`Resolve-DnsName grafana.cachyos-x8664` nach der Anpassung:

```text
Name                                           Type   TTL   Section    IPAddress
grafana.cachyos-x8664                          A      0     Answer     192.168.0.198
```

`nslookup -type=A example.com 192.168.0.198`:

```text
*** example.com wurde von UnKnown nicht gefunden: Query refused.
DNS request timed out.
    timeout was 2 seconds.
Server:  UnKnown
Address:  192.168.0.198

DNS request timed out.
    timeout was 2 seconds.
```

`nslookup -debug homepage.cachyos-x8664` nach der Anpassung endete mit
`Server: UnKnown`, `Address: 192.168.0.198`, `rcode = NOERROR`,
`internet address = 192.168.0.198`, `ttl = 0 (0 secs)` und
`Name: homepage.cachyos-x8664 / Address: 192.168.0.198`. Die Ausgabe enthielt
vor der Antwort mehrere DNS-Timeout-Meldungen.

### Schritt 2b

Die Cache-Leerung mit `gsudo ipconfig /flushdns` gab aus:

```text
Windows-IP-Konfiguration

Der DNS-Aufl�sungscache wurde geleert.
```

### Schritt 3

`certutil -dump ... | Select-String -Pattern "SHA256"` endete mit:

```text
Zertifikathash(sha256): 6ac744ae120e66fe258afa5cd268f142e8c390924860bbed77969b5c2d883109
```

Der Wert entspricht dem erwarteten Fingerprint mit Doppelpunkten und
Grossbuchstaben.

Die Ursache der anfänglichen Namensaufloesung war die DNS-Konfiguration des
aktiven Ethernet-Adapters: Er nutzte zuerst `192.168.0.1`; die WLAN-Schnittstelle
hatte `192.168.0.198` bereits zuerst eingetragen. Nach der dokumentierten
Anpassung des Ethernet-Adapters mit `gsudo` loesten beide Namen auf
`192.168.0.198` auf.

## Abweichungen

### Schritt 2: zuerst fehlende Namensaufloesung

Vor der lokalen DNS-Anpassung meldete `Resolve-DnsName homepage.cachyos-x8664`:

```text
Resolve-DnsName : homepage.cachyos-x8664 : Der DNS-Name ist nicht vorhanden
In Zeile:2 Zeichen:1
+ Resolve-DnsName homepage.cachyos-x8664
+ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : ResourceUnavailable: (homepage.cachyos-x8664:String) [Resolve-DnsName], Win32Exception
    + FullyQualifiedErrorId : DNS_ERROR_RCODE_NAME_ERROR,Microsoft.DnsClient.Commands.ResolveDnsName
```

`Resolve-DnsName grafana.cachyos-x8664` meldete entsprechend:

```text
Resolve-DnsName : grafana.cachyos-x8664 : Der DNS-Name ist nicht vorhanden
In Zeile:2 Zeichen:1
+ Resolve-DnsName grafana.cachyos-x8664
+ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : ResourceUnavailable: (grafana.cachyos-x8664:String) [Resolve-DnsName], Win32Exception
    + FullyQualifiedErrorId : DNS_ERROR_RCODE_NAME_ERROR,Microsoft.DnsClient.Commands.ResolveDnsName
```

Die direkte Zonenabfrage lieferte nach Timeouts die Adresse:

```text
DNS request timed out.
    timeout was 2 seconds.
Server:  UnKnown
Address:  192.168.0.198

DNS request timed out.
    timeout was 2 seconds.
DNS request timed out.
    timeout was 2 seconds.
Name:    homepage.cachyos-x8664
Address:  192.168.0.198
```

Die nicht-erhoehte DNS-Aenderung, Cache-Leerung und Hosts-Datei-Ausweichloesung
scheiterten an fehlenden Administratorrechten. Der Hosts-Eintrag wurde nicht
geschrieben. Nach `gsudo` war die DNS-Aenderung erfolgreich; die danach
ausgefuehrten `Resolve-DnsName`-Befehle lieferten jeweils `192.168.0.198`.
`nslookup -debug homepage.cachyos-x8664` fragte nach der DNS-Aenderung
`192.168.0.198` ohne Suchendung ab und erhielt `NOERROR` mit Antwort
`192.168.0.198`.

### Schritt 2b: Cache

Die erste nicht-erhoehte Cache-Leerung meldete:

```text
Der angeforderte Vorgang erfordert erh�hte Rechte.
```

Die erneute Ausfuehrung mit `gsudo ipconfig /flushdns` meldete:

```text
Windows-IP-Konfiguration

Der DNS-Aufl�sungscache wurde geleert.
```

### Schritt 3: Root-Zertifikat

Der erste Import ohne Administratorrechte scheiterte:

```text
Zur Verwendung der ausgew�hlten Optionen werden Administratorberechtigungen ben�tigt. Verwenden Sie einen Administratorbefehl, um diese Aufgaben abzuschlie�en.
Root "Vertrauensw�rdige Stammzertifizierungsstellen"
Der Zertifikatspeicher konnte nicht ge�ffnet werden.
CertUtil: -addstore-Befehl ist fehlgeschlagen: 0x80070005 (WIN32: 5 ERROR_ACCESS_DENIED)
CertUtil: Zugriff verweigert
```

Nach Fingerprint-Vergleich wurde der Import mit `gsudo` erfolgreich ausgefuehrt:

```text
Root "Vertrauensw�rdige Stammzertifizierungsstellen"
Signatur stimmt mit dem �ffentlichen Schl�ssel �berein.
Das Zertifikat "Caddy Local Authority - 2026 ECC Root" wurde zum Speicher hinzugef�gt.
CertUtil: -addstore-Befehl wurde erfolgreich ausgef�hrt.
```

### Schritte 4 und 4b: HTTPS

Die dokumentierte Routenpruefung lieferte sowohl vor als auch nach DNS- und
Zertifikatsanpassung:

```text
homepage    erwartet 200  erhalten 000  ABWEICHUNG
littlem     erwartet 200  erhalten 000  ABWEICHUNG
llm-direct  erwartet 200  erhalten 000  ABWEICHUNG
grafana     erwartet 301  erhalten 000  ABWEICHUNG
dozzle      erwartet 401  erhalten 000  ABWEICHUNG
direct-llm  erwartet 401  erhalten 000  ABWEICHUNG
grafana gefolgt: 000 https://grafana.cachyos-x8664/
```

Die Statusabfragen in Schritt 4b ergaben:

```text
llm-direct 000
littlem 000
direct-llm without Basic-Auth 000
```

Die dokumentierten `curl.exe -s`-Aufrufe lieferten keinen Body; die
Statusabfragen ergaben `000`. Der direkte Aufruf ohne Zugangswerte endete mit
curl-Exitcode `35`. Der Benutzer bestaetigte anschliessend, dass der Browser
bei `https://direct-llm.cachyos-x8664/v1/models` nach Benutzer und Passwort
fragt. Diese Beobachtung betraf die alte Konfiguration; der Betreiber stellte
danach klar, dass `direct-llm` ohne API-Schluessel und Proxy-Anmeldung direkt
zur vLLM-API fuehren soll. Die neue Repo-Konfiguration ist daher noch separat
auszurollen und von Windows zu pruefen. Es wurden keine Zugangswerte
ausgegeben oder protokolliert.

## Nicht geprueft

- Die Browser-Host-Cache-Seite und ein InPrivate-Aufruf wurden nicht unabhaengig
  bedient. Der Benutzer bestaetigte spaeter, dass die Homepage aufrufbar ist;
  ob dabei eine Zertifikatswarnung erschien, wurde nicht beobachtet.
- Der erwartete direkte `direct-llm`-Modelllistenabruf nach der
  Konfigurationsaenderung ist noch nicht geprueft; der dokumentierte Windows-
  curl-Aufruf scheiterte vorher mit Status `000`.
- Die HTTPS-Routen und die Gateway-Modelllisten blieben mit `curl.exe` bei
  Status `000` (curl-Exitcode `35`); die Abnahme dieser Endpunkte ist daher
  offen, auch wenn der Benutzer die Homepage im Browser inzwischen aufrufen
  konnte.
- Der Windows-Hostname wurde nicht erhoben, da dafuer kein Befehl in der
  freigegebenen Handover-Prueffolge stand.
