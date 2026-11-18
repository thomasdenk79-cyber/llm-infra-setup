// Abnahme der Grafana-Dashboards: Screenshot + DOM-Pruefung je Dashboard.
// Aufruf: bun scripts/grafana-dashboard-qualitaet.mjs <uid> [uid...]
//         GRAFANA_URL (Standard http://127.0.0.1:3000) AUFLOESUNG (Standard 1680x1050)
//         ZEIT (Standard now-3h) ZUSTAND (zusaetzlicher var-Zustand, optional)
// Werkzeug ist ein Headless-Chrome per CDP (same Engine wie im Browser); ein
// leichtgewichtigerWebView lieferte hier Veraesserungen, die es nicht gab.
// Ausgaben: docs/screenshots/<uid>.png und ein JSON-Bericht pro Dashboard:
// Panelzahl, Titel, Fehler-/Leer-Meldungen, Ueberlauf, was oberhalb der
// Falzkante liegt. Bild ist das Beweismittel, der Bericht die Abnahme.
const CHROME = process.env.CHROME_PATH ??
  `${process.env.HOME}/.cache/ms-playwright/chromium-1255/chrome-linux64/chrome`;
const BASIS = (process.env.GRAFANA_URL ?? "http://127.0.0.1:3000").replace(/\/$/, "");
const ZEIT = process.env.ZEIT ?? "now-3h";
const [BREITE, HOEHE] = (process.env.AUFLOESUNG ?? "1680x1050").split("x").map(Number);
const PORT = Number(process.env.CDP_PORT ?? 9340);

async function warteAuf(fn, milliSekunden, intervall = 400) {
  const bis = Date.now() + milliSekunden;
  for (;;) {
    if (await fn()) return true;
    if (Date.now() > bis) return false;
    await new Promise(r => setTimeout(r, intervall));
  }
}

async function verbinde() {
  const prozess = Bun.spawn([CHROME, "--headless=new", "--disable-gpu", "--no-sandbox",
    `--remote-debugging-port=${PORT}`, `--user-data-dir=/tmp/grafana-qualitaet-profil`,
    "--window-size=" + BREITE + "," + HOEHE, "about:blank"],
    { stdout: "ignore", stderr: "ignore" });
  const erreichbar = await warteAuf(async () => {
    try { return (await fetch(`http://127.0.0.1:${PORT}/json/version`)).ok; } catch { return false; }
  }, 15000, 300);
  if (!erreichbar) { prozess.kill(9); throw new Error("Headless-Chrome nicht erreichbar"); }
  const ws = new WebSocket((await fetch(`http://127.0.0.1:${PORT}/json/version`)
    .then(x => x.json())).webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let zaehler = 0;
  const senden = (methode, params = {}) => new Promise((res, rej) => {
    const mein = ++zaehler;
    const hor = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== mein) return;
      ws.removeEventListener("message", hor);
      if (m.error) rej(new Error(methode + ": " + m.error.message)); else res(m.result);
    };
    ws.addEventListener("message", hor);
    ws.send(JSON.stringify({ id: mein, method: methode, params }));
  });
  return { prozess, ws, senden };
}

const abnahme = `(function(){
  var out = {titel: document.title.replace(/ - LLM Infrastructure.*| - Grafana$/g, ""), panel: []};
  document.querySelectorAll('.react-grid-item').forEach(function(el, idx){
    var t = el.querySelector('.panel-title, [class*=panel-title]');
    var rect = el.getBoundingClientRect();
    var text = (el.innerText || "");
    var zustand = "ok";
    if (/No data|Keine Daten/i.test(text)) zustand = "leer";
    if (/Failed to query|query failed|exec\\w+ protocol error|Datasource Error|parse error/i.test(text)) zustand = "fehler";
    out.panel.push({id: el.getAttribute('data-panelid') || String(idx), titel: t ? t.textContent.trim() : "",
                    zustand: zustand, x: Math.round(rect.left), y: Math.round(rect.top),
                    b: Math.round(rect.right), h: Math.round(rect.height)});
  });
  out.seitenFehler = /An unexpected error happened/.test(document.body.innerText || "");
  out.dokumentHoehe = document.body.scrollHeight;
  out.obenSichtbar = out.panel.filter(function(p){ return p.y < ${HOEHE} && p.y + p.h > 0; }).length;
  return out;
})()`;

