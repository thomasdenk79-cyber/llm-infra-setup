#!/usr/bin/env python3
"""KI-Incident-Agent (Demo) fuer den LUNI-LLM-Stack.

Empfaengt Alertmanager-Webhooks, fuehrt Tickets in einer SQLite-Datenbank
(das "Problemtool" dieser Demo - Zugriff per SQL), sammelt Beweise aus Loki,
Prometheus und der Git-Aenderungsspur, laesst ein Modell ueber das eigene
Gateway eine Hypothese bilden und liefert Kunden-, Hotline- und
Betriebsstatusdatei fuer die Grafana-Seiten.

Grundregeln dieser Fassung (Auftrag 2026-11-18):
* Keine erfundene Reparaturzeit. Zustand der Einschaetzung ist immer
  "unbekannt", "grobe-schaetzung" (aus dokumentiertem Erfahrungswert/
  Spielplan), "einengend" (nachgemessen) oder "geplant" (Menschenentscheid).
  Ein KI-Vorschlag ist nie die Anzeige-ETA, sondern nur der Vorschlag.
* Eine KI-Zuordnung ist eine Hypothese mit Zuversichtsstufe, nie "Ursache".
  BESTAETIGT gilt nur fuer gemessene Tatsachen (z. B. "Unit failed").
* Getrennte Zeiten: Wiederherstellung (evtl. unbekannt) und
  naechste Kommunikation (fixe Meldefrist, 30 Minuten).

Nur Standardbibliothek; laeuft im Container python:3.12-alpine.

    POST /webhook   Alertmanager-Format (firing/resolved)
    POST /replay    Demo: Beispielalarm einspielen
    POST /approve   Problemrecord freigeben/ablehnen (Token noetig)
    GET  /health    Liveness
    GET  /metrics   Prometheus-Textformat
    GET  /tickets   letzte Tickets als JSON
    GET  /timeline  Zeitachse eines Tickets
"""
import json
import os
import queue
import re
import sqlite3
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("AGENT_PORT", "9104"))
LOKI_URL = os.environ.get("LOKI_URL", "http://loki:3100")
PROM_URL = os.environ.get("PROM_URL", "http://prometheus:9090")
GATEWAY_URL = os.environ.get("GATEWAY_URL", "http://litellm:4000")
GATEWAY_KEY = os.environ.get("GATEWAY_KEY", "")
AGENT_MODEL = os.environ.get("AGENT_MODEL", "qwen3.8-flash-next")
STATE_DIR = os.environ.get("STATE_DIR", "/var/lib/incident-agent")
ADAPTERS_FILE = os.environ.get("ADAPTERS", "/etc/incident-agent/adapters.json")
APPROVE_TOKEN = os.environ.get("APPROVE_TOKEN", "")
MELDEFRIST = int(os.environ.get("MELDEFRIST", "1800"))          # 30 min
BEOBACHTUNGSFENSTER = int(os.environ.get("BEOBACHTUNG", "600"))  # 10 min

DB = os.path.join(STATE_DIR, "tickets.db")
STATUS_DATEI = os.path.join(STATE_DIR, "customer-status.json")
AENDERUNGEN_DATEI = os.path.join(STATE_DIR, "recent-changes.json")
LOCK = threading.Lock()
WARTEN = queue.Queue()
COUNTERS = {"webhooks": 0, "llm_calls": 0, "llm_errors": 0, "loki_push_errors": 0}

# Dienst -> (Kundenservice, Spielplan-Aktion, Erfahrungswert min von-bis oder None)
SPIELPLAN = {
    "runtime": ("llm-inferenz", "Unit der Laufzeit neu starten (apply-runtime-unit.sh)", (12, 18)),
    "litellm": ("llm-api", "Gateway-Unit neu starten", (1, 2)),
    "litellm-postgres": ("llm-api", "Datenbank-Unit neu starten", (1, 2)),
    "open-webui": ("chat-oberflaeche", "Chat-Unit neu starten", (1, 2)),
    "llm-proxy": ("llm-api", "LAN-Proxy neu starten", (1, 1)),
    "vllm-forwarder": ("llm-api", "Weiterleiter-Unit neu starten", (1, 1)),
    "reverse-tunnel": ("llm-api", "Wartungstunnel pruefen", (2, 5)),
}
KUNDEN_LABEL = {"llm-inferenz": "Inferenz", "llm-api": "LLM API",
                "chat-oberflaeche": "Chat-Oberflaeche"}
