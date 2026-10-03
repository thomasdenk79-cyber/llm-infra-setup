# ADR 0011: PLE-Auslagerung auf ext4-Loopdatei, nicht auf ZFS

- Status: Akzeptiert (2026-10-02), mit dokumentierter Verbesserung
- Kontext: Die Runtime lagert Einbettungstabellen (PLE) auf SSD aus und liest sie
  mit io_uring. Auf ZFS schlug derselbe Leseversuch mit
  `OSError: Function not implemented (os error 38)` fehl; der RAM-Pfad war auf dem
  64-GiB-Rechner keine Option, weil das Modelladen sonst keinen Platz mehr hat.
- Entscheidung: Eine sparse ext4-Datei auf dem ZFS-Pool wird als Loop-Geraet
  eingehaengt (`nofail` in `/etc/fstab`). Der Pfad ist im Repository erzeugt und
  gepueft (`scripts/47-setup-ple-storage.sh`, Kennzahl `llm_ple_mounted`).
- Folgen:
  * Zuverlaessig und reproduzierbar, aber durch drei Speicherschichten
    (Loop -> ext4 -> ZFS) langsamer als eine echte Partition.
  * Besserer Pfad vorbereitet: `PLE_BLOCK_DEVICE=/dev/...` in `config/host.env`
    nutzt eine echte Partition; das Skript formatiert nie selbst.
  * Vergleichsmessung (RAM gegen SSD) bleibt als Aufgabe in `docs/performance.md`.
