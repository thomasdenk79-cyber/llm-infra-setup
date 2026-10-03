#!/usr/bin/env python3
"""Objektiver Qualitaetsvergleich vor und nach einem Tuning-Lauf.

Die Frage "was kostet das an Qualitaet" laesst sich nur beantworten, wenn man
dieselben Aufgaben vor und nachher gleich misst. Dieses Skript stellt kurze,
deutlich messbare Aufgaben (Rechnen, exakte Vorgabe einhalten, striktes JSON,
Werkzeugaufruf) und langlebige Aufgaben (eine Information in langem Text wieder-
finden) an das laufende Modell. Es verandert nichts am System.

  ./scripts/quality_check.py                 alle Aufgaben (auch die langen)
  ./scripts/quality_check.py --schnell       nur die kurzen, ca. 1 Minute
  ./scripts/quality_check.py --vergleich     gegen die letzte Messung erklaren

Ergebnis: state/quality/<stempel>.json und .md
"""
from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import random
import re
import sys
import time
import urllib.error
import urllib.request

FILLER = (
    "Die Anlage dokumentiert jeden Rechenschritt mit Zeitstempel, Pruefer und "
    "Aktenzeichen, damit spaetere Nachfragen ohne Ruecksprache beantwortet werden koennen. "
)


def ask(base_url: str, key: str, model: str, prompt: str, max_tokens: int = 200,
        tools: list | None = None, timeout: int = 900) -> dict:
    payload = {"model": model, "temperature": 0, "max_tokens": max_tokens,
               "messages": [{"role": "user", "content": prompt}]}
    if tools:
        payload["tools"] = tools
        payload["tool_choice"] = "auto"
    request = urllib.request.Request(
        f"{base_url}/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {key}"} if key else {})},
    )
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.loads(response.read().decode())
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
        return {"ok": False, "error": str(exc), "seconds": round(time.perf_counter() - start, 2)}
    choice = body["choices"][0]
    message = choice["message"]
    # Diese Bauart antwortet mit Denkketten: die fertige Antwort kann im Feld
    # content stehen oder, wenn der Reasoning-Parser liefert, in reasoning_content.
    # Nur content zu lesen waere ein Messfehler, kein Modellfehler.
    content = (message.get("content") or "").strip()
    reasoning = (message.get("reasoning_content") or "").strip()
    text = content or reasoning
    return {"ok": True, "text": text, "content_empty": not bool(content),
            "tool_calls": message.get("tool_calls"),
            "usage": body.get("usage", {}),
            "seconds": round(time.perf_counter() - start, 2)}


