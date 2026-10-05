# Arbeitsauftrag fuer den lokalen Qwen-Agenten auf CachyOS

Du arbeitest auf `cachyos2` im Repository `~/work/llm-infra-setup`. Lies zuerst
`AGENTS.md`, `docs/HANDOFF.md`, `docs/gateway-access.md` und den aktuellen
`git status`. Das Repository und der Live-Host koennen auseinanderlaufen:
pruefe beides, bevor du etwas aenderst.

## Ziel

Den bestehenden Reverse-SSH-Tunnel fuer LiteLLM, Grafana und Homepage
zuverlaessig betreiben, die Aenderungen im Repository konsistent dokumentieren
und den Betreiber mit einer funktionierenden Client-Anleitung uebergeben.

## Bekannter Live-Stand (2026-10-05)

* Gateway: Ubuntu-VM `20.73.54.102`, Login fuer Operatoren `azureuser`.
* Verifizierter Gateway-Host-Key (ED25519):
  `SHA256:rDkL6da/9HUzecqAq5JS0TB1lhQh8F3fKsdA85AbjGo`.
* CachyOS-Tunnel-Key: `~/.ssh/llm_gateway_reverse_ed25519` (privat, Modus
  `0600`). Bekannte Host-Keys liegen in
  `~/.local/share/llm-infra/ssh/known_hosts`.
* Lokale Tunnel-Konfiguration ist ignoriert und bleibt ausserhalb von Git:
  `config/autossh.env`. Sie setzt den dedizierten Key und Gateway-Benutzer.
* Der rootless Quadlet-Service `llm-autossh.service` und Container
  `llm-autossh` laufen. Die Reverse-Forwards sind:
  `127.0.0.1:4000` -> LiteLLM `127.0.0.1:4000`,
  `127.0.0.1:3000` -> Grafana `127.0.0.1:3000` und
  `127.0.0.1:3002` -> Homepage `127.0.0.1:3002`.
* Alle drei Ports muessen auf dem Gateway an Loopback gebunden bleiben. Fuer
  den Tunnel-Key ist `permitlisten="127.0.0.1:*"` gesetzt: keine oeffentlichen
  Listener. Die SSH-Zugriffsregel wurde mit einer kommagetrennten Portliste
  getestet und vom Server abgelehnt; den funktionierenden Loopback-Wildcard-
  Eintrag nicht ohne erfolgreichen Authentifizierungs- und Bindetest ersetzen.
* Gateway-Checks zuletzt: API-Liveness `200`, Grafana `301` (Login-Weiterleitung),
  Homepage `200`; `ss` zeigte nur Loopback-Listener. Die Runtime lief und
  beantwortete `/health` mit `200`.
* Fuenf LiteLLM-Virtual-Keys sind erstellt und auf `qwen3.8-flash-next`
  beschraenkt. Werte liegen nur in
  `~/.config/llm-infra/team-api-tokens/{owner,thomas,martin,johannes,holger}.key`
  (Modus `0600`). Niemals Werte ausgeben, in Logs schreiben oder committen.
  `make team-api-keys` ist idempotent und behaelt vorhandene Dateien.
* Lokale Commits: `4d68f72`, `9ab713e` und `4816481`. Der letzte Commit ergaenzt
  Grafana und Homepage im Tunnel. Ein Push scheiterte an fehlender
  GitHub-Anmeldung. Keine Credentials erfinden, konfigurieren oder umgehen;
  push nur, wenn der Betreiber bereits eine sichere, verfuegbare Anmeldung hat.
* Der Tunnel und die drei Forwards sind eingerichtet. Bei Start des Agents war
  der Worktree nur durch diese bestehenden, nicht zugehoerigen Aenderungen
  geaendert: `config/homepage/services.yaml`, `docs/operations.md` und
  `quadlet/dozzle.container`. Vor jedem Schritt erneut `git status` lesen und
  diese Aenderungen unangetastet lassen.

## Sicherheit und Grenzen

