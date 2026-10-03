# ADR 0012: Die Schreibrate ist nicht durch Thunderbolt begrenzt (Korrektur)

- Status: Akzeptiert (2026-10-03), ersetzt die Fassung vom 2026-10-02
- Kontext: Erwartet wurden ueber 200 Token/s pro einzelner Anfrage; gemessen wurden
  157,88 Token/s (normaler Prompt) und 119,01 Token/s (langer Prompt). Die erste
  Deutung lautete: die externe Grafikkarte hanldelt nur x4 bei 16 GT/s aus
  (Thunderbolt 4 statt PCIe x16) und das sei die Grenze. **Diese Deutung war falsch.**
- Messbefund (2026-10-03, `nvidia-smi dmon -s t` waehrend des Schreibens):

  | Groesse | Messwert | Deutung |
  |---|---|---|
  | PCIe Ein-/Ausgabe | 3 bis 25 MB/s | weit unter jeder Grenze; die Strecke wartet leer |
  | GPU-Auslastung | 61 % | Rechenwerke warten, aber nicht auf der Anbindung |
  | Leistungsverbrauch | 275 W von 600 W Limit | keine Leistungsgrenze |
  | Temperatur / Takt | 56 C, 2857 von 3090 MHz | keine Warme-Drosselung |
  | VRAM | 94,9 von 97,9 GiB | Modell und Puffer sind voll in der Karte |

- Entscheidung: Die Thunderbolt-Anbindung wird weiter angezeigt (sie ist eine
  reale Eigenschaft des Aufbaus und verbessert den Vorlesedatenweg der Tabellen,
  sobald diese nicht mehr im Seitenspeicher stehen), aber sie ist **nicht** die
  Erklaerung fuer die Schreibrate. Uebrige Erklarungsansaetze, in dieser Reihenfolge
  zu untersuchen:
  1. Auslagerung der Einbettungstabellen (PLE): Latenz der Auslesepfade,
     Seitenspeicher-Anteil, Vorwärmen nach Neustart.
  2. Guete der spekultativen Ausfuehrung (`sglang:spec_accept_length` 2,4 bis 3,3,
     Akzeptanz 0,74) - hier liegt der groesste gewinnbare Hebel.
  3. Decode-Pfade der Laufzeit selbst (Kernel, Speicherbandbreite der Karte).
- Folgen:
  * Die Alarmregel `PCIeAnbindungReduziert` bleibt, aber als Hinweis ohne
    Schuldzuweisung; ihr Text verweist auf diese Messung.
  * "200+ Token/s pro Anfrage" ist auf diesem Rechner nicht durch den Anschluss
    verboten, sondern muss ueber 1 und 2 geholt werden. Die Messgroessen dafuer
    sind vorhanden (`docs/performance.md`).
