# ADR 0010: Host-Kennzahlen im rootless Container mit /host-Einhaengung

- Status: Akzeptiert (2026-10-02)
- Kontext: Fur CPU-, RAM-, Platten- und ZFS-Werte gibt es zwei Wege: ein nativer
  Dienst auf dem Host oder ein Container. Der Masterprompt bevorzugt nativ, wenn
  es sauberer ist, weil Container sonst nur die Containersicht liefern.
- Entscheidung: Node-Exporter laeuft als rootless Quadlet und haengt den Host
  schreibgeschuetzt unter `/host` ein (`--path.rootfs=/host`). Der eigene
  Kennzahlensammler schreibt zusaetzliche Werte als Textdatei in einen Ordner,
  den der Exporter einsammelt.
- Begruendung: Die Containerloesung bleibt bei der Rege "alles ist eine User-Unit",
  braucht kein Paket, keinen Systemdienst und keine sudo-Regel. Verifiziert am
  2026-10-02: MemTotal 67 GB (Hostwert), ZFS-ARC 8,1 GB, Last 8,73, Temperaturen,
  Textdatei-Werte sichtbar.
- Folgen:
  * Netzwerkzaehler zeigen die Container-Sicht; daefuer sind die Hostwerte ueber
    `/host/proc/net/dev` in den eigenen Kennzahlen enthalten, und die PCIe-Werte
    kommen aus `/sys`.
  * SMART braucht sudo und ist optional (`llm_smart_available`).