PHASEN = ("detected", "acknowledged", "investigating", "cause-identified",
          "mitigating", "monitoring", "resolved")
ZUVERSICHT = ("BESTAETIGT (Messung)", "HIGH CONFIDENCE", "PROBABLE", "POSSIBLE",
              "INSUFFICIENT EVIDENCE")


def log(*a):
    print(time.strftime("[%Y-%m-%dT%H:%M:%S%z]"), *a, flush=True)


def zeit():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


# ---------------------------------------------------------------- Datenhaltung
def db():
    verbindung = sqlite3.connect(DB, timeout=10)
    verbindung.row_factory = sqlite3.Row
    return verbindung


def db_init():
    os.makedirs(STATE_DIR, exist_ok=True)
    with db() as v:
        if (v.execute("PRAGMA user_version").fetchone()[0] or 0) < 2:
            v.execute("DROP TABLE IF EXISTS tickets")
            v.execute("DROP TABLE IF EXISTS ereignisse")
            v.execute("PRAGMA user_version=2")
        v.execute("""CREATE TABLE IF NOT EXISTS tickets(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            schluessel TEXT NOT NULL, alertname TEXT NOT NULL, service TEXT,
            schwergrad TEXT, phase TEXT NOT NULL DEFAULT 'detected',
            kundenservice TEXT, starts TEXT, detected TEXT, geloest TEXT,
            zusammenfassung TEXT, symptome TEXT, ursache TEXT,
            zuversicht TEXT, korrelationen TEXT, aenderungen TEXT,
            evidenz TEXT, massnahme TEXT, workaround TEXT,
            eta_art TEXT DEFAULT 'unbekannt', eta_text TEXT, ki_vorschlag TEXT,
            kommunikation TEXT, kundenmeldung TEXT,
            problemrecord TEXT, freigabe TEXT DEFAULT 'freigabe-ausstehend',
            aktualisiert TEXT)""")
        v.execute("""CREATE TABLE IF NOT EXISTS ereignisse(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ticket_id INTEGER NOT NULL, ts TEXT, wer TEXT, text TEXT, quelle TEXT)""")
        v.execute("CREATE INDEX IF NOT EXISTS ix_t_key ON tickets(schluessel, phase)")
        v.execute("CREATE INDEX IF NOT EXISTS ix_e_t ON ereignisse(ticket_id)")


def ticket_lesen(ticket_id):
    with db() as v:
        return v.execute("SELECT * FROM tickets WHERE id=?", (ticket_id,)).fetchone()


def offenes_ticket(schluessel):
    with db() as v:
        return v.execute(
            "SELECT * FROM tickets WHERE schluessel=? AND phase NOT IN ('resolved','monitoring') "
            "ORDER BY id DESC LIMIT 1", (schluessel,)).fetchone()


def ereignis(ticket_id, wer, text, quelle):
    """Ein Zeitachseneintrag - jeder Punkt muss auf eine Quelle verweisen."""
    with db() as v:
        v.execute("INSERT INTO ereignisse(ticket_id,ts,wer,text,quelle) VALUES (?,?,?,?,?)",
                  (ticket_id, zeit(), wer, text, quelle))
    reihe = ticket_lesen(ticket_id)
    loki_push("ZEITACHSE | %s | #%s | %s | %s | Quelle: %s" % (
        zeit(), ticket_id, wer, text, quelle),
        {"phase": "timeline", "service": (reihe["service"] if reihe else "unbekannt")})


def feld_setzen(ticket_id, **felder):
    felder["aktualisiert"] = zeit()
    spalten = ", ".join("%s=?" % k for k in felder)
    with db() as v:
        v.execute("UPDATE tickets SET %s WHERE id=?" % spalten,
                  (*felder.values(), ticket_id))
    status_neu_berechnen()


