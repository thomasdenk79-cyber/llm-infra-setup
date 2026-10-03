# ADR 0009: Prometheus haengt an beiden Netzen, die Runtime an einem

- Status: Akzeptiert (2026-10-02)
- Kontext: Inferenz- und Beobachtungsnetz sind getrennt. Die erste Version sah
  vor, beide Netze zu verbinden, indem die Runtime zusaetzlich im Observability-Netz
  angemeldet wird. Die Metrik `up{job="pennyroyal"}` war deshalb dauerhaft 0,
  weil der Name im anderen Netz nicht aufloesbar war - und ein Aendern der
  Runtime-Unit bedeutet einen 15-Minuten-Kaltstart.
- Entscheidung: Die Runtime bleibt einhuehnig im Inferenz-Netz. Prometheus erhaelt
  ein zweites `Network=llm-inference.network` und holt sich `/metrics` von dort.
  Der GPU-Exporter braucht nur das Observability-Netz, weil er ueber NVML misst.
- Folgen:
  * Beobachtungs-Aenderungen eroeffnen keinen Zugriff auf die Runtime und erfordern
    keinen Runtime-Neustart.
  * Die Richtung bleibt "ziehen statt senden": die Runtime kennt keine
    Beobachtungsadresse.
  * Pruefbar: `curl http://127.0.0.1:9090/api/v1/query?query=up`.
