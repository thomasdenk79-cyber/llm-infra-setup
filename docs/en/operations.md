# Operations (English short version)

Daily check: `./scripts/doctor.sh --short` (full: `./scripts/doctor.sh`, it
prints the exact next command for every finding).

Full start after a reboot or GPU reconnect: `make deploy-ready`.
Everything except the model runtime: `make deploy-non-gpu`.
Apply repository unit changes safely: `./scripts/apply-runtime-unit.sh`
(it refuses to restart the runtime while requests are running).

## Logs and metrics

The vLLM runtime `flash-next-v3` is an unmanaged container (no unit yet,
see `docs/HANDOFF.md`): `podman logs flash-next-v3`. Everything else runs as a
user unit and logs to the journal, for example
`journalctl --user -u litellm.service -n 200 --no-pager`,
`journalctl --user -u llm-vllm-forwarder.service -n 50 --no-pager`,
`journalctl --user -u llm-proxy.service -n 40 --no-pager` (LAN proxy).
Browser log viewer: Dozzle at http://127.0.0.1:8080 (also via HTTPS, see
[LAN HTTPS access](lan-access.md)); metrics: http://127.0.0.1:9090.

## HTTPS proxy

`make local-proxy` rolls out the proxy; `--plan`, `--check`, `--status`,
`--ca-import`, `--ca-export` and `--print-hosts` are
modes of `./scripts/74-setup-local-proxy.sh`. The command list, the protection
model and the Windows client setup are on the [LAN HTTPS access](lan-access.md)
page; teardown is described there too.

## Benchmarks and backups

Benchmarks measure two numbers separately: time to first token and steady
tokens/s per request (`./scripts/benchmark.sh normal 4`). Why single-request
throughput sits around 120-160 tokens/s on this machine: see
`docs/performance.md` (Thunderbolt x4 link) and `docs/adr/0012-*`.

Backups: `./scripts/backup.sh` (a run with exit code 0 means complete),
inspect with `./scripts/restore.sh --list`, check with
`./scripts/restore.sh --check`.