def needle_case(base_url, key, model, target_tokens: int) -> dict:
    """Information in fuellenden Text einbetten und nach ihr fragen."""
    rng = random.Random(20260903 + target_tokens)
    code = f"AK-{rng.randint(100000, 999999)}"
    blocks = max(1, target_tokens // 900)
    middle = blocks // 2
    parts = []
    for index in range(blocks):
        sentence = FILLER.replace("jeden Rechenschritt", f"Schritt {index:04d}")
        if index == middle:
            sentence = f"Wichtige Merkinformation in Block {index:04d}: Der Vertraege ist {code}. " + sentence
        parts.append(sentence)
    prompt = "".join(parts) + "\n\nFrage: Wie lautet die Merkinformation (nur der Code)?"
    answer = ask(base_url, key, model, prompt, max_tokens=40)
    if not answer.get("ok"):
        answer.update({"passed": False, "expected": code, "got": answer.get("error")})
        return answer
    answer["passed"] = code in answer["text"]
    answer["expected"] = code
    return answer


def case_rechnen(base_url, key, model):
    result = ask(base_url, key, model, "Ein Rechteck ist 17 mal 11 Meter. Wie viel Quadratmeter sind das? Nur die Zahl.", 40)
    result["passed"] = bool(re.search(r"\b187\b", result.get("text", "")))
    return result


def case_vorgabe(base_url, key, model):
    # Die Baumarkt-Maschine denkt laut; mit zu kleiner Antwortgrenze endet die
    # Antwort mitten im Denkteil. 600 Token lassen Platz fuer Denkkette und Antwort.
    result = ask(base_url, key, model, "Antworte mit genau einem Wort: PONYTECHNIK", 600)
    text = result.get("text", "")
    result["passed"] = bool(re.search(r"(?m)^\s*PONYTECHNIK\s*$", text)) or text.strip() == "PONYTECHNIK"
    return result


def case_json(base_url, key, model):
    result = ask(base_url, key, model,
                 'Gib ausschliesslich ein JSON-Objekt zurueck mit den Schluesseln "marke" (Wert "Lenovo") und "jahr" (Wert 2021).', 80)
    result["passed"] = _is_json(result.get("text", ""))
    return result


def case_werkzeug(base_url, key, model):
    tools = [{"type": "function", "function": {
        "name": "stadt_abfrage", "description": "Fragt eine Stadt ab.",
        "parameters": {"type": "object", "properties": {"name": {"type": "string"}},
                       "required": ["name"]}}}]
    result = ask(base_url, key, model, "Frage per Werkzeug nach dem aktuellen Namen von Hamburg.", 120, tools=tools)
    result["passed"] = bool(result.get("tool_calls"))
    return result


CASES = {
    "rechnen": case_rechnen,
    "exakte_vorgabe": case_vorgabe,
    "striktes_json": case_json,
    "werkzeugaufruf": case_werkzeug,
}


def _is_json(text: str) -> bool:
    match = re.search(r"\{.*\}", text, re.S)
    if not match:
        return False
    try:
        data = json.loads(match.group(0))
    except json.JSONDecodeError:
        return False
    return data.get("marke") == "Lenovo" and data.get("jahr") == 2021


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8001/v1")
    parser.add_argument("--key", default="", help="Schluessel fuer ein Gateway, falls ueber Gateway gemessen wird")
    parser.add_argument("--model", default="pennyroyal")
    parser.add_argument("--schnell", action="store_true", help="nur die kurzen Aufgaben")
    parser.add_argument("--vergleich", action="store_true")
    args = parser.parse_args()

    if args.vergleich:
        return compare()

    root = pathlib.Path(__file__).resolve().parent.parent
    out_dir = root / "state" / "quality"
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    results = {}
    for name, case in CASES.items():
        results[name] = case(args.base_url, args.key, args.model)
        print(f"  {name:17} {'bestanden' if results[name].get('passed') else 'NICHT bestanden'}  ({results[name].get('seconds')} s)")
    if not args.schnell:
        for tokens in (20000, 100000, 300000):
            name = f"merken_{tokens // 1000}k"
            results[name] = needle_case(args.base_url, args.key, args.model, tokens)
            used = results[name].get("usage", {}).get("prompt_tokens")
            print(f"  {name:17} {'bestanden' if results[name].get('passed') else 'NICHT bestanden'}"
                  f"  (Prompt {used or '?'} Token, {results[name].get('seconds')} s)")

    passed = sum(1 for r in results.values() if r.get("passed"))
    document = {"timestamp": stamp, "base_url": args.base_url, "model": args.model,
                "passed": passed, "total": len(results), "cases": results}
    (out_dir / f"{stamp}.json").write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")
    lines = [f"# Qualitaetspruefung {stamp}", "",
             f"Ergebnis: {passed} von {len(results)} Aufgaben bestanden", "", "| Aufgabe | bestanden | Prompt-Token | Sekunden |", "|---|---|---|---|"]
    for name, result in results.items():
        lines.append(f"| {name} | {'ja' if result.get('passed') else 'nein'} | "
                     f"{result.get('usage', {}).get('prompt_tokens', '-')} | {result.get('seconds', '-')} |")
    lines += ["", "Vergleich mit der letzten Messung: `./scripts/quality_check.py --vergleich`", ""]
    (out_dir / f"{stamp}.md").write_text("\n".join(lines))
    print(f"\n{passed}/{len(results)} bestanden  ->  state/quality/{stamp}.md")
    return 0 if passed == len(results) else 1


def compare() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    files = sorted((root / "state" / "quality").glob("*.json"))
    if len(files) < 2:
        print("Es braucht mindestens zwei Messungen fuer einen Vergleich.")
        return 1
    old = json.loads(files[-2].read_text())
    new = json.loads(files[-1].read_text())
    print(f"Vergleich {old['timestamp']} gegen {new['timestamp']}")
    changed = 0
    for name in sorted(set(old["cases"]) | set(new["cases"])):
        before = old["cases"].get(name, {}).get("passed")
        after = new["cases"].get(name, {}).get("passed")
        mark = "  gleich" if before == after else "  UNTERSCHIED"
        if before != after:
            changed += 1
        print(f"  {name:18} vorher {'ja' if before else 'nein'}   nachher {'ja' if after else 'nein'}{mark}")
    print(f"\nBestanden vorher {old['passed']}/{old['total']}, nachher {new['passed']}/{new['total']}.")
    if changed == 0:
        print("Keine Anzeichen von Qualitaetsverlust in diesen Aufgaben.")
    else:
        print("Es hat sich etwas geaendert - die betroffenen Aufgaben nochmal einzeln durchgehen.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
