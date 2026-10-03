# Operations (English short version)

Daily check: `./scripts/doctor.sh --short`.

Full start after a reboot or GPU reconnect: `make deploy-ready`.
Everything except the model runtime: `make deploy-non-gpu`.
Apply repository unit changes safely: `./scripts/apply-runtime-unit.sh`
(it refuses to restart the runtime while requests are running).

Logs: `journalctl --user -u pennyroyal.service -n 200 --no-pager`,
browser log viewer http://127.0.0.1:8080 (Dozzle), metrics http://127.0.0.1:9090.

Benchmarks measure two numbers separately: time to first token and steady
tokens/s per request (`./scripts/benchmark.sh normal 4`). Why single-request
throughput sits around 120-160 tokens/s on this machine: see
`docs/performance.md` (Thunderbolt x4 link) and `docs/adr/0012-*`.

Backups: `./scripts/backup.sh`, restore with `./scripts/restore.sh`.
