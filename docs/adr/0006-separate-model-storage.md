# ADR 0006: Modellage vom System trennen

- Status: Akzeptiert, 2026-10-02 ergaenzt
- Kontext: Modelle sind gross, ändern sich selten und profitieren von
  Snapshot-Faehigkeit und Kompression. Die Runtime braucht zusaetzlich eine
  Schnellanlage fuer ausgelagerte Einbettungen (PLE).
- Entscheidung: Modellgewichte liegen auf dem ZFS-Dataset `pool/llm/models`
  (mntpoint `/srv/llm/models`, lz4, recordsize 1 MiB, atime aus,
  `primarycache=metadata`). Der PLE-Bereich liegt absichtlich nicht auf ZFS,
  sondern auf ext4 in einer Loopdatei (ADR 0011). Runtime-Zustand liegt unter
  `~/.local/share/llm-infra`. Bequemer Zugang ueber Symlink `~/llm/models`.
- Folgen:
  * System-Update und Modellbestand sind unabhaengig.
  * Snapshots sind moeglich; `scripts/backup.sh` legt einen an.
  * Die ARC-Begrenzung (`ZFS_ARC_MAX_GB`) ist noetig, damit Modelladen nicht
    durch Cache-Druck verdraengt wird.