async function nimm({ senden }, uid) {
  const ziel = await senden("Target.createTarget", { url: "about:blank" });
  const liste = await fetch(`http://127.0.0.1:${PORT}/json/list`).then(x => x.json());
  const eintrag = liste.find(t => t.id === ziel.targetId);
  const wsZiel = new WebSocket(eintrag.webSocketDebuggerUrl);
  await new Promise((res, rej) => { wsZiel.onopen = res; wsZiel.onerror = rej; });
  let zaehler = 0;
  const an = (methode, params = {}) => new Promise((res, rej) => {
    const mein = ++zaehler;
    const hor = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== mein) return;
      wsZiel.removeEventListener("message", hor);
      if (m.error) rej(new Error(methode + ": " + m.error.message)); else res(m.result);
    };
    wsZiel.addEventListener("message", hor);
    wsZiel.send(JSON.stringify({ id: mein, method: methode, params }));
  });
  try {
    await an("Page.enable");
    await an("Runtime.enable");
    await an("Emulation.setDeviceMetricsOverride",
      { width: BREITE, height: HOEHE, deviceScaleFactor: 1, mobile: false });
    const url = `${BASIS}/grafana/d/${uid}?orgId=1&from=${encodeURIComponent(ZEIT)}&to=now` +
      (process.env.ZUSTAND ? `&var-zustand=${process.env.ZUSTAND}` : "");
    await an("Page.navigate", { url });
    await warteAuf(async () => {
      const r = await an("Runtime.evaluate",
        { expression: "document.querySelectorAll('.react-grid-item').length", returnByValue: true });
      return Number(r.result.value) > 1;
    }, 45000, 800);
    const spaeter = async () => {
      const r = await an("Runtime.evaluate",
        { expression: "document.querySelectorAll('[class*=panel-loading]').length", returnByValue: true });
      return Number(r.result.value) === 0;
    };
    await warteAuf(spaeter, 20000, 700);
    await an("Runtime.evaluate", { expression: "window.scrollTo(0, document.body.scrollHeight)" });
    await new Promise(r => setTimeout(r, 2500));
    await an("Runtime.evaluate", { expression: "window.scrollTo(0, 0)" });
    await new Promise(r => setTimeout(r, 1200));
    const bericht = (await an("Runtime.evaluate", { expression: abnahme, returnByValue: true })).result.value;
    const bild = await an("Page.captureScreenshot", { format: "png" });
    const pfad = `docs/screenshots/${uid}.png`;
    await Bun.write(pfad, Buffer.from(bild.data, "base64"));
    const paneele = bericht.panel ?? [];
    const ueberlauf = paneele.filter(p => p.b > BREITE + 2 || p.x < -2);
    return { uid, titel: bericht.titel, paneele: paneele.length,
             seitenFehler: bericht.seitenFehler,
             leer: paneele.filter(p => p.zustand === "leer").map(p => p.titel || p.id),
             fehler: paneele.filter(p => p.zustand === "fehler").map(p => p.titel || p.id),
             ueberlauf: ueberlauf.map(p => p.titel || p.id),
             obenSichtbar: bericht.obenSichtbar, dokumentHoehe: bericht.dokumentHoehe, datei: pfad };
  } finally {
    wsZiel.close();
    await senden("Target.closeTarget", { targetId: ziel.targetId }).catch(() => {});
  }
}

const { prozess, ws, senden } = await verbinde();
const ergebnisse = [];
try {
  for (const uid of process.argv.slice(2)) {
    try { ergebnisse.push(await nimm({ senden }, uid)); }
    catch (fehler) { ergebnisse.push({ uid, fehler: String(fehler) }); }
  }
} finally {
  ws.close();
  prozess.kill(9);
}
console.log(JSON.stringify(ergebnisse, null, 1));
