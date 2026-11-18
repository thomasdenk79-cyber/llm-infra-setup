#!/usr/bin/env python3
"""KI-Incident-Agent (Demo) fuer den LLM-Stack.

Empfaengt Alertmanager-Webhooks, oeffnet Tickets in einer SQLite-Datenbank
(das "Problemtool" dieser Demo - Zugriff per SQL), sammelt Beweise aus Loki
und Prometheus, laesst ein Modell ueber das eigene LiteLLM-Gateway den Vorfall
analysieren und aktualisiert die Kunden-Statusdatei, die der Kennzahlensammler
(llm_customer_status_*) nach aussen trägt.

Externe Quellen (Splunk, Oracle/Postgres-Instanzen, OpenShift, Nagios, echtes
Ticketsystem per MCP) sind Adapter in config/monitoring/incident-agent-adapters.json
und standardmaessig deaktiviert - die Demo laeuft mit dem, was dieser Stack selbst
misst, und ist damit direkt auf andere Umgebungen uebertragbar.

Nur Standardbibliothek; laeuft im Container python:3.12-alpine.

    POST /webhook   Alertmanager-Format (firing/resolved)
    POST /replay    Demo: ein selbst gebauter Alarm, ohne auf echte zu warten
    GET  /health    Liveness
    GET  /metrics   Prometheus-Textformat
    GET  /tickets   letzte Tickets als JSON
"""
import json
import os
import re
import sqlite3
import subprocess
import threading
import time
import urllib.request
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("AGENT_PORT", "9104"))
LOKI_URL = os.environ.get("LOKI_URL", "http://loki:3100")
PROM_URL = os.environ.get("PROM_URL", "http://prometheus:9090")
GATEWAY_URL = os.environ.get("GATEWAY_URL", "http://litellm:4000")
GATEWAY_KEY = os.environ.get("GATEWAY_KEY", "")
AGENT_MODEL = os.environ.get("AGENT_MODEL", "qwen3.8-flash-next")
STATE_DIR = os.environ.get("STATE_DIR", "/var/lib/incident-agent")
ADAPTERS_FILE = os.environ.get("ADAPTERS", "/etc/incident-agent/adapters.json")
REPO_DIR = os.environ.get("REPO_DIR", "")

DB = os.path.join(STATE_DIR, "tickets.db")
STATUS_DATEI = os.path.join(STATE_DIR, "customer-status.json")
LOCK = threading.Lock()
COUNTERS = {"webhooks": 0, "llm_calls": 0, "llm_errors": 0, "loki_push_errors": 0}

# Erfahrungswerte fuer die Ausfallschaetzung, wenn keine Messung vorliegt
# (Sekunden). decken den ueblichen Rollout dieses Stapels ab.
DEFAULT_ETA = {
    "runtime": 900, "litellm": 60, "litellm-postgres": 45, "open-webui": 60,
    "llm-proxy": 30, "grafana": 30, "prometheus": 30, "loki": 45, "alloy": 30,
    "alertmanager": 30, "dozzle": 20, "homepage": 20, "wiki": 20,
    "llm-node-exporter": 20, "llm-gpu-exporter": 20, "vllm-forwarder": 15,
    "reverse-tunnel": 60,
}
# Dienste, deren Ausfall die Kunden ("Siemens EDI") wirklich trifft.
KUNDEN_DIENSTE = {
    "runtime", "litellm", "litellm-postgres", "open-webui", "llm-proxy",
    "vllm-forwarder", "reverse-tunnel",
}


def log(*a):
    print(time.strftime("[%Y-%m-%dT%H:%M:%S%z]"), *a, flush=True)


# ---------------------------------------------------------------- Datenhaltung
def db():
    verbindung = sqlite3.connect(DB, timeout=10)
    verbindung.row_factory = sqlite3.Row
    return verbindung


def db_init():
    os.makedirs(STATE_DIR, exist_ok=True)
    with db() as v:
        v.execute("""CREATE TABLE IF NOT EXISTS tickets(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            schluessel TEXT NOT NULL, alertname TEXT NOT NULL, service TEXT,
            schwergrad TEXT, zustand TEXT NOT NULL DEFAULT 'offen',
            erstellt TEXT, geloest TEXT, zusammenfassung TEXT,
            analyse TEXT, ursache TEXT, vertrauen REAL, eta_minuten INTEGER,
            massnahmen TEXT, beweise TEXT, aktualisiert TEXT)""")
        v.execute("CREATE INDEX IF NOT EXISTS ix_tickets_schluessel ON tickets(schluessel, zustand)")


