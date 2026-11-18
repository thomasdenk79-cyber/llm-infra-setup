// Abnahme der Grafana-Dashboards: Screenshot + DOM-Pruefung je Panel.
// Aufruf: bun scripts/grafana-dashboard-qualitaet.mjs <uid> [uid...]
//         GRAFANA_URL (Standard http://127.0.0.1:3000) AUFLOESUNG (Standard 1680x1050)
//         GRAFANA_USER/GRAFANA_PASS (Standard admin / Zugang aus
//         ~/.config/llm-infra/credentials.txt, Zeile ADMIN_PASS=)
// Ausgaben: docs/screenshots/<uid>.png und ein JSON-Bericht pro Dashboard:
// Panelzahl, Titel, Fehler-/Leer-Meldungen, Ueberlauf, was oberhalb der
// Falzkante liegt. Bild ist das Beweismittel, der Bericht die Abnahme.
const CHROME = process.env.CHROME_PATH ??
  (await Bun.file(`${process.env.HOME}/.cache/ms-playwright/chromium-1255/chrome-linux64/chrome`).exists()
    ? `${process.env.HOME}/.cache/ms-playwright/chromium-1255/chrome-linux64/chrome` : undefined);
const BASIS = (process.env.GRAFANA_URL ?? "http://127.0.0.1:3000").replace(/\/$/, "");
const ZEIT = process.env.ZEITRAUM ?? "now-3h";
const [BREITE, HOEHE] = (process.env.AUFLOESUNG ?? "1680x1050").split("x").map(Number);

async function zugangsdaten() {
  if (process.env.GRAFANA_USER && process.env.GRAFANA_PASS) {
    return { user: process.env.GRAFANA_USER, pass: process.env.GRAFANA_PASS };
  }
  const text = await Bun.file(`${process.env.HOME}/.config/llm-infra/credentials.txt`).text().catch(() => "");
  const treffer = text.match(/^ADMIN_PASS=(.*)$/m);
  return { user: "admin", pass: treffer ? treffer[1].trim() : "" };
}

const pruefe = `(function(){
  var out = {titel: document.title.replace(/ - LLM Infrastructure.*| - Grafana$/g, ""), panel: [], fehler: []};
  document.querySelectorAll('.react-grid-item').forEach(function(el, idx){
    var t = el.querySelector('.panel-title, [class*=panel-title]');
    var rect = el.getBoundingClientRect();
    var text = (el.innerText || "");
    var zustand = "ok";
    if (/No data|Keine Daten/i.test(text)) zustand = "leer";
    if (/query failed|server error|parse error|not found|exec\w* protocol/i.test(text)) zustand = "fehler";
    out.panel.push({id: el.getAttribute('data-panelid') || String(idx), titel: t ? t.textContent.trim() : "",
                    zustand: zustand, x: Math.round(rect.left), y: Math.round(rect.top),
                    b: Math.round(rect.right), h: Math.round(rect.height)});
  });
  out.dokumentHoehe = document.body.scrollHeight;
  out.obenSichtbar = out.panel.filter(function(p){ return p.y < ${HOEHE} && p.y + p.h > 0; }).length;
  return out;
})()`;

async function nimm(uid, zustand) {
  const zugang = await zugangsdaten();
  const w = new Bun.WebView({ width: BREITE, height: HOEHE, offscreen: true,
                              ...(CHROME ? { backend: { type: "chrome", path: CHROME } } : {}) });
  try {
    await w.navigate(`${BASIS}/grafana/login`);
    for (let i = 0; i < 40 && w.loading; i++) await new Promise(r => setTimeout(r, 200));
    await w.evaluate(`(function(){
      var u = document.querySelector('input[name="user"], #user');
      var p = document.querySelector('input[name="password"], #password');
      if (u && p) { u.value = ${JSON.stringify(zugang.user)}; p.value = ${JSON.stringify(zugang.pass)};
        u.dispatchEvent(new Event("input", {bubbles:true}));
        p.dispatchEvent(new Event("input", {bubbles:true})); return "gefuellt"; }
      return "keine felder";
    })()`);
    await w.evaluate(`(function(){
      var f = document.querySelector('button[type=submit]'); if (f) f.click(); return 1;
    })()`);
    for (let i = 0; i < 30; i++) {
      const wo = await w.evaluate("location.pathname");
      if (!/login/.test(wo)) break;
      await new Promise(r => setTimeout(r, 300));
    }
    await w.navigate(`${BASIS}/grafana/d/${uid}?orgId=1&from=${encodeURIComponent(ZEIT)}&to=now` +
                     (zustand ? `&var-zustand=${zustand}` : ""));
    for (let i = 0; i < 40 && w.loading; i++) await new Promise(r => setTimeout(r, 250));
    let paneele = 0;
    for (let i = 0; i < 25; i++) {
      paneele = await w.evaluate("document.querySelectorAll('.react-grid-item').length");
      const spaeter = await w.evaluate("document.querySelectorAll('[class*=panel-loading]').length");
      if (paneele > 1 && spaeter === 0) break;
      await new Promise(r => setTimeout(r, 800));
    }
    // Einmal durchscrollen, damit spaeter geladene Panel-Daten kommen, dann zurueck
    await w.evaluate(`window.scrollTo(0, document.body.scrollHeight)`);
    await new Promise(r => setTimeout(r, 2500));
    await w.evaluate(`window.scrollTo(0, 0)`);
    await new Promise(r => setTimeout(r, 1200));
    const bericht = await w.evaluate(pruefe);
    const pfad = `docs/screenshots/${uid}${zustand ? "-" + zustand : ""}.png`;
    const buf = await w.screenshot({ format: "png" });
    await Bun.write(pfad, buf);
    const ueberlauf = (bericht.panel ?? []).filter(p => p.b > BREITE + 2 || p.x < -2);
    return { uid, zustand: zustand ?? null, titel: bericht.titel,
             paneele: (bericht.panel ?? []).length,
             leer: (bericht.panel ?? []).filter(p => p.zustand === "leer").map(p => p.titel || p.id),
             fehler: (bericht.panel ?? []).filter(p => p.zustand === "fehler").map(p => p.titel || p.id),
             ueberlauf: ueberlauf.map(p => p.titel || p.id),
             obenSichtbar: bericht.obenSichtbar, dokumentHoehe: bericht.dokumentHoehe, datei: pfad };
  } finally {
    w.close();
  }
}

const ergebnisse = [];
for (const uid of process.argv.slice(2)) {
  try { ergebnisse.push(await nimm(uid, process.env.ZUSTAND ?? null)); }
  catch (fehler) { ergebnisse.push({ uid, fehler: String(fehler) }); }
}
console.log(JSON.stringify(ergebnisse, null, 1));
