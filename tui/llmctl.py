#!/usr/bin/env python3
"""llmctl - Betriebs-CLI fuer die lokale LLM-Infrastruktur.

Jeder Unterbefehl ruft nur ein Skript aus scripts/ auf. In den Skripten stehen
die Erklaerungen und die naechsten Schritte; diese CLI ist der bequeme Zugriff
vom Terminal. Noetig ist ausschliesslich Python aus der Standardinstallation.
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVICES = (
    'pennyroyal', 'litellm-postgres', 'litellm', 'open-webui', 'homepage',
    'prometheus', 'grafana', 'loki', 'alloy', 'dozzle',
    'llm-node-exporter', 'llm-gpu-exporter', 'llm-infra-collect-facts.timer',
    'llm-runtime-watchdog.timer',
)


def run(name, *args):
    return subprocess.run([os.path.join(ROOT, 'scripts', name), *args], check=False).returncode


def service_active(service):
    result = subprocess.run(['systemctl', '--user', '--no-pager', 'is-active', service],
                            capture_output=True, text=True, check=False)
    return result.stdout.strip() or 'unbekannt'


def api_json(port, path, timeout=6):
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{port}{path}', timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


def status():
    print('llmctl status')
    print('repo:', ROOT)
    for service in SERVICES:
        name = service if service.endswith('.timer') else service + '.service'
        state = service_active(name)
        marker = 'ok  ' if state == 'active' else '    ' if state == 'inactive' else '?'
        print(f'  {marker} {service}: {state}')
    runtime = os.getenv('PENNYROYAL_PORT', '8001')
    gateway = os.getenv('LITELLM_PORT', '4000')
    print(f'  API      http://127.0.0.1:{runtime}  '
          f'({"antwortet" if api_json(runtime, "/health") is not None else "keine Antwort"})')
    print(f'  Gateway  http://127.0.0.1:{gateway}  '
          f'({"antwortet" if api_json(gateway, "/health") is not None else "keine Antwort"})')
    metrics = api_json(runtime, '/metrics')
    if metrics is None:
        try:
            with urllib.request.urlopen(f'http://127.0.0.1:{runtime}/metrics', timeout=6) as resp:
                body = resp.read().decode()
            for key in ('sglang:gen_throughput', 'sglang:spec_accept_length', 'sglang:num_running_reqs'):
                for line in body.splitlines():
                    if line.startswith(key + '{') or line.startswith(key + ' '):
                        print(f'  {key}: {line.rsplit(" ", 1)[1]}')
                        break
        except Exception:
            pass
    print("  Details:  ./scripts/doctor.sh")
    return 0


def urls():
    runtime = os.getenv('PENNYROYAL_PORT', '8001')
    gateway = os.getenv('LITELLM_PORT', '4000')
    print('Portal        http://127.0.0.1:3002   Einstieg fuer den Betreiber')
    print('Chat          http://127.0.0.1:3001   Open WebUI (Registrierung: erster Nutzer ist Admin)')
    print('Gateway       http://127.0.0.1:%s   LiteLLM (OpenAI-kompatibel)' % gateway)
    print('Runtime       http://127.0.0.1:%s   Pennyroyal direkt (nur lokal)' % runtime)
    print('Dashboards    http://127.0.0.1:3000   Grafana')
    print('Metriken      http://127.0.0.1:9090   Prometheus')
    print('Logs          http://127.0.0.1:8080   Dozzle')
    print('Zugangsdaten  ./scripts/show-credentials.sh')
    return 0


def main():
    parser = argparse.ArgumentParser(prog='llmctl', description='Betriebs-CLI fuer llm-infra-setup')
    sub = parser.add_subparsers(dest='cmd')
    for name in ('status', 'health', 'doctor', 'start', 'stop', 'restart', 'logs',
                 'deploy', 'deploy-ready', 'deploy-portal', 'update', 'benchmark',
                 'benchmark-long', 'model', 'tunnel', 'urls', 'backup', 'restore',
                 'credentials'):
        sub.add_parser(name)
    args = parser.parse_args()
    cmd = args.cmd
    if not cmd:
        return status()
    if cmd == 'status':
        return status()
    if cmd == 'health':
        return run('healthcheck.sh')
    if cmd == 'doctor':
        return run('doctor.sh')
    if cmd in ('start', 'stop', 'restart'):
        return subprocess.run(['systemctl', '--user', cmd, 'pennyroyal.service'], check=False).returncode
    if cmd == 'logs':
        return subprocess.run(['journalctl', '--user', '-u', 'pennyroyal.service', '-n', '100', '-f'],
                              check=False).returncode
    if cmd == 'deploy':
        return run('deploy.sh')
    if cmd == 'deploy-ready':
        return run('deploy-ready.sh')
    if cmd == 'deploy-portal':
        return run('deploy-non-gpu.sh')
    if cmd == 'benchmark':
        return run('benchmark.sh')
    if cmd == 'benchmark-long':
        return run('benchmark.sh', 'long')
    if cmd == 'model':
        return run('40-download-model.sh')
    if cmd == 'backup':
        return run('backup.sh')
    if cmd == 'restore':
        return run('restore.sh', '--list')
    if cmd == 'credentials':
        return run('show-credentials.sh')
    if cmd == 'update':
        return subprocess.run(['git', 'pull', '--ff-only'], cwd=ROOT, check=False).returncode
    if cmd == 'tunnel':
        print('Der Wartungstunnel ist standardmaessig aus.')
        print('Einrichten: cp config/autossh.env.example config/autossh.env, Host eintragen,')
        print('            dann ./scripts/61-install-autossh.sh --check')
        return 0
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
