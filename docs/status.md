# Projektstatus

Stand: 2026-11-16, geprueft am selben Tag. Fruehere Stiche (WSL-Zeit,
Pennyroyal-Kaltstarts, Tuning-Runden) stehen im `CHANGELOG.md` und im
Git-Verlauf: `git show HEAD:docs/status.md`. Fortsetzungsanker ist
`docs/HANDOFF.md`.

## Verifizierter Zustand (2026-11-16)

### Inferenz-Laufzeit

Der unmanaged Container `flash-next-v3` (vLLM, Bild
`localhost/qwen38-fp4-tp1:v3`) laeuft und bindet sein API nur auf
`127.0.0.1:30000`. Pennyroyal gibt es auf diesem Rechner nicht; die
Identitaet der Laufzeit steht in `config/host.env`. Metriken stellt der
Weiterleiter aus diesem Repo bereit: User-Unit `llm-vllm-forwarder.service`
auf Port 30001, gebunden an Loopback und die Host-Adressen (rootless pasta
reicht die Host-Loopback nicht an Container durch - Begruendung in
`docs/runtime.md`). Die auswaertige `luni-vllm-pub.service` ist retired.

```bash
podman ps --filter name=flash-next-v3 --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:30000/health          # 200
./scripts/73-setup-vllm-forwarder.sh --check                                     # OK: Runtime-Weiterleiter laeuft
ss -tln | grep 30001                                                             # LISTEN 127.0.0.1, 192.168.0.198, ...
```

### Gateway und Datenbank

`litellm` (Bild `docker.litellm.ai/berriai/litellm:v1.105.0`, nur
`127.0.0.1:4000`, startet nach `litellm-postgres`) antwortet keylos auf die
Liveliness. Der Modellkatalog in `config/litellm.yaml` fuehrt 13 Modelle:
Profile `direct-*`, `standard-*`, `local-*`, dazu `qwen3.8-flash-next`,
`bonsai-2-27b` und zwei Siemens-Modelle. `gpt-6-luna` ist ausgelassen, weil
`~/.config/llm-infra/chatgpt-tokens/auth.json` nur den Geraeteanfrage-
Zeitstempel traegt, kein Token (Einordnung in `docs/operations.md`).

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/health/liveliness   # 200
grep -c 'model_name:' config/litellm.yaml                                           # 13
python3 -c "import json;d=json.load(open('$HOME/.config/llm-infra/chatgpt-tokens/auth.json'));print(sorted(d))"
```

### Oeffentlicher Zugang (443 am Azure-Gateway)

Tunnel-Unit aktiv und aktiviert; die vier oeffentlichen Routen liefern die
erwarteten Codes, per DNS-Name und uber die Roh-IP identisch (Einzelheiten:
`docs/gateway-proxy.md`). Basic-Auth-Personen: 5
(`owner, thomas, martin, johannes, holger`). Die retired Unit liegt als
`~/.config/systemd/user/reverse-tunnel.service.retired-20261116`.

```bash
systemctl --user is-active llm-reverse-tunnel.service               # active
systemctl --user is-enabled llm-reverse-tunnel.service              # enabled
cut -d' ' -f1 ~/.config/llm-infra/gateway-proxy/team-users.txt      # 5 Namen
for p in /health/liveliness /v1/models / /grafana/; do
  printf '%-22s %s\n' "$p" "$(curl -sk -o /dev/null -w '%{http_code}' \
    --resolve edipoc-gateway.westeurope.cloudapp.azure.com:443:20.73.54.102 \
    https://edipoc-gateway.westeurope.cloudapp.azure.com$p)"
done                                                                        # 200 401 401 401
```

### Beobachtungsstapel

Prometheus, Grafana, Loki, Alloy, Alertmanager, Dozzle, node- und
GPU-Exporter laufen. Alertmanager `/-/ready` liefert 200 und haelt drei
aktive Alarme bereit (2x `PCIeAnbindungReduziert`, `SwapAktiv`) - der Weg
Prometheus -> Alertmanager ist damit belegt, ein Versandkanal ist bewusst
noch nicht gewaehlt. Alloy sammelt die Quadlet-Container ueber die
Docker-API und `flash-next-v3` ueber das Journal.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9093/-/ready       # 200
curl -s http://127.0.0.1:9093/api/v2/alerts | python3 -c 'import json,sys;print(len(json.load(sys.stdin)),"aktive Alarme")'
curl -s 'http://127.0.0.1:9090/api/v1/targets' | python3 -c '
import json,sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    print("%-14s %s" % (t["labels"]["job"], t["health"]))'
```

Erwartetes Bild: alle acht Jobs up - `alertmanager, alloy, gpu, grafana,
loki, node, prometheus, vllm`. Der Job `grafana` braucht `metrics_path:
/grafana/metrics`, weil Grafana im Unterpfad laeuft (`docs/monitoring.md`).

### Dashboards