# ------------------------------------------------- Statusdatei fuer Sammler/Panels
def status_lesen():
    try:
        with open(STATUS_DATEI, encoding="utf-8") as datei:
            return json.load(datei)
    except Exception:
        return {"services": {}, "open": 0, "severity": "none", "vorfalle": []}


def status_schreiben(status):
    status["updated"] = int(time.time())
    status["versionschema"] = 2
    tmp = STATUS_DATEI + ".tmp"
    with open(tmp, "w", encoding="utf-8") as datei:
        json.dump(status, datei, ensure_ascii=False)
    os.replace(tmp, STATUS_DATEI)


def vorfall_kurzfassung(reihe):
    return {
        "ticket": reihe["id"], "alertname": reihe["alertname"],
        "service": reihe["service"], "phase": reihe["phase"],
        "kundenservice": reihe["kundenservice"], "schwergrad": reihe["schwergrad"],
        "starts": reihe["starts"], "detected": reihe["detected"],
        "kundenmeldung": reihe["kundenmeldung"], "ursache": reihe["ursache"],
        "zuversicht": reihe["zuversicht"], "eta_art": reihe["eta_art"],
        "eta_text": reihe["eta_text"], "kommunikation": reihe["kommunikation"],
        "freigabe": reihe["freigabe"],
    }


def status_neu_berechnen():
    with db() as v:
        offen = v.execute(
            "SELECT * FROM tickets WHERE phase NOT IN ('resolved') ORDER BY id DESC").fetchall()
    vorfalle = [vorfall_kurzfassung(r) for r in offen]
    services = {}
    offen_kunde = [r for r in offen if r["kundenservice"] not in (None, "beobachtung")]
    for r in offen_kunde:
        alter = services.get(r["kundenservice"])
        if alter is None or r["phase"] not in ("monitoring",):
            services[r["kundenservice"]] = {
                "state": {"detected": "investigating", "acknowledged": "investigating",
                          "investigating": "investigating", "cause-identified": "degraded",
                          "mitigating": "degraded", "monitoring": "ok"}.get(r["phase"], "degraded"),
                "message": r["kundenmeldung"] or "Stoerung erkannt und in Bearbeitung",
                "eta": ("%s: %s" % (r["eta_art"], r["eta_text"])) if r["eta_art"] != "unbekannt"
                       else "unbekannt - naechste Meldung %s" % (r["kommunikation"] or "-"),
            }
    status = status_lesen()
    if services:
        schwer = "critical" if any(r["schwergrad"] == "critical" for r in offen_kunde) else "warning"
        status.update({"services": services, "open": len(offen_kunde), "severity": schwer,
                       "letzter_zustand": "stoerung"})
    else:
        hinweis = status.get("behebungshinweis")
        status.update({"services": {"llm-api": {
                           "state": "ok",
                           "message": hinweis or "Alle Dienste betriebsbereit",
                           "eta": "-"},
                       "llm-inferenz": {"state": "ok", "message": "Alle Dienste betriebsbereit",
                                        "eta": "-"},
                       "chat-oberflaeche": {"state": "ok", "message": "Alle Dienste betriebsbereit",
                                            "eta": "-"}}
                      if status.get("letzter_zustand") != "ok" else status.get("services") or {},
                      "open": 0, "severity": "none", "letzter_zustand": "ok"})
        if status.get("letzter_zustand") == "ok" and not status["services"]:
            status["services"] = {"llm-api": {"state": "ok",
                                              "message": "Alle Dienste betriebsbereit", "eta": "-"}}
    status["vorfalle"] = vorfalle
    status_schreiben(status)


# ------------------------------------------------------- Beweise (nur Messbares)
def http_json(url, payload=None, timeout=15, headers=None):
    koepfe = {"Content-Type": "application/json"}
    if headers:
        koepfe.update(headers)
    daten = json.dumps(payload).encode() if payload is not None else None
    anfrage = urllib.request.Request(url, data=daten, headers=koepfe)
    with urllib.request.urlopen(anfrage, timeout=timeout) as antwort:
        leer = antwort.read().decode()
        return json.loads(leer) if leer.strip() else {}