def offenes_ticket(schluessel):
    with db() as v:
        return v.execute(
            "SELECT * FROM tickets WHERE schluessel=? AND zustand IN ('offen','analysiert','in-bearbeitung') "
            "ORDER BY id DESC LIMIT 1", (schluessel,)).fetchone()


# ------------------------------------------------------------- Kunden-Statusdatei
def status_lesen():
    try:
        with open(STATUS_DATEI, encoding="utf-8") as datei:
            return json.load(datei)
    except Exception:
        return {"services": {}, "open": 0, "severity": "none", "updated": 0}


def status_schreiben(status):
    status["updated"] = int(time.time())
    tmp = STATUS_DATEI + ".tmp"
    with open(tmp, "w", encoding="utf-8") as datei:
        json.dump(status, datei, ensure_ascii=False)
    os.replace(tmp, STATUS_DATEI)


def status_neu_berechnen():
    """Aggregiert alle offenen Tickets in die Kunden-Statusdatei."""
    with db() as v:
        offen = v.execute(
            "SELECT * FROM tickets WHERE zustand IN ('offen','analysiert','in-bearbeitung') "
            "ORDER BY id DESC").fetchall()
    services = {}
    offene = [r for r in offen if (r["service"] or "") in KUNDEN_DIENSTE]
    if offene:
        schwer = "critical" if any(r["schwergrad"] == "critical" for r in offene) else "warning"
        for r in offene:
            eintrag = services.get("siemens-edi-oftp") or {
                "state": "investigating",
                "message": "Stoerung erkannt und in Bearbeitung: " + (r["zusammenfassung"] or r["alertname"]),
                "eta": "Analyse laeuft",
            }
            if r["zustand"] == "analysiert" and r["analyse"]:
                try:
                    ki = json.loads(r["analyse"])
                    eintrag = {
                        "state": ki.get("customer_state") or "degraded",
                        "message": ki.get("customer_message") or eintrag["message"],
                        "eta": ki.get("customer_eta") or "unbekannt",
                    }
                    if (ki.get("confidence") or 0) < 0.4:
                        eintrag["eta"] = "unklar - haengt von Abhaengigkeiten ab"
                        eintrag["state"] = "investigating"
                except Exception:
                    pass
            services["siemens-edi-oftp"] = eintrag
        zustand = {"open": len(offene), "severity": schwer}
    else:
        zustand = {"open": 0, "severity": "none"}
    status = status_lesen()
    status["services"] = services
    status["open"] = zustand["open"]
    status["severity"] = zustand["severity"]
    #ETA je Dienst fuer den Kennzahlensammler (llm_service_downtime_estimate_seconds).
    eta_pro_dienst = {}
    for r in offene:
        versuch = None
        try:
            versuch = json.loads(r["analyse"] or "{}").get("eta_minutes")
        except Exception:
            versuch = None
        eta_pro_dienst[r["service"]] = int(versuch or (DEFAULT_ETA.get(r["service"], 60) // 60 or 1)) * 60
    status["eta_seconds_by_service"] = eta_pro_dienst
    status_neuest_gruen = status.get("services", {}) == {} and zustand["open"] == 0
    if status_neuest_gruen and status.get("letzter_zustand") != "ok":
        status["services"] = {"siemens-edi-oftp": {
            "state": "ok",
            "message": status.get("behebungshinweis") or "Alle Systeme betriebsbereit",
            "eta": "-",
        }}
        status["behebungshinweis"] = "Stoerung behoben - alle Kernsysteme betriebsbereit"
        status["letzter_zustand"] = "ok"
    elif status_neuest_gruen:
        status["services"] = {"siemens-edi-oftp": {
            "state": "ok", "message": "Alle Systeme betriebsbereit", "eta": "-"}}
        status["letzter_zustand"] = "ok"
    else:
        status["letzter_zustand"] = "stoerung"
    status_schreiben(status)


# ------------------------------------------------------------------- Loki/Prometheus
def http_json(url, payload=None, timeout=15, headers=None):
    koepfe = {"Content-Type": "application/json"}
    if headers:
        koepfe.update(headers)
    daten = json.dumps(payload).encode() if payload is not None else None
    anfrage = urllib.request.Request(url, data=daten, headers=koepfe)
    with urllib.request.urlopen(anfrage, timeout=timeout) as antwort:
        return json.loads(antwort.read().decode())


def loki_beweise(service):
    """Letzte Logzeilen des betroffenen Containers (15-Minuten-Fenster)."""
    selector = '{stack="llm-infra", container=~".*%s.*"}' % re.escape(service or "")
    if not service:
        selector = '{stack="llm-infra"}'
    try:
        antwort = http_json(LOKI_URL + "/loki/api/v1/query_range?" + urllib.parse.urlencode({
            "query": selector, "limit": 60, "since": "15m", "direction": "backward"}))
        zeilen = []
        for strom in antwort.get("data", {}).get("result", []):
            for _, text in strom.get("values", [])[:30]:
                zeilen.append(text.strip()[:300])
        return zeilen[:60]
    except Exception as fehler:
        return ["(Loki nicht erreichbar: %s)" % fehler]


def prom_beweise(service):
    """Aktive Alarme + up-Verlauf als Kontext."""
    treffer = []
    try:
        antwort = http_json(PROM_URL + "/api/v1/query?" + urllib.parse.urlencode(
            {"query": 'ALERTS{alertstate="firing"}'}))
        for eintrag in antwort.get("data", {}).get("result", []):
            treffer.append("firing: %s (%s)" % (
                eintrag["metric"].get("alertname"), eintrag["metric"].get("name", "-")))
    except Exception as fehler:
        treffer.append("(Prometheus nicht erreichbar: %s)" % fehler)
    try:
        antwort = http_json(PROM_URL + "/api/v1/query?" + urllib.parse.urlencode(
            {"query": 'avg_over_time(llm_service_up{name="%s"}[10m])' % re.escape(service or "")}))
        for eintrag in antwort.get("data", {}).get("result", []):
            treffer.append("Mittelverfuegbarkeit 10 min: %s" % eintrag["value"][1])
    except Exception:
        pass
    return treffer


def historien_beweise(service):
    """Fruehere Tickets desselben Musters - der 'Problemtool'-Anteil der Demo."""
    try:
        with db() as v:
            zeilen = v.execute(
                "SELECT alertname, ursache, eta_minuten, erstellt FROM tickets "
                "WHERE service=? AND zustand='geschlossen' ORDER BY id DESC LIMIT 3",
                (service,)).fetchall()
        return [dict(z) for z in zeilen]
    except Exception:
        return []


def adapter_beweise():
    """Externe Quellen als dokumentierte, bewusst abgeschaltete Adapter."""
    try:
        with open(ADAPTERS_FILE, encoding="utf-8") as datei:
            adapter = json.load(datei)
        return [{"name": a.get("name"), "typ": a.get("typ"), "aktiv": bool(a.get("aktiv"))}
                for a in adapter.get("adapter", [])]
    except Exception:
        return []


def git_beweise():
    """Letzte Aenderungen am Stack (belegt Kausalitaet 'git pull -> Ausfall')."""
    if not REPO_DIR:
        return []
    try:
        ausgabe = subprocess.run(
            ["git", "-C", REPO_DIR, "log", "--oneline", "-5", "--date=iso",
             "--pretty=%h %ad %s"],
            capture_output=True, text=True, timeout=10)
        if ausgabe.returncode == 0:
            return [z for z in ausgabe.stdout.splitlines() if z.strip()]
    except Exception:
        pass
    return []


def loki_push(text, label):
    now_ns = int(time.time() * 1e9)
    payload = {"streams": [{"stream": {"job": "incident", "stack": "llm-infra", **label},
                            "values": [[str(now_ns), text]]}]}
    try:
        http_json(LOKI_URL + "/loki/api/v1/push", payload, timeout=10)
    except Exception as fehler:
        COUNTERS["loki_push_errors"] += 1
        log("loki-push fehlgeschlagen:", fehler)


# ------------------------------------------------------------------- KI-Analyse
PROMPT_SYSTEM = (
    "Du bist ein Nuechterner SRE-Assistent fuer Vorfallanalysen in einem "
    "lokalen LLM-Stack (Podman, Prometheus, Loki, LiteLLM). Antworte AUSSCHLIESSLICH "
    "mit einem JSON-Objekt der Form: {\"root_cause\": \"<max 2 Saetze>\", "
    "\"confidence\": <0..1>, \"eta_minutes\": <Zahl oder null>, "
    "\"customer_state\": \"ok|degraded|down|investigating\", "
    "\"customer_message\": \"<Kundenmeldung, 1 kurzer Satz, deutsch>\", "
    "\"customer_eta\": \"<z.B. ca. 30 min|unklar - haengt von Abhaengigkeiten ab>\", "
    "\"actions\": [\"<massnahme>\", ...]}."
)


def ki_analyse(alert, beweise):
    COUNTERS["llm_calls"] += 1
    prompt = "Alarm: %s\nDienst: %s\nSchwergrad: %s\nBeweislage:\n%s" % (
        alert.get("labels", {}).get("alertname"),
        alert.get("labels", {}).get("name") or alert.get("labels", {}).get("service") or "unbekannt",
        alert.get("labels", {}).get("severity"),
        json.dumps(beweise, ensure_ascii=False)[:6000])
    try:
        antwort = http_json(
            GATEWAY_URL.rstrip("/") + "/v1/chat/completions",
            {"model": AGENT_MODEL,
             "messages": [{"role": "system", "content": PROMPT_SYSTEM},
                          {"role": "user", "content": prompt}],
             "max_tokens": 700, "temperature": 0.2},
            timeout=90, headers={"Authorization": "Bearer " + GATEWAY_KEY})
        text = antwort["choices"][0]["message"]["content"]
        treffer = re.search(r"\{.*\}", text, re.S)
        if not treffer:
            raise ValueError("kein JSON im Modelltext")
        return json.loads(treffer.group(0))
    except Exception as fehler:
        COUNTERS["llm_errors"] += 1
        log("KI-Analyse fehlgeschlagen:", fehler)
        return None


# ------------------------------------------------------------------- Vorfallsflug
def vorfall_bearbeiten(alert):
    labels = alert.get("labels", {})
    service = labels.get("name") or labels.get("service") or "unbekannt"
    alertname = labels.get("alertname", "ohne-Namen")
    schwer = labels.get("severity", "warning")
    schluessel = "%s|%s" % (alertname, service)
    zusammenfassung = (alert.get("annotations", {}).get("summary") or alertname)[:280]

    if alert.get("status") == "resolved":
        ticket = offenes_ticket(schluessel)
        if ticket:
            with db() as v:
                v.execute("UPDATE tickets SET zustand='geschlossen', geloest=?, aktualisiert=? "
                          "WHERE id=?",
                          (time.strftime("%Y-%m-%dT%H:%M:%S"), time.strftime("%Y-%m-%dT%H:%M:%S"),
                           ticket["id"]))
            loki_push("Vorfall geschlossen: %s (%s) - Alarm resolved" % (alertname, service),
                      {"service": service, "alertname": alertname, "severity": schwer,
                       "phase": "resolved"})
            # Beim letzten geschlossenen Ticket einen erkennbaren "behoben"-Hinweis
            # hinterlassen, den die naechste Aggregation einmalig zeigt.
            s = status_lesen()
            s["behebungshinweis"] = "Stoerung behoben - alle Kernsysteme betriebsbereit"
            status_schreiben(s)
        status_neu_berechnen()
        return

    ticket = offenes_ticket(schluessel)
    if ticket:
        return  # bereits in Arbeit (Alertmanager wiederholt)

    with db() as v:
        cur = v.execute(
            "INSERT INTO tickets(schluessel,alertname,service,schwergrad,zustand,erstellt,"
            "zusammenfassung,aktualisiert) VALUES (?,?,?,?,?,?,?,?)",
            (schluessel, alertname, service, schwer, "offen",
             time.strftime("%Y-%m-%dT%H:%M:%S"), zusammenfassung,
             time.strftime("%Y-%m-%dT%H:%M:%S")))
        ticket_id = cur.lastrowid
    loki_push("Vorfall erkannt und Ticket #%d angelegt: %s - %s" % (ticket_id, alertname, zusammenfassung),
              {"service": service, "alertname": alertname, "severity": schwer, "phase": "detected"})
    status_neu_berechnen()

    beweise = {"logs": loki_beweise(service), "metriken": prom_beweise(service),
               "historie": historien_beweise(service), "git": git_beweise(),
               "externe_quellen": adapter_beweise()}
    loki_push("Beweise gesammelt fuer Ticket #%d (%d Logzeilen, %d Metrikhinweise)" % (
        ticket_id, len(beweise.get("logs", [])), len(beweise.get("metriken", []))),
        {"service": service, "alertname": alertname, "severity": schwer, "phase": "analyzing"})

    ki = ki_analyse(alert, beweise)
    eta = ki.get("eta_minutes") if ki else None
    if eta is None:
        eta = DEFAULT_ETA.get(service, 60) // 60 or 1
    ursache = (ki or {}).get("root_cause") or "KI nicht erreichbar - Heuristik: Neustart/Check des Dienstes"
    with db() as v:
        v.execute("UPDATE tickets SET zustand='analysiert', analyse=?, ursache=?, vertrauen=?, "
                  "eta_minuten=?, massnahmen=?, beweise=?, aktualisiert=? WHERE id=?",
                  (json.dumps(ki, ensure_ascii=False), ursache,
                   (ki or {}).get("confidence"), eta,
                   json.dumps((ki or {}).get("actions", []), ensure_ascii=False),
                   json.dumps(beweise, ensure_ascii=False)[:20000],
                   time.strftime("%Y-%m-%dT%H:%M:%S"), ticket_id))
    text = "Ticket #%d analysiert: %s | ETA ca. %s min | Vertrauen %s" % (
        ticket_id, ursache[:200], eta, (ki or {}).get("confidence", "n/a"))
    loki_push(text, {"service": service, "alertname": alertname, "severity": schwer,
                     "phase": "update"})
    if ki and ki.get("customer_message"):
        status_neu_berechnen()


def warteschlange():
    """Ein Worker: die Demo soll synchron nacheinander analysieren, nicht rasen."""
    while True:
        alert = WARTEN.get()
        try:
            vorfall_bearbeiten(alert)
        except Exception as fehler:  # ein kaputter Alarm darf den Agenten nicht toeten
            log("Vorfallsbearbeitung fehlgeschlagen:", fehler)
        finally:
            WARTEN.task_done()


import queue  # noqa: E402  (nach DEM Worker-Objekt definiert, halten wir den Kopf kurz)
WARTEN = queue.Queue()


class Handler(BaseHTTPRequestHandler):
    def _antwort(self, code, text, typ="application/json"):
        koerper = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", typ)
        self.send_header("Content-Length", str(len(koerper)))
        self.end_headers()
        self.wfile.write(koerper)

    def do_GET(self):  # noqa: N802
        if self.path.startswith("/health"):
            self._antwort(200, json.dumps({"status": "ok", "modell": AGENT_MODEL}))
        elif self.path.startswith("/metrics"):
            with db() as v:
                offen = v.execute(
                    "SELECT COUNT(*) AS n FROM tickets WHERE zustand IN "
                    "('offen','analysiert','in-bearbeitung')").fetchone()["n"]
            zeilen = [
                "# HELP incident_agent_up Agent lebt",
                "# TYPE incident_agent_up gauge",
                "incident_agent_up 1",
                "# HELP incident_agent_open_tickets Offene Tickets",
                "# TYPE incident_agent_open_tickets gauge",
                "incident_agent_open_tickets %d" % offen,
            ] + ['incident_agent_%s_total %d' % (k, v) for k, v in sorted(COUNTERS.items())]
            self._antwort(200, "\n".join(zeilen) + "\n", "text/plain")
        elif self.path.startswith("/tickets"):
            with db() as v:
                zeilen = [dict(r) for r in v.execute(
                    "SELECT * FROM tickets ORDER BY id DESC LIMIT 50").fetchall()]
            self._antwort(200, json.dumps(zeilen, ensure_ascii=False))
        else:
            self._antwort(404, '{"error":"unbekannter pfad"}')

    def do_POST(self):  # noqa: N802
        laenge = int(self.headers.get("Content-Length") or 0)
        try:
            koerper = json.loads(self.rfile.read(laenge) or b"{}")
        except Exception:
            self._antwort(400, '{"error":"kein JSON"}')
            return
        if self.path.startswith("/webhook"):
            COUNTERS["webhooks"] += 1
            for alert in koerper.get("alerts", []):
                WARTEN.put(alert)
            self._antwort(202, '{"status":"eingeordnet"}')
        elif self.path.startswith("/replay"):
            alert = koerper.get("alert") or {
                "status": "firing",
                "labels": {"alertname": "DemoAusfall", "name": koerper.get("service", "litellm"),
                           "severity": koerper.get("severity", "critical")},
                "annotations": {"summary": koerper.get(
                    "summary", "Gateway antwortet nicht auf /health/liveliness")}}
            WARTEN.put(alert)
            self._antwort(202, '{"status":"demo-alarm eingeordnet"}')
        else:
            self._antwort(404, '{"error":"unbekannter pfad"}')

    def log_message(self, *args):
        pass  # Zugriffszeilen bleiben im Journal des Containers rauschen-arm


def main():
    db_init()
    status_neu_berechnen()
    threading.Thread(target=warteschlange, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log("Incident-Agent laeuft auf :%d (Modell %s)" % (PORT, AGENT_MODEL))
    server.serve_forever()


if __name__ == "__main__":
    main()
