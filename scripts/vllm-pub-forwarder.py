#!/usr/bin/env python3
"""TCP-Weiterleiter fuer die Modell-Runtime.

Die Runtime (Container flash-next-v3) haengt an keinem Podman-Netz und
veroeffentlicht ihre API nur auf der Host-Loopback 127.0.0.1:30000. Container
erreichen die Host-Loopback bei rootless Podman (pasta) gerade nicht: ein
Versuch gegen host.containers.internal:30000 bringt "Connection refused".
Erreichbar ist der Host fuer Container nur ueber seine geroutete Adresse, daher
hoert dieser Weiterleiter auf allen lokalen Netzwerkschnittstellen des Hosts
(plus Loopback fuer Werkzeuge) und reicht an 127.0.0.1:30000 weiter.

Ausnahme: VLLM_PUBLIC_BIND setzt eine feste Adresse - damit laesst sich die
Veroeffentlichung auf einen Zweitrechner verkleinern. Sauber waere, die Runtime
selbst ans Inferenz-Netz (llm-inference) zu haengen; das erfordert einen
Neustart des Runtime-Containers und ist in docs/runtime.md beschrieben.

Umgebungsvariablen:
  VLLM_PUBLIC_PORT  Host-Port des Weiterleiters (Standard 30001)
  VLLM_PUBLIC_BIND  Adresse, an die gebunden wird; 'auto' nimmt Loopback und
                    alle lokalen Schnittstellen (Standard auto)
  VLLM_UPSTREAM     Ziel als host:port (Standard 127.0.0.1:30000)
"""
import os
import select
import socket
import sys
import threading

CHUNK = 65536
POLL = 1.0


def local_addresses():
    """IPv4-Adressen der lokalen Schnittstellen - darueber erreichen Container den Host."""
    found = []
    out = os.popen("ip -o -4 addr show 2>/dev/null").read()
    for zeile in out.splitlines():
        teile = zeile.split()
        try:
            addr = teile[3].split("/")[0]
        except IndexError:
            continue
        if addr.startswith("127."):
            continue
        found.append(addr)
    return found


def gateway_addresses(limit=4):
    """Gateway-Adressen der Podman-Netze, sortiert nach Bekanntheit."""
    found = []
    for net in ("llm-inference", "llm-observability", "bridge"):
        try:
            out = os.popen(
                f"podman network inspect {net} "
                "--format '{{range .Subnets}}{{.Gateway}} {{end}}' 2>/dev/null"
            ).read().split()
            found.extend(out)
        except OSError:
            pass
    ordered = []
    for addr in found + ["10.88.0.1"]:
        if addr not in ordered:
            ordered.append(addr)
    return ordered[:limit]


def bind_addresses():
    """Adressen, an denen Container und Hosttools die Runtime erreichen."""
    want = os.environ.get("VLLM_PUBLIC_BIND", "auto").strip()
    if want and want != "auto":
        return [want]
    ordered = []
    for addr in ["127.0.0.1"] + local_addresses() + gateway_addresses() + ["10.88.0.1"]:
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind((addr, 0))
            probe.close()
        except OSError:
            continue
        if addr not in ordered:
            ordered.append(addr)
    return ordered or ["127.0.0.1"]


def pipe(src, dst):
    try:
        while True:
            data = src.recv(CHUNK)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for sock in (src, dst):
            try:
                sock.shutdown(socket.SHUT_WR)
            except OSError:
                pass


def serve(client, upstream):
    try:
        remote = socket.create_connection(upstream, timeout=10)
        # Nur der Aufbau darf nach 10 s scheitern. Eine Antwort darf laenger
        # dauern: bei Warteschlange in der Laufzeit liegt die Zeit bis zum ersten
        # Token ueber mehreren Sekunden, und ein Socket-Timeout hier bricht dann
        # den Stuck-Strom ab (bei LiteLLM: TransferEncodingError, Payload
        # unvollstaendig).
        remote.settimeout(None)
    except OSError as err:
        client.close()
        print(f"upstream {upstream} nicht erreichbar: {err}", file=sys.stderr, flush=True)
        return
    threads = [
        threading.Thread(target=pipe, args=(client, remote), daemon=True),
        threading.Thread(target=pipe, args=(remote, client), daemon=True),
    ]
    for thread in threads:
        thread.start()
    while any(thread.is_alive() for thread in threads):
        select.select([], [], [], POLL)
    client.close()
    remote.close()


def main():
    port = int(os.environ.get("VLLM_PUBLIC_PORT", "30001"))
    up_host, _, up_port = os.environ.get("VLLM_UPSTREAM", "127.0.0.1:30000").partition(":")
    upstream = (up_host, int(up_port or 30000))
    bind_list = bind_addresses()
    listeners = []
    for addr in bind_list:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            listener.bind((addr, port))
        except OSError as err:
            print(f"bind {addr}:{port} uebersprungen: {err}", file=sys.stderr, flush=True)
            listener.close()
            continue
        listener.listen(128)
        listeners.append(listener)
    if not listeners:
        print(f"kein Listener auf Port {port} moeglich", file=sys.stderr, flush=True)
        return 1
    print(f"weiterleiter {','.join(bind_list)}:{port} -> {upstream[0]}:{upstream[1]}", flush=True)
    while True:
        ready, _, _ = select.select(listeners, [], [], None)
        for listener in ready:
            client, _ = listener.accept()
            threading.Thread(target=serve, args=(client, upstream), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())