def loki_beweise(service):
    selector = '{stack="llm-infra", container=~".*%s.*"}' % re.escape(service or "")
    if not service:
        selector = '{stack="llm-infra"}'
    try:
        antwort = http_json(LOKI_URL + "/loki/api/v1/query_range?" + urllib.parse.urlencode(
            {"query": selector, "limit": 60, "since": "15m", "direction": "backward"}))
        zeilen = []
        for strom in antwort.get("data", {}).get("result", []):
            for _, text in strom.get("values", [])[:30]:
                zeilen.append(text.strip()[:280])
        return zeilen[:60]
    except Exception as fehler:
        return ["(Loki nicht erreichbar: %s)" % fehler]


def prom_beweise(service):
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
            wert = float(eintrag["value"][1])
            treffer.append("Verfuegbarkeit letzte 10 min: %.0f%%" % (100 * wert))
            if wert >= 0.999:
                treffer.append("HINWEIS: Messreihe zeigt den Dienst durchgehend up - "
                               "Alarm moeglicherweise Kunstprodukt (Demo/Probe prüfen)")
    except Exception:
        pass
    return treffer


def historien_beweise(service):
    try:
        with db() as v:
            zeilen = v.execute(
                "SELECT alertname, ursache, zuversicht, starts FROM tickets "
                "WHERE service=? AND phase='resolved' ORDER BY id DESC LIMIT 3",
                (service,)).fetchall()
        return [dict(z) for z in zeilen]
    except Exception:
        return []


def aenderungs_beweise():
    """Letzte Repo-Aenderungen, vom Sammler auf dem Host gemessen."""
    try:
        with open(AENDERUNGEN_DATEI, encoding="utf-8") as datei:
            return json.load(datei)
    except Exception:
        return []


def adapter_status():
    try:
        with open(ADAPTERS_FILE, encoding="utf-8") as datei:
            adapter = json.load(datei)
        return [{"name": a.get("name"), "typ": a.get("typ"), "aktiv": bool(a.get("aktiv"))}
                for a in adapter.get("adapter", [])]
    except Exception:
        return []


def loki_push(text, label):
    now_ns = int(time.time() * 1e9)
    payload = {"streams": [{"stream": {"job": "incident", "stack": "llm-infra",
                                       **{"service": label.get("service", "unbekannt"),
                                          "alertname": label.get("alertname", "-"),
                                          "severity": label.get("severity", "warning")},
                                       "phase": label.get("phase", "info")},
                            "values": [[str(now_ns), text]]}]}
    try:
        http_json(LOKI_URL + "/loki/api/v1/push", payload, timeout=10)
    except Exception as fehler:
        COUNTERS["loki_push_errors"] += 1
        log("loki-push fehlgeschlagen:", fehler)


# ------------------------------------------------------------------- KI-Analyse
PROMPT_SYSTEM = (
    "Du bist ein nuechterner SRE-Assistent fuer Vorfallshypothesen in einem "
    "lokalen LLM-Stack (Podman, Prometheus, Loki, LiteLLM). Regeln: Erfinde "
    "niemals Ursachen oder Reparaturzeiten; unterscheide gemessene Fakten von "
    "Vermutungen; wenn die Beweise nicht tragen, antworte mit niedriger "
    "Zuversicht. Antworte AUSSCHLIESSLICH mit einem JSON-Objekt: "
    "{\"symptome\": [..], \"hypothese\": \"<max 2 Saetze>\", \"konfidenz\": <0..1>, "
    "\"korrelationen\": [..], \"letzte_aenderungen_erkannt\": [..], "
    "\"massnahme\": \"<Empfehlung>\", \"workaround\": \"<optional>\", "
    "\"kunde_kurzmeldung\": \"<1 deutscher Satz, ruhig, ohne interne Namen>\", "
    "\"ki_eta_minuten\": <Zahl oder null>, \"kundenservice\": \"llm-api|llm-inferenz|chat-oberflaeche|beobachtung\"}."
)


