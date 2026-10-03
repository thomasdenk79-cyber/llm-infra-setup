# ADR 0013: Die Grafikkarte gehoert ausschliesslich dem Modell

- Status: Akzeptiert (2026-10-02) - Betreiberentscheidung
- Kontext: Die Karte ist die teure Ressource dieses Aufbaus und soll nicht durch
  andere Arbeitslasten oder durch Aufteilung unberechenbar werden.
- Entscheidung:
  * Inferenz laeuft mit einem GPU-Kern (TP1); `TP_SIZE` bleibt auf 1.
  * Kein zweiter Container, keine VM und kein Trainingslauf erhaelt GPU-Zugriff.
  * Der GPU-Exporter liest nur ueber NVML; DCGM (das Feldgruppen aktiv misst) ist
    nur als ausdrueckliche, spaetere Option vorgesehen.
  * Aenderungen an der GPU-Nutzung sind nur nach Neustart der Runtime wirksam und
    werden durch `PENNYROYAL_PROTECT` bzw. den Schutz in
    `scripts/apply-runtime-unit.sh` abgesichert.
- Umsetzung (2026-10-03 ergaenzt):
  * `scripts/45-configure-kwin-egpu.sh --modus llm` legt den Desktop auf die
    Intel-Grafik (Nachricht: angeschlossene Bildschirme an der externen Karte fuehren
    zum Abbruch, damit niemand seinen Arbeitsplatz abschaltet).
  * `scripts/44-isolate-blackwell.sh` entzieht per udev-Regel den DRM-Anzeigepfad
    der NVIDIA-Karte; CUDA bleibt unberuehrt und wird danach mit einem eigenen
    Containerlauf nachgewiesen. Bei Erfolglosigkeit nimmt das Skript die Regel selbst
    zurueck.
  *Messbefund belegen: Compositor hielt 28 MiB und einen Anzeigeknoten, Firefox-RDD
    ebenfals; der Rechenpfad des Modells war davon unberuehrt.
- Folgen:
  * Vorhersagbare Latenz fuer einen Nutzer zur Zeit.
  * Der Weg auf hohes Gesamtdurchsatz fuehrt ueber Parallelitaet (4 Anfragen
  brachten 242 Token/s) und ueber die Anbindung, nicht ueber Aufteilung der Karte.