Fuenf provisionierte Dashboards, zusammen 121 Panel-Abfragen. Die
Browser-Pruefung am 2026-11-16 (Playwright, Chromium headless, 1680x1000,
eingeloggt als admin): 89 Panelfelder, davon 8 ohne Daten - ausschliesslich
ZFS/ARC-Panels aus `04-speicher.json` (dieser Rechner hat kein ZFS), alle
anderen gefuellen. Kein `sglang`-
Verweis mehr in Regeln und Dashboards, Loki-Panels haengen an der
provisionierten Loki-Datenquelle.

```bash
grep -o '"expr"' config/monitoring/grafana/provisioning/dashboards/0*.json | wc -l   # 121
grep -c sglang config/monitoring/grafana/provisioning/dashboards/0*.json             # alles 0
podman exec systemd-prometheus promtool check rules /etc/prometheus/alerts.yml   # SUCCESS: 24 rules
./scripts/validate.sh                                                            # rc=0
```

Aktueller Befund dabei: `./scripts/validate.sh` meldet drei Panels ohne
Anfrage in `05-agent-observatorium.json` ("Auslastung je Geraet",
"VRAM-Bedarf je Geraet", "VRAM-Fuellstand"); in HEAD hatten sie noch je eine
Anfrage, die Umstellung hat sie geleert. Nachzuziehen ist sie in einer
Code-Runde (siehe `docs/HANDOFF.md`, offene Punkte).

### Wiki und Timer

`~/work/hermes-wiki` ist geklont, der `site/`-Build entsteht durch
`scripts/wiki-rebuild.sh` (venv mit mkdocs-material). Der Rebuild-Timer laeuft
alle 30 Minuten und hat nichts zu tun, wenn kein neuer Commit anliegt
(`site/.built-sha` gleicht HEAD). Der Kennzahlentimer laeuft wie vorgesehen;
Runtime-, Gateway-, Crashguard- und GitOps-Timer sind auf diesem Rechner
bewusst (noch) nicht installiert.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3003/    # 200
git -C ~/work/hermes-wiki rev-parse HEAD | head -c 12; echo; cat ~/work/hermes-wiki/site/.built-sha
systemctl --user list-timers --no-pager | head -5
```

## Bekannte Abweichungen (bewusst, dokumentiert)

- Der Weiterleiter bindet Port 30001 an die Host-Adressen, also auch ins LAN.
  Begruendung und Verengung auf eine Adresse: `docs/runtime.md`.
- `make drift` ist auf diesem Rechner nicht gruen, und zwar grundlegend: die
  committete `quadlet/pennyroyal.container` ist seit laengerem Handarbeit, nicht
  Generator-Ausgabe. Der Generator schreibt eine andere Unit (Bild
  `ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3` mit Digest, anderes
  `Description`, ohne die beiden `Ulimit`-Zeilen, Modellpfad `/srv/llm-models`
  statt `/home/z000g9hu/models`), committet ist die Fassung des Referenzrechners
  (`localhost/flash-next-sm120:serving`, memlock/nofile-Deckel, eigene
  Start-Gate-Zeile). Keines der beiden Bilder laeuft hier - die Laufzeit ist der
  unmanaged Container `flash-next-v3`. Welche Fassung die Referenz ist, muss der
  Betreiber entscheiden; danach Generator oder committete Datei angleichen. Nichts
  davon ungeprueft anwenden: `apply-runtime-unit.sh` wuerde das Referenzbild tauschen.
- `gpt-6-luna` ist ohne echtes Geraet-Token aus dem Katalog gestrichen;
  Reaktivierung in `docs/operations.md`.
- 8 Panels in `04-speicher.json` (ZFS und ARC) zeigen "keine Daten", weil dieser
  Rechner nichts davon hat; auf dem ZFS-Referenzrechner fuellen sie sich.
- Browser-Pruefung am 2026-11-16 mit Playwright (Chromium headless, 1680x1000):
  89 Panelfelder in fuenf Dashboards, 8 ohne Daten (ZFS/ARC), sonst keine
  "No data"-Felder; Dozzle zeigt alle sieben erwarteten Container; das Portal
  meldet keine fehlerhaften Widgets. Screenshots: `/tmp/qa/screens/`.
- Die Arbeiten des Tages 2026-11-16 sind in mehreren Themen-Commits gesichert
  (`git log --oneline -8`, `./scripts/session-checkpoint.sh --status`);
  offene Punkte stehen in `docs/HANDOFF.md`.

## Betriebsregeln

- Keine ZFS-Pools erstellen, zerstoeren oder umstrukturieren.
- Dauerhafte Aenderungen nur ueber dieses Repository.
- Geheimnisse bleiben ausserhalb von Git.
- Die Grafikkarte bleibt exklusiv beim Modell (ADR 0013).

## Naechste Befehle

```bash
cd /srv/work/llm-infra-setup
./scripts/doctor.sh                        # gefuehrte Diagnose, nennt den naechsten Befehl
./scripts/70-setup-gateway-proxy.sh --check  # oeffentlicher Zugang in Ordnung?
./scripts/60-install-monitoring.sh --check   # Beobachtungsstufe vollstaendig?
./scripts/session-checkpoint.sh --status     # was ist noch ungesichert?
```
