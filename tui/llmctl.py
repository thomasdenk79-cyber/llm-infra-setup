#!/usr/bin/env python3
"""Dependency-free operational CLI; optional rich/textual can be layered later."""
import argparse, os, subprocess, sys, urllib.request
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def run(name,*args): return subprocess.run([os.path.join(ROOT,'scripts',name),*args],check=False).returncode
def status():
 print('llmctl status'); print('repo:',ROOT)
 services = ('pennyroyal','litellm-postgres','litellm','prometheus','grafana','loki','alloy','dozzle')
 for service in services:
  result = subprocess.run(['systemctl','--user','--no-pager','is-active',service+'.service'], capture_output=True, text=True, check=False)
  print(f'{service}: {result.stdout.strip() or "unknown"}')
def health(): return run('healthcheck.sh')
def main():
 p=argparse.ArgumentParser(prog='llmctl'); s=p.add_subparsers(dest='cmd')
 for n in ('status','health','start','stop','restart','logs','deploy','update','benchmark','model','tunnel','urls'): s.add_parser(n)
 a=p.parse_args(); c=a.cmd
 if not c: return status()
 if c=='status': return status()
 if c=='health': return health()
 if c in ('start','stop','restart'):
  return subprocess.run(['systemctl','--user',c,'pennyroyal.service'],check=False).returncode
 if c=='logs': return subprocess.run(['journalctl','--user','-u','pennyroyal.service','-n','100','-f'],check=False).returncode
 if c=='deploy': return run('deploy.sh')
 if c=='benchmark': return run('benchmark.sh')
 if c=='model': return run('40-download-model.sh')
 if c=='update': return subprocess.run(['git','pull','--ff-only'],cwd=ROOT,check=False).returncode
 if c=='urls':
  print('Pennyroyal: http://127.0.0.1:%s' % os.getenv('PENNYROYAL_PORT','8001'))
  print('LiteLLM: http://127.0.0.1:%s' % os.getenv('LITELLM_PORT','4000'))
  print('Grafana: http://127.0.0.1:3000')
  print('Prometheus: http://127.0.0.1:9090')
  print('Dozzle: http://127.0.0.1:8080')
  return 0
 if c=='tunnel': print('Tunnel is disabled by default; configure AUTOSSH_* before enabling.'); return 0
 return 0
if __name__=='__main__': sys.exit(main() or 0)
