# Review-Befunde 2026-11-18 (zwei Agenten je Pod, read-only)

Status: laeuft. A = Konfiguration+Version, B = Betrieb+Sicherheit.

## alertmanager
- A (6 Befunde):
  - HOCH: Live-Konfiguration stammte vom 16.11. - KI-Empfaenger nie geladen.
    Behoben: POST /-/reload (200, Empfaenger jetzt live) + idempotenter
    Reload-Schritt in `60-install-monitoring.sh`, alertmanager.container in
    start_units ergaenzt.
  - MITTEL: dokumentierter Aktivierungsweg in `80-setup-incident-agent.sh`
    war Noop (Reload fehlte). Behoben wie oben.
  - MITTEL: `versions.lock`-Digest war Bild-Id statt Manifest-Digest.
    Behoben: auf sha256:45c3a586... (Registry-Manifest) gestellt.
  - MITTEL: Meta-Wchter `BeobachtungZieltNicht` uebersah Jobs cadvisor,
    caddy, incident-agent, prometheus. Behoben: Regex ergaenzt.
  - NIEDRIG: `AlarmwegFehlt`-Summary sagte das Gegenteil der Bedingung.
    Behoben: "nicht erreicht".
  - NIEDRIG: Quadlet-Kommentar zahlte 24 Regeln (sind 29). Behoben:
    zahlfreie Formulierung.
- B: ausstehend