* Keine LiteLLM-, Grafana- oder Homepage-Ports direkt im Internet oeffnen.
  Clientzugriff erfolgt vorerst ueber SSH-Portweiterleitung; der API-Token allein
  ersetzt keine sichere Transportverschluesselung.
* Eine direkte HTTPS-Freigabe ist ein separates spaeteres Vorhaben. Dafuer
  braucht es DNS oder ein abgestimmtes Zertifikatsverfahren, eine passende
  Azure-Netzwerkregel und einen externen TLS-Test.
* Niemals den Pennyroyal-/SGLang-Inferenzdienst neu starten. Es laufen produktive
  Anfragen; fuer diese Aufgabe sind keine GPU- oder Runtime-Aenderungen noetig.
* Nicht `git restore`, `git reset`, `git checkout` oder rekursive Loeschungen
  gegen unbekannte/uncommittete Dateien verwenden.
* `scripts/session-checkpoint.sh` fuehrt `git add -A` aus. Fuehre es nicht aus,
  solange fremde oder nicht zugehoerige Aenderungen im Worktree liegen; stage
  nur explizit gepruefte Dateien.

## Vorgehen

1. Read-only verifizieren: `systemctl --user is-active llm-autossh.service`,
   `podman ps` und die Gateway-Listener auf `127.0.0.1:3000`, `:3002`, `:4000`.
   Wenn alles aktiv ist, nicht neu bauen oder neu starten.
2. Die installierte Unit mit `quadlet/llm-autossh.container` vergleichen.
   `./scripts/61-install-autossh.sh --check` kann die Schluesselauth pruefen.
   Bei Fehlern zuerst Ursache und Gateway-SSH-Logs lesen; keine Host-Key-
   Pruefung abschalten und keine Schluessel neu erzeugen.
3. Falls ein Forward fehlt, sicherstellen, dass Generator und Quadlet
   uebereinstimmen, dann nur `llm-autossh.service` kontrolliert neu starten
   (niemals die Inferenzruntime). Danach alle drei Listener und HTTP-Status
   pruefen.
4. Pruefen, dass jede Token-Datei existiert, Modus `0600` hat und nicht von Git
   verfolgt wird. API-Zugriff je Token testen, ohne Token oder Antwortinhalte
   auszugeben. Keine neuen Keys erzeugen, wenn die vorhandenen gueltig sind.
5. Die Clientanleitung muss fuer Windows PowerShell diese Verbindung zeigen
   (Terminal offen lassen):

   ```powershell
   ssh -i "$HOME\.ssh\id_rsa" -N `
     -L 4000:127.0.0.1:4000 `
     -L 3000:127.0.0.1:3000 `
     -L 3002:127.0.0.1:3002 `
     azureuser@20.73.54.102
   ```

   Danach: LiteLLM `http://127.0.0.1:4000/v1`, Grafana
   `http://127.0.0.1:3000`, Homepage `http://127.0.0.1:3002`. LiteLLM braucht
   den persoenlichen Virtual Key; Grafana verwendet eigene Zugangsdaten.
6. `make validate`, `bash -n scripts/61-install-autossh.sh
   scripts/create-team-api-keys.sh` und einen strikten Doku-Build ausfuehren.
   `make drift` kann wegen bereits vorhandener anderer Quadlet-Aenderungen
   scheitern; diese weder zuruecksetzen noch mitcommitten.
7. `CHANGELOG.md`, `docs/status.md`, `docs/HANDOFF.md`,
   `docs/gateway-access.md`, `docs/operations.md`, den Generator und die
   generierte Unit konsistent halten. Nur bei echten Aenderungen relevante
   Dateien committen; bestehende lokale Aenderungen niemals in einen
   Sammel-Commit aufnehmen.

Am Ende dem Betreiber knapp mitteilen: genaue Clientbefehle, Dienst-URLs,
Speicherorte der persoenlichen Token-Dateien, Tests, Commit-ID und ob ein Push
gelungen ist. Keine Geheimniswerte in der Uebergabe ausgeben.