def ki_analyse(reihe, beweise):
    COUNTERS["llm_calls"] += 1
    prompt = "Alarm: %s\nDienst: %s\nSchwergrad: %s\nBeweislage:\n%s" % (
        reihe["alertname"], reihe["service"], reihe["schwergrad"],
        json.dumps(beweise, ensure_ascii=False)[:6500])
    # Unter Last liefert das Denke-Model vereinzelt einen Text ohne JSON
    # (Kommentarzeilen, leeres Ergebnis). Ein Wiederholungsversuch ist
    # verbrieft erfolgreich; danach gilt "KI nicht erreichbar".
    for versuch in (1, 2):
        ergebnis = _ki_versuch(prompt, versuch)
        if ergebnis is not None:
            return ergebnis
    return None


def _ki_versuch(prompt, versuch):
    try:
        antwort = http_json(
            GATEWAY_URL.rstrip("/") + "/v1/chat/completions",
            {"model": AGENT_MODEL,
             "messages": [{"role": "system", "content": PROMPT_SYSTEM},
                          {"role": "user", "content": prompt}],
             "max_tokens": 1600, "temperature": 0.2 if versuch == 1 else 0.0},
            timeout=150, headers={"Authorization": "Bearer " + GATEWAY_KEY})
        nachricht = antwort["choices"][0]["message"]
        # Denke-Modelle liefern den Text teils nur in reasoning_content.
        text = (nachricht.get("content") or nachricht.get("reasoning_content") or "")
        treffer = re.search(r"\{.*\}", text, re.S)
        if not treffer:
            raise ValueError("kein JSON im Modelltext")
        return json.loads(treffer.group(0))
    except Exception as fehler:
        COUNTERS["llm_errors"] += 1
        log("KI-Analyse Versuch %d fehlgeschlagen:" % versuch, fehler)
        return None


def zuversicht_stufe(konfidenz):
    try:
        k = float(konfidenz)
    except (TypeError, ValueError):
        return "INSUFFICIENT EVIDENCE"
    if k >= 0.85:
        return "HIGH CONFIDENCE"
    if k >= 0.6:
        return "PROBABLE"
    if k >= 0.3:
        return "POSSIBLE"
    return "INSUFFICIENT EVIDENCE"


# ------------------------------------------------------------------- Vorfallsflug
def kunden_text(reihe):
    return reihe["kundenmeldung"] or "Stoerung erkannt und in Bearbeitung"


