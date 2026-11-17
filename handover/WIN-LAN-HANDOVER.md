# Uebergabe: LAN-Zugang vom Windows-Notebook pruefen

Adresse des Pruefprotokolls: `handover/WIN-LAN-REPORT-<JJJJ-MM-TT>.md` in diesem
Repo (Branch `main`, Push erwuenscht). Arbeitsauftrag Schritt fuer Schritt:
`handover/WIN-LAN-TODO.md`.

## Wer prueft was

Der Linux-Rechner `cachyos-x8664` (`git@github.com:thomasdenk79-cyber/llm-infra-setup.git`)
beantwortet die Fragen selbst - von dort ist das Notebook **nicht** erreichbar
(fruehere ARP-Anfrage auf `192.168.0.55` fehlgeschlagen). Alles, was "am Geraet
passiert", kann nur hier gemessen werden. Genau dafuer ist dieses Dokument da.

## Gemessene Fakten von der Linux-Seite (Stand 2026-11-17)

| Fakt | Wert |
|---|---|
| Rechnername / LAN-Adresse | `cachyos-x8664` / `192.168.0.198` (enp0s31f6; WLAN `192.168.0.47`, bewusst nicht gebunden) |
| HTTPS-Hafen | `192.168.0.198:443` (Container `llm-proxy`, Caddy) |
| DNS-Zone | dnsmasq antwortet auf `*.cachyos-x8664` -> `192.168.0.198`, nur auf `192.168.0.198:53`, keine Weiterleitung |
| Root-Download | `http://192.168.0.198:8081/caddy-local-authority-root.crt` (nur dieser Pfad, sonst 404) |
| Root-Fingerprint (SHA-256) | `6A:C7:44:AE:12:0E:66:FE:25:8A:FA:5C:D2:68:F1:42:E8:C3:90:92:48:60:BB:ED:77:96:9B:5C:2D:88:31:09` |
| Firewall | ufw aktiv, `443/tcp` und `Anywhere` aus `192.168.0.0/24` erlaubt (Ankunftszahler belegen LAN-Pakete) |
| Erwartete Antworten (Wurzel `/`) | `homepage` 200, `littlem` 200, `llm-direct` 200, `grafana` 301 auf `https://grafana.cachyos-x8664/grafana/` und dort 200, `dozzle` 401, `direct-llm` 401 |
| Erwartete Antworten (`/v1/models`) | `littlem` und `llm-direct`: 401 ohne Schluessel (Gateway verlangt `Authorization: Bearer`), mit Schluessel 200 und Modelliste; `direct-llm`: 401 ohne Basic-Auth, mit Basic-Auth 200 |

Drei Dinge sind Absicht und kein Fehler: **401** auf `dozzle` und `direct-llm`
(ohne Basic-Auth), **401 mit `No api key passed in.`** auf `littlem` und
`llm-direct` (ohne Gateway-Schluessel - das ist ein Zugangs-, kein
Verbindungsfehler) und der **TLS-Abbruch bei nackter IP** - `https://192.168.0.198/`
bricht ab, weil Caddy das Zertifikat nach dem Namen auswaehlt und eine nackte IP
kein SNI mitschickt.

## Regeln fuer den Pruefer

1. **Kein Geraet ausser dem Notebook anassen**, keine Ports oeffnen, keine
   Firewallregeln, keine Router-Einstellungen aendern.
2. **Keine Linux-Seite aendern.** Der Linux-Rechner bleibt der Pruef-Anker;
   Aenderungen dort macht nur der Betreiber.
3. **Keine Zugangswerte** in Dateien, Commits oder Protokolle schreiben. Fuer
   `dozzle`/`direct-llm` ist 401 ohne Werte das erwartete Ergebnis.
4. Root-Zertifikat nur nach **Fingerprint-Vergleich** importieren. Bei
   Abweichung: abbrechen, Fingerprint im Protokoll melden, nicht importieren.
5. Protokoll immer mit **vollstaendiger Befehlsausgabe** (kopieren, nicht
   nacherzaehlen). Was nicht geprueft wurde, steht als "nicht geprueft" drin.
