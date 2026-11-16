#!/usr/bin/env bash
# Regressionspruefung fuer scripts/vllm-pub-forwarder.py
#
# Nachweis eines konkreten Fehlers: der Weiterleiter uebernahm das
# Aufbau-Timeout von 10 s als Socket-Timeout. Wartete die Laufzeit bei
# Auslastung laenger als 10 s bis zum ersten Token, brach der Stuck-Strom ab
# (LiteLLM meldete TransferEncodingError, Payload unvollstaendig).
#
# Aufbau: ein langsamer Vorgaetter antwortet erst nach 13 s mit einem
# gehaeuften JSON-Body. Darf der Weiterleiter dann ein Socket-Timeout setzen,
# bekommt der Client nichts. Gefordert: volle Antwort in einem Stueck.
#
# Aufruf: ./scripts/test-vllm-forwarder.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UP_PORT=${UP_PORT:-31999}
FW_PORT=${FW_PORT:-31998}
SLOW_SECONDS=${SLOW_SECONDS:-13}
FEHLER=0

SLOW_UPSTREAM="$(mktemp /tmp/slow-upstream.XXXXXX.py)"
trap 'rm -f "$SLOW_UPSTREAM"; [[ -n "${UP_PID:-}" ]] && kill "$UP_PID" 2>/dev/null' EXIT
cat >"$SLOW_UPSTREAM" <<'PY'
import http.server, socketserver, sys, time

class Handler(socketserver.StreamRequestHandler):
    timeout = 90

    def handle(self):
        self.rfile.readline()
        while True:
            zeile = self.rfile.readline()
            if zeile in (b"\r\n", b"\n", b""):
                break
        time.sleep(float(sys.argv[2]))
        self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                         b"Transfer-Encoding: chunked\r\n\r\n")
        for i in range(4):
            body = ('{"i":%d,"p":"%s"}' % (i, "x" * 200)).encode()
            self.wfile.write(b"%x\r\n" % len(body) + body + b"\r\n")
            self.wfile.flush()
            time.sleep(0.2)
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY

python3 "$SLOW_UPSTREAM" "$UP_PORT" "$SLOW_SECONDS" >/dev/null 2>&1 &
UP_PID=$!
sleep 1

VLLM_PUBLIC_BIND=127.0.0.1 VLLM_PUBLIC_PORT="$FW_PORT" VLLM_UPSTREAM="127.0.0.1:$UP_PORT" \
  python3 "$REPO/scripts/vllm-pub-forwarder.py" >/dev/null 2>&1 &
FW_PID=$!
sleep 1

ANTWORT="$(mktemp /tmp/forwarder-answer.XXXXXX.json)"
curl -s -m 45 -o "$ANTWORT" -w '%{http_code} %{size_download}\n' \
  "http://127.0.0.1:$FW_PORT/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d '{"model":"flash-next","messages":[{"role":"user","content":"JA"}],"stream":true}' >"$ANTWORT.meta"
CURL_RC=$?
read -r CODE GROESSE <"$ANTWORT.meta"
kill "$FW_PID" 2>/dev/null; wait "$FW_PID" 2>/dev/null

echo "weiterleiter-pruefung: curl_rc=$CURL_RC code=$CODE bytes=$GROESSE (Vorgaetter antwortet nach ${SLOW_SECONDS} s)"
if [[ "$CURL_RC" -ne 0 || "$CODE" != "200" ]]; then
  echo "FEHLER: Antwort unvollstaendig - Timeout bricht den Stuck-Strom ab."
  FEHLER=1
elif ! grep -q '"i":3' "$ANTWORT"; then
  echo "FEHLER: letzter Stuck fehlt."
  FEHLER=1
else
  echo "OK: volle Antwort nach ${SLOW_SECONDS} s Vorlaufzeit."
fi
rm -f "$ANTWORT" "$ANTWORT.meta"
exit "$FEHLER"