def vorfall_bearbeiten(alert, wer="alertmanager"):
    labels = alert.get("labels", {})
    service = labels.get("name") or labels.get("service") or "unbekannt"
    alertname = labels.get("alertname", "ohne-Namen")
    schwer = labels.get("severity", "warning")
    schluessel = "%s|%s" % (alertname, service)
    zusammenfassung = (alert.get("annotations", {}).get("summary") or alertname)[:280]

    if alert.get("status") == "resolved":
        ticket = offenes_ticket(schluessel)
        if ticket:
            feld_setzen(ticket["id"], phase="monitoring", geloest=zeit(),
                        kundenmeldung="Stoerung behoben - Dienste werden beobachtet.")
            ereignis(ticket["id"], wer, "Alarm geloest - Beobachtungsphase %s min"
                     % (BEOBACHTUNGSFENSTER // 60), "alertmanager")
        return

    if offenes_ticket(schluessel):
        return  # Alertmanager wiederholt; ein Ticket pro Vorfall

    kundenservice = SPIELPLAN.get(service, (None, None, None))[0] or "beobachtung"
    kommunikation = time.strftime("%H:%M", time.localtime(time.time() + MELDEFRIST)) + " Uhr"
    with db() as v:
        cur = v.execute(
            "INSERT INTO tickets(schluessel,alertname,service,schwergrad,phase,kundenservice,"
            "starts,detected,zusammenfassung,kundenmeldung,kommunikation,eta_art,aktualisiert) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (schluessel, alertname, service, schwer, "detected", kundenservice,
             zeit(), zeit(), zusammenfassung,
             "Stoerung erkannt und in Bearbeitung: " + zusammenfassung,
             kommunikation, "unbekannt", zeit()))
        ticket_id = cur.lastrowid
    ereignis(ticket_id, "system", "Vorfall erkannt: %s - %s" % (alertname, zusammenfassung),
             "alertmanager webhook")
    ereignis(ticket_id, "system", "Ticket angelegt, Kunde informiert (Vorlaeufigkeit: automatisch)",
             "sqlite tickets#%d" % ticket_id)
    status_neu_berechnen()

    feld_setzen(ticket_id, phase="investigating")
    ereignis(ticket_id, "agent", "Beweissammlung gestartet (Loki, Prometheus, Historie, Aenderungen)",
             "agent")
    beweise = {"logs": loki_beweise(service), "metriken": prom_beweise(service),
               "historie": historien_beweise(service),
               "letzte_aenderungen": aenderungs_beweise(),
               "externe_quellen": adapter_status()}
    ereignis(ticket_id, "agent", "Beweise: %d Logzeilen, %d Metrikhinweise, %d Aenderungen" % (
        len(beweise.get("logs", [])), len(beweise.get("metriken", [])),
        len(beweise.get("letzte_aenderungen", []))), "loki+prometheus+git")

    ki = ki_analyse(dict(ticket_lesen(ticket_id)), beweise)
    if ki is None:
        feld_setzen(ticket_id, phase="investigating", zuversicht="INSUFFICIENT EVIDENCE",
                    symptome=json.dumps(beweise.get("logs", [])[:6], ensure_ascii=False),
                    korrelationen=json.dumps(beweise.get("metriken", []), ensure_ascii=False),
                    aenderungen=json.dumps(beweise.get("letzte_aenderungen", []), ensure_ascii=False),
                    evidenz=json.dumps({"loki": LOKI_URL + "/loki", "prometheus": PROM_URL,
                                        "ticket": "tickets.db#%d" % ticket_id}, ensure_ascii=False),
                    ursache="KI nicht erreichbar - Beweise liegen vor, Deutung steht aus.")
        ereignis(ticket_id, "agent", "KI-Analyse nicht moeglich; Beweise gesichert, "
                 "Zuversicht: INSUFFICIENT EVIDENCE", "agent")
        return

    stufe = zuversicht_stufe(ki.get("konfidenz"))
    spielplan = SPIELPLAN.get(service)
    # ETA-Regel: nur dokumentierter Erfahrungswert (Spielplan) wird zur Anzeige-ETA.
    if spielplan and spielplan[2] and stufe in ("HIGH CONFIDENCE", "PROBABLE"):
        nied, hoch = spielplan[2]
        eta_art, eta_text = "grobe-schaetzung", "ca. %d-%d min (Erfahrungswert, keine Messgroesse)" % (nied, hoch)
    else:
        eta_art, eta_text = "unbekannt", None
    if ki.get("ki_eta_minuten"):
        ki_eta = "KI-Vorschlag %s min - gilt nicht als Angabe" % ki["ki_eta_minuten"]
    else:
        ki_eta = None
    ursache = (ki.get("hypothese") or "")[:600] or "keine tragfaehige Hypothese"
    if stufe == "INSUFFICIENT EVIDENCE":
        phase = "investigating"
    else:
        phase = "cause-identified"
    # Gemessener Gegentest: Messreihe sagt durchgehend up -> Hypothese drosseln.
    if any("Kunstprodukt" in z for z in beweise.get("metriken", [])):
        stufe = "POSSIBLE"
        phase = "investigating"
        ursache += " | Gegentest: Messreihe zeigt Dienst durchgehend erreichbar."
    kunde = (ki.get("kunde_kurzmeldung") or ki.get("customer_message")
             or "Stoerung erkannt und in Bearbeitung")
    kundenservice = ki.get("kundenservice") if ki.get("kundenservice") in KUNDEN_LABEL or ki.get("kundenservice") == "beobachtung" else kundenservice
    reihe_alt = ticket_lesen(ticket_id)
    feld_setzen(ticket_id, phase=phase, symptome=json.dumps(ki.get("symptome", []), ensure_ascii=False),
                ursache=ursache, zuversicht=stufe,
                korrelationen=json.dumps(ki.get("korrelationen", []), ensure_ascii=False),
                aenderungen=json.dumps(ki.get("letzte_aenderungen_erkannt", [])
                                       or beweise.get("letzte_aenderungen", []), ensure_ascii=False),
                evidenz=json.dumps({"loki_query": '{job="incident", ticket="%s"}' % ticket_id,
                                    "prometheus": PROM_URL, "ticket": "tickets.db#%d" % ticket_id},
                                   ensure_ascii=False),
                massnahme=(ki.get("massnahme") or spielplan[1] if spielplan else "") or "",
                workaround=ki.get("workaround") or "",
                eta_art=eta_art, eta_text=eta_text, ki_vorschlag=ki_eta,
                kundenservice=kundenservice,
                kundenmeldung="%s. %s" % (kunde, "Unser Betriebsteam arbeitet daran."))
    ereignis(ticket_id, "ki", "Hypothese (%s): %s%s" % (
        stufe, ursache[:180], " | %s" % ki_eta if ki_eta else ""), "gateway:%s" % AGENT_MODEL)
    if phase == "cause-identified":
        ereignis(ticket_id, "agent", "Problemrecord-Entwurf angelegt (Freigabe ausstehend)",
                 "sqlite tickets#%d.problemrecord" % ticket_id)
        problemrecord_entwurf(ticket_id)


def problemrecord_entwurf(ticket_id):
    reihe = ticket_lesen(ticket_id)
    with db() as v:
        knoten = [dict(r) for r in v.execute(
            "SELECT ts,wer,text,quelle FROM ereignisse WHERE ticket_id=? ORDER BY id", (ticket_id,))]
    entwurf = {
        "titel": "Stoerung %s: %s" % (reihe["kundenservice"] or reihe["service"],
                                       reihe["zusammenfassung"]),
        "beschreibung": reihe["zusammenfassung"],
        "ursache_hypothese": reihe["ursache"],
        "zuversicht": reihe["zuversicht"],
        "auswirkungen": reihe["kundenmeldung"],
        "beobachtungen": knoten,
        "ursuengliche_aenderungen": json.loads(reihe["aenderungen"] or "[]"),
        "empfohlene_massnahme": reihe["massnahme"],
        "workaround": reihe["workaround"],
        "wiederherstellung": ("%s: %s" % (reihe["eta_art"], reihe["eta_text"]))
                             if reihe["eta_art"] != "unbekannt" else
                             "unbekannt - ki_vorschlag: %s" % (reihe["ki_vorschlag"] or "keiner"),
        "naechste_meldung": reihe["kommunikation"],
        "herkunft": "incident-agent demo, Belege in tickets.db und Loki job=incident",
    }
    feld_setzen(ticket_id, problemrecord=json.dumps(entwurf, ensure_ascii=False),
                freigabe="freigabe-ausstehend")


# --------------------------------------------------------------- Hintergrundarbeit
def ticker():
    """Beobachtungsphase abschliessen und Meldetermine nachziehen."""
    while True:
        try:
            with db() as v:
                reihen = v.execute(
                    "SELECT * FROM tickets WHERE phase='monitoring' AND geloest IS NOT NULL").fetchall()
            for r in reihen:
                try:
                    vor = time.mktime(time.strptime(r["geloest"], "%Y-%m-%dT%H:%M:%S%z"))
                except Exception:
                    vor = 0
                if time.time() - vor >= BEOBACHTUNGSFENSTER:
                    feld_setzen(r["id"], phase="resolved",
                                kundenmeldung="Stoerung behoben - Dienste stabil.")
                    ereignis(r["id"], "agent", "Beobachtungsphase ohne Rueckfall - Vorfall abgeschlossen",
                             "agent ticker")
        except Exception as fehler:
            log("ticker:", fehler)
        time.sleep(30)


def warteschlange():
    while True:
        alert, wer = WARTEN.get()
        try:
            vorfall_bearbeiten(alert, wer)
        except Exception as fehler:
            log("Vorfallsbearbeitung fehlgeschlagen:", fehler)
        finally:
            WARTEN.task_done()


class Handler(BaseHTTPRequestHandler):
    def _antwort(self, code, text, typ="application/json"):
        koerper = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", typ)
        self.send_header("Content-Length", str(len(koerper)))
        self.end_headers()
        self.wfile.write(koerper)

    def do_GET(self):  # noqa: N802
        pfad = urllib.parse.urlparse(self.path).path
        abfragen = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if pfad.startswith("/health"):
            self._antwort(200, json.dumps({"status": "ok", "modell": AGENT_MODEL,
                                           "phasen": list(PHASEN),
                                           "zuversichtsstufen": list(ZUVERSICHT)}))
        elif pfad.startswith("/metrics"):
            with db() as v:
                offen = v.execute(
                    "SELECT COUNT(*) AS n FROM tickets WHERE phase NOT IN ('resolved')").fetchone()["n"]
            zeilen = ["# TYPE incident_agent_up gauge", "incident_agent_up 1",
                      "# TYPE incident_agent_open_tickets gauge",
                      "incident_agent_open_tickets %d" % offen]
            zeilen += ["incident_agent_%s_total %d" % (k, w) for k, w in sorted(COUNTERS.items())]
            self._antwort(200, "\n".join(zeilen) + "\n", "text/plain")
        elif pfad.startswith("/tickets"):
            with db() as v:
                reihen = [dict(r) for r in v.execute(
                    "SELECT * FROM tickets ORDER BY id DESC LIMIT 50").fetchall()]
            self._antwort(200, json.dumps(reihen, ensure_ascii=False))
        elif pfad.startswith("/timeline"):
            ticket = int((abfragen.get("ticket") or ["0"])[0])
            with db() as v:
                knoten = [dict(r) for r in v.execute(
                    "SELECT ts,wer,text,quelle FROM ereignisse WHERE ticket_id=? ORDER BY id",
                    (ticket,)).fetchall()]
            self._antwort(200, json.dumps(knoten, ensure_ascii=False))
        else:
            self._antwort(404, '{"error":"unbekannter pfad"}')

    def do_POST(self):  # noqa: N802
        laenge = int(self.headers.get("Content-Length") or 0)
        try:
            koerper = json.loads(self.rfile.read(laenge) or b"{}")
        except Exception:
            self._antwort(400, '{"error":"kein JSON"}')
            return
        pfad = urllib.parse.urlparse(self.path).path
        if pfad.startswith("/webhook"):
            COUNTERS["webhooks"] += 1
            for alert in koerper.get("alerts", []):
                WARTEN.put((alert, "alertmanager"))
            self._antwort(202, '{"status":"eingeordnet"}')
        elif pfad.startswith("/replay"):
            alert = koerper.get("alert") or {
                "status": "firing",
                "labels": {"alertname": "DemoAusfall",
                           "name": koerper.get("service", "litellm"),
                           "severity": koerper.get("severity", "critical")},
                "annotations": {"summary": koerper.get(
                    "summary", "Gateway antwortet nicht auf /health/liveliness")}}
            WARTEN.put((alert, "demo"))
            self._antwort(202, '{"status":"demo-alarm eingeordnet"}')
        elif pfad.startswith("/approve"):
            if not APPROVE_TOKEN or koerper.get("token") != APPROVE_TOKEN:
                self._antwort(403, '{"error":"token fehlt oder falsch"}')
                return
            ticket = int(koerper.get("ticket") or 0)
            entscheid = koerper.get("entscheid", "freigegeben")
            if entscheid not in ("freigegeben", "abgelehnt") or not ticket:
                self._antwort(400, '{"error":"ticket und entscheid freigegeben|abgelehnt noetig"}')
                return
            if not ticket_lesen(ticket):
                self._antwort(404, '{"error":"ticket unbekannt"}')
                return
            feld_setzen(ticket, freigabe=entscheid)
            ereignis(ticket, "mensch", "Problemrecord %s" % entscheid, "POST /approve")
            self._antwort(200, '{"status":"%s"}' % entscheid)
        else:
            self._antwort(404, '{"error":"unbekannter pfad"}')

    def log_message(self, *args):
        pass


def main():
    db_init()
    status_neu_berechnen()
    threading.Thread(target=warteschlange, daemon=True).start()
    threading.Thread(target=ticker, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log("Incident-Agent laeuft auf :%d (Modell %s, Zustandsmaschine v2)" % (PORT, AGENT_MODEL))
    server.serve_forever()


if __name__ == "__main__":
    main()
